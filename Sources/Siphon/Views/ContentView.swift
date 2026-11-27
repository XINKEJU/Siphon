import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// MDM/IDM window layout: menu bar (in `SiphonCommands`), a 143pt category
/// tree, the 14-column download list, a status strip, and an optional preview
/// column. The four legacy filter tabs are represented by the category tree;
/// the `filter` state stays plumbed for the store's existing contract.
struct ContentView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var showingAdd: Bool
    @Binding var showingInspector: Bool
    @State private var filter: TaskFilter = .all
    // Optional so a custom category (not representable by MDMCategory) can be
    // the active tree selection with no built-in node highlighted.
    @State private var category: MDMCategory? = .all
    @State private var selectedQueue: String?
    @State private var searchText = ""
    @State private var showingAddURL = false
    @State private var showingTorrentImporter = false
    @State private var showingLinkGrabber = false
    @State private var showingFind = false
    @State private var showingScheduler = false
    @State private var showingOptions = false
    @State private var showingProperties = false
    @State private var showingVerify = false
    @State private var network = NetworkMonitor.shared
    @ObservedObject private var theme = MDMThemeStore.shared

    private var torrentContentTypes: [UTType] {
        ["torrent", "metalink", "meta4"].compactMap { UTType(filenameExtension: $0) }
    }

    private func handleTorrentImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        let accessible = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessible.forEach { $0.stopAccessingSecurityScopedResource() } }
        store.addDropped(urls)
    }

    var body: some View {
        // HSplitView lays out at its subviews' ideal height (~135pt) and
        // ignores a maxHeight:.infinity proposal, collapsing the whole
        // three-pane layout into a thin centred strip. Pin it to the real
        // available size reported by GeometryReader so it always fills the
        // window, at any window size.
        GeometryReader { geo in
            mainLayout
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(theme.color(.listBackground))
        .searchable(text: $searchText, prompt: MDMI18n.t("dialog.find"))
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAdd) { AddTaskView().environmentObject(theme) }
        .sheet(isPresented: $showingAddURL) {
            MDMAddURLDialog(isPresented: $showingAddURL).environmentObject(theme)
        }
        .sheet(isPresented: $showingLinkGrabber) {
            MDMLinkGrabberDialog(isPresented: $showingLinkGrabber).environmentObject(theme)
        }
        .sheet(isPresented: $showingFind) {
            MDMFindDialog(isPresented: $showingFind, query: $searchText) {
                findNext()
            }
            .environmentObject(theme)
        }
        .sheet(isPresented: $showingScheduler) {
            MDMSchedulerDialog(isPresented: $showingScheduler).environmentObject(theme)
        }
        .sheet(isPresented: $showingOptions) {
            MDMOptionsView(isPresented: $showingOptions).environmentObject(theme)
        }
        .sheet(isPresented: $showingProperties) {
            if let task = selectedTask {
                MDMPropertiesDialog(task: task, isPresented: $showingProperties)
                    .environmentObject(theme)
            }
        }
        .sheet(isPresented: $showingVerify) {
            MDMVerifyChecksumDialog(isPresented: $showingVerify).environmentObject(theme)
        }
        .fileImporter(isPresented: $showingTorrentImporter,
                      allowedContentTypes: torrentContentTypes,
                      allowsMultipleSelection: true,
                      onCompletion: handleTorrentImport)
        .task {
            await store.start()
            store.handleNetworkChange(NetworkMonitor.shared.status)
        }
        .onReceive(NotificationCenter.default.publisher(for: .siphonOpenAddSheet)) { _ in
            showingAddURL = true
        }
        // Menu-bar commands post notifications because the dialog state lives
        // in the window: every toolbar command stays reachable from the menu,
        // without duplicating @State in two scenes.
        .onReceive(NotificationCenter.default.publisher(for: .mdmOpenAddURL)) { _ in showingAddURL = true }
        .onReceive(NotificationCenter.default.publisher(for: .mdmOpenLinkGrabber)) { _ in showingLinkGrabber = true }
        .onReceive(NotificationCenter.default.publisher(for: .mdmOpenOptions)) { _ in showingOptions = true }
        .onReceive(NotificationCenter.default.publisher(for: .mdmOpenFind)) { _ in showingFind = true }
        .onReceive(NotificationCenter.default.publisher(for: .mdmOpenScheduler)) { _ in showingScheduler = true }
        .onReceive(NotificationCenter.default.publisher(for: .mdmOpenProperties)) { _ in showingProperties = true }
        .onReceive(NotificationCenter.default.publisher(for: .mdmOpenVerify)) { _ in showingVerify = true }
        .onReceive(NotificationCenter.default.publisher(for: .mdmOpenAddTorrent)) { _ in showingTorrentImporter = true }
        .alert("无法添加任务", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: {
            Text(store.lastError ?? "")
        }
        // No min-only frame here: in a Window scene a min-only frame makes the
        // root view size to its ideal height (~135pt) and centre it. The window
        // scene (SiphonApp) already supplies min 700x450 and max:.infinity.
    }

    /// The three-pane split itself. Kept as a separate expression so the
    /// GeometryReader frame above can size it without a type-check timeout.
    ///
    /// HStack, not HSplitView: on this toolchain HSplitView lays out at its
    /// subviews' ideal height (~135pt) and ignores an explicit frame height,
    /// collapsing the layout into a thin centred strip. An HStack with
    /// maxHeight:.infinity children fills the frame reliably.
    private var mainLayout: some View {
        HStack(spacing: 0) {
            MDMCategoryTreeView(selection: $category, selectedQueue: $selectedQueue)
                .frame(width: 143)

            Divider()

            VStack(spacing: 0) {
                taskList
                Divider()
                statusBar
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            if showingInspector {
                Divider()
                inspectorPanel
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(theme.color(.surface))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(theme)
        .environment(\.layoutDirection, MDMI18n.shared.isRTL ? .rightToLeft : .leftToRight)
    }

    // MARK: - List

    private var taskList: some View {
        TaskListView(filter: filter,
                     searchText: searchText,
                     category: category,
                     selectedQueue: selectedQueue,
                     onSelect: { task in
                        store.selectedTaskID = task.id
                        // MDM: double-clicking a row opens that task's own
                        // progress window (one window per download).
                        MDMProgressPanelController.shared.show(taskID: task.id, store: store)
                     })
    }

    private func findNext() {
        guard !searchText.isEmpty else { return }
        let needle = searchText.lowercased()
        let tasks = store.tasks.sorted { $0.createdAt > $1.createdAt }
        let start = tasks.firstIndex { $0.id == store.selectedTaskID } ?? -1
        if let match = tasks.dropFirst(start + 1).first(where: {
            $0.name.lowercased().contains(needle)
                || $0.source.absoluteString.lowercased().contains(needle)
        }) {
            store.selectedTaskID = match.id
        }
    }

    // MARK: - Preview column

    @ViewBuilder
    private var inspectorPanel: some View {
        if store.selectedTaskIDs.count > 1 {
            BatchSelectionPanel()
        } else if let task = selectedTask {
            TaskDetailView(task: task)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("未选择任务")
                    .font(.headline)
                Text("点击列表中的任务，详情会显示在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            let active = store.tasks.filter { $0.state == .active }
            let totalSpeed = active.map { $0.progress.speedBytesPerSec }.reduce(Int64(0), +)
            let queued = store.tasks.filter { $0.state == .pending || $0.state == .paused }.count

            Label {
                Text("\(active.count) \(MDMI18n.t("status.downloading"))")
                    .font(.system(size: 11))
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(theme.color(.success))
                    .font(.system(size: 10))
            }

            if queued > 0 {
                Label {
                    Text("\(queued) \(MDMI18n.t("status.queued"))")
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "clock").foregroundStyle(.orange).font(.system(size: 10))
                }
            }

            if let note = network.status.displayText {
                Label {
                    Text(note).font(.system(size: 11, weight: .semibold))
                } icon: {
                    Image(systemName: network.status.symbolName)
                        .foregroundStyle(.orange).font(.system(size: 10))
                }
                .help(store.networkPauseReason?.displayText ?? "当前网络状态")
            }

            if store.selectedTaskIDs.count > 1 {
                Label {
                    Text("已选 \(store.selectedTaskIDs.count) 项")
                        .font(.system(size: 11, weight: .semibold))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor).font(.system(size: 10))
                }
                Button("取消") { store.clearSelection() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if totalSpeed > 0 {
                Label {
                    Text("\(formatBytes(totalSpeed))/s")
                        .font(.system(size: 11, design: .monospaced))
                } icon: {
                    Image(systemName: "speedometer").foregroundStyle(.blue).font(.system(size: 10))
                }
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(store.downloadDirectory)
            } label: {
                Label {
                    Text(store.downloadDirectory.lastPathComponent)
                        .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("在访达中打开下载目录")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.color(.surfaceRaised))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // MDM's eleven toolbar actions, all direct (no "more" menu). Every one
        // is also reachable from the menu bar; these are the fast paths.
        toolbarAddActions
        toolbarRunActions
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        toolbarQueueActions
    }

    @ToolbarContentBuilder
    private var toolbarAddActions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingAddURL = true
            } label: {
                Label(MDMI18n.t("menu.addURL"), systemImage: "link.badge.plus")
            }
            .help("添加 URL (⌘N)")

            Button {
                showingTorrentImporter = true
            } label: {
                Label("添加种子", systemImage: "arrow.down.doc")
            }
            .help("添加 .torrent / .metalink 文件")

            Button {
                store.resumeTasks(store.selectedTaskIDs)
            } label: {
                Label("继续", systemImage: "play.fill")
            }
            .help("继续所选任务")
            .disabled(!store.selectedTasks.contains { $0.state == .paused || $0.state == .error })

            Button {
                store.pauseTasks(store.selectedTaskIDs)
            } label: {
                Label("停止", systemImage: "pause.fill")
            }
            .help("停止所选任务")
            .disabled(!store.selectedTasks.contains { $0.state == .active || $0.state == .pending })

            Button {
                store.pauseAll()
            } label: {
                Label("全部停止", systemImage: "stop.fill")
            }
            .help("停止全部任务")
            .disabled(!store.tasks.contains { $0.state == .active || $0.state == .pending })
        }
    }

    @ToolbarContentBuilder
    private var toolbarRunActions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.pendingDeleteIDs = store.selectedTaskIDs
            } label: {
                Label("删除", systemImage: "trash")
            }
            .help("删除所选任务")
            .disabled(store.selectedTaskIDs.isEmpty)

            Button {
                store.removeCompleted()
            } label: {
                Label("删除已完成", systemImage: "trash.slash")
            }
            .help("从列表移除已完成的任务")
            .disabled(!store.tasks.contains { $0.state == .completed })

            Button {
                showingOptions = true
            } label: {
                Label(MDMI18n.t("menu.options"), systemImage: "gearshape")
            }
            .help("选项 (⌘,)")

            Button {
                showingScheduler = true
            } label: {
                Label(MDMI18n.t("menu.scheduler"), systemImage: "clock.arrow.circlepath")
            }
            .help("计划任务")
        }
    }

    @ToolbarContentBuilder
    private var toolbarQueueActions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.startQueue(selectedQueue)
            } label: {
                Label("启动队列", systemImage: "play.circle")
            }
            .help(selectedQueue.map { "启动队列「\($0)」" } ?? "启动全部队列")

            Button {
                store.stopQueue(selectedQueue)
            } label: {
                Label("停止队列", systemImage: "pause.circle")
            }
            .help(selectedQueue.map { "停止队列「\($0)」" } ?? "停止全部队列")
        }
    }

    private var selectedTask: DownloadTask? {
        guard let id = store.selectedTaskID else { return nil }
        return store.tasks.first { $0.id == id }
    }
}

// MARK: - Task filter

enum TaskFilter: String, CaseIterable, Identifiable {
    case all, active, paused, completed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return MDMI18n.t("category.all")
        case .active: return MDMI18n.t("category.unfinished")
        case .paused: return MDMI18n.t("status.stopped")
        case .completed: return MDMI18n.t("category.finished")
        }
    }
    func count(_ tasks: [DownloadTask]) -> Int {
        switch self {
        case .all: return tasks.count
        case .active: return tasks.filter { $0.state == .active || $0.state == .pending }.count
        case .paused: return tasks.filter { $0.state == .paused }.count
        case .completed: return tasks.filter { $0.state == .completed }.count
        }
    }
}

// MARK: - 多选汇总面板

/// Right-hand summary for a multi-selection: same batch actions as the list
/// bar and the Tasks menu, so all three paths share one store implementation.
private struct BatchSelectionPanel: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        let selected = store.selectedTasks
        let ids = store.selectedTaskIDs
        let totalBytes = selected.reduce(Int64(0)) { $0 + $1.progress.totalBytes }
        let doneBytes = selected.reduce(Int64(0)) { $0 + $1.progress.downloadedBytes }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选 \(selected.count) 项").font(.title3.weight(.semibold))
                    Text("批量暂停、继续、拷贝链接或删除这一组任务")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    row("总大小", totalBytes > 0 ? Formatting.bytes(totalBytes) : "—")
                    row("已下载", Formatting.bytes(doneBytes))
                    if totalBytes > 0 {
                        ProgressView(value: min(1, Double(doneBytes) / Double(max(1, totalBytes))))
                            .progressViewStyle(.linear)
                        row("完成度", Formatting.percent(Double(doneBytes) / Double(max(1, totalBytes))))
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button { store.pauseTasks(ids) } label: { Label("暂停", systemImage: "pause.fill") }
                        Button { store.resumeTasks(ids) } label: { Label("继续", systemImage: "play.fill") }
                    }
                    HStack(spacing: 8) {
                        Button { _ = store.copyLinks(ids) } label: { Label("拷贝链接", systemImage: "link") }
                        Button(role: .destructive) { store.pendingDeleteIDs = ids } label: {
                            Label("删除…", systemImage: "trash")
                        }
                    }
                    Button { store.clearSelection() } label: {
                        Label("取消选择", systemImage: "xmark.circle")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("包含任务").font(.caption).foregroundStyle(.secondary)
                    ForEach(selected.prefix(12)) { task in
                        HStack(spacing: 6) {
                            Image(systemName: task.state == .completed ? "checkmark.circle.fill"
                                  : task.state == .error ? "exclamationmark.circle.fill"
                                  : task.state == .paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 10))
                            Text(task.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Formatting.percent(task.progress.percent))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    if selected.count > 12 {
                        Text("…还有 \(selected.count - 12) 项")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let fmt = ByteCountFormatter()
    fmt.countStyle = .binary
    return fmt.string(fromByteCount: bytes)
}
