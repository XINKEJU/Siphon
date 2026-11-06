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

if failCount == 0 {
    print("ALL NATIVE-HTTP CHECKS PASSED")
} else {
    print("\(failCount) NATIVE-HTTP CHECK(S) FAILED")
    exit(1)
}
