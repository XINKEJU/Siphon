import Foundation
import JavaScriptCore

/// JavaScript plugin system (ABD's app.js plugins, minimal viable shape).
///
/// A plugin is a directory under `Application Support/Siphon/plugins/<name>/`
/// containing:
///
/// ```
/// manifest.json  { "name": "…", "version": "…", "match": ["host.example/*"] }
/// main.js        function resolve(url, headers) -> { url, headers?, name? }
/// ```
///
/// When a submitted URL matches a plugin's `match` wildcard, the plugin's
/// `resolve` function may rewrite it into a direct download URL (rename it,
/// attach headers). Plugins run in an isolated `JSContext` with **no** network
/// or filesystem access — they are pure URL rewriters, which keeps the trust
/// model simple: a malicious plugin can at worst misdirect one download.
///
/// `SIPHON_PLUGINS_DIR` overrides the directory (tests inject fixtures).
public final class PluginHost: @unchecked Sendable {

    public struct Resolved: Equatable {
        public let url: URL
        public let headers: [String: String]
        public let name: String?
    }

    struct Plugin {
        let name: String
        let matches: [String]
        let context: JSContext
    }

    public static let shared = PluginHost()

    private let lock = NSLock()
    private var plugins: [Plugin] = []
    private var loaded = false

    private init() {}

    public static func pluginsDirectory() -> URL {
        if let p = ProcessInfo.processInfo.environment["SIPHON_PLUGINS_DIR"],
           !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("Siphon/plugins", isDirectory: true)
    }

    /// Scan + compile. Safe to call repeatedly; re-reads from disk. A plugin
    /// with a broken manifest or script is skipped (never fatal to the app).
    public func reload() {
        let dir = Self.pluginsDirectory()
        var found: [Plugin] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for entry in entries {
                guard entry.isDirectoryFallback,
                      let manifest = Self.loadManifest(at: entry) else { continue }
                guard let scriptURL = entry.appendingPathComponent(manifest.script)
                        .existsAsFile else { continue }
                guard let ctx = JSContext() else { continue }
                let source = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
                ctx.evaluateScript(source)
                // The script must define a global `resolve`; anything else is
                // unusable and skipped.
                guard ctx.objectForKeyedSubscript("resolve")?.isObject == true else {
                    continue
                }
                found.append(Plugin(name: manifest.name, matches: manifest.match,
                                    context: ctx))
            }
        }
        lock.lock(); plugins = found; loaded = true; lock.unlock()
    }

    public var count: Int {
        ensureLoaded()
        return lock.withLock { plugins.count }
    }

    public var pluginNames: [String] {
        ensureLoaded()
        return lock.withLock { plugins.map { $0.name } }
    }

    private func ensureLoaded() {
        lock.lock()
        let wasLoaded = loaded
        lock.unlock()
        if !wasLoaded { reload() }
    }

    // MARK: - matching & resolution

    /// Wildcard matcher: patterns match against `host + "/" + path`, e.g.
    /// `"example.com/*"`, `"*.example.com/*"`. `*` and `?` are the only wildcards.
    static func patternMatches(_ pattern: String, url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.isEmpty ? "/" : url.path
        let subject = host + path
        return Self.fnmatch(pattern.lowercased(), subject)
    }

    /// POSIX-style glob → regex translation. Small and side-effect free.
    static func fnmatch(_ pattern: String, _ subject: String) -> Bool {
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += "[^/]*"
            case "?": regex += "."
            case ".", "(", ")", "[", "]", "{", "}", "^", "$", "+", "|", "\\":
                regex += "\\" + String(ch)
            default: regex += String(ch)
            }
        }
        regex += "$"
        return subject.range(of: regex, options: .regularExpression) != nil
    }

    /// Run the first matching plugin's `resolve`. Returns nil when no plugin
    /// matches or the script returns nothing usable — the caller then proceeds
    /// with the original URL.
    public func resolve(urlString: String, headers: [String: String]) -> Resolved? {
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        ensureLoaded()
        let current = lock.withLock { plugins }
        guard let plugin = current.first(where: {
            $0.matches.contains { Self.patternMatches($0, url: url) }
        }) else { return nil }

        let resolveFn = plugin.context.objectForKeyedSubscript("resolve")
        let args: [Any] = [urlString, NSDictionary(dictionary: headers)]
        let out = resolveFn?.call(withArguments: args)
        guard let dict = out?.toDictionary() as? [String: Any],
              let newURL = dict["url"] as? String, !newURL.isEmpty,
              URL(string: newURL)?.scheme != nil else { return nil }
        let newHeaders = (dict["headers"] as? [String: String]) ?? headers
        // CRLF injection guard on everything a plugin produced.
        let cleanHeaders = newHeaders.mapValues { Self.sanitize($0) }
        let name = (dict["name"] as? String).map { Self.sanitize($0) }
        return Resolved(url: URL(string: Self.sanitize(newURL))!, headers: cleanHeaders,
                        name: (name?.isEmpty == false) ? name : nil)
    }

    static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value > 0x1F || $0 == " " })
    }

    // MARK: - manifest

    struct Manifest {
        let name: String
        let match: [String]
        let script: String
    }

    static func loadManifest(at pluginDir: URL) -> Manifest? {
        guard let manifestURL = pluginDir.appendingPathComponent("manifest.json")
                .existsAsFile else { return nil }
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let name = (json["name"] as? String) ?? pluginDir.lastPathComponent
        let match = (json["match"] as? [String])?.filter { !$0.isEmpty } ?? []
        guard !match.isEmpty else { return nil }
        let script = (json["script"] as? String) ?? "main.js"
        return Manifest(name: name, match: match, script: script)
    }
}

private extension URL {
    var isDirectoryFallback: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    var existsAsFile: URL? {
        FileManager.default.fileExists(atPath: path) ? self : nil
    }
}
