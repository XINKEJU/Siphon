import Foundation
import Network
import Security
import CryptoKit

/// Optional LAN HTTPS control server. Default off; binds only to an explicitly
/// chosen interface. Uses Network.framework TLS with a self-signed certificate
/// whose private key lives in the Keychain. The built-in web page is served from
/// memory and requires a paired device token; no CORS, no local API token.
public final class RemoteControlServer {
    public static let shared = RemoteControlServer()

    public struct Config: Codable, Sendable {
        public var enabled: Bool
        public var address: String
        public var port: UInt16

        public init(enabled: Bool = false, address: String = "127.0.0.1", port: UInt16 = 17803) {
            self.enabled = enabled; self.address = address; self.port = port
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Siphon.RemoteControl")
    private var _fingerprint: String?

    public var config: Config {
        get {
            let d = UserDefaults.standard
            let portValue = d.integer(forKey: "Siphon.remote.port")
            return Config(enabled: d.bool(forKey: "Siphon.remote.enabled"),
                          address: d.string(forKey: "Siphon.remote.address") ?? "127.0.0.1",
                          port: portValue > 0 ? UInt16(portValue) : 17803)
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.enabled, forKey: "Siphon.remote.enabled")
            d.set(newValue.address, forKey: "Siphon.remote.address")
            d.set(Int(newValue.port), forKey: "Siphon.remote.port")
        }
    }

    public var isRunning: Bool { listener != nil }
    public var fingerprint: String? { _fingerprint }

    private init() {}

    public func start() throws {
        stop()
        let cfg = config
        guard cfg.enabled else { return }
        guard let identity = try Self.loadOrCreateIdentity() else {
            throw RemoteError.certificateFailed
        }
        _fingerprint = Self.fingerprint(for: identity)

        let options = NWProtocolTLS.Options()
        configureTLS(options, identity: identity)
        let params = NWParameters(tls: options)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(cfg.address),
            port: NWEndpoint.Port(rawValue: cfg.port)!)
        listener = try NWListener(using: params)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener?.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func configureTLS(_ options: NWProtocolTLS.Options, identity: SecIdentity) {
        let secIdentity = identity as AnyObject
        if let secIdentity = secIdentity as? sec_identity_t {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        }
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
                guard let self else { conn.cancel(); return }
                if let data, !data.isEmpty { buffer.append(data) }
                if error == nil, data != nil, !Self.hasCompleteRequest(buffer) {
                    read(); return
                }
                let request = buffer
                Task { @MainActor in
                    let response = self.process(request)
                    conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        read()
    }

    static func hasCompleteRequest(_ data: Data) -> Bool {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let headerEnd = data.range(of: Data(terminator)) else { return false }
        let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        guard header.hasPrefix("POST") else { return true }
        var declared: Int?
        for line in header.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            guard field == "content-length" else { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            declared = Int(value)
            break
        }
        guard let len = declared, len >= 0 else { return true }
        if len > 10 << 20 { return true }
        return (data.count - headerEnd.upperBound) >= len
    }

    @MainActor
    private func process(_ data: Data) -> Data {
        guard let raw = String(data: data, encoding: .utf8),
              let bodyStart = raw.range(of: "\r\n\r\n")?.upperBound else {
            return http("400 Bad Request", "Bad request")
        }
        let lines = raw[..<bodyStart].components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return http("400 Bad Request", "Bad request") }
        let method = String(parts[0])
        let path = String(parts[1])

        let host = Self.header(named: "Host", in: lines)?.lowercased() ?? ""
        guard !host.isEmpty else { return http("403 Forbidden", "Missing Host") }

        if path.hasPrefix("/api/") && path != "/api/pair" {
            let auth = Self.header(named: "Authorization", in: lines)
            guard RemotePairing.shared.verify(presented: auth) else {
                return http("401 Unauthorized", "Unauthorized")
            }
        }

        switch (method, path) {
        case ("GET", "/"):
            return http("200 OK", Self.webPage, contentType: "text/html; charset=utf-8")
        case ("GET", "/api/status"):
            return json(["ok": true, "name": "Siphon", "version": "0.5.0"])
        case ("GET", "/api/tasks"):
            return handleTasks()
        case ("POST", "/api/add"):
            return handleAdd(String(raw[bodyStart...]))
        case ("POST", "/api/pause"), ("POST", "/api/resume"), ("POST", "/api/remove"):
            return handleAction(path: path, body: String(raw[bodyStart...]))
        case ("POST", "/api/pair"):
            return handlePair(String(raw[bodyStart...]))
        default:
            return http("404 Not Found", "Not found")
        }
    }

    @MainActor
    private func handleTasks() -> Data {
        guard let store = AutomationService.shared.store else {
            return json(["ok": false, "error": "store unavailable"], status: 500)
        }
        let answer = store.mdmRecentAnswer()
        let tasks = answer.recent.map { t -> [String: Any] in
            ["id": t.id, "name": t.fileName, "url": t.url, "state": t.status,
             "downloaded": t.downloaded, "total": t.size]
        }
        return json(["ok": true, "tasks": tasks])
    }

    @MainActor
    private func handleAdd(_ body: String) -> Data {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["url"] as? String else {
            return json(["ok": false, "error": "missing url"], status: 400)
        }
        Task {
            try? await AutomationService.shared.add(AutomationService.AddCommand(url: url))
        }
        return json(["ok": true])
    }

    @MainActor
    private func handleAction(path: String, body: String) -> Data {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            return json(["ok": false, "error": "missing id"], status: 400)
        }
        let action = String(path.dropFirst("/api/".count))
        Task {
            switch action {
            case "pause": try? await AutomationService.shared.pause(id)
            case "resume": try? await AutomationService.shared.resume(id)
            case "remove": try? await AutomationService.shared.remove(id)
            default: break
            }
        }
        return json(["ok": true])
    }

    @MainActor
    private func handlePair(_ body: String) -> Data {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? String else {
            return json(["ok": false, "error": "missing code"], status: 400)
        }
        // The pairing code is validated by RemotePairing's state machine.
        guard case .awaiting(let expected, let expires) = RemotePairing.shared.state,
              Date() <= expires, code == expected else {
            return json(["ok": false, "error": "invalid or expired code"], status: 403)
        }
        let name = obj["name"] as? String ?? "Remote device"
        if let device = RemotePairing.shared.confirmPairing(deviceName: name) {
            return json(["ok": true, "token": device.token, "id": device.id.uuidString])
        }
        return json(["ok": false, "error": "pairing failed"], status: 500)
    }

    private func json(_ obj: [String: Any], status: Int = 200) -> Data {
        let text = (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let statusText = status == 200 ? "200 OK" : "\(status) Error"
        return http(statusText, text)
    }

    private func http(_ status: String, _ body: String, contentType: String = "application/json") -> Data {
        let payload = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n" +
            "Strict-Transport-Security: max-age=31536000\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "X-Frame-Options: DENY\r\n" +
            "\r\n\(body)"
        return payload.data(using: .utf8) ?? Data()
    }

    private static func header(named name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard field.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Certificate

    private static let identityLabel = "Siphon Remote Control"

    static func loadOrCreateIdentity() throws -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: identityLabel,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess {
            return item as! SecIdentity?
        }
        // Certificate generation requires assembling X.509 DER manually or using
        // private Security.framework APIs. For now, if no identity exists we fail
        // explicitly; a later build step can install a self-signed identity into
        // the keychain. This keeps the server honest: it never pretends to be
        // running HTTPS without a real certificate.
        return nil
    }

    static func fingerprint(for identity: SecIdentity) -> String {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return "" }
        let data = SecCertificateCopyData(cert) as Data
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public enum RemoteError: LocalizedError {
        case certificateFailed
        public var errorDescription: String? { "Remote HTTPS certificate could not be loaded" }
    }

    // MARK: - Built-in web page

    static let webPage = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Siphon Remote</title>
      <style>
        body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;padding:16px;background:#f5f5f7;color:#1d1d1f}
        header{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px}
        h1{font-size:20px}
        button{background:#007aff;color:#fff;border:0;border-radius:6px;padding:8px 14px;cursor:pointer}
        input,select{padding:8px;border:1px solid #d2d2d7;border-radius:6px;font-size:14px}
        .card{background:#fff;border-radius:10px;padding:12px;margin-bottom:10px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
        .muted{color:#6e6e73;font-size:12px}
        .row{display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap}
      </style>
    </head>
    <body>
      <header><h1>Siphon Remote</h1><span id="conn" class="muted">connecting…</span></header>
      <div class="row">
        <input id="url" placeholder="https://example.com/file.zip" style="flex:1;min-width:200px">
        <button onclick="add()">Add</button>
      </div>
      <div id="tasks"></div>
      <script>
        let token = localStorage.getItem('siphon-token') || '';
        if (!token) { token = prompt('Enter device token') || ''; localStorage.setItem('siphon-token', token); }
        const headers = { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' };
        async function refresh() {
          try {
            const r = await fetch('/api/tasks', { headers });
            if (!r.ok) throw new Error('unauthorized');
            const data = await r.json();
            document.getElementById('conn').textContent = 'connected';
            render(data.tasks || []);
          } catch (e) {
            document.getElementById('conn').textContent = 'disconnected';
          }
        }
        function render(tasks) {
          const el = document.getElementById('tasks');
          el.innerHTML = tasks.map(t => `
            <div class="card">
              <strong>${escapeHtml(t.name)}</strong>
              <div class="muted">${t.state} · ${formatBytes(t.downloaded)} / ${formatBytes(t.total)}</div>
              <div class="row" style="margin-top:8px">
                <button onclick="act('pause','${t.id}')">Pause</button>
                <button onclick="act('resume','${t.id}')">Resume</button>
                <button onclick="act('remove','${t.id}')">Remove</button>
              </div>
            </div>`).join('');
        }
        function escapeHtml(s){return s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
        function formatBytes(n){if(!n)return'0 B';const u=['B','KB','MB','GB'];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}return n.toFixed(1)+' '+u[i]}
        async function add(){const u=document.getElementById('url').value;if(!u)return;await fetch('/api/add',{method:'POST',headers,body:JSON.stringify({url:u})});document.getElementById('url').value='';refresh()}
        async function act(a,id){await fetch('/api/'+a,{method:'POST',headers,body:JSON.stringify({id})});refresh()}
        setInterval(refresh, 3000); refresh();
      </script>
    </body>
    </html>
    """
}
