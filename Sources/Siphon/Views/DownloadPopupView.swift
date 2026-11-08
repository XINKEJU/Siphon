import SwiftUI
import AppKit

/// NDM 风格「下载弹窗」的焦点状态。
///
/// AppKit 窗口只创建一次（避免反复新建 NSHostingView 丢掉动画与用户拖动的
/// 位置），新任务到来时只更新这个可观察对象，SwiftUI 侧就能换到新任务。
@MainActor
@Observable
final class DownloadPopupFocus {
    var taskID: UUID?
}

/// 检测到新下载时浮出的紧凑窗口内容：实时速度概览、总进度、当前任务的
/// 分段进度，以及最近任务的快速切换。与完整主窗口互不包含，也不复用它的
/// 侧边栏 / 筛选 / 设置等界面。
struct DownloadPopupView: View {
    @Environment(DownloadStore.self) private var store
    let focus: DownloadPopupFocus
    let onClose: () -> Void
    let onOpenMain: () -> Void

    static let width: CGFloat = 400
    static let height: CGFloat = 468

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 15) {
                    if store.tasks.isEmpty {
                        emptyState
                    } else {
                        speedOverview
                        overallProgress
                        focusCard
                        otherTasks
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background { PopupSurface() }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Header (window is movable by its background)

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Siphon 下载").font(.system(size: 12, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { onOpenMain() } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开 Siphon 完整主窗口")

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收起这个弹窗（下载继续进行）")
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .background(Color.primary.opacity(0.04))
    }

    private var headerSubtitle: String {
        let active = store.tasks.filter { $0.state == .active }.count
        let pending = store.tasks.filter { $0.state == .pending }.count
        if active > 0 { return "\(active) 个正在下载" + (pending > 0 ? " · \(pending) 个排队中" : "") }
        if pending > 0 { return "\(pending) 个排队中" }
        let done = store.tasks.filter { $0.state == .completed }.count
        return done > 0 ? "\(done) 个已完成" : "暂无进行中的任务"
    }

    // MARK: - 实时速度概览

    private var speedOverview: some View {
        let history = store.speedHistory
        let peak = history.max() ?? 0
        let average = history.isEmpty ? 0 : history.reduce(Int64(0), +) / Int64(history.count)
        let active = store.tasks.filter { $0.state == .active }.count
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("实时速度").font(.caption).foregroundStyle(.secondary)
                    Text(Formatting.speed(store.aggregateSpeed))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                PopupSparkline(samples: history)
                    .frame(width: 132, height: 40)
            }
            HStack(spacing: 10) {
                Text("峰值 \(Formatting.speed(peak))")
                Text("平均 \(Formatting.speed(average))")
                Text("\(active) 个活动中")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    // MARK: - 总进度（所有活动任务字节合计）

    private var overallProgress: some View {
        let active = store.tasks.filter { $0.state == .active || $0.state == .pending }
        let done = active.reduce(Int64(0)) { $0 + $1.progress.downloadedBytes }
        let total = active.reduce(Int64(0)) { $0 + $1.progress.totalBytes }
        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
        let speed = store.aggregateSpeed
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("总进度").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(total > 0 ? Formatting.percent(fraction) : "大小未知")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            PopupProgressTrack(fraction: total > 0 ? fraction : nil)
            HStack(spacing: 8) {
                Text("\(Formatting.bytes(done)) / \(total > 0 ? Formatting.bytes(total) : "—")")
                Spacer()
                Text(total > 0 ? "剩余 \(Formatting.eta(downloaded: done, total: total, speed: speed))" : "正在获取文件大小")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(11)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 当前任务：总进度 + 分段进度

    @ViewBuilder
    private var focusCard: some View {
        if let task = focusTask {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: icon(for: task))
                        .font(.system(size: 13))
                        .foregroundStyle(tint(for: task))
                    Text(task.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(task.state.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Formatting.speed(task.progress.speedBytesPerSec))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(Formatting.percent(task.progress.percent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Formatting.bytes(task.progress.downloadedBytes)) / \(task.progress.totalBytes > 0 ? Formatting.bytes(task.progress.totalBytes) : "—")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                PopupProgressTrack(fraction: task.progress.totalBytes > 0 ? task.progress.percent : nil)

                Text("分段进度").font(.caption2).foregroundStyle(.secondary)
                PopupSegmentBar(taskID: task.id, connectionCount: task.connections)

                if let error = task.errorDescription, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(11)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 最近任务（点击切换焦点）

    @ViewBuilder
    private var otherTasks: some View {
        let recent = Array(store.tasks.suffix(6).reversed())
        if recent.count > 1 {
            VStack(alignment: .leading, spacing: 5) {
                Text("最近任务").font(.caption).foregroundStyle(.secondary)
                ForEach(recent) { task in
                    PopupTaskRow(task: task, isFocused: task.id == focusTask?.id) {
                        focus.taskID = task.id
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("还没有下载任务")
                .font(.headline)
            Text("浏览器接管、剪贴板链接或手动新建下载后，这里会立即显示速度、总进度和分段进度。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { toggleFocusedTask() } label: {
                Label(canPauseFocused ? "暂停" : "继续",
                      systemImage: canPauseFocused ? "pause.fill" : "play.fill")
            }
            .disabled(!canPauseFocused && !canResumeFocused)

            Button { revealFocusedTask() } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            .disabled(focusTask == nil)

            Spacer(minLength: 4)

            Button { onOpenMain() } label: {
                Label("主窗口", systemImage: "arrow.up.right.square")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 13)
        .frame(height: 42)
    }

    // MARK: - Derived state / actions

    private var focusTask: DownloadTask? {
        if let id = focus.taskID, let task = store.tasks.first(where: { $0.id == id }) {
            return task
        }
        return store.tasks.last { $0.state == .active } ?? store.tasks.last
    }

    private var canPauseFocused: Bool {
        guard let s = focusTask?.state else { return false }
        return s == .active || s == .pending
    }

    private var canResumeFocused: Bool {
        guard let s = focusTask?.state else { return false }
        return s == .paused || s == .error
    }

    private func toggleFocusedTask() {
        guard let task = focusTask else { return }
        if canPauseFocused { store.pause(task.id) } else { store.resume(task.id) }
    }

    private func revealFocusedTask() {
        guard let task = focusTask else { return }
        NSWorkspace.shared.activateFileViewerSelecting([task.destination])
    }

    private func icon(for task: DownloadTask) -> String {
        switch task.state {
        case .active: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        default: return "clock.circle"
        }
    }

    private func tint(for task: DownloadTask) -> Color {
        switch task.state {
        case .active: return .accentColor
        case .completed: return .green
        case .error: return .red
        case .paused: return .orange
        default: return .secondary
        }
    }
}

// MARK: - 弹窗底色（实心，不透明）

/// 弹窗底板：**完全不透明**，不再使用 `.bar` / `NSVisualEffectView` 这类材质，
/// 否则桌面和浏览器会透过来，看起来像一块悬空的毛玻璃。
/// 只用系统语义色，浅色与深色模式自动跟随；顶部的轻微渐变叠在不透明底色之上，
/// 最终合成结果仍然 100% 不透明，只用来给标题栏一点层次。
private struct PopupSurface: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.primary.opacity(0.05), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - 速度曲线

private struct PopupSparkline: View {
    let samples: [Int64]

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }
            let peak = max(samples.max() ?? 1, Int64(1))
            let w = size.width
            let h = size.height
            let step = w / CGFloat(samples.count - 1)
            var line = Path()
            for (i, v) in samples.enumerated() {
                let x = CGFloat(i) * step
                let y = h - max(1, CGFloat(v) / CGFloat(peak) * (h - 2))
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            var area = line
            area.addLine(to: CGPoint(x: w, y: h))
            area.addLine(to: CGPoint(x: 0, y: h))
            area.closeSubpath()
            let gradient = Gradient(colors: [Color.accentColor.opacity(0.28),
                                             Color.accentColor.opacity(0)])
            ctx.fill(area, with: .linearGradient(gradient,
                                                 startPoint: CGPoint(x: 0, y: 0),
                                                 endPoint: CGPoint(x: 0, y: h)))
            ctx.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
        }
    }
}

// MARK: - 总进度条（未知大小时显示流动条纹）

private struct PopupProgressTrack: View {
    let fraction: Double?   // nil = indeterminate

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                if let fraction {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
                        .animation(.easeInOut(duration: 0.35), value: fraction)
                } else {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: geo.size.width * 0.22)
                        .modifier(IndeterminateSlide(containerWidth: geo.size.width))
                }
            }
        }
        .frame(height: 8)
    }
}

private struct IndeterminateSlide: ViewModifier {
    let containerWidth: CGFloat
    @State private var atEnd = false

    func body(content: Content) -> some View {
        content
            .offset(x: atEnd ? containerWidth * 0.78 : 0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: atEnd)
            .onAppear { atEnd = true }
    }
}

// MARK: - 分段进度（每 0.5 秒从引擎拉一次真实快照）

private struct PopupSegmentBar: View {
    @Environment(DownloadStore.self) private var store
    let taskID: UUID
    let connectionCount: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let segments = Array(store.segmentSnapshot(for: taskID).filter(\.knownEnd).prefix(64))
            if segments.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "minus.circle").font(.caption2)
                    Text("该引擎不提供分段数据（单路或外部进程传输）")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(height: 16, alignment: .leading)
            } else {
                let total = max(1, segments.reduce(0) { $0 + Double($1.span) })
                let finished = segments.filter { $0.fraction >= 0.999 }.count
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        HStack(spacing: 1.5) {
                            ForEach(segments) { s in
                                let width = max(2, geo.size.width * Double(s.span) / total - 1.5)
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.16))
                                    Capsule().fill(Color.accentColor)
                                        .frame(width: width * s.fraction)
                                }
                                .frame(width: width)
                            }
                        }
                    }
                    .frame(height: 11)
                    HStack(spacing: 9) {
                        Text("分段 \(segments.count)")
                        Text("已完成 \(finished)")
                        Spacer()
                        Text("连接 \(connectionCount)")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 16)
    }
}

// MARK: - 最近任务行

private struct PopupTaskRow: View {
    let task: DownloadTask
    let isFocused: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: task.state == .active ? "arrow.down.circle.fill"
                      : task.state == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                Text(task.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isFocused ? .primary : .secondary)
                Spacer(minLength: 4)
                Text(task.state == .active
                     ? Formatting.speed(task.progress.speedBytesPerSec)
                     : Formatting.percent(task.progress.percent))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
