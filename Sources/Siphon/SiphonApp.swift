import SwiftUI
import AppKit

/// Siphon — native macOS download manager, MDM-aligned product layer.
///
/// - The engine layer (native HTTP/HLS/DASH/eD2K + optional aria2) is unchanged.
/// - The product layer follows MDM's contract: one command vocabulary, five
///   user-visible states, MDM's category tree, 14-column list, progress window
///   with Status/Limiter/Completion tabs, and a 12-page Options window.
/// - Every toolbar action is also present in the menu bar (macOS HIG).
@main
struct SiphonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DownloadStore()

    @State private var showingAdd = false
    @AppStorage("Siphon.showInspector") private var showingInspector = false

    var body: some Scene {
        Window("下载", id: "main-window") {
            ContentView(showingAdd: $showingAdd, showingInspector: $showingInspector)
                .environment(store)
                // A min-only frame makes the root view size to its ideal height
                // (~135pt) and centre it once the window grows. The max:infinity
                // proposal lets the three-pane layout fill the whole window.
                .frame(minWidth: 700, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)
                .onAppear {
                    appDelegate.store = store
                    SystemPresence.shared.configure(store: store)
                    appDelegate.flushPendingServiceText()
                    store.handleNetworkChange(NetworkMonitor.shared.status)
                }
        }
        // contentSize pins the window to the collapsed ideal size so it can
        // never be enlarged. contentMinSize keeps 700x450 as the floor while
        // allowing the user to resize the window normally.
        .windowResizability(.contentMinSize)
        .commands {
            SiphonCommands(showingAdd: $showingAdd,
                           showingInspector: $showingInspector,
                           store: store)
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

extension Notification.Name {
    static let mdmOpenAddURL = Notification.Name("mdm.openAddURL")
    static let mdmOpenLinkGrabber = Notification.Name("mdm.openLinkGrabber")
    static let mdmOpenOptions = Notification.Name("mdm.openOptions")
    static let mdmOpenFind = Notification.Name("mdm.openFind")
    static let mdmOpenScheduler = Notification.Name("mdm.openScheduler")
    static let mdmOpenProperties = Notification.Name("mdm.openProperties")
    static let mdmOpenVerify = Notification.Name("mdm.openVerify")
}

/// MDM's menu bar: Tasks / File / Downloads / View / Help. The order and
/// mnemonics mirror the IDM-derived layout; the commands act on the same
/// store methods as the toolbar and context menus.
struct SiphonCommands: Commands {
    @Binding var showingAdd: Bool
    @Binding var showingInspector: Bool
    var store: DownloadStore
    @ObservedObject private var theme = MDMThemeStore.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu(MDMI18n.t("menu.tasks")) {
            Button(MDMI18n.t("menu.addURL")) {
                NotificationCenter.default.post(name: .mdmOpenAddURL, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(MDMI18n.t("menu.downloadLater")) {
                NotificationCenter.default.post(name: .mdmOpenAddURL, object: nil)
            }
            Button(MDMI18n.t("menu.linkGrabber")) {
                NotificationCenter.default.post(name: .mdmOpenLinkGrabber, object: nil)
            }
            Button(MDMI18n.t("menu.batch")) { showingAdd = true }

            Divider()

            Button(MDMI18n.t("menu.scheduler")) {
                NotificationCenter.default.post(name: .mdmOpenScheduler, object: nil)
            }
            Button(MDMI18n.t("menu.find")) {
                NotificationCenter.default.post(name: .mdmOpenFind, object: nil)
            }
            Button(MDMI18n.t("menu.properties")) {
                NotificationCenter.default.post(name: .mdmOpenProperties, object: nil)
            }
            .disabled(store.selectedTaskID == nil)
            Button(MDMI18n.t("menu.verifyChecksum")) {
                NotificationCenter.default.post(name: .mdmOpenVerify, object: nil)
            }
            Divider()
            Button(MDMI18n.t("menu.options")) {
                NotificationCenter.default.post(name: .mdmOpenOptions, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu(MDMI18n.t("menu.file")) {
            Button("打开下载文件夹") {
                NSWorkspace.shared.open(store.downloadDirectory)
            }
            Button("打开所选文件") { openSelectedFiles() }
                .disabled(selectedFileURLs.isEmpty)
            Button("在访达中显示") { revealSelectedFiles() }
                .disabled(selectedFileURLs.isEmpty)
            Button("快速查看") { QuickLookController.shared.toggle(urls: selectedFileURLs) }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(selectedFileURLs.isEmpty)
            Divider()
            Button("清理已完成") { store.removeCompleted() }
            Button("重新启动 aria2") { Task { await store.restartAria2() } }
        }

        CommandMenu(MDMI18n.t("menu.downloads")) {
            Button(MDMI18n.t("menu.pauseSelected")) { store.pauseTasks(store.selectedTaskIDs) }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!store.selectedTasks.contains {
                    $0.state == .active || $0.state == .pending
                })
            Button(MDMI18n.t("menu.resumeSelected")) { store.resumeTasks(store.selectedTaskIDs) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!store.selectedTasks.contains {
                    $0.state == .paused || $0.state == .error
                })
            Button(MDMI18n.t("menu.copySelectedLinks")) { _ = store.copyLinks(store.selectedTaskIDs) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selectedTaskIDs.isEmpty)
            Button(MDMI18n.t("menu.deleteSelected")) {
                store.pendingDeleteIDs = store.selectedTaskIDs
            }
            .disabled(store.selectedTaskIDs.isEmpty)
            Button(MDMI18n.t("menu.clearSelection")) { store.clearSelection() }
                .disabled(store.selectedTaskIDs.isEmpty)

            Divider()

            Menu("Speed Limiter") {
                Button("不限速") { store.setSpeedLimit(store.selectedTaskIDs, bytesPerSec: nil) }
                Button("512 KB/s") { store.setSpeedLimit(store.selectedTaskIDs, bytesPerSec: 524288) }
                Button("1 MB/s") { store.setSpeedLimit(store.selectedTaskIDs, bytesPerSec: 1048576) }
                Button("5 MB/s") { store.setSpeedLimit(store.selectedTaskIDs, bytesPerSec: 5242880) }
            }
            Menu("优先级") {
                Button("高") { store.setPriority(store.selectedTaskIDs, 1) }
                Button("普通") { store.setPriority(store.selectedTaskIDs, 0) }
                Button("低") { store.setPriority(store.selectedTaskIDs, -1) }
            }

            Divider()

            Button(MDMI18n.t("menu.resumeAll")) { store.resumeAll() }
            Button(MDMI18n.t("menu.pauseAll")) { store.pauseAll() }
        }

        CommandMenu(MDMI18n.t("menu.view")) {
            Toggle(MDMI18n.t("menu.showInspector"), isOn: $showingInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(MDMI18n.t("menu.showPopup")) {
                DownloadPopupController.shared.toggle(store: store)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("进度窗口") {
                guard let id = store.selectedTaskID else { return }
                MDMProgressPanelController.shared.show(taskID: id, store: store)
            }
            .disabled(store.selectedTaskID == nil)

            Divider()

            Menu("主题") {
                ForEach(MDMTheme.allCases) { item in
                    Button {
                        theme.theme = item
                    } label: {
                        if theme.theme == item {
                            Label(item.displayName, systemImage: "checkmark")
                        } else { Text(item.displayName) }
                    }
                }
            }
            Menu("外观") {
                ForEach(MDMAppearance.allCases, id: \.rawValue) { item in
                    Button {
                        theme.appearance = item
                    } label: {
                        let title = item == .system ? "跟随系统"
                                    : item == .light ? "浅色" : "深色"
                        if theme.appearance == item { Label(title, systemImage: "checkmark") }
                        else { Text(title) }
                    }
                }
            }
            Menu("界面大小") {
                ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { scale in
                    Button {
                        theme.scale = scale
                    } label: {
                        if theme.scale == scale {
                            Label("\(Int(scale * 100))%", systemImage: "checkmark")
                        } else { Text("\(Int(scale * 100))%") }
                    }
                }
            }
            Menu("语言") {
                ForEach(MDMI18n.availableLanguages, id: \.code) { language in
                    Button {
                        MDMI18n.shared.language = language.code
                    } label: {
                        if MDMI18n.shared.language == language.code {
                            Label(language.name, systemImage: "checkmark")
                        } else { Text(language.name) }
                    }
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button("关于 Siphon") { NSApp.orderFrontStandardAboutPanel(nil) }
        }
    }

    private var selectedFileURLs: [URL] {
        store.selectedTasks
            .map(\.destination)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func openSelectedFiles() {
        for url in selectedFileURLs { NSWorkspace.shared.open(url) }
    }

    private func revealSelectedFiles() {
        let urls = selectedFileURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
