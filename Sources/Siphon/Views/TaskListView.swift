import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Task list. All global commands live in the window's unified toolbar (see
/// `ContentView`); the list column itself is pure opaque content.
///
/// Keeping the list free of floating chrome is deliberate: on macOS 26+ the
/// system already draws the sidebar and toolbar in Liquid Glass, and Apple's
/// guidance is to reserve custom glass for genuine floating controls — never
/// for list rows, text or an ersatz bottom command bar.
struct TaskListView: View {
    @Environment(DownloadStore.self) private var store
    let filter: TaskFilter
    let searchText: String
    var onSelect: ((DownloadTask) -> Void)? = nil
    @State private var previewTask: DownloadTask?
    @State private var isDropTargeted = false

    /// Two-way derived binding into the store: the list, the 「任务」menu and the
    /// detail column must all see the same selection, so it lives in one place.
    /// `Set<UUID>` (not `UUID?`) is what gives ⌘-click and ⇧-click for free.
    private var selectionBinding: Binding<Set<UUID>> {
        Binding(get: { store.selectedTaskIDs }, set: { store.selectedTaskIDs = $0 })
    }

    private var visible: [DownloadTask] {
        let base: [DownloadTask]
        switch filter {
        case .all: base = store.tasks
        case .active: base = store.tasks.filter { $0.state == .active || $0.state == .pending }
        case .paused: base = store.tasks.filter { $0.state == .paused }
        case .completed: base = store.tasks.filter { $0.state == .completed }
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
            // 从浏览器 / 访达拖入：链接、种子、Metalink 与播放列表。
            .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor,
                                      style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .padding(8)
                        .overlay {
                            Label("松开以添加下载", systemImage: "arrow.down.circle")
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: $previewTask) { task in
                StreamingPreviewView(task: task)
            }
            .alert(deleteTitle, isPresented: Binding(
                get: { !store.pendingDeleteIDs.isEmpty },
                set: { if !$0 { store.pendingDeleteIDs = [] } }
            )) {
                Button("删除文件并移除", role: .destructive) {
                    store.deleteTasks(store.pendingDeleteIDs)
                }
                Button("仅移出列表") {
                    store.removeTasks(store.pendingDeleteIDs)
                }
                Button("取消", role: .cancel) { store.pendingDeleteIDs = [] }
            } message: {
                Text(deleteMessage)
            }
    }

    private var deleteTargets: [DownloadTask] {
        store.tasks.filter { store.pendingDeleteIDs.contains($0.id) }
    }

    private var deleteTitle: String {
        deleteTargets.count > 1 ? "删除 \(deleteTargets.count) 个任务及文件？"
                                : "删除任务及文件？"
    }

    private var deleteMessage: String {
        if deleteTargets.count == 1, let task = deleteTargets.first {
            return "将从列表移除「\(task.name)」，并永久删除磁盘上的文件（含未完成的分片）。此操作不可撤销。"
        }
        return "将从列表移除这 \(deleteTargets.count) 个任务，并永久删除磁盘上的文件（含未完成的分片）。此操作不可撤销。"
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
                VStack(spacing: 0) {
                    // 多选时才出现的上下文操作条：批量动作不该只藏在右键菜单里，
                    // 选中两项以上就明确告诉用户「现在操作的是这一组」。
                    if store.selectedTaskIDs.count > 1 {
                        batchBar
                        Divider()
                    }
                    List(selection: selectionBinding) {
                        ForEach(visible) { task in
                            TaskRowView(task: task)
                                .tag(task.id)
                                .contextMenu { contextMenu(for: task) }
                                // 用 simultaneousGesture 而不是 onTapGesture：
                                // 独占手势会吃掉单击，导致 ⌘/⇧ 多选在 List 里失效。
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    onSelect?(task)
                                })
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Esc 只用来「退出多选」，单选时不拦截，避免影响关窗 / 关面板的默认行为。
        .onExitCommand {
            if store.selectedTaskIDs.count > 1 { store.clearSelection() }
        }
    }

    // MARK: - 批量操作条

    private var batchBar: some View {
        let selected = store.selectedTasks
        let ids = store.selectedTaskIDs
        let canPause = selected.contains { $0.state == .active || $0.state == .pending }
        let canResume = selected.contains { $0.state == .paused || $0.state == .error }
        let totalBytes = selected.reduce(Int64(0)) { $0 + $1.progress.totalBytes }
        return HStack(spacing: 12) {
            Label("已选 \(selected.count) 项", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)

            if totalBytes > 0 {
                Text(Formatting.bytes(totalBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button { store.pauseTasks(ids) } label: {
                Label("暂停", systemImage: "pause.fill")
            }
            .disabled(!canPause)

            Button { store.resumeTasks(ids) } label: {
                Label("继续", systemImage: "play.fill")
            }
            .disabled(!canResume)

            Button { store.copyLinks(ids) } label: {
                Label("拷贝链接", systemImage: "link")
            }

            Button { revealSelected() } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            .disabled(!selected.contains { FileManager.default.fileExists(atPath: $0.destination.path) })

            Button(role: .destructive) { store.pendingDeleteIDs = ids } label: {
                Label("删除", systemImage: "trash")
            }

            Button { store.clearSelection() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("取消选择 (Esc)")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func revealSelected() {
        let urls = store.selectedTasks
            .map(\.destination)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Drag & drop

    /// 接受从浏览器（链接 / 选中文本）与访达（种子、Metalink、播放列表）拖入的条目。
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                                  options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let value = item as? URL {
                        url = value
                    } else if let value = item as? String {
                        url = URL(string: value)
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    Task { @MainActor in store.addDropped([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier,
                                  options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? NSURL) as URL?
                    guard let url else { return }
                    Task { @MainActor in store.addDropped([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let text = item as? String else { return }
                    Task { @MainActor in store.addDroppedText(text) }
                }
            }
        }
        return accepted
    }

    // MARK: - Context menu

    /// Right-clicking inside a multi-selection acts on the whole selection —
    /// the alternative (silently acting on just the row under the cursor) is the
    /// classic way batch UI loses people's files.
    @ViewBuilder
    private func contextMenu(for task: DownloadTask) -> some View {
        if store.selectedTaskIDs.count > 1, store.selectedTaskIDs.contains(task.id) {
            batchContextMenu
        } else {
            singleContextMenu(for: task)
        }
    }

    @ViewBuilder
    private var batchContextMenu: some View {
        let ids = store.selectedTaskIDs
        let selected = store.selectedTasks
        let canPause = selected.contains { $0.state == .active || $0.state == .pending }
        let canResume = selected.contains { $0.state == .paused || $0.state == .error }

        Text("已选 \(selected.count) 项")
        Divider()
        if canPause { Button("暂停") { store.pauseTasks(ids) } }
        if canResume { Button("继续") { store.resumeTasks(ids) } }
        Button("拷贝 \(selected.count) 条链接") { store.copyLinks(ids) }
        Button("在访达中显示") { revealSelected() }
            .disabled(!selected.contains { FileManager.default.fileExists(atPath: $0.destination.path) })
        Divider()
        Menu("限速") {
            Button("不限速") { store.setSpeedLimit(ids, bytesPerSec: nil) }
            Button("512 KB/s") { store.setSpeedLimit(ids, bytesPerSec: 524288) }
            Button("1 MB/s") { store.setSpeedLimit(ids, bytesPerSec: 1048576) }
            Button("5 MB/s") { store.setSpeedLimit(ids, bytesPerSec: 5242880) }
        }
        Menu("优先级") {
            Button("高") { store.setPriority(ids, 1) }
            Button("普通") { store.setPriority(ids, 0) }
            Button("低") { store.setPriority(ids, -1) }
        }
        Divider()
        Button("从列表移除（保留文件）") { store.removeTasks(ids) }
        Button("删除任务及文件", role: .destructive) { store.pendingDeleteIDs = ids }
        Divider()
        Button("取消选择") { store.clearSelection() }
    }

    @ViewBuilder
    private func singleContextMenu(for task: DownloadTask) -> some View {
        if task.state == .active || task.state == .pending {
            Button("暂停") { store.pause(task.id) }
        }
        if task.state == .paused || task.state == .error {
            Button("继续") { store.resume(task.id) }
        }
        if task.state == .completed {
            Button("用默认应用打开") { store.openWithDefaultApp(task) }
            Button("在访达中显示") { reveal(task) }
        } else if store.isPreviewable(task) {
            Button("边下边播") { previewTask = task }
        }
        Button("显示详情…") { onSelect?(task) }
        Divider()
        Menu("限速") {
            Button("不限速") { store.setTaskSpeedLimit(task.id, nil) }
            Button("512 KB/s") { store.setTaskSpeedLimit(task.id, 524288) }
            Button("1 MB/s") { store.setTaskSpeedLimit(task.id, 1048576) }
            Button("5 MB/s") { store.setTaskSpeedLimit(task.id, 5242880) }
        }
        Menu("优先级") {
            Button(task.priority == 1 ? "✓ 高" : "高") { store.setTaskPriority(task.id, 1) }
            Button(task.priority == 0 ? "✓ 普通" : "普通") { store.setTaskPriority(task.id, 0) }
            Button(task.priority == -1 ? "✓ 低" : "低") { store.setTaskPriority(task.id, -1) }
        }
        Divider()
        Button("拷贝链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.source.absoluteString, forType: .string)
        }
        if store.selectedTaskIDs.count > 1 {
            Button("只选这一项") { store.selectedTaskIDs = [task.id] }
        } else if !store.selectedTaskIDs.isEmpty {
            Button("取消选择") { store.clearSelection() }
        }
        Button("从列表移除（保留文件）") { store.remove(task.id) }
        Button("删除任务及文件", role: .destructive) { store.pendingDeleteIDs = [task.id] }
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
