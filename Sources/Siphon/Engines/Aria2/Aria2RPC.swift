import Foundation

/// Minimal JSON-RPC 2.0 client for aria2's HTTP interface.
/// All methods are async and throw `Aria2Error.rpcFailure` on an RPC-level error.
///
/// `secret` must match aria2's `--rpc-secret`; it is prepended to every call as
/// aria2's `token:<secret>` first parameter. Without it, any local process (or,
/// with `--rpc-allow-origin-all`, any web page) could drive aria2.
public final class Aria2RPC {
    private let endpoint: URL
    private let secret: String
    private let session: URLSession
    private var idCounter = 0

    public init(endpoint: URL, secret: String = "", session: URLSession = .shared) {
        self.endpoint = endpoint
        self.secret = secret
        self.session = session
    }

    private func call(method: String, params: [Any]) async throws -> Any? {
        idCounter += 1
        // aria2 requires `token:<secret>` as the FIRST parameter of every method.
        let fullParams = secret.isEmpty ? params : ["token:" + secret] + params
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idCounter,
            "method": method,
            "params": fullParams
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await session.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any],
           let msg = (err["message"] as? String) ?? (err["faultString"] as? String) {
            throw Aria2Error.rpcFailure(msg)
        }
        return obj["result"]
    }

    // MARK: - add
    @discardableResult
    public func addUri(_ uri: String, options: [String: String] = [:]) async throws -> String {
        let res = try await call(method: "aria2.addUri", params: [[uri], options])
        return res as? String ?? ""
    }

    @discardableResult
    public func addTorrent(_ data: Data, options: [String: String] = [:]) async throws -> String {
        let res = try await call(method: "aria2.addTorrent", params: [data.base64EncodedString(), options])
        return res as? String ?? ""
    }

    /// A Metalink document may describe several files, so `aria2.addMetalink`
    /// returns an array of GIDs. Siphon tracks the first one.
    @discardableResult
    public func addMetalink(_ data: Data, options: [String: String] = [:]) async throws -> String {
        let res = try await call(method: "aria2.addMetalink",
                                 params: [data.base64EncodedString(), options])
        return (res as? [String])?.first ?? ""
    }

    // MARK: - control
    public func pause(_ gid: String) async throws { _ = try await call(method: "aria2.pause", params: [gid]) }
    public func unpause(_ gid: String) async throws { _ = try await call(method: "aria2.unpause", params: [gid]) }
    public func remove(_ gid: String) async throws { _ = try await call(method: "aria2.remove", params: [gid]) }
    public func forceRemove(_ gid: String) async throws { _ = try await call(method: "aria2.forceRemove", params: [gid]) }
    /// Pause every active/waiting download. Used right after a session-file
    /// reload: restored tasks are `.paused` and only resume on user action.
    public func forcePauseAll() async throws {
        _ = try await call(method: "aria2.forcePauseAll", params: [])
    }

    // MARK: - query
    private func query(method: String, offset: Int = 0, num: Int = 1000) async throws -> [[String: Any]] {
        guard let res = try await call(method: method, params: [offset, num]) as? [[String: Any]] else { return [] }
        return res
    }

    /// `aria2.tellActive` takes an OPTIONAL array of keys — NOT (offset, num).
    /// Passing numbers makes aria2 answer "The parameter at 0 has wrong type",
    /// which used to be swallowed by `Aria2Engine.poll()` and silently disabled
    /// all progress/state polling.
    public func tellActive() async throws -> [[String: Any]] {
        guard let res = try await call(method: "aria2.tellActive", params: []) as? [[String: Any]] else {
            return []
        }
        return res
    }
    public func tellWaiting() async throws -> [[String: Any]] { try await query(method: "aria2.tellWaiting") }
    public func tellStopped() async throws -> [[String: Any]] { try await query(method: "aria2.tellStopped") }

    // MARK: - global option / stat
    public func setMaxOverallDownloadLimit(_ bytesPerSec: Int64) async throws {
        _ = try await call(method: "aria2.changeGlobalOption",
                           params: [["max-overall-download-limit": String(bytesPerSec)]])
    }

    /// Per-GID speed limit via `aria2.changeOption` (`max-download-limit`). `0`
    /// clears the per-task cap so the global limit applies alone.
    public func setPerDownloadLimit(_ gid: String, _ bytesPerSec: Int64) async throws {
        _ = try await call(method: "aria2.changeOption",
                           params: [gid, ["max-download-limit": String(bytesPerSec)]])
    }

    public func getGlobalStat() async throws -> [String: Any] {
        (try await call(method: "aria2.getGlobalStat", params: [])) as? [String: Any] ?? [:]
    }

    /// File list of a BT/Metalink download: index, path, length, selected.
    /// Empty until BitTorrent metadata has been resolved (magnet → .torrent).
    public func getFiles(_ gid: String) async throws -> [[String: Any]] {
        guard let res = try await call(method: "aria2.getFiles", params: [gid]) as? [[String: Any]] else {
            return []
        }
        return res
    }

    /// Per-GID option change. Used for BT file selection (`select-file`), which
    /// aria2 only accepts once torrent metadata is loaded.
    public func changeOption(_ gid: String, _ options: [String: String]) async throws {
        _ = try await call(method: "aria2.changeOption", params: [gid, options])
    }

    // MARK: - BitTorrent enhancements

    /// Push the merged public-tracker list (Motrix tracker-manager). aria2 takes a
    /// single comma-separated value for `bt-tracker`; private torrents are kept clean
    /// by `Aria2Engine.makeOptions`.
    public func setBtTracker(_ trackers: [String]) async throws {
        let joined = trackers.joined(separator: ",")
        _ = try await call(method: "aria2.changeGlobalOption",
                           params: [["bt-tracker": joined]])
    }

    /// Global seeding ratio (0 = unlimited). Mirrors aria2's `--seed-ratio`.
    public func setSeedRatio(_ ratio: Double) async throws {
        _ = try await call(method: "aria2.changeGlobalOption",
                           params: [["seed-ratio": String(format: "%g", ratio)]])
    }

    /// Global seeding duration in minutes (0 = unlimited). Mirrors aria2's `--seed-time`
    /// (aria2 measures seed-time in minutes).
    public func setSeedTime(_ minutes: Int) async throws {
        _ = try await call(method: "aria2.changeGlobalOption",
                           params: [["seed-time": String(minutes)]])
    }
}
