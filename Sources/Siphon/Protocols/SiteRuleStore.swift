import Foundation

/// Per-site download rules for headers and file names.
///
/// `PerHostSettings` already owns connection counts / speed caps / User-Agent;
/// this store covers the *origin* side of a request: a required `Referer`,
/// extra anti-hotlink headers, and a filename prefix/suffix. It is persisted in
/// UserDefaults and matched by exact host first, then `*.domain`.
///
/// Rules only **fill gaps**: a header explicitly supplied by the caller (browser
/// extension, Add Task form, plugin) is never overwritten.
public struct SiteRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// `example.com` or `*.example.com` (the wildcard also matches the apex).
    public var host: String
    public var referer: String
    public var userAgent: String
    public var filenamePrefix: String
    /// Inserted before the file extension, e.g. `clip` → `clip [siphon].mp4`.
    public var filenameSuffix: String
    public var extraHeaders: [String: String]

    public init(id: UUID = UUID(), host: String = "", referer: String = "",
                userAgent: String = "", filenamePrefix: String = "",
                filenameSuffix: String = "", extraHeaders: [String: String] = [:]) {
        self.id = id; self.host = host; self.referer = referer
        self.userAgent = userAgent; self.filenamePrefix = filenamePrefix
        self.filenameSuffix = filenameSuffix; self.extraHeaders = extraHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case id, host, referer, userAgent, filenamePrefix, filenameSuffix, extraHeaders
    }

    /// Hand-written decode so older/newer files with missing keys keep working
    /// (synthesised Decodable ignores the memberwise defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        referer = (try? c.decode(String.self, forKey: .referer)) ?? ""
        userAgent = (try? c.decode(String.self, forKey: .userAgent)) ?? ""
        filenamePrefix = (try? c.decode(String.self, forKey: .filenamePrefix)) ?? ""
        filenameSuffix = (try? c.decode(String.self, forKey: .filenameSuffix)) ?? ""
        extraHeaders = (try? c.decode([String: String].self, forKey: .extraHeaders)) ?? [:]
    }
}

public final class SiteRuleStore: @unchecked Sendable {
    public static let shared = SiteRuleStore()

    private let lock = NSLock()
    public private(set) var rules: [SiteRule] = []
    private static let key = "Siphon.siteRules"

    init() { load() }

    /// Best match: exact host, then the longest matching `*.domain` pattern.
    public func rule(for host: String) -> SiteRule? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let exact = rules.first(where: { $0.host.lowercased() == h }) { return exact }
        let wildcards = rules.filter { $0.host.hasPrefix("*.") }.sorted {
            $0.host.count > $1.host.count
        }
        for rule in wildcards {
            let domain = rule.host.dropFirst(2).lowercased()
            if h == domain || h.hasSuffix("." + domain) { return rule }
        }
        return nil
    }

    public func rule(for url: URL) -> SiteRule? {
        guard let host = url.host else { return nil }
        return rule(for: host)
    }

    public func upsert(_ rule: SiteRule) {
        lock.lock()
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else if let i = rules.firstIndex(where: {
            $0.host.lowercased() == rule.host.lowercased() && !rule.host.isEmpty
        }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        lock.unlock()
        save()
    }

    public func remove(_ id: UUID) {
        lock.lock(); rules.removeAll { $0.id == id }; lock.unlock()
        save()
    }

    public func replaceAll(_ newRules: [SiteRule]) {
        lock.lock(); rules = newRules; lock.unlock()
        save()
    }

    // MARK: - request enrichment

    /// Fill headers the caller did not supply. Keys are compared case-insensitively.
    public func enrichedOptions(_ options: [String: String], for url: URL) -> [String: String] {
        guard let rule = rule(for: url) else { return options }
        var out = options
        let present = Set(options.keys.map { $0.lowercased() })
        if !rule.referer.isEmpty, !present.contains("referer") {
            out["Referer"] = rule.referer
        }
        if !rule.userAgent.isEmpty, !present.contains("user-agent") {
            out["User-Agent"] = rule.userAgent
        }
        for (key, value) in rule.extraHeaders {
            let k = key.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !value.isEmpty else { continue }
            if !present.contains(k.lowercased()) { out[k] = value }
        }
        return out
    }

    /// Apply the filename prefix/suffix before the extension.
    public func adjustedFileName(_ name: String, for url: URL) -> String {
        guard let rule = rule(for: url),
              !rule.filenamePrefix.isEmpty || !rule.filenameSuffix.isEmpty else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let adjusted = rule.filenamePrefix + base + rule.filenameSuffix
        return ext.isEmpty ? adjusted : adjusted + "." + ext
    }

    // MARK: - persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([SiteRule].self, from: data) else { return }
        rules = decoded
    }

    private func save() {
        lock.lock()
        let snapshot = rules
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
