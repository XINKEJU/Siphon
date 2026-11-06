import SwiftUI

/// Root window. `NavigationSplitView` is the standard macOS three-column
/// pattern: sidebar (library/queues), content (task list), detail (inspector).
///
/// On macOS 26+ the system gives the toolbar and sidebar their Liquid Glass
/// material automatically. We deliberately keep the *content* opaque and add
/// glass only to the floating command bar (see `TaskListView`) and to floating
/// inspector cards — glass must never sit behind body text or progress bars.
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
            ZStack {
                // A very light colour wash gives the floating glass something
                // to refract. Never applied to the list column itself.
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.075),
                             Color.purple.opacity(0.035),
                             Color.clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if showingInspector, let id = store.selectedTaskID,
                   let task = store.tasks.first(where: { $0.id == id }) {
                    TaskDetailView(task: task)
                } else {
                    EmptyDetailView()
                }
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
        // Engine status / aggregate speed now live in the floating glass bar:
        // a translucent toolbar item would be glass stacked on glass.
    }
}

/// Floating "no selection" inspector card. A glass surface over the colour
/// wash, sized as a card rather than filling the whole column.
private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("选择一个任务查看详情")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("支持 HTTP / HTTPS / FTP / SFTP / BitTorrent / Metalink / 磁力 / eD2K / HLS / DASH")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 300)
        .glassCard(cornerRadius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
