import SwiftUI
import AppKit

/// Root window. `NavigationSplitView` is the standard macOS three-column
/// pattern: sidebar (library/queues), content (task list), detail (inspector).
///
/// Window chrome is entirely system-owned: AppKit draws the window controls,
/// the unified title bar and the sidebar; SwiftUI draws the toolbar items on
/// their Liquid Glass surfaces. We never add a custom background, tint or
/// `.glassEffect` to any of those — doing so double-composites over the system
/// material and breaks the scroll edge effect.
///
/// Toolbar layout follows the macOS 26 HIG (three groups, trailing search):
///   leading  — sidebar toggle (system) + view title
///   centre   — transfer controls: resume / pause all
///   trailing — primary action (new download), inspector, more, search
/// The old bottom floating command bar is gone: on macOS, controls belong in
/// the unified toolbar at the top of the window.
struct ContentView: View {
    @EnvironmentObject private var store: DownloadStore
    @Binding var showingAdd: Bool
    @Binding var showingInspector: Bool
    @State private var sidebarSelection: SidebarItem = .all
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
        } content: {
            TaskListView(selection: $sidebarSelection, searchText: searchText)
                .navigationTitle(sidebarSelection.title)
        } detail: {
            if showingInspector, let id = store.selectedTaskID,
               let task = store.tasks.first(where: { $0.id == id }) {
                TaskDetailView(task: task)
            } else {
                EmptyDetailView()
            }
        }
        // On macOS 26+ the system places this in a glass field at the trailing
        // edge of the toolbar. Searching belongs to the whole split view.
        .searchable(text: $searchText, prompt: "搜索任务")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAdd) { AddTaskView() }
        .task { store.start() }
        .alert("无法添加任务", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: {
            Text(store.lastError ?? "")
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Group 1 — transfer controls. ToolbarItemGroup is a real capsule
        // boundary on macOS 26+, so the two buttons read as one unit.
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

        // A fixed spacer with the SAME placement is the only reliable way to
        // keep neighbouring toolbar items on separate glass capsules.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // Group 2 — the single coloured, prominent action. Toolbar content is
        // monochrome by default; colour is reserved for the key action.
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAdd = true
            } label: {
                Label("新建下载", systemImage: "plus")
            }
            // WWDC25: toolbar content is monochrome by default; use a
            // prominent tinted style only for the single key action.
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .help("添加链接、专用链、网关地址或批量列表 (⌘N)")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // Group 3 — inspector visibility and less frequent commands.
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingInspector.toggle()
            } label: {
                Label("显示详情", systemImage: "sidebar.trailing")
            }
            .help("显示或隐藏任务详情")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("清理已完成") { store.removeCompleted() }
                Button("在访达中打开下载目录") {
                    NSWorkspace.shared.open(store.downloadDirectory)
                }
                if let id = store.selectedTaskID,
                   let task = store.tasks.first(where: { $0.id == id }),
                   FileManager.default.fileExists(atPath: task.destination.path) {
                    Button("在访达中显示所选文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([task.destination])
                    }
                }
                Divider()
                Button("重新启动 aria2") { store.restartAria2() }
            } label: {
                Label("更多操作", systemImage: "ellipsis.circle")
            }
            .help("更多任务操作")
        }
    }
}

/// System-standard empty state. `ContentUnavailableView` supplies the correct
/// typography and spacing; a custom glass card here would put a lens over
/// content and compete with the system sidebar material.
private struct EmptyDetailView: View {
    var body: some View {
        ContentUnavailableView {
            Label("未选择任务", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text("从列表中选择一个任务，查看进度、来源协议、引擎与保存位置。")
        }
    }
}
