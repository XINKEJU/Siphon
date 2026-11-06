import Foundation
import Network

/// Model Context Protocol (MCP) server, exposed over loopback HTTP + JSON-RPC 2.0
/// so AI clients (Claude, Cursor, any MCP-capable agent) can manage Siphon
/// downloads. Borrowed from FluxDown's 12-tool MCP server and gopeed's `mcpserver`.
///
/// MCP messages are JSON-RPC 2.0. We implement the minimal transport-agnostic
/// surface that an HTTP/SSE-capable client needs:
///
///     POST http://127.0.0.1:17802/mcp
///     {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
///     -> {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",
///         "capabilities":{"tools":{}},"serverInfo":{"name":"Siphon","version":"0.1"}}}
///
///     {"jsonrpc":"2.0","id":2,"method":"tools/list"}
///     -> {"jsonrpc":"2.0","id":2,"result":{"tools":[...]}}
///
///     {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_download",
///         "arguments":{"url":"https://..."}}}
///     -> {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"..."}]}}
///
/// Tool handlers are injected by the caller (the store) so this server stays a
/// thin transport adapter with no knowledge of download internals.
public final class MCPServer {
    public static let port: UInt16 = 17802

    /// A tool handler: given the parsed `arguments` dict, return the result text.
    public typealias ToolHandler = ([String: Any]) -> String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Siphon.MCP")
    private var handlers: [String: ToolHandler] = [:]

    public init() {}

    /// Register the tool set. `handlers` maps tool name → implementation.
    public func configure(handlers: [String: ToolHandler]) {
        self.handlers = handlers
    }

    public func start() {
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
                if error == nil, data != nil, !Self.hasCompleteRequest(buffer) {
                    read(); return
                }
                let response = self.process(buffer)
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        read()
    }

    /// Same completeness rule as the REST server: full header block plus the
    /// entire POST body per Content-Length (byte-accurate for UTF-8 payloads).
    static func hasCompleteRequest(_ data: Data) -> Bool {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let headerEnd = data.range(of: Data(terminator)) else { return false }
        let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        guard header.hasPrefix("POST"),
              let cl = header.range(of: "Content-Length: "),
              let len = Int(header[cl.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        else { return true }
        return (data.count - headerEnd.upperBound) >= len
    }

    func process(_ data: Data) -> Data {
        guard let raw = String(data: data, encoding: .utf8),
              let bodyStart = raw.range(of: "\r\n\r\n")?.upperBound else {
            return http("400 Bad Request", #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#)
        }
        let body = String(raw[bodyStart...]).data(using: .utf8) ?? Data()
        guard let req = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return http("400 Bad Request", Self.jsonRPCError(id: nil, code: -32700, message: "Parse error"))
        }
        let id = req["id"]
        let method = req["method"] as? String ?? ""
        let result: String

        switch method {
        case "initialize":
            let rpc: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "Siphon", "version": "0.1"],
            ]
            result = Self.jsonRPCResult(id: id, result: rpc)
        case "notifications/initialized", "ping":
            result = Self.jsonRPCResult(id: id, result: [:])
        case "tools/list":
            result = Self.jsonRPCResult(id: id, result: ["tools": Self.toolList()])
        case "tools/call":
            let params = req["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let args = params?["arguments"] as? [String: Any] ?? [:]
            if let handler = handlers[name] {
                let text = handler(args)
                let content: [[String: Any]] = [["type": "text", "text": text]]
                result = Self.jsonRPCResult(id: id, result: ["content": content, "isError": false])
            } else {
                result = Self.jsonRPCError(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
        default:
            result = Self.jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
        return http("200 OK", result)
    }

    /// The tool metadata advertised to clients (name, description, JSON-schema args).
    private static func toolList() -> [[String: Any]] {
        [
            tool("add_download",
                 "Add a new download task from a URL.",
                 ["type": "object",
                  "properties": ["url": ["type": "string", "description": "The URL to download"],
                                 "name": ["type": "string"],
                                 "mirrors": ["type": "array", "items": ["type": "string"]]],
                  "required": ["url"]]),
            tool("list_tasks",
                 "List all download tasks with their state and progress.",
                 ["type": "object", "properties": [:]]),
            tool("pause_task",
                 "Pause a download task by id.",
                 ["type": "object",
                  "properties": ["id": ["type": "string"]],
                  "required": ["id"]]),
            tool("resume_task",
                 "Resume a paused download task by id.",
                 ["type": "object",
                  "properties": ["id": ["type": "string"]],
                  "required": ["id"]]),
            tool("remove_task",
                 "Remove a download task by id.",
                 ["type": "object",
                  "properties": ["id": ["type": "string"]],
                  "required": ["id"]]),
        ]
    }

    private static func tool(_ name: String, _ description: String,
                             _ inputSchema: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }

    // MARK: - JSON-RPC 2.0 helpers

    static func jsonRPCResult(id: Any?, result: [String: Any]) -> String {
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
        obj["id"] = id ?? NSNull()
        return stringify(obj)
    }

    static func jsonRPCError(id: Any?, code: Int, message: String) -> String {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        obj["id"] = id ?? NSNull()
        return stringify(obj)
    }

    private static func stringify(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func http(_ status: String, _ body: String) -> Data {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
        return payload.data(using: .utf8) ?? Data()
    }
}
