import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// MDM probes the system's default browser at startup and sends its
/// User-Agent with every plain HTTP(S) transfer, because many file hosts
/// reject unknown agents or serve a redirect/interstitial page to them.
///
/// This is a compatibility default, not impersonation: the user can override
/// it per task, per host (PerHostSettings) or through the browser gateway.
/// The value is computed once and cached for the process lifetime.
public enum BrowserUserAgent {
    public static let current: String = detect()

    private static func detect() -> String {
        #if canImport(AppKit)
        guard let appURL = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://example.com")!),
              let bundle = Bundle(url: appURL) else {
            return safari(version: "17.0")
        }
        let name = ((bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent).lowercased()
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.0"
        if name.contains("chrome") || name.contains("chromium") || name.contains("brave")
            || name.contains("vivaldi") || name.contains("arc") {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/\(version) Safari/537.36"
        }
        if name.contains("edge") {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/\(version) Safari/537.36 Edg/\(version)"
        }
        if name.contains("firefox") || name.contains("waterfox") || name.contains("librewolf") {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(version)) "
                + "Gecko/20100101 Firefox/\(version)"
        }
        return safari(version: version)
        #else
        return "Siphon/1.0"
        #endif
    }

    private static func safari(version: String) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version) Safari/605.1.15"
    }
}