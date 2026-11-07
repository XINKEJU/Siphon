import Foundation
import Network

/// Local HTTP control endpoint for browser extensions and scripts.
///
/// Design choice: instead of Chrome Native Messaging (which requires shipping a separate
/// helper executable + a host manifest), we expose a loopback HTTP endpoint — the approach
/// used by Gopeed's REST API. A Manifest V3 extension can `fetch` it with host_permissions,
/// and `curl` works out of the box:
///
///     curl -X POST http://127.0.0.1:17801/add \
///          -H 'Content-Type: application/json' \
///          -H "Authorization: Bearer $(token)" \
///          -d '{"url":"https://example.com/file.zip"}'
///
/// Every request except `GET /ping` must carry the per-install token
/// (`LocalAuthToken`, shown/copyable in Settings → 集成). Responses carry no CORS
/// header, so a web page can neither read them nor attach the Authorization
/// header (its "simple request" preflight would fail) — the extension reads and
/// bootstraps its token from `/ping`, which extension contexts with
/// host_permissions can access but web pages cannot.
///
/// POST /add   {"url": "...", "name"?: "...", "queue"?: "...",
///              "headers"?: {"Cookie": "...", "Referer": "..."},
///              "checksum"?: "sha256:…"}                    -> {"ok":true}
/// GET  /ping  -> {"ok":true,"app":"Siphon","token":"…"}   (token bootstrap)
/// GET  /tasks -> {"ok":true,"tasks":[…]}                   (store-backed)
/// POST /pause /resume /remove {"id": "uuid"}               (store-backed)
///
/// `headers` pass-through matters: the extension forwards the page's cookies /
/// referer / UA, which is what makes logged-in direct links downloadable (the
/// same design ABD uses for its integration channel).
public final class NativeMessagingServer {
    public static let port: UInt16 = 17801

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Siphon.NativeMessaging")
    private var onURL: ((String, [String: String], String?, [String]) -> Void)?
    /// Optional richer API surface (task list / pause / resume), wired to the store.
    private var apiHandler: ((String, String, Data) -> Data)?
    /// Optional MDXP JSON-RPC endpoint (`POST /mdxp`).
    private var mdxpHandler: ((Data) -> Data)?
    /// Paired-device tokens are accepted in addition to the local API token.
    private var additionalTokenVerifier: ((String) -> Bool)?
    /// Live `GET /events` subscribers. Mutated only on `queue`.
    private var sseClients: [ObjectIdentifier: NWConnection] = [:]
    /// Subset of `sseClients` connected to `GET /mdxp/events`; they receive
    /// JSON-RPC 2.0 notifications instead of the flat `event: task` frames.
    private var mdxpEventClients = Set<ObjectIdentifier>()

    public init() {}

    public func start(onURL: @escaping (String, [String: String], String?, [String]) -> Void,
                      api: ((String, String, Data) -> Data)? = nil) {
        self.onURL = onURL
        self.apiHandler = api
        stop()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Accept paired-device tokens (MDXP) alongside the local API token.
    public func setAdditionalTokenVerifier(_ verify: ((String) -> Bool)?) {
        additionalTokenVerifier = verify
    }

    /// Route `POST /mdxp` (+ `GET /mdxp/events`) through a JSON-RPC handler.
    public func setMDXPHandler(_ handler: ((Data) -> Data)?) {
        mdxpHandler = handler
    }

    /// Test seam: install the handlers without binding the port, so `process`
    /// can be exercised directly against fabricated HTTP requests.
    func configure(onURL: @escaping (String, [String: String], String?, [String]) -> Void,
                   apiHandler: ((String, String, Data) -> Data)? = nil,
                   mdxpHandler: ((Data) -> Data)? = nil,
                   additionalTokenVerifier: ((String) -> Bool)? = nil) {
        self.onURL = onURL
        self.apiHandler = apiHandler
        self.mdxpHandler = mdxpHandler
        self.additionalTokenVerifier = additionalTokenVerifier
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for conn in sseClients.values { conn.cancel() }
        sseClients.removeAll()
        mdxpEventClients.removeAll()
    }

    /// Push one task-event frame to every subscriber. Called from the main
    /// actor; the actual socket writes are serialized on `queue`.
    ///
    /// `/events` clients get the legacy `event: task` frame with the flat task
    /// JSON. `/mdxp/events` clients get a JSON-RPC 2.0 notification:
    /// `event: message` + `data: {"jsonrpc":"2.0","method":"task.updated","params":{...}}`.
    public func broadcast(_ json: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let restFrame = "event: task\ndata: \(json)\n\n"
            // Wrap the flat task object as the `params` of a JSON-RPC
            // notification. `json` is already a serialized object, so string
            // interpolation avoids a redundant parse/serialize round-trip.
            let rpcFrame = "event: message\n"
                + #"data: {"jsonrpc":"2.0","method":"task.updated","params":\#(json)}"#
                + "\n\n"
            for (key, conn) in self.sseClients {
                let frame = self.mdxpEventClients.contains(key) ? rpcFrame : restFrame
                conn.send(content: frame.data(using: .utf8),
                          completion: .contentProcessed { [weak self] error in
                              guard error != nil else { return }
                              self?.queue.async {
                                  self?.sseClients.removeValue(forKey: key)
                                  self?.mdxpEventClients.remove(key)
                              }
                          })
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
                guard let self else { conn.cancel(); return }
                if let data, !data.isEmpty { buffer.append(data) }
                // Keep reading until we hold a complete HTTP request (full header block
                // plus the entire body per Content-Length). The old code received only
                // once, so a TCP-split or >64 KB POST arrived truncated or was dropped.
                if error == nil, data != nil, !hasCompleteRequest(buffer) {
                    read()
                    return
                }
                if isEventsRequest(buffer) {
                    serveEvents(conn, request: buffer)
                    return
                }
                let response = process(buffer)
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        read()
    }

    private func isEventsRequest(_ data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        let lines = raw.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count > 1 else { return false }
        guard parts[0] == "GET" else { return false }
        let path = parts[1].split(separator: "?")[0]
        if path == "/events" { return true }
        // MDXP clients subscribe to the same stream under their own path.
        if path == "/mdxp/events" { return mdxpHandler != nil }
        return false
    }

    /// Server-Sent Events stream. The HTTP request never completes, so this
    /// bypasses `process` and keeps the socket open until the client disconnects.
    private func serveEvents(_ conn: NWConnection, request: Data) {
        guard let raw = String(data: request, encoding: .utf8) else { conn.cancel(); return }
        let lines = raw.components(separatedBy: "\r\n")
        guard isLocalHost(lines) else {
            conn.send(content: http("403 Forbidden", #"{"ok":false,"error":"invalid host"}"#),
                      completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        guard let auth = header(named: "Authorization", in: lines), authorized(auth) else {
            conn.send(content: http("401 Unauthorized",
                                    #"{"ok":false,"error":"missing or invalid token"}"#),
                      completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "X-Accel-Buffering: no\r\n\r\n"
        conn.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
        let key = ObjectIdentifier(conn)
        // MDXP subscribers are tracked separately so they receive JSON-RPC
        // notification frames rather than the flat `event: task` frames.
        let requestLine = lines.first ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first
            .map { String($0).split(separator: "?")[0] } ?? ""
        let isMDXP = path == "/mdxp/events"
        sseClients[key] = conn
        if isMDXP { mdxpEventClients.insert(key) }
        let ready = isMDXP
            ? "event: message\n"
              + #"data: {"jsonrpc":"2.0","method":"ready","params":{"ok":true}}"#
              + "\n\n"
            : "event: ready\ndata: {\"ok\":true}\n\n"
        conn.send(content: ready.data(using: .utf8),
                  completion: .contentProcessed { _ in })
        func waitForClose() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
                if isComplete || error != nil {
                    self?.sseClients.removeValue(forKey: key)
                    self?.mdxpEventClients.remove(key)
                    conn.cancel()
                } else {
                    waitForClose()
                }
            }
        }
        waitForClose()
    }

    /// True once `data` contains a full HTTP request: a complete header block, and —
    /// for POST — at least `Content-Length` bytes of body after the header terminator.
    /// Body length is measured in **bytes**, not Swift characters, so multi-byte UTF-8
    /// payloads are read exactly (neither truncated nor over-read).
    func hasCompleteRequest(_ data: Data) -> Bool {
        // The header/body terminator "\r\n\r\n" is pure ASCII, so we can locate it by
        // byte value regardless of how the body is encoded.
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let headerEnd = data.range(of: Data(terminator)) else { return false }
        // Header block is everything up to the terminator (ASCII, so UTF-8 safe).
        let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        guard header.hasPrefix("POST"),
              let cl = header.range(of: "Content-Length: "),
              let len = Int(header[cl.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            // Non-POST (e.g. GET) or missing Content-Length: header completeness suffices.
            return true
        }
        // Absurd Content-Length must not grow `buffer` unbounded until OOM:
        // complete immediately and let the JSON parse reject the truncated body.
        if len > 10 << 20 { return true }
        let bodyBytes = data.count - headerEnd.upperBound
        return bodyBytes >= len
    }

    func process(_ data: Data) -> Data {
        guard let raw = String(data: data, encoding: .utf8) else { return http("400 Bad Request", #"{"ok":false}"#) }
        let lines = raw.components(separatedBy: "\r\n")
        // DNS-rebinding guard: a rebound attacker page resolves its own domain
        // to 127.0.0.1 and talks to us with a foreign Host header. CORS alone
        // is not enough because /ping is a simple GET the page CAN read once
        // the socket is "same-origin". Only loopback names are ours.
        guard isLocalHost(lines) else {
            return http("403 Forbidden", #"{"ok":false,"error":"invalid host"}"#)
        }
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        if method == "GET" && path == "/ping" {
            // Auto-bind: extract extension ID from Origin header on first contact.
            if let origin = header(named: "Origin", in: lines) {
                Self.autoBindExtensionID(origin)
            }
            // The token rides along so the extension can bootstrap itself; only
            // extension contexts (host_permissions) and loopback scripts can read
            // the response — web pages get no CORS grant.
            let body = #"{"ok":true,"app":"Siphon","token":""# + LocalAuthToken.current() + #""}"#
            return http("200 OK", body)
        }
        // Everything else is authenticated. A web page's simple request cannot
        // carry Authorization (that would require a preflight), so this is what
        // actually keeps drive-by pages from adding tasks or reading task URLs.
        guard let auth = header(named: "Authorization", in: lines), authorized(auth) else {
            return http("401 Unauthorized", #"{"ok":false,"error":"missing or invalid token"}"#)
        }
        if method == "GET" && path == "/mdxp/ping" {
            return http("200 OK", #"{"ok":true,"app":"Siphon","protocol":"mdxp/1"}"#)
        }
        if method == "POST" && path == "/mdxp" {
            guard let bodyStart = raw.range(of: "\r\n\r\n")?.upperBound, let mdxpHandler else {
                return http("404 Not Found", #"{"ok":false,"error":"mdxp disabled"}"#)
            }
            let body = raw[bodyStart...].data(using: .utf8) ?? Data()
            let response = mdxpHandler(body)
            // JSON-RPC errors are still HTTP 200; only transport failures differ.
            return http("200 OK", String(data: response, encoding: .utf8) ?? "{}")
        }
        if method == "POST" && path == "/add" {
            guard let bodyStart = raw.range(of: "\r\n\r\n")?.upperBound else {
                return http("400 Bad Request", #"{"ok":false,"error":"malformed request"}"#)
            }
            let body = String(raw[bodyStart...]).data(using: .utf8) ?? Data()
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return http("400 Bad Request", #"{"ok":false,"error":"malformed json"}"#)
            }
            // CRLF injection guard (Motrix's aria2-config-builder lesson): argv and
            // header values must never contain control characters.
            func sanitized(_ s: String) -> String {
                s.unicodeScalars.filter { $0.value > 0x1F || $0 == " " }.map(String.init).joined()
            }
            var options: [String: String] = [:]
            if let hs = json["headers"] as? [String: String] {
                for (k, v) in hs { options[sanitized(k)] = sanitized(v) }
            }
            let checksum = (json["checksum"] as? String).map(sanitized)
            let mirrors = (json["mirrors"] as? [String]) ?? []
            // Batch form: {"urls":["…","…"]}. Useful for automation / MCP-less scripts.
            if let urls = json["urls"] as? [String], !urls.isEmpty {
                for u in urls where !u.isEmpty {
                    onURL?(sanitized(u), options, checksum, mirrors.map(sanitized))
                }
                return http("200 OK", #"{"ok":true,"count":"# + "\(urls.count)}")
            }
            guard let url = json["url"] as? String, !url.isEmpty else {
                return http("400 Bad Request", #"{"ok":false,"error":"missing url"}"#)
            }
            onURL?(sanitized(url), options, checksum, mirrors.map(sanitized))
            return http("200 OK", #"{"ok":true}"#)
        }
        // Richer REST surface, handled by the store (GET /tasks, POST /pause, …).
        if let apiHandler {
            let bodyStart = raw.range(of: "\r\n\r\n")?.upperBound ?? raw.endIndex
            let body = raw[bodyStart...].data(using: .utf8) ?? Data()
            let response = apiHandler(method, path, body)
            let status = String(data: response, encoding: .utf8)!.contains("\"ok\":false")
                ? "400 Bad Request" : "200 OK"
            return http(status, String(data: response, encoding: .utf8) ?? "{}")
        }
        return http("404 Not Found", #"{"ok":false,"error":"not found"}"#)
    }

    /// Only loopback names are ours; a rebound attacker domain resolving to
    /// 127.0.0.1 sends a foreign Host header and must be rejected.
    private func isLocalHost(_ lines: [String]) -> Bool {
        let host = (header(named: "Host", in: lines) ?? "").lowercased()
        let hostName: String
        if host.hasPrefix("[") {                       // [::1]:8080
            hostName = String(host.prefix(while: { $0 != "]" }))
        } else {
            hostName = String(host.split(separator: ":").first ?? "")
        }
        if hostName.isEmpty { return true }
        return ["127.0.0.1", "localhost", "[::1", "::1"].contains(hostName)
    }

    /// Local API token or a paired MDXP device token.
    private func authorized(_ presented: String) -> Bool {
        if LocalAuthToken.verify(presented) { return true }
        return additionalTokenVerifier?(presented) ?? false
    }

    private func header(named name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let field = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            if field.lowercased() == name.lowercased() {
                return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Deliberately no `Access-Control-Allow-Origin`: granting `*` let any web
    /// page read the task list (URLs can embed credentials) cross-origin.
    private func http(_ status: String, _ body: String) -> Data {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        return payload.data(using: .utf8) ?? Data()
    }

    /// Auto-bind: extract extension ID from Origin header and save it.
    /// Supports chrome-extension://, moz-extension://, safari-web-extension://
    private static func autoBindExtensionID(_ origin: String) {
        let patterns = ["chrome-extension://", "moz-extension://", "safari-web-extension://"]
        for prefix in patterns {
            guard origin.hasPrefix(prefix) else { continue }
            let rest = origin.dropFirst(prefix.count)
            // Chrome/Edge: 32-char lowercase a-p ID
            // Firefox: UUID format {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}
            // Safari: UUID format without braces
            let id = rest.split(separator: "/").first.map(String.init) ?? ""
            guard !id.isEmpty else { continue }
            // Only save if not already saved or different from current
            let current = NativeMessagingHostInstaller.extensionID
            if id != current {
                UserDefaults.standard.set(id, forKey: NativeMessagingHostInstaller.extensionIDKey)
                // Auto-install native messaging host for this extension ID
                if NativeMessagingHostInstaller.isValidExtensionID(id) {
                    _ = try? NativeMessagingHostInstaller.install(extensionID: id)
                }
            }
            break
        }
    }
}
