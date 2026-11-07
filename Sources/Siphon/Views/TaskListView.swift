import SwiftUI
import AppKit

/// Task list. All global commands live in the window's unified toolbar (see
/// `ContentView`); the list column itself is pure opaque content.
///
/// Keeping the list free of floating chrome is deliberate: on macOS 26+ the
/// system already draws the sidebar and toolbar in Liquid Glass, and Apple's
/// guidance is to reserve custom glass for genuine floating controls — never
/// for list rows, text or an ersatz bottom command bar.
struct TaskListView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var selection: SidebarItem
    let searchText: String

    /// Two-way derived binding: local @State + onChange only flowed changes out,
    /// so programmatic selection (notifications, MCP) never reached the list.
    private var selectionBinding: Binding<UUID?> {
        Binding(get: { store.selectedTaskID }, set: { store.selectedTaskID = $0 })
    }

    private var visible: [DownloadTask] {
        let base: [DownloadTask]
        switch selection {
        case .all: base = store.tasks
        case .downloading: base = store.tasks.filter { $0.state == .active || $0.state == .pending }
        case .completed: base = store.tasks.filter { $0.state == .completed }
        case .paused: base = store.tasks.filter { $0.state == .paused }
        case .queue(let name): base = store.tasks.filter { $0.queueName == name }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        let needle = query.lowercased()
        return base.filter { task in
            task.name.lowercased().contains(needle)
                || task.source.absoluteString.lowercased().contains(needle)
                || (task.origin?.lowercased().contains(needle) ?? false)
                || task.protocol.displayName.lowercased().contains(needle)
        }
    }

    var body: some View {
        listContent
    }

    @ViewBuilder
    private var listContent: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "没有任务" : "没有匹配的任务",
                          systemImage: searchText.isEmpty ? "tray" : "magnifyingglass")
                } description: {
                    Text(searchText.isEmpty
                         ? "点按工具栏的「+」添加下载，或开启剪贴板监听自动捕获链接。"
                         : "换个关键词，或清除顶部搜索框中的文字。")
                }
            } else {
                List(selection: selectionBinding) {
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
                // Content softly fades under the translucent system toolbar.
                .softScrollTopEdge()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Menu("限速") {
            Button("不限速") { store.setTaskSpeedLimit(task.id, nil) }
            Button("512 KB/s") { store.setTaskSpeedLimit(task.id, 524288) }
            Button("1 MB/s") { store.setTaskSpeedLimit(task.id, 1048576) }
            Button("5 MB/s") { store.setTaskSpeedLimit(task.id, 5242880) }
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
    @Environment(DownloadStore.self) private var store
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
