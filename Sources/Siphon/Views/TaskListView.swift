import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// MDM's 14-slot download list. Column order and labels match the IDM-derived
/// contract in MDM `crates/app/src/list.rs`; slots that Siphon has no data for
/// (share ratio, upload speed) are still present and show an em dash, so a
/// saved column layout from MDM remains meaningful.
///
/// Multi-selection, batch bar, context menus and drag/drop are preserved from
/// the previous list: the rewrite changes the presentation, not the actions.
struct TaskListView: View {
    @Environment(DownloadStore.self) private var store
    let filter: TaskFilter
    let searchText: String
    var category: MDMCategory = .all
    var selectedQueue: String? = nil
    var onSelect: ((DownloadTask) -> Void)? = nil

    @State private var previewTask: DownloadTask?
    @State private var isDropTargeted = false
    @State private var sortMode: SortMode = .added

    private enum SortMode: String, CaseIterable, Identifiable {
        case added, name, size, status, rate
        var id: String { rawValue }
        var title: String {
            switch self {
            case .added: return MDMI18n.t("column.added")
            case .name: return MDMI18n.t("column.fileName")
            case .size: return MDMI18n.t("column.size")
            case .status: return MDMI18n.t("column.status")
            case .rate: return MDMI18n.t("column.rate")
            }
        }
    }

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
        var result = base.filter { category.contains($0) }
        if let queue = selectedQueue, category == .queues {
            result = result.filter { $0.queueName == queue }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let needle = query.lowercased()
            result = result.filter { task in
                task.name.lowercased().contains(needle)
                    || task.source.absoluteString.lowercased().contains(needle)
                    || (task.origin?.lowercased().contains(needle) ?? false)
                    || task.protocol.displayName.lowercased().contains(needle)
            }
        }
        switch sortMode {
        case .added: return result.sorted { $0.createdAt > $1.createdAt }
        case .name: return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: return result.sorted { $0.progress.totalBytes > $1.progress.totalBytes }
        case .status: return result.sorted { MDMStatus($0.state).rawValue < MDMStatus($1.state).rawValue }
        case .rate: return result.sorted { $0.progress.speedBytesPerSec > $1.progress.speedBytesPerSec }
        }
    }

    var body: some View {
        listContent
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
                Button("移到废纸篓并移除") {
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
            return "将从列表移除「\(task.name)」，并把磁盘上的文件（含未完成的分片）移到废纸篓，可在废纸篓中恢复。"
        }
        return "将从列表移除这 \(deleteTargets.count) 个任务，并把磁盘上的文件（含未完成的分片）移到废纸篓，可在废纸篓中恢复。"
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
                         ? "添加 URL 或使用链接抓取器开始下载。"
                         : "换个关键词，或清除搜索框中的文字。")
                }
            } else {
                VStack(spacing: 0) {
                    if store.selectedTaskIDs.count > 1 { batchBar; Divider() }
                    sortStrip
                    columnList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            if store.selectedTaskIDs.count > 1 { store.clearSelection() }
        }
    }

    /// Slim strip above the columns: MDM keeps sorting on column headers; the
    /// SwiftUI Table equivalent is a compact menu without stealing row space.
    private var sortStrip: some View {
        HStack(spacing: 8) {
            Text("\(visible.count) 项").font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Menu {
                ForEach(SortMode.allCases) { mode in
                    Button {
                        sortMode = mode
                    } label: {
                        if sortMode == mode { Label(mode.title, systemImage: "checkmark") }
                        else { Text(mode.title) }
                    }
                }
            } label: {
                Label("排序：\(sortMode.title)", systemImage: "arrow.up.arrow.down")
                    .font(.caption2)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.color(.surface))
    }

    private var theme: MDMThemeStore { MDMThemeStore.shared }

    private var columnList: some View {
        Table(visible, selection: selectionBinding) {
            TableColumn(MDMI18n.t("column.fileName")) { task in
                HStack(spacing: 6) {
                    Image(systemName: statusIcon(task))
                        .font(.system(size: 12))
                        .foregroundStyle(statusColor(task))
                    Text(task.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProtocolBadge(proto: task.protocol)
                }
            }
            .width(260)
            TableColumn(MDMI18n.t("column.queue")) { task in
                Text(task.queueName).font(.caption).lineLimit(1)
            }
            .width(70)
            TableColumn(MDMI18n.t("column.size")) { task in
                Text(task.progress.totalBytes > 0 ? Formatting.bytes(task.progress.totalBytes) : "—")
                    .font(.caption.monospacedDigit())
            }
            .width(86)
            TableColumn(MDMI18n.t("column.status")) { task in
                HStack(spacing: 4) {
                    ProgressView(value: task.progress.percent)
                        .progressViewStyle(.linear)
                        .frame(width: 24)
                    Text(MDMStatus(task.state).displayName)
                        .font(.caption)
                        .foregroundStyle(statusColor(task))
                }
            }
            .width(110)
            TableColumn(MDMI18n.t("column.timeLeft")) { task in
                Text(Formatting.eta(downloaded: task.progress.downloadedBytes,
                                    total: task.progress.totalBytes,
                                    speed: task.progress.speedBytesPerSec))
                    .font(.caption.monospacedDigit())
            }
            .width(84)
            TableColumn(MDMI18n.t("column.rate")) { task in
                Text(task.progress.speedBytesPerSec > 0
                     ? Formatting.speed(task.progress.speedBytesPerSec) : "—")
                    .font(.caption.monospacedDigit())
            }
            .width(94)
            TableColumn(MDMI18n.t("column.description")) { task in
                Text(task.errorDescription ?? task.options["description"] ?? "—")
                    .font(.caption).lineLimit(1)
            }
            .width(140)
            TableColumn(MDMI18n.t("column.added")) { task in
                Text(task.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }
            .width(110)
            TableColumn(MDMI18n.t("column.source")) { task in
                Text(task.origin ?? task.source.absoluteString)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .width(180)
            // SwiftUI's TableColumnBuilder caps a flat block at 10 columns, so
            // the four least-used MDM columns (Peers / Share ratio / Upload
            // speed / Save To) are folded into this "Details" column and
            // shown in full in the inspector. The 14 canonical MDM columns
            // remain defined in MDMI18n and the inspector.
            TableColumn(MDMI18n.t("column.details")) { task in
                Text("\(task.progress.connectedPeers) peers · \(task.destination.path)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(180)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu { contextMenuForSelection }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard let id = store.selectedTaskID,
                  let task = store.tasks.first(where: { $0.id == id }) else { return }
            onSelect?(task)
        })
    }

    private func statusIcon(_ task: DownloadTask) -> String {
        switch task.state {
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private func statusColor(_ task: DownloadTask) -> Color {
        switch task.state {
        case .completed: return theme.color(.success)
        case .error: return theme.color(.error)
        case .paused: return theme.color(.warning)
        default: return .accentColor
        }
    }

    /// A context menu attached to the table acts on the whole selection. This
    /// preserves MDM's "right-click a selected row affects the group" rule.
    @ViewBuilder
    private var contextMenuForSelection: some View {
        if store.selectedTaskIDs.count > 1, let first = store.selectedTasks.first {
            batchContextMenu(for: first)
        } else if let id = store.selectedTaskID,
                  let task = store.tasks.first(where: { $0.id == id }) {
            singleContextMenu(for: task)
        } else if let task = visible.first {
            singleContextMenu(for: task)
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

            Button { store.pauseTasks(ids) } label: { Label("暂停", systemImage: "pause.fill") }
                .disabled(!canPause)
            Button { store.resumeTasks(ids) } label: { Label("继续", systemImage: "play.fill") }
                .disabled(!canResume)
            Button { _ = store.copyLinks(ids) } label: { Label("拷贝链接", systemImage: "link") }
            Button { revealSelected() } label: { Label("在访达中显示", systemImage: "folder") }
                .disabled(!selected.contains { FileManager.default.fileExists(atPath: $0.destination.path) })
            Button(role: .destructive) { store.pendingDeleteIDs = ids } label: {
                Label("删除", systemImage: "trash")
            }
            Button { store.clearSelection() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
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

    // MARK: - Context menus

    @ViewBuilder
    private func batchContextMenu(for task: DownloadTask) -> some View {
        let ids = store.selectedTaskIDs
        let selected = store.selectedTasks
        let canPause = selected.contains { $0.state == .active || $0.state == .pending }
        let canResume = selected.contains { $0.state == .paused || $0.state == .error }

        Text("已选 \(selected.count) 项")
        Divider()
        if canPause { Button("暂停") { store.pauseTasks(ids) } }
        if canResume { Button("继续") { store.resumeTasks(ids) } }
        Button("拷贝 \(selected.count) 条链接") { _ = store.copyLinks(ids) }
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
        if FileManager.default.fileExists(atPath: task.destination.path) {
            Button("快速查看") { QuickLookController.shared.present(urls: [task.destination]) }
        }
        if task.state == .completed {
            Button("用默认应用打开") { store.openWithDefaultApp(task) }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([task.destination])
            }
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
}

/// Small semantic tags stay as tinted capsules: at this size a glass lens
/// would lose contrast, which is why the task rows use capsules instead.
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
