import SwiftUI
import AppKit

struct TaskListView: View {
    @EnvironmentObject private var store: DownloadStore
    @Binding var selection: SidebarItem
    @State private var selectedID: UUID?

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
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .onChange(of: selectedID) { _, newValue in
            store.selectedTaskID = newValue
        }
        .safeAreaInset(edge: .bottom) {
            if let e = store.startupError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(e)
                        .font(.caption)
                    Spacer()
                    Button("重试") { store.start() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.08))
            }
        }
    }

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

    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: 4) {
            if task.state == .active || task.state == .pending {
                Button { store.pause(task.id) } label: {
                    Image(systemName: "pause.fill")
                }
                .help("暂停")
            } else if task.state == .paused || task.state == .error {
                Button { store.resume(task.id) } label: {
                    Image(systemName: "play.fill")
                }
                .help("继续")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
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
