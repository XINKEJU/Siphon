import Foundation

// Regression test for NativeMessagingServer's request parsing. The old code read
// only one 64 KB chunk, so a TCP-split or large POST lost its body. The fix keeps
// reading until `hasCompleteRequest` sees a full header + body. We unit-test the
// request-completeness predicate and the parser directly.

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

let s = NativeMessagingServer()
let hdr = "POST /add HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 30\r\n\r\n"
let body = "{\"url\":\"https://x.test/a.bin\"}"
let full = Data((hdr + body).utf8)

// A header that arrives before its body must be reported incomplete so the server
// keeps reading, instead of dropping the body.
check(!s.hasCompleteRequest(Data(hdr.utf8)), "split header-only request is incomplete")
check(s.hasCompleteRequest(full), "full request (header + body) is complete")

// GET has no body; headers alone are enough.
let getReq = "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n"
check(s.hasCompleteRequest(Data(getReq.utf8)), "GET request is complete from headers")

// End-to-end parsing still works.
if let resp = String(data: s.process(full), encoding: .utf8) {
    check(resp.contains("\"ok\":true"), "POST /add returns ok")
} else { check(false, "process produced no response") }
if let resp = String(data: s.process(Data(getReq.utf8)), encoding: .utf8) {
    check(resp.contains("\"app\":\"Siphon\""), "GET /ping returns app banner")
} else { check(false, "process produced no response") }

// Multi-byte UTF-8 body: a CJK filename in the URL. Body length must be counted in
// BYTES, not Swift characters — otherwise the predicate would never see "enough"
// characters for a multi-byte payload and would hang waiting for more bytes.
let mbBodyStr = "{\"url\":\"https://x.test/中文文件名.bin\"}"
let mbBody = mbBodyStr.data(using: .utf8)!
let mbLen = mbBody.count
check(mbLen > mbBodyStr.count, "multibyte body has more bytes than characters (sanity)")
let mbHdr = "POST /add HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(mbLen)\r\n\r\n"
let mbFull = Data(mbHdr.utf8) + mbBody
check(s.hasCompleteRequest(mbFull), "multibyte UTF-8 POST body measured by bytes, not characters")
check(!s.hasCompleteRequest(Data(mbHdr.utf8)), "multibyte POST split header-only is incomplete")
// And the full multi-byte request still parses correctly (URL preserved).
if let resp = String(data: s.process(mbFull), encoding: .utf8) {
    check(resp.contains("\"ok\":true"), "multibyte POST /add returns ok")
} else { check(false, "process produced no response for multibyte body") }

// MARK: - headers passthrough + checksum + REST API routing

do {
    let srv = NativeMessagingServer()
    var captured: (url: String, options: [String: String], checksum: String?, mirrors: [String])?
    srv.configure(onURL: { url, options, checksum, mirrors in
        captured = (url, options, checksum, mirrors)
    })
    // Extension background.js replays the page request: headers dict + referer
    // folded in, checksum from the popup's verify field, plus mirror URLs.
    let addBody = #"{"url":"https://host.test/f.zip","headers":{"User-Agent":"SiphonTest/1.0","Referer":"https://host.test/page","Cookie":"k=v\r\nX-Injected: 1"},"checksum":"sha256:abc123","mirrors":["https://cdn.test/f.zip","https://mirror.test/f.zip"]}"#
    let addReq = "POST /add HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(addBody.utf8.count)\r\n\r\n" + addBody
    let resp = srv.process(Data(addReq.utf8))
    check(String(data: resp, encoding: .utf8)!.contains("\"ok\":true"), "/add with headers accepted")
    guard let cap = captured else {
        check(false, "handler captured add payload")
        if failures == 0 { print("NATIVE MESSAGING TESTS PASSED") }
        else { print("NATIVE MESSAGING TESTS FAILED: \(failures)"); exit(1) }
        exit(1)
    }
    check(cap.url == "https://host.test/f.zip", "url captured")
    check(cap.options["User-Agent"] == "SiphonTest/1.0", "User-Agent header passed through")
    check(cap.options["Referer"] == "https://host.test/page", "Referer header passed through")
    check(cap.options["Cookie"] == "k=v X-Injected: 1" || cap.options["Cookie"] == "k=vX-Injected: 1",
          "CRLF stripped from header values", "got \(cap.options["Cookie"] ?? "nil")")
    check(cap.checksum == "sha256:abc123", "checksum passed through")
    check(cap.mirrors == ["https://cdn.test/f.zip", "https://mirror.test/f.zip"],
          "mirrors passed through")

    // REST surface routes through apiHandler with method/path/body intact.
    var routed: (method: String, path: String, body: String)?
    let srv2 = NativeMessagingServer()
    srv2.configure(onURL: { _, _, _, _ in },
                   apiHandler: { method, path, body in
                       routed = (method, path, String(data: body, encoding: .utf8) ?? "")
                       return Data(#"{"ok":true,"tasks":[]}"#.utf8)
                   })
    let tasksReq = "GET /tasks HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    let r1 = String(data: srv2.process(Data(tasksReq.utf8)), encoding: .utf8) ?? ""
    check(r1.contains("200 OK") && r1.contains("\"ok\":true"), "GET /tasks routed to api handler",
          "got \(r1.prefix(60))")
    check(routed?.method == "GET" && routed?.path == "/tasks", "routing captured GET /tasks")

    let pauseBody = #"{"id":"11111111-2222-3333-4444-555555555555"}"#
    let pauseReq = "POST /pause HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(pauseBody.utf8.count)\r\n\r\n" + pauseBody
    let r2 = String(data: srv2.process(Data(pauseReq.utf8)), encoding: .utf8) ?? ""
    check(r2.contains("200 OK"), "POST /pause routed to api handler")
    check(routed?.method == "POST" && routed?.path == "/pause" && routed?.body == pauseBody,
          "routing captured POST /pause with body")

    // Unknown paths fall through to the api handler too (which answers 404-ish).
    let nfReq = "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    let r3 = String(data: srv2.process(Data(nfReq.utf8)), encoding: .utf8) ?? ""
    check(routed?.path == "/nope", "unknown path reaches api handler for store-side 404")
    _ = r3
}

if failures == 0 { print("NATIVE MESSAGING TESTS PASSED") }
else { print("NATIVE MESSAGING TESTS FAILED: \(failures)"); exit(1) }
