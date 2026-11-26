import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// MDM's fourteen-column download list. The native grid owns column interaction;
/// this wrapper keeps SwiftUI empty states, batch chrome, drop handling, deletion
/// confirmation and streaming preview in one place.
struct TaskListView: View {
    @Environment(DownloadStore.self) private var store
    let filter: TaskFilter
    let searchText: String
    var category: MDMCategory? = .all
    var selectedQueue: String? = nil
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
        var result: [DownloadTask]
        if let key = store.selectedCategoryKey {
            // A custom category is active: filter by resolved key so explicit
            // assignments and extension-derived tasks both land here.
            result = base.filter { CategoryStore.shared.resolvedKey(for: $0) == key }
        } else {
            result = base.filter { (category ?? .all).contains($0) }
            if let queue = selectedQueue, category == .queues {
                result = result.filter { $0.queueName == queue }
            }
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
        return result
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
                    TaskTableRepresentable(
                        tasks: visible,
                        store: store,
                        selectedTaskIDs: selectionBinding,
                        previewTask: $previewTask,
                        isDropTargeted: $isDropTargeted,
                        onDrop: handleDrop,
                        onOpen: onSelect
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
