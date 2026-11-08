import Foundation
import SiphonBridge

/// Native Messaging gateway between the browser extension and the Siphon app.
///
/// Chrome starts this process and speaks the framed stdio protocol. We translate
/// `{"type":"add", …}` / `{"type":"ping"}` into the app's loopback HTTP API
/// (`http://127.0.0.1:17801`). The bearer token is **not** fetched from the
/// network: the app publishes it to a 0600 file (`LocalAuthBootstrap`) which
/// this gateway reads directly, then retries once on 401 (token rotation).
/// Exits when stdin reaches EOF.

let baseURL = "http://127.0.0.1:17801"
var cachedToken: String?

func request(_ method: String, _ path: String, body: [String: Any]? = nil,
             token: String? = nil) -> (status: Int, data: Data) {
    guard let url = URL(string: baseURL + path) else { return (0, Data()) }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 5
    if let token {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body, let data = try? JSONSerialization.data(withJSONObject: body) {
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var status = 0
    var payload = Data()
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, response, _ in
        if let http = response as? HTTPURLResponse { status = http.statusCode }
        payload = data ?? Data()
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 6)
    return (status, payload)
}

func fetchToken() -> String? {
    // Test seam for the restart E2E harness (the app is launched with the same
    // value); a browser-launched gateway never sees this variable.
    if let override = ProcessInfo.processInfo.environment["SIPHON_LOCAL_API_TOKEN"],
       !override.isEmpty { return override }
    // Out-of-band: /ping is unauthenticated and no longer discloses the token.
    // Re-reading on 401 also picks up a token rotated in Settings.
    return LocalAuthBootstrap.read()
}

func currentToken() -> String? {
    if let cachedToken { return cachedToken }
    cachedToken = fetchToken()
    return cachedToken
}

func respond(_ object: [String: Any]) {
    NativeMessagingFraming.writeMessage(object)
}

func handle(_ message: [String: Any]) {
    let type = (message["type"] as? String) ?? ""
    switch type {
    case "ping":
        let (status, _) = request("GET", "/ping")
        if status != 200 {
            respond(["ok": false, "error": "Siphon 未运行或本地控制接口未开启"])
        } else if currentToken() == nil {
            respond(["ok": false, "error": "未找到本地令牌文件，请在 Siphon 设置 → 集成 中开启本地控制接口并重新生成令牌"])
        } else {
            respond(["ok": true, "app": "Siphon"])
        }

    case "add":
        guard let url = message["url"] as? String, !url.isEmpty else {
            respond(["ok": false, "error": "missing url"])
            return
        }
        var payload: [String: Any] = ["url": url]
        if let headers = message["headers"] as? [String: String] { payload["headers"] = headers }
        if let checksum = message["checksum"] as? String { payload["checksum"] = checksum }
        if let mirrors = message["mirrors"] as? [String], !mirrors.isEmpty {
            payload["mirrors"] = mirrors
        }
        var token = currentToken()
        var (status, data) = request("POST", "/add", body: payload, token: token)
        if status == 401 {
            // Token rotated while the app was running — re-bootstrap and retry.
            cachedToken = nil
            token = currentToken()
            (status, data) = request("POST", "/add", body: payload, token: token)
        }
        if status == 200 {
            respond(["ok": true])
        } else {
            let reason = String(data: data, encoding: .utf8) ?? ""
            respond(["ok": false, "error": reason.isEmpty
                     ? "Siphon 返回 HTTP \(status)" : reason])
        }

    default:
        respond(["ok": false, "error": "unknown message type: \(type)"])
    }
}

while let message = NativeMessagingFraming.readMessage() {
    handle(message)
}
