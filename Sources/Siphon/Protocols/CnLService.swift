import Foundation
import Network
import Observation

/// Click'n'Load 2 receiver. A Flash/legacy browser extension POSTs an
/// AES-128-CBC encrypted payload to 127.0.0.1:9666; Siphon decrypts it and
/// either auto-adds the links or holds them for confirmation. The listener only
/// ever binds loopback and the key is the well-known CnL2 key, so the payload
/// must still be shown to the user before anything is downloaded.
@MainActor
@Observable
public final class CnLService {
    public static let shared = CnLService()

    /// Decrypted request shape lives in `CnLPayload.swift` so it can be tested
    /// without the listener.
    public typealias Request = CnLRequest

    public private(set) var isRunning = false
    public private(set) var port: UInt16 = 9666
    public private(set) var pending: [Request] = []
    public private(set) var lastError: String?

    public var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "Siphon.cnl.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "Siphon.cnl.enabled")
            if newValue { start() } else { stop() }
        }
    }

    public var autoAdd: Bool {
        get { UserDefaults.standard.bool(forKey: "Siphon.cnl.autoAdd") }
        set { UserDefaults.standard.set(newValue, forKey: "Siphon.cnl.autoAdd") }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Siphon.CnL")
    private weak var store: DownloadStore?

    private init() {}

    public func configure(store: DownloadStore) {
        self.store = store
        if enabled && !isRunning { start() }
    }

    // MARK: - Lifecycle

    public func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    nonisolated private func handle(_ conn: NWConnection) {
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

    nonisolated static func hasCompleteRequest(_ data: Data) -> Bool {
        guard let headerEnd = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return false }
        let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        guard header.hasPrefix("POST") else { return true }
        var length: Int?
        for line in header.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            length = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            break
        }
        guard let length, length >= 0 else { return true }
        if length > 4 << 20 { return true }
        return data.count - headerEnd.upperBound >= length
    }

    private func process(_ data: Data) -> Data {
        guard let raw = String(data: data, encoding: .utf8),
              let headerBreak = raw.range(of: "\r\n\r\n") else {
            return http("400 Bad Request", "bad request")
        }
        let body = String(raw[headerBreak.upperBound...])
        let requestLine = raw[..<headerBreak.lowerBound].components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return http("400 Bad Request", "bad request") }
        let method = String(parts[0])
        let path = String(parts[1])

        switch (method, path) {
        case ("GET", "/crossdomain.xml"):
            return http("200 OK", Self.crossDomainPolicy, contentType: "text/x-cross-domain-policy")
        case ("POST", "/flash/addcrypted2"):
            return handleEncrypted(form: body)
        case ("POST", "/flash/add"):
            return handlePlain(form: body)
        case ("GET", "/"):
            return http("200 OK", "Siphon Click'n'Load is running")
        default:
            return http("404 Not Found", "not found")
        }
    }

    private func handleEncrypted(form: String) -> Data {
        guard let encoded = Self.formValue("data", in: form), !encoded.isEmpty else {
            return http("400 Bad Request", "missing data")
        }
        do {
            let plaintext = try CnLCrypto.decrypt(base64: encoded)
            let request = CnLPayload.parse(plaintext)
            guard !request.sources.isEmpty else {
                return http("200 OK", "OK")
            }
            accept(request)
            return http("200 OK", "OK")
        } catch {
            lastError = error.localizedDescription
            return http("400 Bad Request", "decrypt failed")
        }
    }

    private func handlePlain(form: String) -> Data {
        // Plain form posts a urls= parameter with newline- or %0A-separated links.
        let raw = Self.formValue("urls", in: form) ?? Self.formValue("url", in: form) ?? ""
        let decoded = raw.removingPercentEncoding ?? raw
        let sources = decoded.split(whereSeparator: \.isNewline)
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        guard !sources.isEmpty else { return http("200 OK", "OK") }
        accept(Request(sources: sources))
        return http("200 OK", "OK")
    }

    private func accept(_ request: Request) {
        if autoAdd, let store {
            Task {
                for url in request.sources {
                    _ = await store.addMDMCommand(MDMCommand(url: url.absoluteString, action: "add"))
                }
            }
        } else {
            pending.append(request)
        }
    }

    // MARK: - Confirmation

    public func confirm(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        guard let store else { return }
        Task {
            for url in request.sources {
                _ = await store.addMDMCommand(MDMCommand(url: url.absoluteString, action: "add"))
            }
        }
    }

    public func reject(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    public func confirmAll() {
        for request in pending { confirm(request.id) }
    }

    public func rejectAll() {
        pending.removeAll()
    }

    // MARK: - helpers

    private func http(_ status: String, _ body: String,
                      contentType: String = "text/plain; charset=utf-8") -> Data {
        let response = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n\(body)"
        return response.data(using: .utf8) ?? Data()
    }

    static func formValue(_ name: String, in form: String) -> String? {
        for pair in form.split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            guard pair[..<eq] == Substring(name) else { continue }
            return String(pair[pair.index(after: eq)...])
        }
        return nil
    }

    static let crossDomainPolicy = """
    <?xml version="1.0"?>
    <!DOCTYPE cross-domain-policy SYSTEM "http://www.adobe.com/xml/dtds/cross-domain-policy.dtd">
    <cross-domain-policy>
      <allow-access-from domain="*" to-ports="9666"/>
    </cross-domain-policy>
    """
}
