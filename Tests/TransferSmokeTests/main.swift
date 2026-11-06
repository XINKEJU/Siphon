import Foundation

// Transfer smoke tests for the engines not yet covered by the suite:
//   * LocalEngine  — file:// copy + data: URI decode
//   * CurlEngine   — system /usr/bin/curl subprocess transport (.curl fallback)
// Both must reach .completed with byte-exact output.

var failCount = 0

func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok {
        print("PASS  \(label)")
    } else {
        print("FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failCount += 1
    }
}

@MainActor
final class Collector: EngineDelegate {
    let taskID: UUID
    private(set) var state: DownloadState = .pending
    private(set) var lastError: String?

    init(taskID: UUID) {
        self.taskID = taskID
    }

    func engineDidUpdate(taskID: UUID, progress: DownloadProgress) {}

    func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) {
        guard taskID == self.taskID else { return }
        self.state = state
        lastError = error.map { "\($0)" }
    }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("siphon-smoke-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

/// Submit a task and poll for a terminal state. Polling (not a semaphore) is
/// essential: `EngineDelegate` callbacks hop to the MainActor, so blocking the
/// main thread would deadlock the very callbacks we are waiting for.
@MainActor
func runTask(engine: DownloadEngine, task: DownloadTask, timeout: Double = 20) async
    -> (state: DownloadState, error: String?) {
    let collector = Collector(taskID: task.id)
    engine.delegate = collector
    do { try await engine.submit(task) } catch {
        return (.error, "\(error)")
    }
    let polls = Int(timeout * 20)
    for _ in 0..<polls {
        switch collector.state {
        case .completed, .error, .paused:
            return (collector.state, collector.lastError)
        default: break
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return (collector.state, "timed out after \(timeout)s, last state \(collector.state)")
}

// MARK: - 1. LocalEngine: file:// copy

let sourceURL = URL(fileURLWithPath: "Tests/fixtures-http/big.bin")
guard let sourceBytes = try? Data(contentsOf: sourceURL) else {
    print("FAIL  cannot read fixture Tests/fixtures-http/big.bin")
    exit(1)
}

do {
    let local = LocalEngine()
    let dest = tmp.appendingPathComponent("filecopy.bin")
    let task = DownloadTask(
        source: URL(fileURLWithPath: sourceURL.path),
        destination: dest)
    let (state, err) = await runTask(engine: local, task: task)
    check(state == .completed, "LocalEngine file:// copy completed", err ?? "")
    let got = (try? Data(contentsOf: dest)) ?? Data()
    check(got == sourceBytes, "LocalEngine copy is byte-exact",
          "got \(got.count), want \(sourceBytes.count)")
}

// MARK: - 2. LocalEngine: data: URI

do {
    let payload = Data("hello siphon 数据 ✓".utf8)
    let local = LocalEngine()
    let dest = tmp.appendingPathComponent("decoded.txt")
    let task = DownloadTask(
        source: URL(string: DataURICodec.encode(payload, mimeType: "text/plain"))!,
        destination: dest)
    let (state, err) = await runTask(engine: local, task: task)
    check(state == .completed, "LocalEngine data: URI completed", err ?? "")
    let got = (try? Data(contentsOf: dest)) ?? Data()
    check(got == payload, "data: URI payload is byte-exact")
}

// MARK: - 3. CurlEngine: system curl subprocess transport

do {
    let curl = CurlEngine()
    let dest = tmp.appendingPathComponent("viacurl.bin")
    let task = DownloadTask(
        source: URL(string: "http://127.0.0.1:18773/big.bin")!,
        destination: dest,
        protoOverride: .curl)
    let (state, err) = await runTask(engine: curl, task: task)
    check(state == .completed, "CurlEngine .curl transport completed", err ?? "")
    let got = (try? Data(contentsOf: dest)) ?? Data()
    check(got == sourceBytes, "CurlEngine output is byte-exact",
          "got \(got.count), want \(sourceBytes.count)")
}

if failCount == 0 {
    print("ALL TRANSFER-SMOKE CHECKS PASSED")
} else {
    print("\(failCount) TRANSFER-SMOKE CHECK(S) FAILED")
    exit(1)
}
