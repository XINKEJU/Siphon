import Foundation
import Network

// Tests for the MCP server (JSON-RPC 2.0 surface) and the webhook manager
// (HMAC signing + payload). Both are pure message-handling with no real network.

var failures = 0
func check(_ cond: Bool, _ msg: String, _ detail: String = "") {
    if cond { print("  ok  \(msg)") }
    else { failures += 1; print("  FAIL \(msg)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

// The MCP surface requires a bearer token on every call. Fixed token so the
// test never touches the login keychain.
LocalAuthToken.testingToken = "test-token"

// MARK: - MCP JSON-RPC

let mcp = MCPServer()
mcp.configure(handlers: [
    "list_tasks": { _ in "a,b" },
    "add_download": { args in "enqueued \(args["url"] ?? "?")" },
])

func json(_ s: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
}

// `process` returns a full HTTP response; extract the JSON-RPC body.
func rpcBody(_ data: Data) -> [String: Any]? {
    let s = String(data: data, encoding: .utf8) ?? ""
    guard let range = s.range(of: "\r\n\r\n") else { return json(s) }
    return json(String(s[range.upperBound...]))
}

// initialize
let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
let initResp = rpcBody(mcp.process(httpBody(initReq)))
check(initResp?["jsonrpc"] as? String == "2.0", "init → jsonrpc 2.0")
check((initResp?["result"] as? [String: Any])?["protocolVersion"] != nil, "init → protocolVersion")

// tools/list
let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
let listResp = rpcBody(mcp.process(httpBody(listReq)))
let tools = (listResp?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
check(tools?.count == 5, "tools/list → 5 tools", "got \(tools?.count ?? 0)")
let names = Set(tools?.compactMap { $0["name"] as? String } ?? [])
check(names == ["add_download", "list_tasks", "pause_task", "resume_task", "remove_task"],
      "tool names match")

// tools/call
let callReq = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_download","arguments":{"url":"https://x/f"}}}"#
let callResp = rpcBody(mcp.process(httpBody(callReq)))
let content = (callResp?["result"] as? [String: Any])?["content"] as? [[String: Any]]
check(content?.first?["text"] as? String == "enqueued https://x/f", "tools/call → handler result")

// unknown tool
let badReq = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#
let badResp = rpcBody(mcp.process(httpBody(badReq)))
check((badResp?["error"] as? [String: Any])?["code"] as? Int == -32602, "unknown tool → -32602")

// unknown method
let unkReq = #"{"jsonrpc":"2.0","id":5,"method":"bogus"}"#
let unkResp = rpcBody(mcp.process(httpBody(unkReq)))
check((unkResp?["error"] as? [String: Any])?["code"] as? Int == -32601, "unknown method → -32601")

// request completeness (byte-accurate body detection)
var complete = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello".data(using: .utf8)!
check(MCPServer.hasCompleteRequest(complete), "complete request detected")
var incomplete = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhe".data(using: .utf8)!
check(!MCPServer.hasCompleteRequest(incomplete), "incomplete body not ready")

// Regression: Content-Length is not necessarily the last header. The old
// `range(of: "Content-Length: ")` + `Int(rest of header)` parse failed and
// declared the request complete before any body bytes arrived.
let trailing = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    + "Content-Length: 5\r\nAuthorization: Bearer test-token\r\n\r\n"
check(!MCPServer.hasCompleteRequest(Data((trailing).utf8)),
      "incomplete when Content-Length is not the last header")
check(MCPServer.hasCompleteRequest(Data((trailing + "hello").utf8)),
      "complete once the full body arrives")
let lowerTrailing = trailing.replacingOccurrences(of: "Content-Length:",
                                                  with: "content-length:")
check(!MCPServer.hasCompleteRequest(Data(lowerTrailing.utf8))
      && MCPServer.hasCompleteRequest(Data((lowerTrailing + "hello").utf8)),
      "Content-Length field name is case-insensitive")

// Host guard must be identical to the REST server: absent/foreign Host → 403.
check((String(data: mcp.process(Data(("POST /mcp HTTP/1.1\r\n"
    + "Content-Length: \(initReq.utf8.count)\r\nAuthorization: Bearer test-token\r\n\r\n"
    + initReq).utf8)), encoding: .utf8) ?? "").contains("403"),
      "missing Host → 403")
check((String(data: mcp.process(Data(("POST /mcp HTTP/1.1\r\nHost: evil.example\r\n"
    + "Content-Length: \(initReq.utf8.count)\r\nAuthorization: Bearer test-token\r\n\r\n"
    + initReq).utf8)), encoding: .utf8) ?? "").contains("403"),
      "foreign Host → 403")
check(MCPServer.hostName(from: "[::1]:17802") == "::1", "IPv6 Host normalized")

// MARK: - Webhook payload

let snap = WebhookManager.TaskSnapshot(
    id: UUID(), name: "a.zip", url: "https://x/a.zip", state: "completed",
    downloadedBytes: 123, totalBytes: 123, error: nil)
let payload = try! JSONSerialization.jsonObject(with: snap.payload) as! [String: Any]
check(payload["event"] as? String == "task.completed", "webhook event name")
check(payload["name"] as? String == "a.zip", "webhook name")
check(payload["downloadedBytes"] as? Int == 123, "webhook bytes")

// Endpoint Codable round-trip
let ep = WebhookManager.Endpoint(url: "https://hook.example/1", secret: "s3cr3t")
let encoded = try! JSONEncoder().encode([ep])
let decoded = try! JSONDecoder().decode([WebhookManager.Endpoint].self, from: encoded)
check(decoded.first == ep, "Endpoint Codable round-trip")

func httpBody(_ body: String) -> Data {
    "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".data(using: .utf8)!
}

// Auth: without the token every call is rejected before JSON parsing.
let noAuth = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(initReq.utf8.count)\r\n\r\n\(initReq)"
check((String(data: mcp.process(Data(noAuth.utf8)), encoding: .utf8) ?? "").contains("401"),
      "missing token → 401")
let badAuth = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer wrong\r\nContent-Length: \(initReq.utf8.count)\r\n\r\n\(initReq)"
check((String(data: mcp.process(Data(badAuth.utf8)), encoding: .utf8) ?? "").contains("401"),
      "wrong token → 401")

// MARK: - Webhook SSRF / exfiltration policy

check(WebhookPolicy.isAllowed("https://hook.example/x") != nil,
      "public https endpoint allowed")
check(WebhookPolicy.isAllowed("http://hook.internal/x") == nil,
      "plain http to a private-sounding host rejected")
check(WebhookPolicy.isAllowed("file:///etc/passwd") == nil,
      "file: endpoint rejected")
check(WebhookPolicy.isAllowed("ftp://hook.example/x") == nil,
      "non-http scheme rejected")
check(WebhookPolicy.isAllowed("http://169.254.169.254/latest/meta-data") == nil,
      "cloud metadata endpoint rejected")
check(WebhookPolicy.isAllowed("http://127.0.0.1:8080/hook") == nil,
      "loopback rejected by default")
check(WebhookPolicy.isAllowed("http://127.0.0.1:8080/hook", allowPrivate: true) != nil,
      "loopback allowed with explicit opt-in")
check(WebhookPolicy.isAllowed("https://u:p@hook.example/x") == nil,
      "embedded credentials rejected")
check(WebhookPolicy.isAllowed(URL(string: "https://192.168.1.5/x")!) == false,
      "redirect target on private IPv4 rejected")
let redacted = WebhookPolicy.redact(
    "https://user:pass@host.example/x?X-Amz-Signature=abc&keep=1")
check(!redacted.contains("user:pass"), "redact strips URL credentials")
check(redacted.contains("REDACTED"), "redact masks presigned signature")
check(redacted.contains("keep=1"), "redact keeps non-sensitive query values")
let redactedPayload = WebhookManager.TaskSnapshot(
    id: UUID(), name: "x", url: "https://u:p@h/x?X-Amz-Signature=secret",
    state: "completed", downloadedBytes: 0, totalBytes: 0, error: nil)
    .payload
check(!(String(data: redactedPayload, encoding: .utf8) ?? "").contains("secret"),
      "webhook payload never carries the raw presigned URL")

if failures == 0 { print("MCP + WEBHOOK TESTS PASSED") }
else { print("MCP + WEBHOOK TESTS FAILED: \(failures)"); exit(1) }
