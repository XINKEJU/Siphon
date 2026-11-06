import AppKit

/// Watches the pasteboard for downloadable URLs (inspired by HyperDM's clipboard monitor).
/// Only *new* strings are reported, and a URL is emitted at most once per copy.
@MainActor
public final class ClipboardMonitor: ObservableObject {
    @Published public var isEnabled = false
    @Published public var lastDetected: URL?

    private var timer: Timer?
    private var lastChangeCount: Int
    private var seen: Set<String> = []

    public init() { lastChangeCount = NSPasteboard.general.changeCount }

    public var onURLDetected: ((URL) -> Void)?

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        timer?.invalidate()
        guard enabled else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let raw = pb.string(forType: .string) else { return }

        // Only act on a single plausible download URL, not arbitrary copied text.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "sftp", "magnet", "ed2k"].contains(scheme)
                || trimmed.contains(".m3u8") || trimmed.contains(".mpd") else { return }
        guard !seen.contains(trimmed) else { return }
        seen.insert(trimmed)
        if seen.count > 200 { seen.removeAll() }
        lastDetected = url
        onURLDetected?(url)
    }
}
