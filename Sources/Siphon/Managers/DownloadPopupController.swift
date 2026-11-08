import AppKit
import SwiftUI

/// 无边框悬浮面板：允许成为 key（接收 Esc 与按钮点击），但永不成为 main —
/// 这样它不会顶替主窗口，也不会把整个应用窗口层级翻到最前。
final class DownloadPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 承载 `DownloadPopupView` 的窗口生命周期管理。
///
/// 设计约束（与「新任务弹一次主窗口」的旧行为区分开）：
/// 1. 面板只创建一次，之后复用，避免反复 new NSHostingView 丢掉动画和用户拖放的位置；
/// 2. 默认不激活应用，用 `orderFrontRegardless()` 浮到最前 —— 用户在浏览器里点下载后
///    不会被整窗切换打断，也不会把主窗口翻上来；
/// 3. 只有用户主动从菜单/偏好设置打开时才激活。
@MainActor
public final class DownloadPopupController: NSObject, NSWindowDelegate {
    public static let shared = DownloadPopupController()

    public enum PrefKey {
        /// 新任务出现时自动弹出（默认开）。
        public static let onDownload = "Siphon.popupOnDownload"
        /// 弹出时把 Siphon 切到前台（默认关，避免主窗口一起翻上来）。
        public static let activate = "Siphon.popupActivate"
        /// 全部任务进入终态后自动收起（默认开）。
        public static let autoHide = "Siphon.popupAutoHide"
        /// 用户拖动后的位置，形如 "x,y"。
        static let origin = "Siphon.popupOrigin"
    }

    private var panel: DownloadPopupPanel?
    private let focus = DownloadPopupFocus()
    private weak var store: DownloadStore?
    private var autoHideTimer: Timer?
    private var idleTicks = 0
    private var autoHideArmed = false
    private var keyMonitor: Any?

    private override init() { super.init() }

    // MARK: - 偏好（缺省值集中在这里，避免三处各写一遍）

    public static var showsOnNewDownload: Bool {
        UserDefaults.standard.object(forKey: PrefKey.onDownload) as? Bool ?? true
    }

    public static var activatesOnShow: Bool {
        UserDefaults.standard.object(forKey: PrefKey.activate) as? Bool ?? false
    }

    public static var autoHidesWhenIdle: Bool {
        UserDefaults.standard.object(forKey: PrefKey.autoHide) as? Bool ?? true
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 对外入口

    /// 新任务路径：只有「新下载」才弹，启动恢复不经过这里。
    public func present(taskID: UUID?, store: DownloadStore) {
        guard Self.showsOnNewDownload else { return }
        self.store = store
        focus.taskID = taskID
        autoHideArmed = true
        idleTicks = 0
        showPanel(activating: Self.activatesOnShow)
        startAutoHideTimer()
    }

    /// 用户主动打开（菜单 / 偏好设置 / 菜单栏）：这一次允许激活并取消自动收起。
    public func show(store: DownloadStore, activate: Bool = true) {
        self.store = store
        autoHideArmed = false
        stopAutoHideTimer()
        showPanel(activating: activate)
    }

    public func toggle(store: DownloadStore) {
        if isVisible { hide() } else { show(store: store) }
    }

    public func hide() {
        stopAutoHideTimer()
        removeKeyMonitor()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    // MARK: - 面板构建

    private func showPanel(activating: Bool) {
        guard let store else { return }
        let panel = self.panel ?? makePanel(store: store)
        self.panel = panel

        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            var frame = panel.frame
            let target = targetOrigin(for: frame.size)
            frame.origin = NSPoint(x: target.x, y: target.y - 12)
            panel.setFrame(frame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                var end = frame
                end.origin = target
                panel.animator().setFrame(end, display: true)
            }
        }

        if activating {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        installKeyMonitor()
    }

    private func makePanel(store: DownloadStore) -> DownloadPopupPanel {
        let rect = NSRect(x: 0, y: 0,
                          width: DownloadPopupView.width,
                          height: DownloadPopupView.height)
        let panel = DownloadPopupPanel(contentRect: rect,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered,
                                       defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        // 全屏浏览器里也要浮得出来：canJoinAllSpaces + fullScreenAuxiliary。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 窗口本身保留透明通道，只为让 16pt 圆角外侧能干净地透出桌面（否则会
        // 出现方形黑角）。真正的内容底板由 `PopupSurface` 画成实心底色，
        // 因此视觉上完全不透明，不会有「毛玻璃透出背景」的效果。
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.delegate = self

        let root = DownloadPopupView(focus: focus,
                                     onClose: { [weak self] in self?.hide() },
                                     onOpenMain: { [weak self] in self?.openMainWindow() })
            .environment(store)
        let host = NSHostingView(rootView: root)
        host.frame = rect
        panel.contentView = host
        return panel
    }

    // MARK: - 位置

    private func targetOrigin(for size: CGSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: PrefKey.origin) {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                let p = NSPoint(x: parts[0], y: parts[1])
                // 显示器布局变了就退回默认位置，别把窗口丢到不存在的屏幕上。
                if NSScreen.screens.contains(where: {
                    $0.visibleFrame.insetBy(dx: -60, dy: -60).contains(p)
                }) {
                    return p
                }
            }
        }
        // 优先跟随鼠标所在屏幕（用户刚在哪个屏幕点的下载）。
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 20,
                       y: visible.minY + 20)
    }

    public func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: PrefKey.origin)
    }

    // MARK: - 主窗口

    private func openMainWindow() {
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }

    // MARK: - Esc 收起

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - 完成后自动收起

    private func startAutoHideTimer() {
        guard Self.autoHidesWhenIdle else { return }
        stopAutoHideTimer()
        idleTicks = 0
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopAutoHideTimer() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    private func tick() {
        guard autoHideArmed, let store, panel?.isVisible == true else { return }
        let busy = store.tasks.contains { $0.state == .active || $0.state == .pending }
        if busy {
            idleTicks = 0
            return
        }
        idleTicks += 1
        // 留 4 秒让用户看到「已完成 / 失败」，再收起，避免闪一下就消失。
        if idleTicks >= 4 { hide() }
    }
}
