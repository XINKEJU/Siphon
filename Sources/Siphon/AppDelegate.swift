import AppKit
import Darwin
import SwiftUI

/// Handles real application-level lifecycle events. View `onDisappear` is not a
/// reliable place to stop the download daemon — it also fires during navigation
/// changes and when auxiliary windows gain focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DownloadStore?
    /// 进程级单实例锁：两个实例同时写 tasks.json 会互相覆盖。
    /// 用 flock(2) 而不是 NSDistributedLock：后者把锁表示成一个目录，进程被
    /// SIGKILL 后目录会留下，下一次启动 `try()` 永远失败并被误判成「已在运行」；
    /// 反过来，为了绕开这种坏锁去删目录，又会把正在运行实例的锁删掉。
    /// flock 由内核在进程退出时释放，两个方向都不会留残渣。
    private var instanceLockFD: Int32 = -1

    override init() {
        super.init()
        // A download manager is a single-window app. Without this, macOS can
        // merge extra WindowGroup windows into tabs and stack translucent
        // columns on top of each other.
        NSWindow.allowsAutomaticWindowTabbing = false
        // After a self-update relaunch, the superseded <App>.old bundle lingers.
        cleanupUpdateBackups()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Background residency (menu-bar download manager), off by default.
        return !UserDefaults.standard.bool(forKey: "Siphon.backgroundRun")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        if UserDefaults.standard.bool(forKey: "Siphon.menuBarOnly") {
            // Menu-bar-only mode keeps residency even without a Dock icon.
            UserDefaults.standard.set(true, forKey: "Siphon.backgroundRun")
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // 下载弹窗也是一个可见窗口，不能因为它在就算「主窗口已打开」——
        // 否则主窗口关掉、弹窗还在时，点 Dock 图标不会有任何反应。
        let mainVisible = NSApp.windows.contains {
            $0.identifier?.rawValue.contains("main-window") == true && $0.isVisible
        }
        if !mainVisible { showMainWindow() }
        return true
    }

    /// 尝试获取单实例锁；已有实例运行时提示并返回 false。
    private func acquireInstanceLock() -> Bool {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Siphon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent("app.lock").path

        // 旧版本用 NSDistributedLock，锁就是个目录；升级后第一次启动会撞见它。
        // 那是死锁残留（旧代码从没能往里写过 PID），改名备份而不是删除，避免
        // 万一还有旧实例在跑时把别人的锁拆了。
        var lockIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: lockPath, isDirectory: &lockIsDir),
           lockIsDir.boolValue {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(atPath: lockPath,
                                              toPath: "\(lockPath).legacy-\(stamp)")
        }

        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // 拿不到锁文件（权限/磁盘异常）时不该把用户挡在门外：任务列表的
            // 并发写入还有 save() 的原子替换兜底。
            NSLog("Siphon: cannot open instance lock at %@ (errno %d)", lockPath, errno)
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            let alert = NSAlert()
            alert.messageText = "Siphon 已在运行"
            alert.informativeText = "同时运行两个实例会互相覆盖任务列表，请切换到已打开的窗口。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return false
        }

        // 记下 PID 便于排查；锁的权威性来自 flock，不靠这个数字。
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        pid.withCString { _ = write(fd, $0, strlen($0)) }
        instanceLockFD = fd
        return true
    }

    /// 主窗口的唯一打开路径：菜单栏、Dock 重新激活、下载弹窗的「主窗口」按钮
    /// 都走这里，避免三份各自实现的窗口查找逻辑逐步漂移。
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { $0.identifier?.rawValue.contains("main-window") == true }
            ?? NSApp.windows.first { $0.canBecomeMain }
        main?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
        TransferStats.shared.flush()
        if instanceLockFD >= 0 {
            // 显式解锁不是必需的（进程退出内核就会释放），但能让紧接着的
            // 自更新重启立刻拿到锁，不必等本进程完全消失。
            _ = flock(instanceLockFD, LOCK_UN)
            close(instanceLockFD)
            instanceLockFD = -1
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handles magnet: / ed2k: / siphon: URL schemes and dropped .torrent / .metalink files.
        for url in urls {
            if url.scheme?.lowercased() == "siphon" {
                handleSiphonURL(url)
            } else {
                store?.add(urlString: url.absoluteString)
            }
        }
    }

    /// Parse siphon:// control URLs:
    ///   siphon://add?url=<encoded>  → add download
    ///   siphon://pause              → pause all
    ///   siphon://resume             → resume all
    ///   siphon://popup              → show the compact download popup
    ///   siphon://show               → show main window
    private func handleSiphonURL(_ url: URL) {
        let host = url.host?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        switch host {
        case "add":
            if let urlString = queryItems.first(where: { $0.name == "url" })?.value,
               !urlString.isEmpty {
                // siphon:// URL scheme gets a priority boost.
                // 不再顺带把主窗口翻到最前：新任务的反馈统一交给紧凑浮窗，
                // 否则「点一个链接」会连带整窗跳到前台（NDM 也不会这样）。
                Task { @MainActor in store?.add(urlString: urlString, priority: 1) }
            }
        case "popup":
            let current = store
            Task { @MainActor in
                if let current { DownloadPopupController.shared.show(store: current) }
            }
        case "pause":
            Task { @MainActor in store?.pauseAll() }
        case "resume":
            Task { @MainActor in store?.resumeAll() }
        case "show":
            showMainWindow()
        default:
            showMainWindow()
        }
    }
}
