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
                // Least-privilege gate: the sandbox can only honour pure URL
                // rewriting, so any plugin that asks for more is refused up front.
                if !manifest.permissions.isEmpty {
                    Self.log("插件 \"\(manifest.name)\" 请求了沙箱不支持的权限 \(manifest.permissions)，已拒绝加载")
                    continue
                }
                guard let scriptURL = entry.appendingPathComponent(manifest.script)
                        .existsAsFile else { continue }
                guard let ctx = JSContext() else { continue }
                Self.harden(ctx)
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

    /// Remove every JS global that could reach the network or the filesystem, and
    /// install an exception handler so a plugin error is logged rather than crashing
    /// the host. The VM is otherwise standard (pure JS, no bridges), so a malicious
    /// plugin can at worst rewrite one download URL — never touch the disk or network.
    private static func harden(_ ctx: JSContext) {
        let dangerous = ["XMLHttpRequest", "fetch", "WebSocket", "importScripts",
                         "import", "require", "process", "Worker", "EventSource",
                         "Notification", "indexedDB", "open", "location"]
        for name in dangerous {
            ctx.setObject(nil, forKeyedSubscript: name as NSString)
        }
        ctx.exceptionHandler = { _, exc in
            Self.log("插件脚本异常：\(exc?.toString() ?? "未知")")
        }
    }

    private static func log(_ message: String) {
        #if DEBUG
        print("[PluginHost] \(message)")
        #endif
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
        // Sanitize BEFORE parsing: the CRLF guard keeps spaces, and URL(string:)
        // rejects them — checking the raw string then unwrapping the cleaned one
        // could force-unwrap nil and crash on a space-bearing plugin URL.
        let cleanedURLString = Self.sanitize(newURL)
        guard let resolved = URL(string: cleanedURLString), resolved.scheme != nil else { return nil }
        let newHeaders = (dict["headers"] as? [String: String]) ?? headers
        // CRLF injection guard on everything a plugin produced.
        let cleanHeaders = newHeaders.mapValues { Self.sanitize($0) }
        let name = (dict["name"] as? String).map { Self.sanitize($0) }
        return Resolved(url: resolved, headers: cleanHeaders,
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
        /// Declared privileges. The sandbox only supports pure URL rewriting, so any
        /// non-empty list causes the plugin to be refused at load time.
        let permissions: [String]
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
        let permissions = (json["permissions"] as? [String])?.filter { !$0.isEmpty } ?? []
        return Manifest(name: name, match: match, script: script, permissions: permissions)
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
