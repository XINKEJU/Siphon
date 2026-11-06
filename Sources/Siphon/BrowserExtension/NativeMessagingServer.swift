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
///          -d '{"url":"https://example.com/file.zip"}'
///
/// POST /add   {"url": "...", "name"?: "...", "queue"?: "..."}  -> {"ok":true}
/// GET  /ping  -> {"ok":true,"app":"Siphon"}
public final class NativeMessagingServer {
    public static let port: UInt16 = 17801

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Siphon.NativeMessaging")
    private var onURL: ((String) -> Void)?

    public init() {}

    public func start(onURL: @escaping (String) -> Void) {
        self.onURL = onURL
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

    public func stop() {
        listener?.cancel()
        listener = nil
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
                let response = process(buffer)
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        read()
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
        let bodyBytes = data.count - headerEnd.upperBound
        return bodyBytes >= len
    }

    func process(_ data: Data) -> Data {
        guard let raw = String(data: data, encoding: .utf8) else { return http("400 Bad Request", #"{"ok":false}"#) }
        let lines = raw.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        if method == "GET" && path == "/ping" {
            return http("200 OK", #"{"ok":true,"app":"Siphon"}"#)
        }
        if method == "POST" && path == "/add" {
            guard let bodyStart = raw.range(of: "\r\n\r\n")?.upperBound else {
                return http("400 Bad Request", #"{"ok":false,"error":"malformed request"}"#)
            }
            let body = String(raw[bodyStart...]).data(using: .utf8) ?? Data()
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let url = json["url"] as? String, !url.isEmpty else {
                return http("400 Bad Request", #"{"ok":false,"error":"missing url"}"#)
            }
            onURL?(url)
            return http("200 OK", #"{"ok":true}"#)
        }
        return http("404 Not Found", #"{"ok":false,"error":"not found"}"#)
    }

    private func http(_ status: String, _ body: String) -> Data {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
        return payload.data(using: .utf8) ?? Data()
    }
}
