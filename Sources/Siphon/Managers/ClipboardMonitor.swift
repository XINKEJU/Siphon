import AppKit
import Observation

/// Watches the pasteboard for downloadable URLs (inspired by HyperDM's clipboard monitor).
/// Only *new* strings are reported, and a URL is emitted at most once per copy.
///
/// Smart mode (`smartDetection = true`) only fires for URLs that look like downloads:
/// recognized file extensions, media stream patterns, or known download sites.
@MainActor
@Observable
public final class ClipboardMonitor {
    public var isEnabled = false
    public var smartDetection = true
    public var lastDetected: URL?

    private var timer: Timer?
    private var lastChangeCount: Int
    private var seen: Set<String> = []

    public init() { lastChangeCount = NSPasteboard.general.changeCount }

    /// Called when a download-like URL is detected. The boolean indicates whether
    /// smart detection classified it as a definite download (true) or a generic
    /// URL that passed the basic filter (false).
    public var onURLDetected: ((URL, Bool) -> Void)?

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

    // MARK: - download URL patterns

    private static let downloadExtensions: Set<String> = [
        // archives
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "tbz2", "lz", "lzma",
        // documents
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
        "rtf", "epub", "mobi", "azw", "azw3", "djvu",
        // installers
        "exe", "msi", "dmg", "pkg", "deb", "rpm", "apk", "ipa", "appimage",
        // disk images
        "iso", "img", "vmdk", "vdi", "vhd",
        // torrents / metalinks
        "torrent", "metalink", "meta4",
        // media
        "mp4", "m4v", "webm", "mkv", "avi", "mov", "flv", "wmv", "mpg", "mpeg",
        "3gp", "3g2", "ts", "m2ts", "vob", "ogv",
        "mp3", "m4a", "aac", "flac", "ogg", "wav", "wma", "opus", "aiff", "ape",
        // playlists
        "m3u8", "mpd", "m3u",
    ]

    private static let mediaStreamPatterns = [".m3u8", ".mpd", ".m3u"]

    private static let knownDownloadSites: [String] = [
        "github.com", "gitlab.com", "bitbucket.org",
        "sourceforge.net", "archive.org",
        "download.", "dl.", "releases.",
    ]

    /// Returns true if the URL looks like a downloadable file rather than a web page.
    public static func isDownloadURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let path = url.path.lowercased()

        // Check file extension
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty && downloadExtensions.contains(ext) { return true }

        // Check media stream patterns (may have query strings)
        for pattern in mediaStreamPatterns {
            if urlString.contains(pattern) { return true }
        }

        // Check known download sites with direct file paths
        if let host = url.host?.lowercased() {
            for site in knownDownloadSites {
                if host == site || host.hasSuffix("." + site) || host.hasPrefix(site) {
                    // Only if path looks like a file (has extension)
                    if !ext.isEmpty { return true }
                }
            }
        }

        return false
    }

    /// Returns true if the URL uses a scheme we can handle.
    private static func hasSupportedScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return URISchemes.all.contains(scheme)
            || url.absoluteString.contains(".m3u8")
            || url.absoluteString.contains(".mpd")
    }

    // MARK: - polling

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let raw = pb.string(forType: .string) else { return }

        // Only act on a single plausible download URL, not arbitrary copied text.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "),
              let url = URL(string: trimmed),
              Self.hasSupportedScheme(url) else { return }
        guard !seen.contains(trimmed) else { return }
        seen.insert(trimmed)
        if seen.count > 200 { seen.removeAll() }

        let isDefiniteDownload = Self.isDownloadURL(url)

        // In smart mode, only emit definite downloads.
        if smartDetection && !isDefiniteDownload { return }

        lastDetected = url
        onURLDetected?(url, isDefiniteDownload)
    }
}
