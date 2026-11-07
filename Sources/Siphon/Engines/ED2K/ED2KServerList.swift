import Foundation

/// Configured eD2K servers and Kad bootstrap nodes, used for source discovery when an
/// `ed2k://` link carries no embedded `|sources,host:port|`. The native backend already
/// speaks the eDonkey/eMule TCP transfer protocol (`NativeED2KBackend`); this list is
/// what lets it find peers for source-less links. Kad/UDP DHT bootstrapping itself is
/// *not* implemented, so a server is still required for those links — but with this
/// list populated, such links now resolve peers instead of failing with `noSources`.
public final class ED2KServerList: @unchecked Sendable {
    public static let shared = ED2KServerList()

    /// Posted (on the posting thread) whenever the server or Kad list changes so
    /// engines can rebuild their backend with the new sources.
    public static let didChange = Notification.Name("ED2KServerListDidChange")

    private let lock = NSLock()
    private var _servers: [String]
    private var _kad: [String]

    private static let serversKey = "Siphon.ed2kServers"
    private static let kadKey = "Siphon.ed2kKad"

    private init() {
        _servers = UserDefaults.standard.stringArray(forKey: Self.serversKey) ?? []
        _kad = UserDefaults.standard.stringArray(forKey: Self.kadKey) ?? []
    }

    /// Parsed `host:port` servers ready for the transfer backend.
    public var servers: [(host: String, port: Int)] {
        lock.lock(); defer { lock.unlock() }
        return _servers.compactMap { Self.parse($0) }
    }

    /// Raw Kad bootstrap node strings (e.g. `bootstrap.kad:6881`).
    public var kadBootstrap: [String] {
        lock.lock(); defer { lock.unlock() }
        return _kad
    }

    public func setServers(_ list: [String]) {
        let cleaned = clean(list)
        lock.lock(); _servers = cleaned; lock.unlock()
        UserDefaults.standard.set(cleaned, forKey: Self.serversKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func setKadBootstrap(_ list: [String]) {
        let cleaned = clean(list)
        lock.lock(); _kad = cleaned; lock.unlock()
        UserDefaults.standard.set(cleaned, forKey: Self.kadKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func clean(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Accept `host:port`; tolerate a bare host (default eD2K port 4661).
    private static func parse(_ s: String) -> (host: String, port: Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let port = Int(parts[1]), !parts[0].isEmpty else { return nil }
            return (String(parts[0]), port)
        }
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, 4661)
    }
}
