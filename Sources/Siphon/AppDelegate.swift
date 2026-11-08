import AppKit
import SwiftUI

/// Handles real application-level lifecycle events. View `onDisappear` is not a
/// reliable place to stop the download daemon — it also fires during navigation
/// changes and when auxiliary windows gain focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DownloadStore?
    /// 进程级单实例锁：两个实例同时写 tasks.json 会互相覆盖。
    private var instanceLock: NSDistributedLock?

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

        // 防御：某些异常退出（或 NSDistributedLock 的边界行为）会把锁路径留成一个
        // 空目录。目录永远无法成为 distributed lock，之后每次启动都会误报
        // 「Siphon 已在运行」并退出 —— 直接清掉这种坏锁。
        var lockIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: lockPath, isDirectory: &lockIsDir),
           lockIsDir.boolValue {
            try? FileManager.default.removeItem(atPath: lockPath)
        }

        // Check for stale lock: read PID from lock file and verify process exists
        if let existingData = FileManager.default.contents(atPath: lockPath),
           let pidString = String(data: existingData, encoding: .utf8),
           let pid = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // Check if process is still running
            if kill(pid, 0) != 0 && errno == ESRCH {
                // Process not running — stale lock, remove it
                try? FileManager.default.removeItem(atPath: lockPath)
            } else {
                // Process is still running — another instance exists
                let alert = NSAlert()
                alert.messageText = "Siphon 已在运行"
                alert.informativeText = "同时运行两个实例会互相覆盖任务列表，请切换到已打开的窗口。"
                alert.addButton(withTitle: "好")
                alert.runModal()
                return false
            }
        }

        // Try to acquire NSDistributedLock as backup
        guard let lock = NSDistributedLock(path: lockPath),
              lock.try() else {
            let alert = NSAlert()
            alert.messageText = "Siphon 已在运行"
            alert.informativeText = "同时运行两个实例会互相覆盖任务列表，请切换到已打开的窗口。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return false
        }

        // Write our PID so future instances can detect stale locks
        let pidData = "\(ProcessInfo.processInfo.processIdentifier)\n".data(using: .utf8)
        try? pidData?.write(to: URL(fileURLWithPath: lockPath))
        instanceLock = lock
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
        instanceLock?.unlock()
        instanceLock = nil
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
