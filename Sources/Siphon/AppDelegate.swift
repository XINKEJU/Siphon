import AppKit
import SwiftUI

/// Handles real application-level lifecycle events. View `onDisappear` is not a
/// reliable place to stop the download daemon — it also fires during navigation
/// changes and when auxiliary windows gain focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DownloadStore?

    override init() {
        super.init()
        // A download manager is a single-window app. Without this, macOS can
        // merge extra WindowGroup windows into tabs and stack translucent
        // columns on top of each other.
        NSWindow.allowsAutomaticWindowTabbing = false
        // After a self-update relaunch, the superseded <App>.old bundle lingers.
        cleanupUpdateBackups()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handles magnet: / ed2k: URL schemes and dropped .torrent / .metalink files.
        for url in urls {
            store?.add(urlString: url.absoluteString)
        }
    }
}
