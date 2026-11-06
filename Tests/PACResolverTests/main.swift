import Foundation

// Pure-logic tests for the PAC resolver (parse + JavaScriptCore evaluation).

var failures = 0
func check(_ cond: Bool, _ msg: String, _ detail: String = "") {
    if cond { print("  ok  \(msg)") }
    else { failures += 1; print("  FAIL \(msg)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

// MARK: - directive string parsing

let parsed = PACResolver.parse("PROXY proxy.example.com:8080; DIRECT")
check(parsed.count == 2, "two directives from PROXY;DIRECT")
check(parsed[0] == .proxy(host: "proxy.example.com", port: 8080), "first is PROXY host:port")
check(parsed[1] == .direct, "second is DIRECT")

check(PACResolver.parse("DIRECT") == [.direct], "DIRECT alone → [.direct]")
check(PACResolver.parse("SOCKS5 127.0.0.1:1080") ==
      [.socks(host: "127.0.0.1", port: 1080, version: 5)], "SOCKS5 parse")
check(PACResolver.parse("SOCKS4 10.0.0.1:9050") ==
      [.socks(host: "10.0.0.1", port: 9050, version: 4)], "SOCKS4 parse")
check(PACResolver.parse("HTTPS secure.proxy:8443") ==
      [.https(host: "secure.proxy", port: 8443)], "HTTPS parse")

// IPv6 literal host
check(PACResolver.parse("PROXY [::1]:8080") ==
      [.proxy(host: "::1", port: 8080)], "IPv6 literal PROXY")

// Whitespace tolerance + unknown token skip
check(PACResolver.parse("PROXY a:1 ; BOGUS x ; DIRECT").count == 2, "skip unknown tokens")
check(PACResolver.parse("") == [], "empty string → empty")

// MARK: - JavaScriptCore evaluation

let script = """
function FindProxyForURL(url, host) {
    if (host == "internal.example.com") return "DIRECT";
    if (shExpMatch(host, "*.corp.com")) return "PROXY corp.proxy:3128";
    return "PROXY default.proxy:8080; DIRECT";
}
"""
let resolver = PACResolver(script: script)
let internalURL = URL(string: "http://internal.example.com/file")!
let corpURL = URL(string: "https://app.corp.com/x")!
let otherURL = URL(string: "https://example.org/y")!

let r1 = resolver.resolve(internalURL)
check(r1 == [.direct], "internal host → DIRECT", "got \(r1)")
let r2 = resolver.resolve(corpURL)
check(r2.first == PACResolver.Directive.proxy(host: "corp.proxy", port: 3128),
      "corp host → corp proxy", "got \(r2)")
let r3 = resolver.resolve(otherURL)
check(r3.first == PACResolver.Directive.proxy(host: "default.proxy", port: 8080),
      "default → default proxy")

// A script that references only the built-in helpers must not throw.
let helperScript = """
function FindProxyForURL(url, host) {
    if (isPlainHostName(host) || isResolvable(host) == false) return "DIRECT";
    return "PROXY p:80";
}
"""
let r4 = PACResolver(script: helperScript).resolve(URL(string: "http://localhost:9/")!)
check(r4.first == PACResolver.Directive.proxy(host: "p", port: 80) ||
      r4.first == PACResolver.Directive.direct,
      "helper functions don't throw")

// Missing FindProxyForURL → empty result (no crash)
check(PACResolver(script: "var x = 1;").resolve(otherURL) == [],
      "missing FindProxyForURL → empty")

if failures == 0 { print("PAC TESTS PASSED") }
else { print("PAC TESTS FAILED: \(failures)"); exit(1) }
