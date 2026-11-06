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

if failures == 0 { print("NATIVE MESSAGING TESTS PASSED") }
else { print("NATIVE MESSAGING TESTS FAILED: \(failures)"); exit(1) }
