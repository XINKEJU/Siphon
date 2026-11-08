import Foundation

// Offline tests for UpdateChecker's pure logic (no network, no bundle).
var pass = 0, fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { pass += 1 } else { fail += 1; print("FAIL: \(name)") }
}

// isNewer
check("isNewer patch bump", UpdateChecker.isNewer("1.2.3", than: "1.2.2"))
check("isNewer minor bump", UpdateChecker.isNewer("1.10", than: "1.9"))
check("isNewer major bump", UpdateChecker.isNewer("2.0", than: "1.9.9"))
check("isNewer equal", !UpdateChecker.isNewer("1.2.3", than: "1.2.3"))
check("isNewer older", !UpdateChecker.isNewer("1.2.2", than: "1.2.3"))
check("isNewer shorter version not newer", !UpdateChecker.isNewer("1.2", than: "1.2.0"))
check("isNewer longer version newer", UpdateChecker.isNewer("1.2.1", than: "1.2"))
check("isNewer non-numeric segment", UpdateChecker.isNewer("1.2.3-beta", than: "1.2.3-alpha"))

// parseFeed: direct object
let direct = Data(#"{"version":"2.0.1","url":"https://example.com/Siphon.zip","sha256":"ABCD","notes":"hi"}"#.utf8)
guard let info = UpdateChecker.parseFeed(direct) else {
    fatalError("parseFeed direct failed")
}
check("parseFeed direct version", info.version == "2.0.1")
check("parseFeed direct url", info.url == "https://example.com/Siphon.zip")
check("parseFeed direct sha256", info.sha256 == "ABCD")
check("parseFeed direct notes", info.notes == "hi")

// parseFeed: wrapped {"update": {...}}
let wrapped = Data(#"{"update":{"version":"3.0","url":"https://example.com/b.zip"}}"#.utf8)
guard let w = UpdateChecker.parseFeed(wrapped) else {
    fatalError("parseFeed wrapped failed")
}
check("parseFeed wrapped", w.version == "3.0" && w.url == "https://example.com/b.zip")

// parseFeed: invalid
check("parseFeed empty data", UpdateChecker.parseFeed(Data()) == nil)
check("parseFeed missing url", UpdateChecker.parseFeed(Data(#"{"version":"1.0"}"#.utf8)) == nil)
check("parseFeed missing version", UpdateChecker.parseFeed(Data(#"{"url":"https://x"}"#.utf8)) == nil)
check("parseFeed garbage", UpdateChecker.parseFeed(Data("not json".utf8)) == nil)
check("parseFeed array", UpdateChecker.parseFeed(Data("[1,2]".utf8)) == nil)

// Update source policy (regression: http:// and file:// were accepted, and the
// optional hash was trusted from that same feed — a supply-chain RCE path).
check("https update source accepted",
      UpdateChecker.trustedURL("https://example.com/latest.json") != nil)
check("http update source rejected",
      UpdateChecker.trustedURL("http://example.com/latest.json") == nil)
check("file update source rejected",
      UpdateChecker.trustedURL("file:///tmp/latest.json") == nil)
check("loopback update source rejected",
      UpdateChecker.trustedURL("https://127.0.0.1/latest.json") == nil)
check("private IPv4 update source rejected",
      UpdateChecker.trustedURL("https://192.168.1.5/latest.json") == nil)
check("link-local update source rejected",
      UpdateChecker.trustedURL("https://169.254.169.254/latest.json") == nil)
check("localhost update source rejected",
      UpdateChecker.trustedURL("https://localhost/latest.json") == nil)
check("embedded credentials rejected",
      UpdateChecker.trustedURL("https://user:pass@example.com/latest.json") == nil)
check("nonstandard port rejected",
      UpdateChecker.trustedURL("https://example.com:8443/latest.json") == nil)
check("empty update source rejected", UpdateChecker.trustedURL("") == nil)

let digest = String(repeating: "a", count: 64)
check("valid SHA-256 accepted", UpdateChecker.isValidSHA256(digest))
check("uppercase SHA-256 accepted", UpdateChecker.isValidSHA256(digest.uppercased()))
check("placeholder digest rejected", !UpdateChecker.isValidSHA256("ABCD"))
check("missing digest rejected", !UpdateChecker.isValidSHA256(nil))
check("short digest rejected", !UpdateChecker.isValidSHA256(String(repeating: "a", count: 63)))
check("non-hex digest rejected",
      !UpdateChecker.isValidSHA256(String(repeating: "z", count: 64)))

// sha256Hex of a small file ("abc" → known digest)
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("siphon-update-test-\(UUID().uuidString).txt")
try! Data("abc".utf8).write(to: tmp)
check("sha256Hex known digest",
      UpdateChecker.sha256Hex(of: tmp)
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("sha256Hex missing file empty", UpdateChecker.sha256Hex(
    of: tmp.appendingPathExtension("nope")) == "")
try? FileManager.default.removeItem(at: tmp)

print("PASS: \(pass)  FAIL: \(fail)")
exit(fail == 0 ? 0 : 1)
