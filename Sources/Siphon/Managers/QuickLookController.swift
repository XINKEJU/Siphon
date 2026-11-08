import AppKit
import Quartz

/// 空格快速查看（Quick Look）。没有它，macOS 用户按空格会以为应用坏了 ——
/// 这是访达里最根深蒂固的肌肉记忆之一。
///
/// 直接驱动共享的 `QLPreviewPanel`：它是系统面板，天然支持缩放、多选翻页、
/// 视频播放与「用其他应用打开」，不需要自绘任何预览界面。
@MainActor
public final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookController()

    private var urls: [URL] = []

    private override init() { super.init() }

    public var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    public func toggle(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if isOpen, self.urls == urls {
            dismiss()
        } else {
            present(urls: urls)
        }
    }

    public func present(urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    public func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }

    // MARK: - QLPreviewPanelDataSource
    //
    // 面板在 main run loop 上回调，但协议本身没有 MainActor 标注，
    // 因此必须显式声明 isolation，避免 Swift 6 报「跨 actor 访问」。

    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!,
                                         previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { () -> QLPreviewItem? in
            guard urls.indices.contains(index) else { return nil }
            return urls[index] as NSURL
        }
    }
}
