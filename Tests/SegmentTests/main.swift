import Foundation

// End-to-end test of SegmentAssembler: 3 concurrent segments must be written
// in strict order. Requires the fixture server started by scripts/verify.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("siphon-segment-test.ts")
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
try assembler.start(taskID: UUID(), destination: out, requests: requests)

// Wait for the detached assembly task to finish.
for _ in 0..<80 {
    if let d = try? Data(contentsOf: out), d.count == 12 { break }
    Thread.sleep(forTimeInterval: 0.1)
}
let got = String(data: (try? Data(contentsOf: out)) ?? Data(), encoding: .utf8) ?? "<nil>"
check("ordered assembly under concurrency", got == "AAAABBBBCCCC", got)
try? FileManager.default.removeItem(at: out)

print(failures == 0 ? "SegmentTests: ALL PASS" : "SegmentTests: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
