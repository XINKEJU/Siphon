import Foundation

/// Regression test for the dependency-free native HTTP download engine.
/// Downloads a 5 MiB fixture from a local Range-capable server and verifies the
/// bytes arrive intact and that multi-connection segmentation is actually used.
/// No external tool (aria2c / ffmpeg / curl) is involved.

var failCount = 0

func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok {
        print("PASS  \(label)")
    } else {
        print("FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failCount += 1
    }
}

let expectedURL = URL(fileURLWithPath: "Tests/fixtures-http/big.bin")
guard let expectedBytes = try? Data(contentsOf: expectedURL) else {
    print("FAIL  cannot read local fixture Tests/fixtures-http/big.bin")
    exit(1)
}
let expectedSize = Int64(expectedBytes.count)
check(expectedSize > 1_000_000, "fixture is large enough to trigger segmentation",
      "size=\(expectedSize)")

// MARK: - hand-off fields: internal options never become headers, proxies parse

do {
    let sample = DownloadTask(
        source: URL(string: "https://example.com/a.bin")!,
        destination: URL(fileURLWithPath: "/tmp/siphon-wire.bin"),
        options: ["User-Agent": "UA", "PostData": "a=1", "PostContentType": "text/plain",
                  "Siphon.Proxy": "socks5://127.0.0.1:1080", "Siphon.Private": "1"])
    let wire = HTTPDownloadEngine.wireHeaders(sample.options)
    check(wire["User-Agent"] == "UA", "normal headers survive wireHeaders")
    check(wire["PostData"] == nil && wire["PostContentType"] == nil,
          "POST fields are not sent as headers")
    check(wire.keys.allSatisfy { !$0.lowercased().hasPrefix("siphon.") },
          "internal Siphon.* options are stripped")

    let socks = HTTPDownloadEngine.proxyOverride(for: sample, url: sample.source)
    check(socks?["SOCKSProxy"] as? String == "127.0.0.1", "socks proxy URL parsed",
          "\(String(describing: socks))")

    let fixed = DownloadTask(source: sample.source, destination: sample.destination,
                             options: ["Siphon.Proxy": "10.1.2.3:3128"])
    let http = HTTPDownloadEngine.proxyOverride(for: fixed, url: fixed.source)
    check(http?["HTTPProxy"] as? String == "10.1.2.3", "host:port proxy parsed")
    check(http?["HTTPSPort"] as? Int == 3128, "proxy port parsed")

    let direct = DownloadTask(source: sample.source, destination: sample.destination,
                              options: ["Siphon.Proxy": "direct"])
    let directDict = HTTPDownloadEngine.proxyOverride(for: direct, url: direct.source)
    check(directDict?.isEmpty == true, "explicit DIRECT yields an empty dictionary")

    let pac = DownloadTask(source: sample.source, destination: sample.destination,
                           options: ["Siphon.ProxyPac":
                                     "function FindProxyForURL(u,h){return 'PROXY 10.9.8.7:8080';}"])
    let pacDict = HTTPDownloadEngine.proxyOverride(for: pac, url: pac.source)
    check(pacDict?["HTTPProxy"] as? String == "10.9.8.7", "browser PAC script evaluated")
}

let engine = HTTPDownloadEngine()
let dest = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("siphon_native_http_\(UUID().uuidString).bin")
try? FileManager.default.removeItem(at: dest)

let source = URL(string: "http://127.0.0.1:18767/big.bin")!
let task = DownloadTask(source: source, destination: dest)

let sem = DispatchSemaphore(value: 0)
Task {
    do { try await engine.submit(task) }
    catch {
        check(false, "submit threw", "\(error)")
        sem.signal()
        return
    }
    for _ in 0..<400 {
        if engine.lastState == .completed || engine.lastState == .error { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    check(engine.lastState == .completed, "native engine reached completed state",
          "state=\(engine.lastState)")
    if engine.lastState == .completed {
        guard let got = try? Data(contentsOf: dest) else {
            check(false, "output file readable"); sem.signal(); return
        }
        check(got.count == expectedBytes.count,
              "downloaded size matches source", "got \(got.count), want \(expectedBytes.count)")
        check(got == expectedBytes, "downloaded bytes exactly match source")
        check(engine.lastSegmentCount >= 2, "used multi-connection segments",
              "count=\(engine.lastSegmentCount)")
    }
    sem.signal()
}
sem.wait()

// MARK: - form POST replay (a button that posts and answers with the file)

let postEngine = HTTPDownloadEngine()
let postDest = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("siphon_native_post_\(UUID().uuidString).bin")
try? FileManager.default.removeItem(at: postDest)
let postTask = DownloadTask(
    source: URL(string: "http://127.0.0.1:18767/form")!,
    destination: postDest,
    options: ["PostData": "field=value&second=1",
              "PostContentType": "application/x-www-form-urlencoded",
              "Siphon.ExpectedSize": "\(expectedSize)"])
let postSem = DispatchSemaphore(value: 0)
Task {
    do { try await postEngine.submit(postTask) }
    catch {
        check(false, "POST submit threw", "\(error)")
        postSem.signal()
        return
    }
    for _ in 0..<400 {
        if postEngine.lastState == .completed || postEngine.lastState == .error { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    check(postEngine.lastState == .completed, "POST form download completed",
          "state=\(postEngine.lastState)")
    if let got = try? Data(contentsOf: postDest) {
        check(got == expectedBytes, "POST response bytes exactly match the file",
              "got \(got.count), want \(expectedBytes.count)")
    } else {
        check(false, "POST output readable")
    }
    postSem.signal()
}
postSem.wait()

if failCount == 0 {
    print("ALL NATIVE-HTTP CHECKS PASSED")
} else {
    print("\(failCount) NATIVE-HTTP CHECK(S) FAILED")
    exit(1)
}
