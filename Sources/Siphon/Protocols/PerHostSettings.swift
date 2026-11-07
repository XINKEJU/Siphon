import Foundation

/// Per-host connection / bandwidth / identity overrides (AB Download Manager
/// `PerHostSettingsManager`). Lets the user tune a specific host without
/// touching the global policy: e.g. cap a flaky CDN to 2 connections, or raise
/// the cap for a fast mirror, or pin a User-Agent that a site requires.
public struct PerHostRule: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var host: String            // "example.com" or "*.example.com"
    public var maxConnections: Int = 8
    public var speedLimitBytesPerSec: Int64 = 0   // 0 = unlimited
    public var userAgent: String = ""

    public init(host: String = "") {
        self.host = host
    }
}

public final class PerHostSettings: @unchecked Sendable {
    public static let shared = PerHostSettings()

    public private(set) var rules: [PerHostRule] = []
    private let lock = NSLock()
    private static let key = "Siphon.perHostRules"

    private init() { load() }

    /// Best match for a host: exact first, then `*.domain` wildcard suffix.
    public func rule(for host: String) -> PerHostRule? {
        lock.lock(); defer { lock.unlock() }
        let h = host.lowercased()
        if let exact = rules.first(where: { $0.host.lowercased() == h }) { return exact }
        let wild = rules.first {
            $0.host.hasPrefix("*.") && h.hasSuffix($0.host.dropFirst(2).lowercased())
        }
        return wild
    }

    public func upsert(_ rule: PerHostRule) {
        lock.lock()
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else if let i = rules.firstIndex(where: {
            $0.host.lowercased() == rule.host.lowercased() }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        lock.unlock()
        save()
    }

    public func remove(_ id: UUID) {
        lock.lock(); rules.removeAll { $0.id == id }; lock.unlock(); save()
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.key),
              let r = try? JSONDecoder().decode([PerHostRule].self, from: d) else { return }
        rules = r
    }

    private func save() {
        if let d = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }
}
