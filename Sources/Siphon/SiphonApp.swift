import SwiftUI
import AppKit

/// Siphon — a native macOS download manager.
///
/// Architecture (borrowing the best of each project reviewed):
/// - The core for HTTP/HTTPS/FTP and every vendor-link front-end (thunder, WebDAV, S3, IPFS…)
///   is a dependency-free native engine (URLSession + byte-range segmentation).
/// - aria2 (C++) is an OPTIONAL separate process, used only for protocols with no pure-Swift
///   implementation: BitTorrent / Magnet / Metalink / SFTP (avoids GPL linking obligations).
/// - Native Swift engines also cover HLS, DASH (with native AVFoundation fMP4 flattening) and eD2K id.
/// - A DownloadManager routes each task to the correct engine and aggregates progress for the UI.
/// - QueueManager (named queues, sequential/concurrent, schedule windows) — inspired by AB DM / HyperDM.
/// - SpeedLimitController (global token bucket) — inspired by Motrix / HyperDM.
/// - ClipboardMonitor + browser native-messaging — inspired by HyperDM / Gopeed / AB DM.
@main
struct SiphonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DownloadStore()

    // Window-level UI state lives here so the menu-bar Commands and the
    // toolbar operate on exactly the same values (HIG: every toolbar command
    // must also be available from the menu bar).
    @State private var showingAdd = false
    /// Persisted so the detail column reopens in the same state on next launch.
    /// This used to be passed as `.constant(false)`, which made the "显示侧边栏"
    /// toggle in the More menu a no-op.
    @AppStorage("Siphon.showInspector") private var showingInspector = false

    var body: some Scene {
        // Single-window scene: opening a magnet:/ed2k: URL (or re-activating
        // the app) must not spawn extra translucent windows. It also removes
        // the default "New Window" menu item that clashes with ⌘N "new download".
        // HIG: don't title a window with the app name — the current library
        // selection supplies the real title via .navigationTitle.
        Window("下载", id: "main-window") {
            ContentView(showingAdd: $showingAdd, showingInspector: $showingInspector)
                .environment(store)
                .frame(minWidth: 700, minHeight: 450)
                .onAppear {
                    appDelegate.store = store
                    SystemPresence.shared.configure(store: store)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            SiphonCommands(showingAdd: $showingAdd,
                           showingInspector: $showingInspector, store: store)
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// Menu-bar equivalents of every toolbar action. The system may hide or let
/// people customise the toolbar, so no command may live only in the toolbar.
struct SiphonCommands: Commands {
    @Binding var showingAdd: Bool
    @Binding var showingInspector: Bool
    var store: DownloadStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建下载…") { showingAdd = true }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("显示") {
            Toggle("显示侧边栏", isOn: $showingInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("显示下载弹窗") { DownloadPopupController.shared.toggle(store: store) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandMenu("任务") {
            // 多选操作：与列表批量条、右键菜单共用同一套 store 方法，
            // 免得三处各写一遍循环、行为慢慢漂移。
            Button("暂停所选") { store.pauseTasks(store.selectedTaskIDs) }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!store.selectedTasks.contains {
                    $0.state == .active || $0.state == .pending
                })

            Button("继续所选") { store.resumeTasks(store.selectedTaskIDs) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!store.selectedTasks.contains {
                    $0.state == .paused || $0.state == .error
                })

            Button("拷贝所选链接") { _ = store.copyLinks(store.selectedTaskIDs) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selectedTaskIDs.isEmpty)

            Button("删除所选…") { store.pendingDeleteIDs = store.selectedTaskIDs }
                .disabled(store.selectedTaskIDs.isEmpty)

            Button("取消选择") { store.clearSelection() }
                .disabled(store.selectedTaskIDs.isEmpty)

            Divider()

            Button("恢复全部") {
                for t in store.tasks where t.state == .paused || t.state == .error {
                    store.resume(t.id)
                }
            }
            .disabled(!store.tasks.contains { $0.state == .paused || $0.state == .error })

            Button("全部暂停") {
                for t in store.tasks where t.state == .active { store.pause(t.id) }
            }
            .disabled(!store.tasks.contains { $0.state == .active })

            Divider()
            Button("清理已完成") { store.removeCompleted() }
            Button("在访达中打开下载目录") {
                NSWorkspace.shared.open(store.downloadDirectory)
            }
            Divider()
            Button("重新启动 aria2") { Task { await store.restartAria2() } }
        }
    }
}
