import Foundation

// Credential scoping: captured headers must not be replayed to a host they were
// not issued for. Three layers are covered —
//   A. the pure site/origin/header-filter logic
//   B. the URLSession redirect guard (real 302 hops)
//   C. SegmentAssembler writing segments from three different origins
// Requires the fixture started by this file (Tests/fixtures-credscope/echo_server.py).

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

func u(_ s: String) -> URL { URL(string: s)! }

// MARK: - A. pure logic

func pureLogic() {
    let rd = CredentialScope.registrableDomain
    check("eTLD+1 collapses subdomains", rd("cdn.assets.example.com") == "example.com",
          rd("cdn.assets.example.com"))
    check("multi-label suffix keeps three labels", rd("a.b.bank.co.uk") == "bank.co.uk",
          rd("a.b.bank.co.uk"))
    check("co.uk siblings are different sites",
          !CredentialScope.isSameSite(u("https://bank.co.uk/"), u("https://evil.co.uk/")))
    check("com.cn handled", rd("shop.taobao.com.cn") == "taobao.com.cn",
          rd("shop.taobao.com.cn"))
    check("IPv4 literal is its own site", rd("127.0.0.1") == "127.0.0.1")
    check("IPv6 literal is its own site", rd("::1") == "::1")
    check("single-label host is its own site", rd("localhost") == "localhost")
    check("host normalized: case + trailing dot", rd("EXAMPLE.COM.") == "example.com",
          rd("EXAMPLE.COM."))
    check("empty host yields empty site", rd("") == "")
    check("numeric-looking host is not an IP", rd("999.1.1.1.example.com") == "example.com",
          rd("999.1.1.1.example.com"))

    check("default port equals explicit port",
          CredentialScope.isSameOrigin(u("http://a.com/x"), u("http://a.com:80/y")))
    check("https default port equals 443",
          CredentialScope.isSameOrigin(u("https://a.com/x"), u("https://a.com:443/y")))
    check("scheme change is not same origin",
          !CredentialScope.isSameOrigin(u("https://a.com/"), u("http://a.com/")))
    check("subdomain is not same origin",
          !CredentialScope.isSameOrigin(u("http://a.com/"), u("http://sub.a.com/")))
    check("port change is not same origin",
          !CredentialScope.isSameOrigin(u("http://a.com/"), u("http://a.com:8080/")))
    check("subdomain IS same site",
          CredentialScope.isSameSite(u("http://a.com/"), u("https://sub.a.com/")))
    check("different hosts are not same site",
          !CredentialScope.isSameSite(u("http://a.com/"), u("http://b.com/")))
    check("localhost and 127.0.0.1 are different sites",
          !CredentialScope.isSameSite(u("http://localhost/"), u("http://127.0.0.1/")))

    let captured: [String: String] = [
        "Authorization": "Bearer tok",
        "Cookie": "sess=1",
        "Referer": "https://a.com/page",
        "User-Agent": "Siphon/1.0",
        "Accept": "*/*",
        "X-Hotlink-Token": "abc",
    ]
    let origin = u("https://a.com/playlist.m3u8")

    let sameOrigin = CredentialScope.headers(captured, from: origin, to: u("https://a.com/seg1.ts"))
    check("same origin keeps everything", sameOrigin == captured, "\(sameOrigin)")

    let subdomain = CredentialScope.headers(captured, from: origin, to: u("https://cdn.a.com/seg1.ts"))
    check("same-site subdomain keeps Cookie", subdomain["Cookie"] == "sess=1")
    check("same-site subdomain drops Authorization", subdomain["Authorization"] == nil)
    check("same-site subdomain keeps non-credentials",
          subdomain["User-Agent"] == "Siphon/1.0" && subdomain["X-Hotlink-Token"] == "abc")

    let crossSite = CredentialScope.headers(captured, from: origin, to: u("https://evil.net/seg1.ts"))
    check("cross-site drops Cookie", crossSite["Cookie"] == nil)
    check("cross-site drops Authorization", crossSite["Authorization"] == nil)
    check("cross-site keeps User-Agent (needed to download at all)",
          crossSite["User-Agent"] == "Siphon/1.0")

    let downgrade = CredentialScope.headers(captured, from: origin, to: u("http://a.com/seg1.ts"))
    check("https→http drops Cookie even on the same host", downgrade["Cookie"] == nil)
    check("https→http drops Referer", downgrade["Referer"] == nil)
    check("https→http keeps User-Agent", downgrade["User-Agent"] == "Siphon/1.0")

    // Header names are case-insensitive on the wire.
    let mixedCase: [String: String] = ["authorization": "Bearer tok", "cOoKiE": "sess=1"]
    let filtered = CredentialScope.headers(mixedCase, from: origin, to: u("https://evil.net/x"))
    check("lowercase authorization is scoped", filtered["authorization"] == nil)
    check("mixed-case Cookie is scoped", filtered["cOoKiE"] == nil)

    // Proxy-Authorization must never leave the origin either.
    let proxyCreds: [String: String] = ["Proxy-Authorization": "Basic xyz"]
    check("Proxy-Authorization dropped cross-origin",
          CredentialScope.headers(proxyCreds, from: origin,
                                  to: u("https://cdn.a.com/x"))["Proxy-Authorization"] == nil)

    // strippingDisallowedCredentials must leave an already-clean request alone.
    var clean = URLRequest(url: u("https://evil.net/x"))
    clean.setValue("Siphon/1.0", forHTTPHeaderField: "User-Agent")
    let untouched = CredentialScope.strippingDisallowedCredentials(in: clean, from: origin,
                                                                  to: u("https://evil.net/x"))
    check("clean request passes through unchanged",
          untouched.allHTTPHeaderFields?["User-Agent"] == "Siphon/1.0"
          && untouched.allHTTPHeaderFields?.count == 1)

    var dirty = URLRequest(url: u("https://evil.net/x"))
    dirty.setValue("sess=1", forHTTPHeaderField: "Cookie")
    dirty.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
    dirty.setValue("Siphon/1.0", forHTTPHeaderField: "User-Agent")
    let stripped = CredentialScope.strippingDisallowedCredentials(in: dirty, from: origin,
                                                                 to: u("https://evil.net/x"))
    check("redirect strip removes Cookie", stripped.value(forHTTPHeaderField: "Cookie") == nil)
    check("redirect strip removes Authorization",
          stripped.value(forHTTPHeaderField: "Authorization") == nil)
    check("redirect strip keeps User-Agent",
          stripped.value(forHTTPHeaderField: "User-Agent") == "Siphon/1.0")
}

// MARK: - fixture server

func startServer(port: Int) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["Tests/fixtures-credscope/echo_server.py", String(port)]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    return p
}

func waitForServer(port: Int, timeout: Double = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    let probe = u("http://127.0.0.1:\(port)/ping")
    while Date() < deadline {
        if let (_, resp) = try? await URLSession.shared.data(from: probe),
           (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return false
}

func echo(_ url: URL, headers: [String: String]) async -> [String: String] {
    var r = URLRequest(url: url)
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    guard let (data, _) = try? await CredentialScope.session.data(for: r),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    var out: [String: String] = [:]
    for (k, v) in json { if let s = v as? String { out[k] = s } }
    return out
}

// MARK: - B. redirect guard (real 302)

@MainActor
func redirectGuard(port: Int) async {
    let sent = ["Cookie": "sess=1", "Authorization": "Bearer tok",
                "User-Agent": "Siphon/1.0", "Referer": "http://127.0.0.1:\(port)/page"]

    let cross = await echo(u("http://127.0.0.1:\(port)/redirect-cross"), headers: sent)
    check("302 to another site drops Cookie", cross["cookie"] == nil, "\(cross)")
    check("302 to another site drops Authorization", cross["authorization"] == nil, "\(cross)")
    check("302 to another site keeps User-Agent", cross["user-agent"] == "Siphon/1.0", "\(cross)")

    let same = await echo(u("http://127.0.0.1:\(port)/redirect-same"), headers: sent)
    check("302 within the origin keeps Cookie", same["cookie"] == "sess=1", "\(same)")
    check("302 within the origin keeps Authorization", same["authorization"] == "Bearer tok",
          "\(same)")

    // A direct request (no redirect) must still deliver credentials to its own origin.
    let direct = await echo(u("http://127.0.0.1:\(port)/echo"), headers: sent)
    check("direct same-origin request keeps both credentials",
          direct["cookie"] == "sess=1" && direct["authorization"] == "Bearer tok", "\(direct)")
}

// MARK: - C. SegmentAssembler across three origins

@MainActor
final class ProgressSpy: EngineDelegate {
    var state: DownloadState?
    var last: DownloadProgress?
    func engineDidUpdate(taskID: UUID, progress: DownloadProgress) { last = progress }
    func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) { self.state = state }
}

@MainActor
func assemblerScoping(port: Int, otherPort: Int) async {
    let out = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("siphon-credscope-\(UUID().uuidString).ts")
    defer { try? FileManager.default.removeItem(at: out) }

    // Headers captured for the playlist on 127.0.0.1:port.
    let origin = u("http://127.0.0.1:\(port)/media.m3u8")
    let headers = ["Cookie": "sess", "Authorization": "Bearer tok", "User-Agent": "Siphon/1.0"]
    let requests = [
        SegmentRequest(url: u("http://127.0.0.1:\(port)/seg")),       // same origin
        SegmentRequest(url: u("http://127.0.0.1:\(otherPort)/seg")),  // same site, other port
        SegmentRequest(url: u("http://localhost:\(port)/seg")),       // different site
    ]
    let assembler = SegmentAssembler(concurrency: 3)
    let spy = ProgressSpy()
    assembler.delegate = spy
    do {
        try assembler.start(taskID: UUID(), destination: out, requests: requests,
                            headers: headers, credentialOrigin: origin)
    } catch {
        check("assembler started", false, error.localizedDescription)
        return
    }
    for _ in 0..<100 {
        if spy.state == .completed || spy.state == .error { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    check("assembly completed", spy.state == .completed, "\(String(describing: spy.state))")

    let got = String(data: (try? Data(contentsOf: out)) ?? Data(), encoding: .utf8) ?? "<nil>"
    let want = "C=sess;A=Bearer tok\n"   // same origin: both
             + "C=sess;A=-\n"           // same site, other port: cookie only
             + "C=-;A=-\n"              // other site: neither
    check("segments receive only the credentials their site is entitled to", got == want, got)
}

// MARK: - entry point

@main
struct CredentialScopeTests {
    @MainActor
    static func main() async {
        pureLogic()

        let port = 18791
        let otherPort = 18792
        let a = startServer(port: port)
        let b = startServer(port: otherPort)
        func shutdown() { a.terminate(); b.terminate(); a.waitUntilExit(); b.waitUntilExit() }

        guard await waitForServer(port: port), await waitForServer(port: otherPort) else {
            check("fixture servers reachable", false, "ports \(port)/\(otherPort)")
            shutdown()
            exit(1)
        }
        // `localhost` must resolve to the dual-stack fixture, otherwise the
        // cross-site assertions below would pass for the wrong reason.
        let localhostReachable = await waitForLocalhost(port: port)
        check("localhost fixture reachable (cross-site case is meaningful)", localhostReachable)

        await redirectGuard(port: port)
        await assemblerScoping(port: port, otherPort: otherPort)

        shutdown()
        print(failures == 0 ? "CredentialScopeTests: ALL PASS"
                            : "CredentialScopeTests: \(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    static func waitForLocalhost(port: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let (_, r) = try? await URLSession.shared.data(from: u("http://localhost:\(port)/ping")),
               (r as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}