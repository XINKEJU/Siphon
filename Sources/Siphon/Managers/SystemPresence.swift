import AppKit
import UserNotifications

/// macOS-level presence for downloads: a menu-bar item with live progress,
/// a Dock progress tile, and completion/error banners with real actions.
/// Motrix/Persepolis keep the app reachable from the tray; Siphon mirrors that
/// with native AppKit and adds the pieces those ports miss on macOS (Dock
/// progress, Finder-aware notifications, Services).
@MainActor
public final class SystemPresence: NSObject, UNUserNotificationCenterDelegate, NSMenuDelegate {
    public static let shared = SystemPresence()

    private var statusItem: NSStatusItem?
    private weak var store: DownloadStore?
    private var notificationsAuthorized = false
    private var lastNotification: Date = .distantPast
    private var statusHeaderItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var resumeItem: NSMenuItem?

    private enum Category {
        static let clipboard = "CLIPBOARD_DOWNLOAD"
        static let completed = "TASK_COMPLETED"
        static let failed = "TASK_FAILED"
        /// 纯信息通知（网络暂停等）：没有可执行动作，避免行动按钮点了没反应。
        static let notice = "SIPHON_NOTICE"
    }

    private enum ActionID {
        static let clipboardDownload = "CLIPBOARD_DOWNLOAD_ACTION"
        static let reveal = "TASK_REVEAL"
        static let open = "TASK_OPEN"
        static let retry = "TASK_RETRY"
    }

    private enum InfoKey {
        static let taskID = "taskID"
        static let path = "path"
        static let url = "url"
    }

    private override init() { super.init() }

    public func configure(store: DownloadStore) {
        self.store = store
        installStatusItem()
        DockPresence.shared.clear()
        requestNotificationPermission()
    }

    // MARK: - menu bar

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.down.circle",
                                   accessibilityDescription: "Siphon")
            button.imagePosition = .imageLeading
            button.toolTip = "Siphon 下载"
            // 等宽数字：速度从 999 KB/s 跳到 1.0 MB/s 时标题宽度不抖动。
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                           weight: .regular)
        }
        let menu = makeMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 顶部一行实时状态：菜单栏图标只有几个字符，完整信息放这里。
        let header = NSMenuItem(title: "空闲", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        statusHeaderItem = header
        menu.addItem(.separator())

        menu.addItem(withTitle: "显示 Siphon", action: #selector(showMainWindow), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "显示下载弹窗", action: #selector(showPopup), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "新建下载…", action: #selector(newDownload), keyEquivalent: "n")
            .target = self
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: "全部暂停", action: #selector(pauseAll), keyEquivalent: "")
        pause.target = self
        pauseItem = pause
        let resume = menu.addItem(withTitle: "恢复全部", action: #selector(resumeAll), keyEquivalent: "")
        resume.target = self
        resumeItem = resume
        menu.addItem(withTitle: "在访达中打开下载目录", action: #selector(openDownloadFolder), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "退出 Siphon", action: #selector(quit), keyEquivalent: "q")
            .target = self
        return menu
    }

    /// 菜单每次打开都重新计算可用态与实际速度 —— 静态 enabled 的托盘菜单
    /// 会让人点了「全部暂停」却什么都没发生（当时根本没有进行中的任务）。
    nonisolated public func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            guard let store else { return }
            let active = store.tasks.filter { $0.state == .active }
            let speed = active.reduce(Int64(0)) { $0 + $1.progress.speedBytesPerSec }
            if active.isEmpty {
                let paused = store.tasks.filter { $0.state == .paused }.count
                statusHeaderItem?.title = paused > 0 ? "已暂停 \(paused) 个任务" : "空闲"
            } else {
                statusHeaderItem?.title =
                    "\(active.count) 个进行中 · \(MenuBarTitle.compactSpeed(speed))"
            }
            pauseItem?.isEnabled = !active.isEmpty
            resumeItem?.isEnabled = store.tasks.contains {
                $0.state == .paused || $0.state == .error
            }
        }
    }

    /// Recompute the aggregate percentage shown in the menu bar and Dock.
    public func refresh(tasks: [DownloadTask]) {
        let items = tasks.map {
            DockProgressItem(isActive: $0.state == .active,
                             isPaused: $0.state == .paused,
                             totalBytes: $0.progress.totalBytes,
                             downloadedBytes: $0.progress.downloadedBytes)
        }
        let summary = DockProgressModel.summarize(items)
        let style = MenuBarStyle(rawValue: UserDefaults.standard.string(
            forKey: PresenceDefaults.menuBarStyleKey) ?? "") ?? .speed
        let speed = tasks.filter { $0.state == .active }
            .reduce(Int64(0)) { $0 + $1.progress.speedBytesPerSec }

        if let button = statusItem?.button {
            let title = MenuBarTitle.text(style: style, summary: summary, speedBytesPerSec: speed)
            button.title = title.isEmpty ? "" : " " + title
            button.image = NSImage(
                systemSymbolName: summary == nil ? "arrow.down.circle" : "arrow.down.circle.fill",
                accessibilityDescription: "Siphon")
        }

        // Dock：优先画真实进度条；用户关掉时退回旧版的百分比 badge。
        // 两者不同时出现，否则图标上会同时有“进度条 + 数字”两层噪音。
        if PresenceDefaults.bool(PresenceDefaults.dockProgressKey, default: true) {
            NSApp.dockTile.badgeLabel = nil
            DockPresence.shared.update(summary, enabled: true)
        } else {
            DockPresence.shared.clear()
            NSApp.dockTile.badgeLabel = summary?.percentLabel
            NSApp.dockTile.display()
        }
    }

    @objc private func showPopup() {
        guard let store else { return }
        DownloadPopupController.shared.show(store: store)
    }

    @objc private func newDownload() {
        NotificationCenter.default.post(name: .siphonOpenAddSheet, object: nil)
        showMainWindow()
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

    // MARK: - 通知偏好

    private var notificationsEnabled: Bool {
        PresenceDefaults.bool("Siphon.notificationsEnabled", default: true)
    }

    /// Show a plain banner (network paused, clipboard, …) outside the per-task flow.
    public func showNotice(title: String, body: String) {
        guard notificationsAuthorized, notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Category.notice
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "notice-\(UUID().uuidString)", content: content, trigger: nil))
    }

    // MARK: - clipboard detection notification

    private var pendingClipboardURL: URL?

    /// Show a notification offering to download the clipboard URL.
    public func showClipboardNotification(url: URL, filename: String?) {
        guard notificationsAuthorized, notificationsEnabled else { return }

        pendingClipboardURL = url
        let content = UNMutableNotificationContent()
        content.title = "检测到下载链接"
        content.body = filename ?? url.absoluteString
        content.categoryIdentifier = Category.clipboard
        content.sound = .default
        content.userInfo = [InfoKey.url: url.absoluteString]

        let request = UNNotificationRequest(
            identifier: "clipboard-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - notifications

    private func registerCategories() {
        let clipboardDownload = UNNotificationAction(
            identifier: ActionID.clipboardDownload, title: "立即下载", options: [.foreground])
        let clipboardCategory = UNNotificationCategory(
            identifier: Category.clipboard, actions: [clipboardDownload],
            intentIdentifiers: [], options: [])

        // 完成通知的两个动作都直接作用在文件上：下载完还要先切回 App、
        // 再去列表里找那一条，是桌面下载器最没必要的两步。
        let reveal = UNNotificationAction(
            identifier: ActionID.reveal, title: "在访达中显示", options: [])
        let open = UNNotificationAction(
            identifier: ActionID.open, title: "打开文件", options: [.foreground])
        let completedCategory = UNNotificationCategory(
            identifier: Category.completed, actions: [reveal, open],
            intentIdentifiers: [], options: [])

        let retry = UNNotificationAction(
            identifier: ActionID.retry, title: "重试", options: [.foreground])
        let failedCategory = UNNotificationCategory(
            identifier: Category.failed, actions: [reveal, retry],
            intentIdentifiers: [], options: [])

        let noticeCategory = UNNotificationCategory(
            identifier: Category.notice, actions: [],
            intentIdentifiers: [], options: [])

        UNUserNotificationCenter.current().setNotificationCategories(
            [clipboardCategory, completedCategory, failedCategory, noticeCategory])
    }

    private func requestNotificationPermission() {
        // `swift run` has no bundle identifier; UNUserNotificationCenter silently
        // ignores requests without one, so only ask in a real .app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsAuthorized = granted
                if granted { self?.registerCategories() }
            }
        }
    }

    /// Fire at most one banner per second so a burst of failures does not spam
    /// Notification Center.
    public func taskStateChanged(_ task: DownloadTask) {
        guard notificationsAuthorized, notificationsEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastNotification) >= 1 else { return }
        let state = task.state
        guard state == .completed || state == .error else { return }
        lastNotification = now

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = state == .completed ? Category.completed : Category.failed
        content.userInfo = [
            InfoKey.taskID: task.id.uuidString,
            InfoKey.path: task.destination.path,
            InfoKey.url: task.source.absoluteString
        ]
        if state == .completed {
            content.title = "下载完成"
            let size = task.progress.totalBytes > 0
                ? " · \(Formatting.bytes(task.progress.totalBytes))" : ""
            content.body = task.name + size
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
        let info = response.notification.request.content.userInfo
        let path = info[InfoKey.path] as? String
        let fileURL = path.map { URL(fileURLWithPath: $0) }
        let taskID = (info[InfoKey.taskID] as? String).flatMap(UUID.init(uuidString:))

        switch actionId {
        case ActionID.reveal:
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        case ActionID.open:
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                NSWorkspace.shared.open(fileURL)
            }
        case ActionID.retry:
            Task { @MainActor in
                if let taskID { store?.resume(taskID) }
                showMainWindow()
            }
        case ActionID.clipboardDownload:
            if let urlString = info[InfoKey.url] as? String,
               let url = URL(string: urlString) {
                Task { @MainActor in
                    store?.add(urlString: url.absoluteString)
                    showMainWindow()
                }
            }
        default:
            // 点击横幅：完成的任务直接在访达里定位文件（Motrix/gopeed 的做法），
            // 文件已被移走再退回主窗口，避免点开一片空白。
            Task { @MainActor in
                if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } else {
                    if let taskID { store?.selectedTaskIDs = [taskID] }
                    showMainWindow()
                }
            }
        }
        completionHandler()
    }
}

extension Notification.Name {
    /// 菜单栏 / Dock 菜单里「新建下载…」需要把 SwiftUI 的 sheet 翻出来。
    /// 直接持有 `@State` 绑定做不到，交给通知解耦。
    public static let siphonOpenAddSheet = Notification.Name("Siphon.openAddSheet")
}
