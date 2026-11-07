import Foundation
import CryptoKit

// Segment-level resume suite for SegmentAssembler's `.siphon-resume.json`
// sidecar (v1). Requires the fixture server started by scripts/verify.sh
// (media.m3u8 → seg0.ts "AAAA", seg1.ts "BBBB", seg2.ts "CCCC").

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

@MainActor
final class StateSpy: EngineDelegate {
    var state: DownloadState?
    func engineDidUpdate(taskID: UUID, progress: DownloadProgress) {}
    func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) {
        self.state = state
    }
}

@main
struct ResumeTests {
    /// Mirrors SegmentAssembler's v1 fingerprint: SHA-256 over the ordered
    /// segment URLs (with ranges), one per line.
    static func fingerprint(_ requests: [SegmentRequest]) -> String {
        var material = ""
        for r in requests {
            material += r.url.absoluteString
            if let (len, off) = r.byteRange { material += "#\(off)+\(len)" }
            material += "\n"
        }
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func runAssembler(_ assembler: SegmentAssembler, spy: StateSpy,
                             out: URL, requests: [SegmentRequest],
                             context: SegmentResumeContext) async {
        do {
            try assembler.start(taskID: UUID(), destination: out, requests: requests,
                                resumeContext: context)
        } catch {
            check("assembler started", false, error.localizedDescription)
            return
        }
        for _ in 0..<80 {
            if spy.state == .completed { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    static func main() async {
        let base = URL(string: "http://127.0.0.1:18765/media.m3u8")!
        guard let text = try? String(contentsOf: base, encoding: .utf8) else {
            print("FAIL  fixture server not reachable at \(base)")
            exit(1)
        }
        let pl = HLSParser.parse(text, baseURL: base)
        let requests = pl.segments.map { SegmentRequest(url: $0.url, byteRange: $0.byteRange) }
        check("fixture segments parsed", requests.count == 3)

        let context = SegmentResumeContext(kind: "hls", source: base.absoluteString)
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("siphon-resume-test.ts")
        let sidecar = URL(fileURLWithPath: out.path + ".siphon-resume.json")
        func cleanup() {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: sidecar)
        }
        cleanup()

        // Simulate an interrupted run: the first two segments are already on
        // disk, and a sidecar records that exact boundary.
        let firstTwo = Data("AAAABBBB".utf8)
        func writePartialState(fingerprint: String) {
            try? firstTwo.write(to: out)
            let record: [String: Any] = [
                "kind": context.kind,
                "source": context.source,
                "totalSegments": requests.count,
                "writtenCount": 2,
                "writtenBytes": firstTwo.count,
                "fingerprint": fingerprint,
                "updatedAt": Date().timeIntervalSince1970
            ]
            guard let d = try? JSONSerialization.data(withJSONObject: record) else { return }
            try? d.write(to: sidecar)
        }
        func fileBytes() -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size]
                as? NSNumber)?.intValue ?? -1
        }

        // 1) Matching sidecar → the completed segments are kept and only seg2 is
        //    fetched. Re-downloading everything would append a second copy.
        writePartialState(fingerprint: fingerprint(requests))
        let spy1 = StateSpy()
        let a1 = SegmentAssembler(concurrency: 3)
        a1.delegate = spy1
        await runAssembler(a1, spy: spy1, out: out, requests: requests, context: context)
        let got1 = String(data: (try? Data(contentsOf: out)) ?? Data(), encoding: .utf8) ?? "<nil>"
        check("resume appends only the missing segment", got1 == "AAAABBBBCCCC", got1)
        check("resume keeps 12 bytes (no duplicated prefix)", fileBytes() == 12, "\(fileBytes())")
        check("sidecar removed after completion",
              !FileManager.default.fileExists(atPath: sidecar.path))

        // 2) Changed playlist (different fingerprint) → the stale sidecar must be
        //    rejected: truncate and download all three segments again.
        writePartialState(fingerprint: fingerprint(Array(requests.reversed())))
        let spy2 = StateSpy()
        let a2 = SegmentAssembler(concurrency: 3)
        a2.delegate = spy2
        await runAssembler(a2, spy: spy2, out: out, requests: requests, context: context)
        let got2 = String(data: (try? Data(contentsOf: out)) ?? Data(), encoding: .utf8) ?? "<nil>"
        check("fingerprint change restarts from zero", got2 == "AAAABBBBCCCC", got2)
        check("restart output is not spliced", fileBytes() == 12, "\(fileBytes())")

        cleanup()
        print(failures == 0 ? "ResumeTests: ALL PASS" : "ResumeTests: \(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
