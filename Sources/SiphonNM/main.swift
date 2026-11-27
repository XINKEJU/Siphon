import Foundation
import SiphonBridge

/// Native Messaging gateway between the browser extension and the Siphon app.
///
/// Chrome starts this process and speaks the framed stdio protocol. The app
/// publishes its bearer token to a 0600 file (`LocalAuthBootstrap`), which this
/// gateway reads directly — the token is never fetched over the network.
///
/// Two message families are accepted:
///
/// - **MDM-style** flat JSON: `{hello|rules}`, `{recent}`, `{downloadAct}` and a
///   download (`{url, referrer, cookies, userAgent, filename, …}` with no `type`).
///   They are forwarded to the app's loopback API (`/rules`, `/recent`, `/act`,
///   `/browser/add`) so the extension keeps one contract.
/// - **Legacy Siphon**: `{type:"add"|"ping"|"recent"}` used by older builds and
///   by scripts that only know the small `add` shape.
///
/// Exits when stdin reaches EOF.
let baseURL = "http://127.0.0.1:17801"
var cachedToken: String?

func request(_ method: String, _ path: String, body: [String: Any]? = nil,
             token: String? = nil) -> (status: Int, data: Data) {
    guard let url = URL(string: baseURL + path) else { return (0, Data()) }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 6
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
    _ = sem.wait(timeout: .now() + 8)
    return (status, payload)
}

func fetchToken() -> String? {
    // Test seam for the restart E2E harness (the app is launched with the same
    // value); a browser-launched gateway never sees this variable.
    if let override = ProcessInfo.processInfo.environment["SIPHON_LOCAL_API_TOKEN"],
       !override.isEmpty { return override }
    // Out-of-band: /ping is unauthenticated and never discloses the token.
    // Re-reading on 401 also picks up a token rotated in Settings.
    return LocalAuthBootstrap.read()
}

func currentToken() -> String? {
    if let cachedToken { return cachedToken }
    cachedToken = fetchToken()
    return cachedToken
}

/// Authenticated call with one retry: a token rotated while the app is running
/// must not make every later hand-off fail until the browser restarts.
func authed(_ method: String, _ path: String,
            body: [String: Any]? = nil) -> (status: Int, data: Data) {
    var token = currentToken()
    var result = request(method, path, body: body, token: token)
    if result.status == 401 {
        cachedToken = nil
        token = currentToken()
        result = request(method, path, body: body, token: token)
    }
    return result
}

func respond(_ object: [String: Any]) {
    NativeMessagingFraming.writeMessage(object)
}

func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func isTrue(_ value: Any?) -> Bool {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    return false
}

/// Answer for a control message the app could not serve: `why` is what MDM's
/// extension uses to tell "not running" from "I won't take this one".
func failure(_ status: Int, _ data: Data) -> [String: Any] {
    let reason = (jsonObject(data)?["error"] as? String)
        ?? String(data: data, encoding: .utf8)
        ?? ""
    if status == 0 {
        return ["ok": false, "why": "not-running",
                "error": "Siphon 未运行或本地控制接口未开启"]
    }
    if status == 401 || status == 403 {
        return ["ok": false, "why": "not-running",
                "error": "本地令牌无效。请在 Siphon 设置 → 集成 中确认本地控制接口已开启"]
    }
    return ["ok": false, "why": status >= 500 ? "not-running" : "refused",
            "error": reason.isEmpty ? "Siphon 返回 HTTP \(status)" : reason]
}

// MARK: - starting the app

/// A shipped gateway lives in `Siphon.app/Contents/Resources`; in a `swift build`
/// checkout there is no bundle, and the browser's copy can never start one.
func appBundleURL() -> URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let candidate = exe.deletingLastPathComponent()   // Resources
        .deletingLastPathComponent()                  // Contents
        .deletingLastPathComponent()                  // Siphon.app
    return candidate.pathExtension == "app" ? candidate : nil
}

/// A hand-off must not be lost because Siphon was closed: start it the way MDM's
/// helper does (behind the browser, `-g`) and wait briefly for the control port.
func startAppIfNeeded() {
    guard ProcessInfo.processInfo.environment["SIPHON_NM_NO_AUTOSTART"] != "1",
          let bundle = appBundleURL(),
          request("GET", "/ping").status != 200 else { return }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    child.arguments = ["-g", bundle.path]
    do { try child.run() } catch { return }
    child.waitUntilExit()
    for _ in 0..<50 {
        if request("GET", "/ping").status == 200 { return }
        Thread.sleep(forTimeInterval: 0.2)
    }
}

// MARK: - MDM-style messages

/// A download hand-off may start the app; a control/monitoring message may not
/// (MDM's `recent` and `downloadAct` never launch anything).
func handoffCall(_ path: String, body: [String: Any]) -> (status: Int, data: Data) {
    var result = authed("POST", path, body: body)
    if result.status == 0 {
        startAppIfNeeded()
        cachedToken = nil
        result = authed("POST", path, body: body)
    }
    return result
}

func handleRules(_ message: [String: Any]) {
    let (status, data) = authed("POST", "/rules", body: message)
    guard status == 200, let reply = jsonObject(data) else {
        respond(failure(status, data))
        return
    }
    // The app's answer already has the wire shape (ok/types/capture/…).
    respond(reply)
}

func handleRecent() {
    let (status, data) = authed("GET", "/recent")
    guard status == 200, let object = jsonObject(data) else {
        respond(failure(status, data))
        return
    }
    respond(["ok": true, "recent": object["recent"] ?? []])
}

func handleAct(_ act: [String: Any]) {
    let (status, data) = authed("POST", "/act", body: act)
    guard status == 200, let reply = jsonObject(data) else {
        respond(failure(status, data))
        return
    }
    respond(reply)
}

/// A flat download hand-off. Everything the browser knows travels unchanged;
/// the app decides which fields it can use (cookies, referrer, UA, file name,
/// final URL, form data…) and ignores the rest.
func handleHandoff(_ message: [String: Any]) {
    guard let url = message["url"] as? String, !url.isEmpty else {
        respond(["ok": false, "why": "refused", "error": "missing url"])
        return
    }
    let (status, data) = handoffCall("/browser/add", body: message)
    guard status == 200, let reply = jsonObject(data) else {
        respond(failure(status, data))
        return
    }
    respond(reply["ok"] as? Bool == true
            ? ["ok": true]
            : failure(status, data))
}

// MARK: - dispatch

func handle(_ message: [String: Any]) {
    let type = (message["type"] as? String) ?? ""

    switch type {
    case "ping":
        let (status, _) = request("GET", "/ping")
        if status != 200 {
            respond(["ok": false, "why": "not-running",
                     "error": "Siphon 未运行或本地控制接口未开启"])
        } else if currentToken() == nil {
            respond(["ok": false, "why": "not-running",
                     "error": "未找到本地令牌文件，请在 Siphon 设置 → 集成 中开启本地控制接口并重新生成令牌"])
        } else {
            respond(["ok": true, "app": "Siphon"])
        }

    case "recent":
        handleRecent()

    case "add":
        // Legacy shape. Kept for older extension builds and scripts.
        var payload: [String: Any] = [:]
        if let url = message["url"] as? String { payload["url"] = url }
        if let name = message["name"] as? String { payload["name"] = name }
        if let headers = message["headers"] as? [String: String] { payload["headers"] = headers }
        if let checksum = message["checksum"] as? String { payload["checksum"] = checksum }
        if let mirrors = message["mirrors"] as? [String], !mirrors.isEmpty {
            payload["mirrors"] = mirrors
        }
        let (status, data) = handoffCall("/add", body: payload)
        if status == 200 {
            respond(["ok": true])
        } else {
            respond(failure(status, data))
        }

    default:
        // MDM's extension sends no `type`: the keys themselves say what it is.
        if isTrue(message["hello"]) || isTrue(message["rules"]) {
            handleRules(message)
        } else if message["recent"] != nil {
            handleRecent()
        } else if let act = message["downloadAct"] as? [String: Any] {
            handleAct(act)
        } else if message["url"] is String {
            handleHandoff(message)
        } else if let action = message["action"] as? String, action == "recent" {
            handleRecent()
        } else {
            respond(["ok": false, "error": "unknown message"])
        }
    }
}

while let message = NativeMessagingFraming.readMessage() {
    handle(message)
}