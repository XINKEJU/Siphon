import AppKit

/// 把下载进度画进 Dock 图标。
///
/// macOS 没有 Electron `setProgressBar` 那样的系统 API：想要与「下载器」身份
/// 匹配的真实进度条，只能接管 `NSApp.dockTile.contentView` 自己画。接管后必须
/// **自己把应用图标画出来**，否则 Dock 上会只剩一条进度条。
@MainActor
public final class DockPresence {
    public static let shared = DockPresence()

    private var tileView: DockProgressTile?
    private var lastUpdate: Date = .distantPast
    private var lastSummary: DockProgressSummary?

    private init() {}

    /// `enabled == false` 或 `summary == nil` 时移除接管、清空 badge，
    /// 让 Dock 回到系统默认的样子。
    public func update(_ summary: DockProgressSummary?, enabled: Bool) {
        guard enabled, let summary else {
            clear()
            return
        }
        // 进度刷新可能每秒好几次；Dock 重绘是 GPU 合成，没必要跟着每帧走。
        // 0.4 秒或 0.5% 的阈值肉眼不可辨，但能省掉大量无意义重绘。
        let now = Date()
        if let lastSummary,
           now.timeIntervalSince(lastUpdate) < 0.4,
           abs(lastSummary.fraction - summary.fraction) < 0.005,
           lastSummary.isPausedOnly == summary.isPausedOnly {
            return
        }
        lastUpdate = now
        lastSummary = summary
        let view: DockProgressTile
        if let existing = tileView {
            view = existing
        } else {
            // Dock 图块默认 128×128 点；沿用系统尺寸，Retina 下由 AppKit 放大。
            let size = NSSize(width: 128, height: 128)
            view = DockProgressTile(frame: NSRect(origin: .zero, size: size))
            NSApp.dockTile.contentView = view
            tileView = view
        }
        view.summary = summary
        NSApp.dockTile.display()
    }

    public func clear() {
        lastUpdate = .distantPast
        lastSummary = nil
        guard tileView != nil else {
            if NSApp.dockTile.badgeLabel != nil {
                NSApp.dockTile.badgeLabel = nil
                NSApp.dockTile.display()
            }
            return
        }
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
        tileView = nil
    }
}

/// 图标 + 底部进度条。用实色而不是材质：Dock 背景可能是任意壁纸，
/// 半透明轨道在浅色壁纸上会直接消失。
final class DockProgressTile: NSView {
    var summary: DockProgressSummary? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // contentView 取代了整个图块，应用图标必须自己画。
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let summary else { return }

        let inset: CGFloat = 10
        let barHeight: CGFloat = 9
        let bar = NSRect(x: inset,
                         y: 8,
                         width: max(0, bounds.width - inset * 2),
                         height: barHeight)
        guard bar.width > barHeight else { return }
        let radius = barHeight / 2

        let track = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
        NSColor(white: 0, alpha: 0.5).setFill()
        track.fill()
        NSColor(white: 1, alpha: 0.28).setStroke()
        track.lineWidth = 1
        track.stroke()

        // 总大小未知时画一段固定长度，表示“在跑但没法给出比例”，
        // 比一直空着或假装 100% 都更接近真实。
        let fraction = summary.isIndeterminate ? 0.32 : max(summary.fraction, summary.fraction > 0 ? 0.045 : 0)
        guard fraction > 0 else { return }
        let fillWidth = max(barHeight, bar.width * fraction)
        let fillRect = NSRect(x: bar.minX, y: bar.minY, width: fillWidth, height: bar.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        (summary.isPausedOnly ? NSColor(white: 0.86, alpha: 0.92) : NSColor.controlAccentColor).setFill()
        fill.fill()
    }
}
