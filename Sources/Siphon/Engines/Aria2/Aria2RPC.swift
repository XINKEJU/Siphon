import Foundation

/// Minimal JSON-RPC 2.0 client for aria2's HTTP interface.
/// All methods are async and throw `Aria2Error.rpcFailure` on an RPC-level error.
public final class Aria2RPC {
    private let endpoint: URL
    private let session: URLSession
    private var idCounter = 0

    public init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    private func call(method: String, params: [Any]) async throws -> Any? {
        idCounter += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idCounter,
            "method": method,
            "params": params
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

    // MARK: - control
    public func pause(_ gid: String) async throws { _ = try await call(method: "aria2.pause", params: [gid]) }
    public func unpause(_ gid: String) async throws { _ = try await call(method: "aria2.unpause", params: [gid]) }
    public func remove(_ gid: String) async throws { _ = try await call(method: "aria2.remove", params: [gid]) }
    public func forceRemove(_ gid: String) async throws { _ = try await call(method: "aria2.forceRemove", params: [gid]) }

    // MARK: - query
    private func query(method: String, offset: Int = 0, num: Int = 1000) async throws -> [[String: Any]] {
        guard let res = try await call(method: method, params: [offset, num]) as? [[String: Any]] else { return [] }
        return res
    }

    public func tellActive() async throws -> [[String: Any]] { try await query(method: "aria2.tellActive") }
    public func tellWaiting() async throws -> [[String: Any]] { try await query(method: "aria2.tellWaiting") }
    public func tellStopped() async throws -> [[String: Any]] { try await query(method: "aria2.tellStopped") }

    // MARK: - global option / stat
    public func setMaxOverallDownloadLimit(_ bytesPerSec: Int64) async throws {
        _ = try await call(method: "aria2.changeGlobalOption",
                           params: [["max-overall-download-limit": String(bytesPerSec)]])
    }

    public func getGlobalStat() async throws -> [String: Any] {
        (try await call(method: "aria2.getGlobalStat", params: [])) as? [String: Any] ?? [:]
    }
}
