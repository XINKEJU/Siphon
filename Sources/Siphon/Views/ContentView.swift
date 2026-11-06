import SwiftUI

/// Root window. Uses `NavigationSplitView` — the standard macOS three-column
/// pattern — with a sidebar for library/queues, the task list as the content
/// column, and an inspector-style detail column for the selected task.
struct ContentView: View {
    @EnvironmentObject private var store: DownloadStore
    @State private var showingAdd = false
    @State private var showingInspector = true
    @State private var sidebarSelection: SidebarItem = .all

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
        } content: {
            TaskListView(selection: $sidebarSelection)
                .navigationTitle(sidebarSelection.title)
        } detail: {
            if showingInspector, let id = store.selectedTaskID,
               let task = store.tasks.first(where: { $0.id == id }) {
                TaskDetailView(task: task)
            } else {
                EmptyDetailView()
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAdd) { AddTaskView() }
        .task { store.start() }
        .frame(minWidth: 900, minHeight: 560)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAdd = true
            } label: {
                Label("新建下载", systemImage: "plus")
            }
            .help("添加 HTTP / FTP / BT / 磁力 / eD2K / HLS / DASH 任务 (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                for t in store.tasks where t.state == .active { store.pause(t.id) }
            } label: {
                Label("全部暂停", systemImage: "pause")
            }
            .help("暂停所有进行中的任务")
            .disabled(!store.tasks.contains { $0.state == .active })
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingInspector.toggle()
            } label: {
                Label("显示详情", systemImage: "sidebar.trailing")
            }
            .help("显示或隐藏任务详情")
        }

        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.aria2Status == "已停止" || store.aria2Status == "aria2 不可用"
                          ? Color.red : Color.green)
                    .frame(width: 7, height: 7)
                Text(store.aria2Status)
                Text("·")
                Text(Formatting.speed(store.aggregateSpeed))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("选择一个任务查看详情")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("支持 HTTP / HTTPS / FTP / SFTP / BitTorrent / Metalink / 磁力 / eD2K / HLS / DASH")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
