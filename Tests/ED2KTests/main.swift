import Foundation

// Regression test for ED2KEngine.resume(): it used to download into
// NSTemporaryDirectory() instead of the task's real destination. A mock backend
// captures the destination actually handed to `download`.

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

final class CaptureBackend: ED2KBackend {
    var lastDestination: URL?
    var connectCalled = false
    func connect() async throws { connectCalled = true }
    func download(_ link: ED2KLink, destination: URL,
                  onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        lastDestination = destination
    }
    func cancel(fileHashHex: String) async {}
}

let link = "ed2k://|file|movie.avi|123456789|ABCDEF0123456789ABCDEF0123456789|/"
// ed2k links are not RFC-valid URLs (they contain '|'), so percent-encode the
// illegal characters before building the URL; ED2KURI.parse decodes them back.
var allowed = CharacterSet.alphanumerics
allowed.insert(charactersIn: ":/.-_~")
let encoded = link.addingPercentEncoding(withAllowedCharacters: allowed)!

let backend = CaptureBackend()
let engine = ED2KEngine(backend: backend)
let dest = URL(fileURLWithPath: NSTemporaryDirectory() + "ed2k-dest.bin")
let task = DownloadTask(source: URL(string: encoded)!, destination: dest, protoOverride: .ed2k)

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        try await engine.submit(task)
        // resume must reuse the original destination, not NSTemporaryDirectory().
        await engine.resume(task.id)
        check(backend.lastDestination?.path == dest.path,
              "resume uses original task.destination (regression: was NSTemporaryDirectory)")
        check(backend.connectCalled, "backend.connect invoked")
    } catch {
        check(false, "ed2k submit/resume threw: \(error)")
    }
    sem.signal()
}
sem.wait()

if failures == 0 { print("ED2K ENGINE TESTS PASSED") }
else { print("ED2K ENGINE TESTS FAILED: \(failures)"); exit(1) }
