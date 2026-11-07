import Foundation
import Network

// Token hardening of the loopback control surfaces:
//   - LocalAuthToken verify semantics (Bearer prefix, bare token, rejection)
//   - NativeMessagingServer: /ping open (token bootstrap), everything else 401
//   - MCPServer: every call 401 without the token
//   - no CORS header is ever emitted
// Pure message-level tests through the `configure` / `process` seams — no ports.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

LocalAuthToken.testingToken = "test-token"
defer { LocalAuthToken.testingToken = nil }

func status(_ data: Data) -> String {
    String(data: data, encoding: .utf8)?
        .components(separatedBy: "\r\n").first ?? ""
}

func restRequest(_ method: String, _ path: String, auth: String? = nil,
                 body: String = "") -> Data {
    var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    if let auth { head += "Authorization: \(auth)\r\n" }
    if !body.isEmpty { head += "Content-Length: \(body.utf8.count)\r\n" }
    return Data((head + "\r\n" + body).utf8)
}

// MARK: - token semantics

let generated = Keychain.randomToken() ?? ""
check("token generation is non-empty and long enough",
      !generated.isEmpty && generated.count >= 40)
check("constant-time equal matches", Keychain.constantTimeEqual("abc", "abc"))
check("constant-time equal rejects", !Keychain.constantTimeEqual("abc", "abd"))
check("constant-time equal rejects different lengths",
      !Keychain.constantTimeEqual("abc", "abcd"))
check("verify accepts bare token", LocalAuthToken.verify("test-token"))
check("verify accepts Bearer form", LocalAuthToken.verify("Bearer test-token"))
check("verify rejects wrong token", !LocalAuthToken.verify("nope"))
check("verify rejects nil/empty", !LocalAuthToken.verify(nil) && !LocalAuthToken.verify(""))

// Rotation replaces the active token immediately.
let rotated = LocalAuthToken.rotate()
check("rotate produces a new token", rotated != "test-token")
check("old token rejected after rotate", !LocalAuthToken.verify("test-token"))
check("new token accepted after rotate", LocalAuthToken.verify(rotated))
LocalAuthToken.testingToken = "test-token"

// MARK: - NativeMessagingServer

let srv = NativeMessagingServer()
var added: String?
srv.configure(onURL: { url, _, _, _ in added = url },
              apiHandler: { method, path, _ in
                  Data(#"{"ok":true,"method":"\#(method)","path":"\#(path)"}"#.utf8)
              })

let ping = srv.process(restRequest("GET", "/ping"))
check("GET /ping stays token-free", status(ping).contains("200 OK"))
let pingBody = String(data: ping, encoding: .utf8) ?? ""
check("ping response carries the bootstrap token",
      pingBody.contains("\"token\":\"test-token\""), pingBody)

check("/add without token → 401",
      status(srv.process(restRequest("POST", "/add", body: #"{"url":"https://x/f"}"#)))
          .contains("401 Unauthorized"))
check("nothing reached the handler when rejected", added == nil)
check("/add with wrong token → 401",
      status(srv.process(restRequest("POST", "/add", auth: "Bearer nope",
                                     body: #"{"url":"https://x/f"}"#)))
          .contains("401 Unauthorized"))
check("/tasks without token → 401",
      status(srv.process(restRequest("GET", "/tasks"))).contains("401 Unauthorized"))
check("/tasks with bare token accepted",
      status(srv.process(restRequest("GET", "/tasks", auth: "test-token")))
          .contains("200 OK"))
check("/tasks with Bearer token accepted",
      status(srv.process(restRequest("GET", "/tasks", auth: "Bearer test-token")))
          .contains("200 OK"))
let addOK = srv.process(restRequest("POST", "/add", auth: "Bearer test-token",
                                    body: #"{"url":"https://x/f"}"#))
check("/add with token accepted", status(addOK).contains("200 OK") && added == "https://x/f")

// Header parsing is case-insensitive on field names.
let weirdCase = srv.process(restRequest("GET", "/tasks", auth: nil).replacingAuthorizations())
check("authorizAtion header recognized", !status(weirdCase).contains("401"))

extension Data {
    func replacingAuthorizations() -> Data {
        // restRequest without auth has no Authorization line; append a
        // mixed-case one before the blank line.
        let s = String(decoding: self, as: UTF8.self)
        let patched = s.replacingOccurrences(of: "Host: 127.0.0.1\r\n",
            with: "Host: 127.0.0.1\r\nauthorizAtion: Bearer test-token\r\n")
        return Data(patched.utf8)
    }
}

check("no CORS header on any response",
      !pingBody.contains("Access-Control-Allow-Origin"))

// MARK: - MDXP route (device tokens + JSON-RPC passthrough)

let mdxp = NativeMessagingServer()
mdxp.configure(onURL: { _, _, _, _ in },
               apiHandler: nil,
               mdxpHandler: { body in
                   Data(#"{"jsonrpc":"2.0","id":1,"result":{"echo":"\#(String(decoding: body, as: UTF8.self))"}}"#.utf8)
               },
               additionalTokenVerifier: { value in
                   // Mirrors RemotePairing.verify: strip an optional Bearer prefix.
                   let token = value.lowercased().hasPrefix("bearer ")
                       ? String(value.dropFirst("bearer ".count)) : value
                   return token == "device-token"
               })
let rpcBody = #"{"jsonrpc":"2.0","id":1,"method":"mdxp.ping"}"#

let mdxpLocal = mdxp.process(restRequest("POST", "/mdxp", auth: "Bearer test-token", body: rpcBody))
check("MDXP accepts the local API token", status(mdxpLocal).contains("200 OK"))
check("MDXP passes the JSON-RPC body through",
      (String(data: mdxpLocal, encoding: .utf8) ?? "").contains("mdxp.ping"))

let mdxpDevice = mdxp.process(restRequest("POST", "/mdxp", auth: "Bearer device-token", body: rpcBody))
check("MDXP accepts a paired device token", status(mdxpDevice).contains("200 OK"))

check("MDXP rejects an unknown token",
      status(mdxp.process(restRequest("POST", "/mdxp", auth: "Bearer nope", body: rpcBody)))
          .contains("401 Unauthorized"))
check("MDXP rejects a device token when no verifier is configured",
      status(srv.process(restRequest("POST", "/mdxp", auth: "Bearer device-token", body: rpcBody)))
          .contains("401 Unauthorized"))

let mdxpDisabled = NativeMessagingServer()
mdxpDisabled.configure(onURL: { _, _, _, _ in }, apiHandler: nil, mdxpHandler: nil)
check("MDXP route is 404 when the bridge is off",
      status(mdxpDisabled.process(restRequest("POST", "/mdxp", auth: "Bearer test-token",
                                             body: rpcBody))).contains("404 Not Found"))

// MARK: - MCPServer

let mcp = MCPServer()
mcp.configure(handlers: ["list_tasks": { _ in "a,b" }])
let rpc = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
func mcpRequest(auth: String?) -> Data {
    var head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(rpc.utf8.count)\r\n"
    if let auth { head += "Authorization: \(auth)\r\n" }
    return Data((head + "\r\n" + rpc).utf8)
}
check("MCP without token → 401", status(mcp.process(mcpRequest(auth: nil))).contains("401"))
check("MCP with wrong token → 401", status(mcp.process(mcpRequest(auth: "Bearer x"))).contains("401"))
let mcpOK = mcp.process(mcpRequest(auth: "Bearer test-token"))
check("MCP with token accepted", status(mcpOK).contains("200 OK")
      && (String(data: mcpOK, encoding: .utf8) ?? "").contains("list_tasks"))
check("MCP responses carry no CORS header",
      !(String(data: mcpOK, encoding: .utf8) ?? "").contains("Access-Control-Allow-Origin"))

if failures == 0 { print("LOCAL AUTH TESTS PASSED") }
else { print("LOCAL AUTH TESTS FAILED: \(failures)"); exit(1) }
