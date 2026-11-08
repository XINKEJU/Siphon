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
        .task { await store.start() }
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
        if let task = selectedTask {
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
            .help("恢复所有已暂停或出错的任务")
            .disabled(!store.tasks.contains { $0.state == .paused || $0.state == .error })

            Button {
                for t in store.tasks where t.state == .active { store.pause(t.id) }
            } label: {
                Label("全部暂停", systemImage: "pause.fill")
            }
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

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("清理已完成") { store.removeCompleted() }
                Button("在访达中打开下载目录") {
                    NSWorkspace.shared.open(store.downloadDirectory)
                }
                Divider()
                Button("重新启动 aria2") { Task { await store.restartAria2() } }
                Divider()
                Toggle("显示侧边栏", isOn: $showingInspector)
            } label: {
                Label("更多操作", systemImage: "ellipsis.circle")
            }
            .help("更多任务操作")
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

private func formatBytes(_ bytes: Int64) -> String {
    let fmt = ByteCountFormatter()
    fmt.countStyle = .binary
    return fmt.string(fromByteCount: bytes)
}
