import Foundation
import JavaScriptCore
import OSLog

/// JavaScript plugin system (ABD's app.js plugins, minimal viable shape).
///
/// A plugin is a directory under `Application Support/Siphon/plugins/<name>/`
/// containing:
///
/// ```
/// manifest.json  { "name": "…", "version": "1.0", "apiVersion": 2,
///                  "priority": 0, "match": ["host.example/*"] }
/// main.js        function resolve(url, headers) -> {
///                    url, headers?, name?, mirrors?, checksum?, queue?
///                }
/// ```
///
/// When a submitted URL matches a plugin's `match` wildcard, the plugin's
/// `resolve` function may rewrite it into a direct download URL (rename it,
/// attach headers, add mirrors / checksum / queue). Plugins run in a
/// `JSContext` whose obvious network/filesystem globals are removed and whose
/// manifest may not request extra permissions.
///
/// **This is defence in depth, not a process sandbox.** JavaScriptCore runs
/// in-process, with no execution timeout or memory cap: a deliberately hostile
/// script can still hang the calling thread or exploit a JSC bug with the app's
/// full privileges. Only install plugins you trust; the Settings page states
/// the same. A future process-isolated plugin host would remove that caveat.
///
/// API v2 additions are all optional, so v1 plugins keep working unchanged:
/// `apiVersion` (default 1, values > 2 are refused), `priority` (higher runs
/// first), and the extra `resolve` result fields above. Enable/disable state
/// is persisted per plugin name; disabled plugins stay listed but never run.
///
/// `SIPHON_PLUGINS_DIR` overrides the directory (tests inject fixtures).
public final class PluginHost: @unchecked Sendable {

    public struct Resolved: Equatable {
        public let url: URL
        public let headers: [String: String]
        public let name: String?
        /// API v2: alternate sources for the same file.
        public let mirrors: [URL]
        /// API v2: expected integrity hash (`sha256:…` or bare hex).
        public let checksum: String?
        /// API v2: destination queue name.
        public let queueName: String?
    }

    /// User-facing snapshot of one plugin directory, including load failures.
    public struct PluginInfo: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let version: String
        public let apiVersion: Int
        public let priority: Int
        public let matches: [String]
        public let enabled: Bool
        /// Non-nil when the directory was skipped; shown in Settings.
        public let error: String?

        public init(name: String, version: String, apiVersion: Int, priority: Int,
                    matches: [String], enabled: Bool, error: String? = nil) {
            self.name = name
            self.version = version
            self.apiVersion = apiVersion
            self.priority = priority
            self.matches = matches
            self.enabled = enabled
            self.error = error
        }
    }

    struct Plugin {
        let name: String
        let version: String
        let apiVersion: Int
        let priority: Int
        let matches: [String]
        let context: JSContext
    }

    public static let shared = PluginHost()

    private let lock = NSLock()
    private var plugins: [Plugin] = []
    private var infos: [PluginInfo] = []
    private var loaded = false

    public static let maxAPIVersion = 2

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

    /// Create the plugin directory if it does not exist yet.
    @discardableResult
    public func ensurePluginsDirectory() -> URL {
        let dir = Self.pluginsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scan + compile. Safe to call repeatedly; re-reads from disk. A plugin
    /// with a broken manifest or script is skipped (never fatal to the app),
    /// but still appears in `pluginInfos` with an `error` so the user can fix it.
    public func reload() {
        let dir = Self.pluginsDirectory()
        var found: [Plugin] = []
        var foundInfos: [PluginInfo] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard entry.isDirectoryFallback else { continue }
                let dirName = entry.lastPathComponent
                let manifestURL = entry.appendingPathComponent("manifest.json")
                guard manifestURL.existsAsFile != nil else {
                    foundInfos.append(PluginInfo(name: dirName, version: "—", apiVersion: 1,
                                                 priority: 0, matches: [],
                                                 enabled: Self.isEnabled(dirName),
                                                 error: "缺少 manifest.json"))
                    continue
                }
                guard let manifest = Self.loadManifest(at: entry) else {
                    foundInfos.append(PluginInfo(name: dirName, version: "—", apiVersion: 1,
                                                 priority: 0, matches: [],
                                                 enabled: Self.isEnabled(dirName),
                                                 error: "manifest.json 无效或缺少 match 规则"))
                    continue
                }
                let enabled = Self.isEnabled(manifest.name)
                // Version gate: only API 1 / 2 exist. Refuse future versions
                // upfront instead of silently running them with old semantics.
                guard manifest.apiVersion <= Self.maxAPIVersion else {
                    foundInfos.append(PluginInfo(name: manifest.name, version: manifest.version,
                                                 apiVersion: manifest.apiVersion,
                                                 priority: manifest.priority,
                                                 matches: manifest.match, enabled: enabled,
                                                 error: "不支持的 apiVersion \(manifest.apiVersion)"))
                    continue
                }
                // Least-privilege gate: the sandbox can only honour pure URL
                // rewriting, so any plugin that asks for more is refused up front.
                if !manifest.permissions.isEmpty {
                    let msg = "请求了沙箱不支持的权限 \(manifest.permissions.joined(separator: ", "))"
                    Self.log("插件 \"\(manifest.name)\" \(msg)，已拒绝加载")
                    foundInfos.append(PluginInfo(name: manifest.name, version: manifest.version,
                                                 apiVersion: manifest.apiVersion,
                                                 priority: manifest.priority,
                                                 matches: manifest.match, enabled: enabled,
                                                 error: msg))
                    continue
                }
                // `manifest.script` comes from a package on disk. Force it to a
                // single component inside the plugin directory (no `../../`),
                // and cap the source size before handing it to JavaScriptCore.
                let scriptName = (manifest.script as NSString).lastPathComponent
                let pluginRoot = entry.standardizedFileURL.path
                let candidate = entry.appendingPathComponent(scriptName).standardizedFileURL
                guard !scriptName.isEmpty, scriptName != ".", scriptName != "..",
                      candidate.path.hasPrefix(pluginRoot + "/"),
                      let scriptURL = candidate.existsAsFile,
                      let attrs = try? FileManager.default.attributesOfItem(
                          atPath: scriptURL.path),
                      let size = attrs[.size] as? NSNumber,
                      size.uint64Value <= 1 << 20 else {
                    let msg = "脚本路径越界、缺失或超过 1 MiB：\(manifest.script)"
                    Self.log("插件 \"\(manifest.name)\" \(msg)，已拒绝加载")
                    foundInfos.append(PluginInfo(name: manifest.name, version: manifest.version,
                                                 apiVersion: manifest.apiVersion,
                                                 priority: manifest.priority,
                                                 matches: manifest.match, enabled: enabled,
                                                 error: msg))
                    continue
                }
                guard let ctx = JSContext() else { continue }
                Self.harden(ctx)
                let source = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
                ctx.evaluateScript(source)
                if let exception = ctx.exception {
                    let msg = exception.toString() ?? "未知错误"
                    foundInfos.append(PluginInfo(name: manifest.name, version: manifest.version,
                                                 apiVersion: manifest.apiVersion,
                                                 priority: manifest.priority,
                                                 matches: manifest.match, enabled: enabled,
                                                 error: "脚本加载失败：\(msg)"))
                    continue
                }
                // The script must define a global `resolve`; anything else is
                // unusable and skipped.
                guard ctx.objectForKeyedSubscript("resolve")?.isObject == true else {
                    foundInfos.append(PluginInfo(name: manifest.name, version: manifest.version,
                                                 apiVersion: manifest.apiVersion,
                                                 priority: manifest.priority,
                                                 matches: manifest.match, enabled: enabled,
                                                 error: "脚本未定义 resolve(url, headers)"))
                    continue
                }
                found.append(Plugin(name: manifest.name, version: manifest.version,
                                    apiVersion: manifest.apiVersion,
                                    priority: manifest.priority,
                                    matches: manifest.match, context: ctx))
                foundInfos.append(PluginInfo(name: manifest.name, version: manifest.version,
                                             apiVersion: manifest.apiVersion,
                                             priority: manifest.priority,
                                             matches: manifest.match, enabled: enabled))
            }
        }
        // Higher priority first; ties fall back to name for deterministic order.
        found.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.name < $1.name }
        foundInfos.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.name < $1.name }
        lock.lock()
        plugins = found
        infos = foundInfos
        loaded = true
        lock.unlock()
    }

    /// Remove the obvious JS globals that could reach the network or filesystem
    /// and install an exception handler. This is a denylist of names JSC does not
    /// normally expose anyway — useful as defence in depth, **not** a security
    /// boundary (see the class documentation). JS exceptions are logged in both
    /// debug and release builds so a broken plugin is diagnosable.
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

    private static let logger = Logger(subsystem: "com.xinkeju.siphon.macos",
                                       category: "plugins")

    private static func log(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    public var count: Int {
        ensureLoaded()
        return lock.withLock { plugins.count }
    }

    public var pluginNames: [String] {
        ensureLoaded()
        return lock.withLock { plugins.map { $0.name } }
    }

    /// All discovered plugin directories (loaded or failed), sorted by priority.
    public var pluginInfos: [PluginInfo] {
        ensureLoaded()
        return lock.withLock { infos }
    }

    private static func enabledKey(_ name: String) -> String { "Siphon.pluginEnabled.\(name)" }

    static func isEnabled(_ name: String) -> Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: enabledKey(name)) != nil else { return true }
        return d.bool(forKey: enabledKey(name))
    }

    /// Persist the enable flag. Resolution reads it live; no recompile required.
    public func setEnabled(name: String, on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey(name))
        lock.lock()
        infos = infos.map {
            PluginInfo(name: $0.name, version: $0.version, apiVersion: $0.apiVersion,
                       priority: $0.priority, matches: $0.matches,
                       enabled: $0.name == name ? on : $0.enabled, error: $0.error)
        }
        lock.unlock()
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

    /// Run the highest-priority matching, enabled plugin's `resolve`. Returns nil
    /// when no plugin matches or the script returns nothing usable — the caller
    /// then proceeds with the original URL.
    public func resolve(urlString: String, headers: [String: String]) -> Resolved? {
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        ensureLoaded()
        let current = lock.withLock { plugins }
        guard let plugin = current.first(where: { p in
            Self.isEnabled(p.name) && p.matches.contains { Self.patternMatches($0, url: url) }
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
        let mirrorStrings = (dict["mirrors"] as? [String]) ?? []
        let mirrors = mirrorStrings
            .map { Self.sanitize($0) }
            .filter { URL(string: $0)?.scheme != nil }
            .compactMap { URL(string: $0) }
        let checksum = (dict["checksum"] as? String).map { Self.sanitize($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let queueRaw = (dict["queue"] as? String) ?? (dict["queueName"] as? String)
        let queueName = queueRaw.map { Self.sanitize($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return Resolved(url: resolved, headers: cleanHeaders,
                        name: (name?.isEmpty == false) ? name : nil,
                        mirrors: mirrors, checksum: checksum, queueName: queueName)
    }

    static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value > 0x1F || $0 == " " })
    }

    // MARK: - example plugin

    /// Write a commented example plugin (API v2) into the plugin directory and
    /// reload. Existing files are left untouched. Returns the directory URL.
    @discardableResult
    public func createExamplePlugin() -> URL? {
        let dir = ensurePluginsDirectory().appendingPathComponent("example-rewriter",
                                                                  isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {
          "name": "示例：直链改写",
          "version": "1.0",
          "apiVersion": 2,
          "priority": 10,
          "match": ["example.com/download/*"],
          "script": "main.js"
        }
        """
        let script = """
        // 示例插件（API v2）：把页面链接改写成 CDN 直链，并附带请求头、
        // 备用镜像、校验和与目标队列。返回值里的所有字段都是可选的。
        function resolve(url, headers) {
          var direct = url.replace("/download/", "/cdn/");
          return {
            url: direct,
            headers: Object.assign({}, headers, { Referer: "https://example.com/" }),
            name: "example.bin",
            mirrors: [direct + "?mirror=1", direct + "?mirror=2"],
            checksum: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            queue: "Default"
          };
        }
        """
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let scriptURL = dir.appendingPathComponent("main.js")
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        reload()
        return dir
    }

    // MARK: - manifest

    struct Manifest {
        let name: String
        let version: String
        let apiVersion: Int
        let priority: Int
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
        // Older manifests omit these; defaults keep API v1 plugins working.
        let version = (json["version"] as? String) ?? "1.0"
        let apiVersion = (json["apiVersion"] as? NSNumber)?.intValue ?? 1
        let priority = (json["priority"] as? NSNumber)?.intValue ?? 0
        return Manifest(name: name, version: version, apiVersion: apiVersion,
                        priority: priority, match: match, script: script,
                        permissions: permissions)
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
