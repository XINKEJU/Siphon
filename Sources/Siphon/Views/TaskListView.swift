import SwiftUI
import AppKit

/// Task list with a floating Liquid Glass command bar.
///
/// The list itself is deliberately opaque: glass belongs above content, not
/// behind text and progress bars. The command bar is a single
/// `GlassEffectContainer`, so its pills share one lens system and morph into
/// each other when quick actions expand/collapse (macOS 26+).
struct TaskListView: View {
    @EnvironmentObject private var store: DownloadStore
    @Binding var selection: SidebarItem
    @State private var selectedID: UUID?
    @State private var controlsExpanded = false
    @Namespace private var glassNamespace

    private var visible: [DownloadTask] {
        switch selection {
        case .all: return store.tasks
        case .downloading: return store.tasks.filter { $0.state == .active || $0.state == .pending }
        case .completed: return store.tasks.filter { $0.state == .completed }
        case .paused: return store.tasks.filter { $0.state == .paused }
        case .queue(let name): return store.tasks.filter { $0.queueName == name }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            listContent
            floatingControls
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .onChange(of: selectedID) { _, newValue in
            store.selectedTaskID = newValue
        }
    }

    // MARK: - Content layer (never glass)

    @ViewBuilder
    private var listContent: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("没有任务", systemImage: "tray")
                } description: {
                    Text("点按工具栏的「+」添加下载，或开启剪贴板监听自动捕获链接。")
                }
            } else {
                List(selection: $selectedID) {
                    ForEach(visible) { task in
                        TaskRowView(task: task)
                            .tag(task.id)
                            .contextMenu { contextMenu(for: task) }
                    }
                }
                // macOS 27 paints alternating row backgrounds across the whole
                // visible scroll area (including empty space), which looks like
                // a stack of phantom tasks. Plain inset keeps only real rows.
                .listStyle(.inset)
                // Content softly fades under the translucent toolbar / bar.
                .softScrollTopEdge()
            }
        }
        // Reserve space for the floating glass bar in BOTH states — the empty
        // state is centred, so without this its description sits under the bar.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 76)
        }
        // Fill the whole content column so the ZStack's bottom alignment really
        // is the window bottom; otherwise the bar floats in the middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Floating glass layer

    @ViewBuilder
    private var floatingControls: some View {
        GlassGroup(spacing: 10) {
            if let e = store.startupError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(e).font(.caption).lineLimit(1)
                    Button("重试") { store.restartAria2() }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassPill(tint: .orange.opacity(0.16))
                .glassMorphID("error", in: glassNamespace)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 7, height: 7)
                Text(store.aria2Status)
                Text("·").foregroundStyle(.tertiary)
                Text(Formatting.speed(store.aggregateSpeed))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassPill()
            .glassMorphID("status", in: glassNamespace)

            Button {
                withAnimation(.smooth) { controlsExpanded.toggle() }
            } label: {
                Image(systemName: controlsExpanded ? "xmark" : "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(9)
            .glassCircle()
            .glassMorphID("more", in: glassNamespace)
            .help(controlsExpanded ? "收起快捷操作" : "展开快捷操作")

            if controlsExpanded {
                Button {
                    for t in store.tasks where t.state == .paused || t.state == .error {
                        store.resume(t.id)
                    }
                } label: {
                    Label("恢复全部", systemImage: "play.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassPill(interactive: true)
                .glassMorphID("resume-all", in: glassNamespace)
                .glassMorphTransition()

                Button {
                    store.removeCompleted()
                } label: {
                    Label("清理已完成", systemImage: "trash").font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassPill(interactive: true)
                .glassMorphID("clean", in: glassNamespace)
                .glassMorphTransition()
            }
        }
        .animation(.smooth, value: controlsExpanded)
    }

    private var statusTint: Color {
        store.aria2Status == "已停止" || store.aria2Status == "aria2 不可用"
            ? .red : .green
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for task: DownloadTask) -> some View {
        if task.state == .active || task.state == .pending {
            Button("暂停") { store.pause(task.id) }
        }
        if task.state == .paused || task.state == .error {
            Button("继续") { store.resume(task.id) }
        }
        if task.state == .completed {
            Button("在访达中显示") { reveal(task) }
        }
        Divider()
        Button("拷贝链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.source.absoluteString, forType: .string)
        }
        Button("移除", role: .destructive) { store.remove(task.id) }
    }

    private func reveal(_ task: DownloadTask) {
        NSWorkspace.shared.activateFileViewerSelecting([task.destination])
    }
}

struct TaskRowView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 19))
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProtocolBadge(proto: task.protocol)
                }

                if task.state == .active || task.state == .pending {
                    ProgressView(value: task.progress.percent)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }

                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if task.state == .error, let e = task.errorDescription {
                        Text(e)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Spacer()
                    if task.state == .active {
                        Text(Formatting.speed(task.progress.speedBytesPerSec))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(Formatting.eta(downloaded: task.progress.downloadedBytes,
                                            total: task.progress.totalBytes,
                                            speed: task.progress.speedBytesPerSec))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 4)
            controlButtons
        }
        .padding(.vertical, 6)
    }

    /// Icon-only controls are small circular glass lenses. `.clear` keeps the
    /// row behind them readable; the system adds refraction on hover/press.
    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: 6) {
            if task.state == .active || task.state == .pending {
                Button { store.pause(task.id) } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .glassCircle()
                .help("暂停")
            } else if task.state == .paused || task.state == .error {
                Button { store.resume(task.id) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .glassCircle()
                .help("继续")
            }
        }
    }

    private var iconName: String {
        switch task.state {
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        default:
            switch task.protocol {
            case .bittorrent, .magnet: return "arrow.triangle.2.circlepath.circle.fill"
            case .ed2k: return "network"
            case .hls, .dash: return "play.rectangle.fill"
            default: return "arrow.down.circle.fill"
            }
        }
    }

    private var tint: Color {
        switch task.state {
        case .completed: return .green
        case .error: return .red
        case .paused: return .orange
        default: return .accentColor
        }
    }

    private var statusText: String {
        switch task.state {
        case .pending: return "等待中"
        case .paused: return "已暂停 · \(Formatting.percent(task.progress.percent))"
        case .completed: return "已完成 · \(Formatting.bytes(task.progress.totalBytes))"
        case .error: return "出错"
        case .removed: return "已移除"
        case .active:
            return "\(Formatting.bytes(task.progress.downloadedBytes)) / \(Formatting.bytes(task.progress.totalBytes)) · \(Formatting.percent(task.progress.percent))"
        }
    }
}

/// Small semantic tags stay as tinted capsules. At this size a glass lens would
/// lose contrast and hurt legibility — Apple explicitly discourages glass on
/// tiny content elements.
struct ProtocolBadge: View {
    let proto: DownloadProtocol

    var body: some View {
        Text(proto.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch proto {
        case .bittorrent, .magnet, .metalink: return .purple
        case .ed2k: return .pink
        case .hls, .dash: return .orange
        case .ftp, .sftp: return .teal
        default: return .blue
        }
    }
}
