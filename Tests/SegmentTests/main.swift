import Foundation

// End-to-end test of SegmentAssembler: 3 concurrent segments must be written
// in strict order, and progress must be reported in BYTES (not segment count).
// Requires the fixture server started by scripts/verify.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

@MainActor
final class ProgressSpy: EngineDelegate {
    var last: DownloadProgress?
    var state: DownloadState?
    func engineDidUpdate(taskID: UUID, progress: DownloadProgress) { last = progress }
    func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) {
        self.state = state
    }
}

@main
struct SegmentTests {
    @MainActor
    static func main() async {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("siphon-segment-test.ts")
        try? FileManager.default.removeItem(at: out)
        let base = URL(string: "http://127.0.0.1:18765/media.m3u8")!

        guard let text = try? String(contentsOf: base, encoding: .utf8) else {
            print("FAIL  fixture server not reachable at \(base)")
            exit(1)
        }
        let pl = HLSParser.parse(text, baseURL: base)
        check("fixture segments parsed", pl.segments.count == 3)

        let requests = pl.segments.map { SegmentRequest(url: $0.url, byteRange: $0.byteRange) }
        let assembler = SegmentAssembler(concurrency: 3)
        let spy = ProgressSpy()
        assembler.delegate = spy
        do {
            try assembler.start(taskID: UUID(), destination: out, requests: requests)
        } catch {
            check("assembler started", false, error.localizedDescription)
        }

        // Wait for the detached assembly task to finish and its MainActor
        // delegate callbacks to be delivered.
        for _ in 0..<80 {
            if spy.state == .completed { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let got = String(data: (try? Data(contentsOf: out)) ?? Data(), encoding: .utf8) ?? "<nil>"
        check("ordered assembly under concurrency", got == "AAAABBBBCCCC", got)
        check("completion delivered", spy.state == .completed, "\(String(describing: spy.state))")
        // Regression: progress used to be measured in segments (3/3), which
        // made the UI report "180 / 180" for a 1.4 MB public HLS stream.
        check("progress counts bytes, not segments",
              spy.last?.downloadedBytes == 12, "\(spy.last?.downloadedBytes ?? -1)")
        check("total matches byte count",
              spy.last?.totalBytes == 12, "\(spy.last?.totalBytes ?? -1)")

        try? FileManager.default.removeItem(at: out)
        print(failures == 0 ? "SegmentTests: ALL PASS" : "SegmentTests: \(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
