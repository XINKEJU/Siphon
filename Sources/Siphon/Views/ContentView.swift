import SwiftUI
import AppKit

/// NDM-style simplified main window: filter tabs at top, compact task list,
/// bottom status bar. Task details open in a sheet, or in an optional right
/// detail column when "显示侧边栏" is on (never both at once).
struct ContentView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var showingAdd: Bool
    @Binding var showingInspector: Bool
    @State private var filter: TaskFilter = .all
    @State private var searchText = ""
    @State private var showingDetail = false
    @State private var network = NetworkMonitor.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filterTabs
                Divider()
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
                    .background(.background)
            }
        }
        .searchable(text: $searchText, prompt: "搜索任务")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAdd) { AddTaskView() }
        .sheet(isPresented: $showingDetail) {
            if let task = selectedTask {
                TaskDetailView(task: task)
                    .frame(minWidth: 400, minHeight: 500)
                    .padding()
            }
        }
        .task {
            await store.start()
            // 启动瞬间可能已经处于断网 / 计费网络，先按当前状态对一次策略。
            store.handleNetworkChange(NetworkMonitor.shared.status)
        }
        .onReceive(NotificationCenter.default.publisher(for: .siphonOpenAddSheet)) { _ in
            showingAdd = true
        }
        .onChange(of: showingInspector) { _, visible in
            // A sheet left over from the sheet-only layout must not stack on
            // top of the new detail column.
            if visible { showingDetail = false }
        }
        .alert("无法添加任务", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: {
            Text(store.lastError ?? "")
        }
        .frame(minWidth: 700, minHeight: 450)
    }

    // MARK: - Filter tabs

    private var filterTabs: some View {
        HStack(spacing: 0) {
            ForEach(TaskFilter.allCases) { item in
                Button {
                    filter = item
                } label: {
                    Text("\(item.title) (\(item.count(store.tasks)))")
                        .font(.system(size: 12, weight: filter == item ? .semibold : .regular))
                        .foregroundStyle(filter == item ? Color.accentColor : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            if filter == item {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.1))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Task list

    private var taskList: some View {
        TaskListView(filter: filter, searchText: searchText, onSelect: { task in
            store.selectedTaskID = task.id
            // With the detail column visible the selection is already shown;
            // opening a second copy as a sheet would be redundant.
            if !showingInspector { showingDetail = true }
        })
    }

    // MARK: - Detail column

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
                Text("点击左侧列表中的任务，详情会显示在这里。")
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
                Text("\(active.count) 个进行中")
                    .font(.system(size: 11))
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 10))
            }

            if queued > 0 {
                Label {
                    Text("\(queued) 个排队中")
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "clock")
                        .foregroundStyle(.orange)
                        .font(.system(size: 10))
                }
            }

            // 网络异常不该只体现在任务失败里：状态栏提前说明「为什么都停了」。
            if let note = network.status.displayText {
                Label {
                    Text(note)
                        .font(.system(size: 11, weight: .semibold))
                } icon: {
                    Image(systemName: network.status.symbolName)
                        .foregroundStyle(.orange)
                        .font(.system(size: 10))
                }
                .help(store.networkPauseReason?.displayText ?? "当前网络状态")
            }

            if store.selectedTaskIDs.count > 1 {
                Label {
                    Text("已选 \(store.selectedTaskIDs.count) 项")
                        .font(.system(size: 11, weight: .semibold))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 10))
                }
                Button("取消") { store.clearSelection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if totalSpeed > 0 {
                Label {
                    Text("\(formatBytes(totalSpeed))/s")
                        .font(.system(size: 11, design: .monospaced))
                } icon: {
                    Image(systemName: "speedometer")
                        .foregroundStyle(.blue)
                        .font(.system(size: 10))
                }
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(store.downloadDirectory)
            } label: {
                Label {
                    Text(store.downloadDirectory.lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("在访达中打开下载目录")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                for t in store.tasks where t.state == .paused || t.state == .error {
                    store.resume(t.id)
                }
            } label: {
                Label("恢复全部", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .help("恢复所有已暂停或出错的任务")
            .disabled(!store.tasks.contains { $0.state == .paused || $0.state == .error })

            Button {
                for t in store.tasks where t.state == .active { store.pause(t.id) }
            } label: {
                Label("全部暂停", systemImage: "pause.fill")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .help("暂停所有进行中的任务")
            .disabled(!store.tasks.contains { $0.state == .active })
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAdd = true
            } label: {
                Label("新建下载", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .help("添加链接、专用链、网关地址或批量列表 (⌘N)")
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
        case .all: return "全部"
        case .active: return "进行中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
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

/// 右侧详情列在多选时的替代内容：一屏看清这组任务的数量、体量与状态分布，
/// 并把批量动作放在手边 —— 否则「选了十几个却只能回列表右键」很别扭。
private struct BatchSelectionPanel: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        content(selected: store.selectedTasks)
    }

    private func content(selected: [DownloadTask]) -> some View {
        let ids = store.selectedTaskIDs
        let totalBytes = selected.reduce(Int64(0)) { $0 + $1.progress.totalBytes }
        let doneBytes = selected.reduce(Int64(0)) { $0 + $1.progress.downloadedBytes }
        let active = selected.filter { $0.state == .active || $0.state == .pending }.count
        let paused = selected.filter { $0.state == .paused }.count
        let finished = selected.filter { $0.state == .completed }.count
        let failed = selected.filter { $0.state == .error }.count

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选 \(selected.count) 项")
                        .font(.title3.weight(.semibold))
                    Text("批量暂停、继续、拷贝链接或删除这一组任务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("状态").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if active > 0 { chip("进行中 \(active)", .accentColor) }
                        if paused > 0 { chip("已暂停 \(paused)", .orange) }
                        if finished > 0 { chip("已完成 \(finished)", .green) }
                        if failed > 0 { chip("出错 \(failed)", .red) }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button { store.pauseTasks(ids) } label: {
                            Label("暂停", systemImage: "pause.fill")
                        }
                        .disabled(active == 0)
                        Button { store.resumeTasks(ids) } label: {
                            Label("继续", systemImage: "play.fill")
                        }
                        .disabled(paused + failed == 0)
                    }
                    HStack(spacing: 8) {
                        Button { store.copyLinks(ids) } label: {
                            Label("拷贝链接", systemImage: "link")
                        }
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
                                .foregroundStyle(task.state == .completed ? .green
                                                 : task.state == .error ? .red
                                                 : task.state == .paused ? .orange : Color.accentColor)
                            Text(task.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Formatting.percent(task.progress.percent))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if selected.count > 12 {
                        Text("…还有 \(selected.count - 12) 项")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let fmt = ByteCountFormatter()
    fmt.countStyle = .binary
    return fmt.string(fromByteCount: bytes)
}
