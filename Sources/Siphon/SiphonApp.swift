import SwiftUI

/// Siphon — a native macOS download manager.
///
/// Architecture (borrowing the best of each project reviewed):
/// - aria2 (C++) is the battle-tested core for HTTP/HTTPS/FTP/SFTP/BitTorrent/Metalink/magnet,
///   driven over JSON-RPC as a separate process (avoids GPL linking obligations).
/// - Native Swift engines add the protocols aria2 lacks: HLS, DASH and eD2K identification.
/// - A DownloadManager routes each task to the correct engine and aggregates progress for the UI.
/// - QueueManager (named queues, sequential/concurrent, schedule windows) — inspired by AB DM / HyperDM.
/// - SpeedLimitController (global token bucket + aria2 limit) — inspired by Motrix / HyperDM.
/// - ClipboardMonitor + browser native-messaging — inspired by HyperDM / Gopeed / AB DM.
@main
struct SiphonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DownloadStore()

    var body: some Scene {
        // Single-window scene: opening a magnet:/ed2k: URL (or re-activating
        // the app) must not spawn extra translucent windows. It also removes
        // the default "New Window" menu item that clashes with ⌘N "new download".
        Window("Siphon", id: "main-window") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appDelegate.store = store }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
