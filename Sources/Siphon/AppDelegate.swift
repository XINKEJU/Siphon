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
        if !flag { showMainWindow() }
        return true
    }

    /// 尝试获取单实例锁；已有实例运行时提示并返回 false。
    private func acquireInstanceLock() -> Bool {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Siphon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let lock = NSDistributedLock(
            path: dir.appendingPathComponent("app.lock").path),
              lock.try() else {
            let alert = NSAlert()
            alert.messageText = "Siphon 已在运行"
            alert.informativeText = "同时运行两个实例会互相覆盖任务列表，请切换到已打开的窗口。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return false
        }
        instanceLock = lock
        return true
    }

    private func showMainWindow() {
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
        // Handles magnet: / ed2k: URL schemes and dropped .torrent / .metalink files.
        for url in urls {
            store?.add(urlString: url.absoluteString)
        }
    }
}
