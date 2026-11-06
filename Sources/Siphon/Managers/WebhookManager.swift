import Foundation
import CommonCrypto

/// Task-event webhooks (FluxDown's task-event webhooks model).
///
/// On every terminal state transition (completed / error / removed) a small JSON
/// payload is POSTed to each configured URL, letting the user chain downloads into
/// scripts, notification bots (IFTTT / Zapier / a local webhook relay), or CI.
///
/// Delivery is fire-and-forget: the request is sent on a background queue, failures
/// are swallowed (an unreachable endpoint must never block or error a download),
/// and the payload is capped so a malicious endpoint can't be used to exfiltrate
/// large option blobs.
public final class WebhookManager: @unchecked Sendable {
    public static let shared = WebhookManager()

    /// One endpoint. `secret` signs the payload with HMAC-SHA256 when non-empty
    /// (sent as `X-Siphon-Signature: sha256=<hex>`), matching the common
    /// "webhook secret" convention used by GitHub / Slack / Discord webhooks.
    public struct Endpoint: Codable, Identifiable, Equatable {
        public var id: UUID = UUID()
        public var url: String
        public var secret: String = ""

        public init(url: String, secret: String = "") {
            self.url = url
            self.secret = secret
        }
    }

    private static let defaultsKey = "Siphon.webhooks"
    private let queue = DispatchQueue(label: "Siphon.WebhookManager", qos: .utility)
    private let lock = NSLock()

    private var _endpoints: [Endpoint]
    public var endpoints: [Endpoint] {
        lock.lock(); defer { lock.unlock() }
        return _endpoints
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Endpoint].self, from: data) {
            _endpoints = decoded
        } else {
            _endpoints = []
        }
    }

    public func setEndpoints(_ list: [Endpoint]) {
        lock.lock(); _endpoints = list; lock.unlock()
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    public func add(url: String, secret: String = "") {
        var list = endpoints
        list.append(Endpoint(url: url, secret: secret))
        setEndpoints(list)
    }

    public func remove(id: UUID) {
        setEndpoints(endpoints.filter { $0.id != id })
    }

    /// Queue a terminal-state event for delivery. Safe to call from any context.
    public func deliver(task: TaskSnapshot) {
        let targets = endpoints
        guard !targets.isEmpty else { return }
        let payload = task.payload
        queue.async {
            for ep in targets {
                Self.post(payload, to: ep)
            }
        }
    }

    /// A minimal, self-contained snapshot of a task at a terminal transition.
    /// Decoupled from `DownloadTask` so the webhook surface stays stable and we
    /// never accidentally serialize engine state.
    public struct TaskSnapshot: Sendable {
        public var id: UUID
        public var name: String
        public var url: String
        public var state: String
        public var downloadedBytes: Int64
        public var totalBytes: Int64
        public var error: String?

        public init(id: UUID, name: String, url: String, state: String,
                    downloadedBytes: Int64, totalBytes: Int64, error: String?) {
            self.id = id; self.name = name; self.url = url; self.state = state
            self.downloadedBytes = downloadedBytes
            self.totalBytes = totalBytes
            self.error = error
        }

        var payload: Data {
            var dict: [String: Any] = [
                "event": "task.\(state)",
                "id": id.uuidString,
                "name": name,
                "url": url,
                "state": state,
                "downloadedBytes": downloadedBytes,
                "totalBytes": totalBytes,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ]
            if let error { dict["error"] = error }
            return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        }
    }

    private static func post(_ payload: Data, to ep: Endpoint) {
        guard let url = URL(string: ep.url), url.scheme != nil else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Siphon/0.1", forHTTPHeaderField: "User-Agent")
        if !ep.secret.isEmpty {
            req.setValue("sha256=\(Self.hmacSHA256(payload, key: ep.secret))",
                         forHTTPHeaderField: "X-Siphon-Signature")
        }
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 5)
    }

    /// HMAC-SHA256 hex digest (CommonCrypto), the standard webhook signing scheme.
    private static func hmacSHA256(_ data: Data, key: String) -> String {
        guard let keyData = key.data(using: .utf8) else { return "" }
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            keyData.withUnsafeBytes { k in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       k.baseAddress, keyData.count,
                       raw.baseAddress, data.count, &out)
            }
        }
        return out.map { String(format: "%02x", $0) }.joined()
    }
}
