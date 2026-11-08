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
    /// Secrets live in the Keychain, keyed by endpoint id — never in UserDefaults.
    public struct Endpoint: Codable, Identifiable, Equatable {
        public var id: UUID = UUID()
        public var url: String
        public var secret: String = ""

        public init(id: UUID = UUID(), url: String, secret: String = "") {
            self.id = id
            self.url = url
            self.secret = secret
        }
    }

    /// What actually hits UserDefaults — the secret lives in the Keychain.
    private struct StoredEndpoint: Codable {
        var id: UUID, url: String
    }

    private static func secretAccount(_ id: UUID) -> String { "webhook-secret-\(id.uuidString)" }

    private static let defaultsKey = "Siphon.webhooks"
    private let lock = NSLock()

    private var _endpoints: [Endpoint]
    public var endpoints: [Endpoint] {
        lock.lock(); defer { lock.unlock() }
        return _endpoints
    }

    /// Last delivery/policy failure, surfaced in Settings instead of being
    /// swallowed by `try?`.
    private var _lastError: String?
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }

    func record(_ message: String) {
        lock.lock(); _lastError = message; lock.unlock()
    }

    func clearFailure() {
        lock.lock(); _lastError = nil; lock.unlock()
    }

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.defaultsKey) {
            if let legacy = try? JSONDecoder().decode([Endpoint].self, from: data) {
                // One-time migration: lift secrets into the Keychain.
                for ep in legacy where !ep.secret.isEmpty {
                    Keychain.setSecret(ep.secret, account: Self.secretAccount(ep.id))
                }
                let stored = legacy.map { StoredEndpoint(id: $0.id, url: $0.url) }
                if let out = try? JSONEncoder().encode(stored) {
                    d.set(out, forKey: Self.defaultsKey)
                }
                _endpoints = legacy
            } else if let list = try? JSONDecoder().decode([StoredEndpoint].self, from: data) {
                _endpoints = list.map {
                    Endpoint(id: $0.id, url: $0.url,
                             secret: Keychain.secret(account: Self.secretAccount($0.id)) ?? "")
                }
            } else {
                _endpoints = []
            }
        } else {
            _endpoints = []
        }
    }

    public func setEndpoints(_ list: [Endpoint]) {
        lock.lock(); _endpoints = list; lock.unlock()
        let stored = list.map { StoredEndpoint(id: $0.id, url: $0.url) }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        let newIDs = Set(list.map(\.id))
        for old in endpoints where !newIDs.contains(old.id) {
            Keychain.setSecret("", account: Self.secretAccount(old.id))
        }
        for ep in list {
            Keychain.setSecret(ep.secret, account: Self.secretAccount(ep.id))
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
    /// Endpoints are POSTed concurrently — a semaphore-serial loop let one slow
    /// endpoint delay every other subscriber by its full 5 s timeout.
    public func deliver(task: TaskSnapshot) {
        let targets = endpoints
        guard !targets.isEmpty else { return }
        let payload = task.payload
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for ep in targets {
                    group.addTask { await Self.post(payload, to: ep) }
                }
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
                // Task URLs can embed Basic credentials or an S3 presigned
                // signature. Never ship the raw value to a third-party endpoint.
                "url": WebhookPolicy.redact(url),
                "state": state,
                "downloadedBytes": downloadedBytes,
                "totalBytes": totalBytes,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ]
            if let error { dict["error"] = error }
            return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        }
    }

    /// Dedicated session: `URLSession.shared` follows redirects without any
    /// policy hook, so a public HTTPS endpoint could bounce a credential-bearing
    /// payload into a private network.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg, delegate: RedirectGuard.shared,
                          delegateQueue: nil)
    }()

    private static func post(_ payload: Data, to ep: Endpoint) async {
        let allowPrivate = UserDefaults.standard.bool(forKey: WebhookPolicy.allowPrivateKey)
        guard let url = WebhookPolicy.isAllowed(ep.url, allowPrivate: allowPrivate) else {
            Self.shared.record(
                "Webhook 地址被安全策略拒绝（仅 http/https；默认禁止私网/回环）：\(ep.url)")
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Siphon/0.1", forHTTPHeaderField: "User-Agent")
        if !ep.secret.isEmpty {
            req.setValue("sha256=\(Self.hmacSHA256(payload, key: ep.secret))",
                         forHTTPHeaderField: "X-Siphon-Signature")
        }
        do {
            let (_, response) = try await Self.session.data(for: req)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                Self.shared.record("Webhook 返回 HTTP \(http.statusCode)：\(url.host ?? "")")
            } else {
                Self.shared.clearFailure()
            }
        } catch {
            Self.shared.record("Webhook 投递失败：\(error.localizedDescription)")
        }
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

/// Re-validate every redirect hop. Returning `nil` stops the redirect and lets
/// the response come back as a 3xx, which `post` reports as a delivery failure.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectGuard()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let allowPrivate = UserDefaults.standard.bool(forKey: WebhookPolicy.allowPrivateKey)
        guard let url = request.url,
              WebhookPolicy.isAllowed(url, allowPrivate: allowPrivate) else {
            WebhookManager.shared.record("Webhook 重定向到不允许的地址，已阻断")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
