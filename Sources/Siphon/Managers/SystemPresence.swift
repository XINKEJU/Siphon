import AppKit
import UserNotifications

/// macOS-level presence for downloads: a menu-bar item with live progress,
/// a Dock badge, and completion/error banners. Motrix/Persepolis keep the app
/// reachable from the tray; Siphon mirrors that with native AppKit.
@MainActor
public final class SystemPresence: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = SystemPresence()

    private var statusItem: NSStatusItem?
    private weak var store: DownloadStore?
    private var notificationsAuthorized = false
    private var lastNotification: Date = .distantPast

    private override init() { super.init() }

    public func configure(store: DownloadStore) {
        self.store = store
        installStatusItem()
        requestNotificationPermission()
    }

    // MARK: - menu bar

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                   accessibilityDescription: "Siphon")
            button.imagePosition = .imageLeading
            button.toolTip = "Siphon 下载"
        }
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "显示 Siphon", action: #selector(showMainWindow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "全部暂停", action: #selector(pauseAll), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "恢复全部", action: #selector(resumeAll), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "在访达中打开下载目录", action: #selector(openDownloadFolder), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Siphon", action: #selector(quit), keyEquivalent: "q")
            .target = self
        return menu
    }

    /// Recompute the aggregate percentage shown in the menu bar and Dock.
    public func refresh(tasks: [DownloadTask]) {
        let active = tasks.filter { $0.state == .active }
        guard !active.isEmpty else {
            statusItem?.button?.title = ""
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let total = active.reduce(Int64(0)) { $0 + $1.progress.totalBytes }
        let done = active.reduce(Int64(0)) { $0 + $1.progress.downloadedBytes }
        let text: String
        if total > 0 {
            text = "\(Int(Double(done) / Double(total) * 100))%"
        } else {
            text = "\(active.count)"
        }
        statusItem?.button?.title = " " + text
        NSApp.dockTile.badgeLabel = text
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { $0.identifier?.rawValue.contains("main-window") == true }
            ?? NSApp.windows.first { $0.canBecomeMain }
        main?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    @objc private func pauseAll() {
        guard let store else { return }
        for t in store.tasks where t.state == .active || t.state == .pending {
            store.pause(t.id)
        }
    }

    @objc private func resumeAll() {
        guard let store else { return }
        for t in store.tasks where t.state == .paused || t.state == .error {
            store.resume(t.id)
        }
    }

    @objc private func openDownloadFolder() {
        guard let store else { return }
        NSWorkspace.shared.open(store.downloadDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - clipboard detection notification

    private static let clipboardNotificationCategory = "CLIPBOARD_DOWNLOAD"
    nonisolated private static let clipboardDownloadAction = "CLIPBOARD_DOWNLOAD_ACTION"
    private var pendingClipboardURL: URL?

    /// Show a notification offering to download the clipboard URL.
    public func showClipboardNotification(url: URL, filename: String?) {
        guard notificationsAuthorized else { return }
        let key = "Siphon.notificationsEnabled"
        let enabled = UserDefaults.standard.object(forKey: key) == nil
            || UserDefaults.standard.bool(forKey: key)
        guard enabled else { return }

        pendingClipboardURL = url
        let content = UNMutableNotificationContent()
        content.title = "检测到下载链接"
        content.body = filename ?? url.absoluteString
        content.categoryIdentifier = Self.clipboardNotificationCategory
        content.sound = .default
        content.userInfo = ["url": url.absoluteString]

        let request = UNNotificationRequest(
            identifier: "clipboard-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func registerClipboardCategory() {
        let downloadAction = UNNotificationAction(
            identifier: Self.clipboardDownloadAction,
            title: "立即下载",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.clipboardNotificationCategory,
            actions: [downloadAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - notifications

    private func requestNotificationPermission() {
        // `swift run` has no bundle identifier; UNUserNotificationCenter silently
        // ignores requests without one, so only ask in a real .app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsAuthorized = granted
                if granted { self?.registerClipboardCategory() }
            }
        }
    }

    /// Fire at most one banner per second so a burst of failures does not spam
    /// Notification Center.
    public func taskStateChanged(_ task: DownloadTask) {
        guard notificationsAuthorized else { return }
        // Respect user toggle (default on).
        let key = "Siphon.notificationsEnabled"
        let enabled = UserDefaults.standard.object(forKey: key) == nil
            || UserDefaults.standard.bool(forKey: key)
        guard enabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastNotification) >= 1 else { return }
        let state = task.state
        guard state == .completed || state == .error else { return }
        lastNotification = now

        let content = UNMutableNotificationContent()
        content.sound = .default
        if state == .completed {
            content.title = "下载完成"
            content.body = task.name
        } else {
            content.title = "下载失败"
            content.body = "\(task.name)\n\(task.errorDescription ?? "未知错误")"
        }
        let request = UNNotificationRequest(identifier: task.id.uuidString,
                                           content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        if actionId == Self.clipboardDownloadAction,
           let urlString = userInfo["url"] as? String,
           let url = URL(string: urlString) {
            Task { @MainActor in
                store?.add(urlString: url.absoluteString)
                showMainWindow()
            }
        } else {
            Task { @MainActor in self.showMainWindow() }
        }
        completionHandler()
    }
}
