import Foundation
import CryptoKit

/// Regression tests for the native HTTP engine's correctness features:
///   1. pause → sidecar → resume completes byte-exactly
///   2. ETag pinning: a changed remote file restarts cleanly (no corrupt mix)
///   3. server that ignores Range (200 full body) downgrades to one stream
///   4. checksum verification passes on match and hard-fails on mismatch
var failCount = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("PASS  \(label)") }
    else {
        print("FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failCount += 1
    }
}

final class StateBoxCore: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: DownloadState = .pending
    private var _error: Error?
    var state: DownloadState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }
    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return _error
    }
    func record(_ s: DownloadState, _ e: Error?) {
        lock.lock()
        _state = s
        _error = e
        lock.unlock()
    }
}

// Conforming to the @MainActor EngineDelegate protocol infers @MainActor on this
// class, so the mutable storage lives in a separate lock-protected core object.
final class StateBox: EngineDelegate {
    private let core: StateBoxCore
    private let taskID: UUID
    init(taskID: UUID) {
        self.taskID = taskID
        self.core = StateBoxCore()
    }
    nonisolated var state: DownloadState { core.state }
    nonisolated var error: Error? { core.error }
    nonisolated func engineDidUpdate(taskID: UUID, progress: DownloadProgress) {}
    nonisolated func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) {
        guard taskID == self.taskID else { return }
        core.record(state, error)
    }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("siphon-resume-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// Fixture: 300 KB deterministic bytes (enough to pause mid-flight at 100 KB/s).
let size = 300_000
var seed: UInt64 = 0x9E3779B97F4A7C15
var fixture = Data(); fixture.reserveCapacity(size)
for _ in 0..<size {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    fixture.append(UInt8(truncatingIfNeeded: seed >> 33))
}
try fixture.write(to: tmp.appendingPathComponent("fixture-source.bin"))
let fixtureSHA256 = SHA256.hash(data: fixture)
    .map { String(format: "%02x", $0) }.joined()
let fixtureSHA512 = SHA512.hash(data: fixture)
    .map { String(format: "%02x", $0) }.joined()

// MARK: test servers

func startServer(port: UInt16, honorRange: Bool, etag: String, sendLength: Bool = true) -> Process {
    let script = """
    import http.server, socketserver, os, re
    ROOT = '\(tmp.path)'
    class H(http.server.BaseHTTPRequestHandler):
        def do_HEAD(self):
            p = os.path.join(ROOT, self.path.lstrip('/'))
            self.send_response(200)
            self.send_header('Accept-Ranges', 'bytes' if \(honorRange ? "True" : "False") else 'none')
            if \(sendLength ? "True" : "False"):
                self.send_header('Content-Length', str(os.path.getsize(p)))
            self.send_header('ETag', '\(etag)')
            self.end_headers()
        def do_GET(self):
            p = os.path.join(ROOT, self.path.lstrip('/'))
            if not os.path.isfile(p):
                self.send_error(404); return
            size = os.path.getsize(p)
            rng = self.headers.get('Range')
            m = re.match(r'bytes=(\\d+)-(\\d*)', rng or '')
            if \(honorRange ? "True" : "False") and rng and m:
                start = int(m.group(1)); end = size - 1
                if m.group(2): end = min(int(m.group(2)), size - 1)
                with open(p, 'rb') as f:
                    f.seek(start); data = f.read(end - start + 1)
                self.send_response(206)
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('ETag', '\(etag)')
                self.end_headers(); self.wfile.write(data)
            else:
                with open(p, 'rb') as f: data = f.read()
                self.send_response(200)
                if \(sendLength ? "True" : "False"):
                    self.send_header('Content-Length', str(size))
                self.send_header('ETag', '\(etag)')
                self.end_headers(); self.wfile.write(data)
        def log_message(self, *a): pass
    socketserver.TCPServer.allow_reuse_address = True
    class T(socketserver.ThreadingMixIn, socketserver.TCPServer):
        daemon_threads = True
    with T(('127.0.0.1', \(port)), H) as s:
        s.serve_forever()
    """
    let py = tmp.appendingPathComponent("srv-\(port).py")
    try! script.write(to: py, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [py.path]
    try? p.run()
    // Wait until reachable.
    for _ in 0..<100 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(sock)
        if r == 0 { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return p
}

func killServer(_ p: Process) {
    p.terminate()
    p.waitUntilExit()
}

/// Polls for a terminal state. MUST await (not RunLoop.main.run): EngineDelegate
/// callbacks hop to the MainActor, and top-level main-actor code only services
/// them while suspended in an `await` — RunLoop.main.run does NOT pump them.
func waitState(_ box: StateBox, states: [DownloadState], timeout: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if states.contains(box.state) { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return states.contains(box.state)
}

// MARK: - 1. pause → sidecar → resume, byte-exact

do {
    let srv = startServer(port: 18781, honorRange: true, etag: "etag-v1")
    defer { killServer(srv) }
    let engine = HTTPDownloadEngine()
    let dest = tmp.appendingPathComponent("resume.bin")
    let task = DownloadTask(source: URL(string: "http://127.0.0.1:18781/fixture-source.bin")!,
                            destination: dest)
    let box = StateBox(taskID: task.id)
    engine.delegate = box
    try await engine.submit(task)

    // Throttle the shared bucket so the 300 KB download takes ~15 s, giving us a
    // real mid-flight pause point.
    await engine.setGlobalSpeedLimit(20_000) // 20 KB/s
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    await engine.pause(task.id)
    check(await waitState(box, states: [.paused], timeout: 5), "engine reached paused state",
          "state=\(box.state)")
    await engine.setGlobalSpeedLimit(nil)

    let sidecar = Sidecar.path(for: URL(fileURLWithPath: dest.path + ".part"))
    check(FileManager.default.fileExists(atPath: sidecar.path),
          "sidecar state file saved on pause")
    // The output file is pre-allocated to the full size, so progress is judged by
    // the sidecar's saved cursor, not the file size.
    let sc = Sidecar.load(for: URL(fileURLWithPath: dest.path + ".part"))
    let cursor = sc?.parts.map { $0[1] }.max() ?? 0
    check(cursor > 0 && cursor < Int64(size), "partial progress saved in sidecar",
          "cursor=\(cursor)")

    await engine.resume(task.id)
    check(await waitState(box, states: [.completed], timeout: 30), "resumed download completed",
          "state=\(box.state) err=\(String(describing: box.error))")
    let got = (try? Data(contentsOf: dest)) ?? Data()
    if got == fixture {
        check(true, "resumed file is byte-exact")
    } else {
        var diffAt = -1
        for i in 0..<min(got.count, fixture.count) where got[i] != fixture[i] {
            diffAt = i
            break
        }
        check(false, "resumed file is byte-exact",
              "count=\(got.count)/\(fixture.count) first-diff=\(diffAt) " +
              "got[0..7]=\(Array(got.prefix(8))) fixture[0..7]=\(Array(fixture.prefix(8))) " +
              "cursor=\(Sidecar.load(for: URL(fileURLWithPath: dest.path + ".part"))?.parts.first?.count ?? -1)")
    }
    check(!FileManager.default.fileExists(atPath: sidecar.path),
          "sidecar cleared after completion")
    // .part publish pattern: unfinished data lives at <dest>.part; on completion it
    // is atomically renamed to the final name.
    check(!FileManager.default.fileExists(atPath: dest.path + ".part"),
          "no .part residue after completion")
    check(FileManager.default.fileExists(atPath: dest.path),
          "final file published at destination")
}

// MARK: - 2. ETag pinning: changed remote restarts cleanly

do {
    let srv = startServer(port: 18782, honorRange: true, etag: "etag-old")
    defer { killServer(srv) }
    let engine = HTTPDownloadEngine()
    let dest = tmp.appendingPathComponent("pinning.bin")
    let task = DownloadTask(source: URL(string: "http://127.0.0.1:18782/fixture-source.bin")!,
                            destination: dest)
    let box = StateBox(taskID: task.id)
    engine.delegate = box
    try await engine.submit(task)
    await engine.setGlobalSpeedLimit(20_000)
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    await engine.pause(task.id)
    _ = await waitState(box, states: [.paused], timeout: 5)
    await engine.setGlobalSpeedLimit(nil)

    // Simulate the remote file changing between pause and resume.
    let sidecarPath = Sidecar.path(for: URL(fileURLWithPath: dest.path + ".part")).path
    check(FileManager.default.fileExists(atPath: sidecarPath), "sidecar exists before tamper")
    if let data = try? Data(contentsOf: URL(fileURLWithPath: sidecarPath)) {
        let s = String(data: data, encoding: .utf8) ?? ""
        try s.replacingOccurrences(of: "etag-old", with: "etag-new")
            .data(using: .utf8)?.write(to: URL(fileURLWithPath: sidecarPath))
    }

    await engine.resume(task.id)
    check(await waitState(box, states: [.completed], timeout: 30),
          "download completed after remote changed",
          "state=\(box.state) err=\(String(describing: box.error))")
    let got = (try? Data(contentsOf: dest)) ?? Data()
    check(got == fixture, "restarted download is still byte-exact (no corrupt mix)")
}

// MARK: - 3. server ignores Range → single-stream downgrade

do {
    let srv = startServer(port: 18783, honorRange: false, etag: "etag-norange")
    defer { killServer(srv) }
    let engine = HTTPDownloadEngine()
    let dest = tmp.appendingPathComponent("norange.bin")
    let task = DownloadTask(source: URL(string: "http://127.0.0.1:18783/fixture-source.bin")!,
                            destination: dest)
    let box = StateBox(taskID: task.id)
    engine.delegate = box
    try await engine.submit(task)
    check(await waitState(box, states: [.completed], timeout: 30),
          "non-range server download completed", "state=\(box.state)")
    let got = (try? Data(contentsOf: dest)) ?? Data()
    check(got == fixture, "non-range bytes exact")
    check(engine.lastSegmentCount <= 1, "stayed single-connection on non-range server",
          "peak=\(engine.lastSegmentCount)")
}

// MARK: - 4a. checksum match completes

do {
    let srv = startServer(port: 18784, honorRange: true, etag: "etag-ck")
    defer { killServer(srv) }
    let engine = HTTPDownloadEngine()
    let dest = tmp.appendingPathComponent("ck-ok.bin")
    let task = DownloadTask(source: URL(string: "http://127.0.0.1:18784/fixture-source.bin")!,
                            destination: dest, checksum: "sha256:\(fixtureSHA256)")
    let box = StateBox(taskID: task.id)
    engine.delegate = box
    try await engine.submit(task)
    check(await waitState(box, states: [.completed], timeout: 30),
          "correct checksum accepted", "state=\(box.state)")
}

// MARK: - 4b. checksum mismatch → one clean retry → explicit error

do {
    let srv = startServer(port: 18785, honorRange: true, etag: "etag-ck2")
    defer { killServer(srv) }
    let engine = HTTPDownloadEngine()
    let dest = tmp.appendingPathComponent("ck-bad.bin")
    let bogus = String(repeating: "0", count: 64)
    let task = DownloadTask(source: URL(string: "http://127.0.0.1:18785/fixture-source.bin")!,
                            destination: dest, checksum: "sha256:\(bogus)")
    let box = StateBox(taskID: task.id)
    engine.delegate = box
    try await engine.submit(task)
    check(await waitState(box, states: [.error], timeout: 30),
          "wrong checksum surfaced as error", "state=\(box.state)")
    if let e = box.error as? NetFailure, case .checksumMismatch = e {
        check(true, "error is the explicit checksumMismatch")
    } else {
        check(false, "error is the explicit checksumMismatch", "\(String(describing: box.error))")
    }
}

// MARK: - 4c. SHA-512 checksum accepted (extended algorithm set)

do {
    let srv = startServer(port: 18788, honorRange: true, etag: "etag-ck3")
    defer { killServer(srv) }
    let engine = HTTPDownloadEngine()
    let dest = tmp.appendingPathComponent("ck-sha512.bin")
    let task = DownloadTask(source: URL(string: "http://127.0.0.1:18788/fixture-source.bin")!,
                            destination: dest, checksum: "sha512:\(fixtureSHA512)")
    let box = StateBox(taskID: task.id)
    engine.delegate = box
    try await engine.submit(task)
    check(await waitState(box, states: [.completed], timeout: 30),
          "sha-512 checksum accepted", "state=\(box.state) err=\(String(describing: box.error))")
}

// MARK: - 5. unknown size (no Content-Length) → single sentinel stream, no split
// Regression: the 2026-11-07 crash — the size-unknown sentinel part [0, 2^62]
// was work-stolen into 8 parts with astronomical offsets; the first flush then
// seeked to ~2^61 and the write raised an uncatchable EFBIG NSException (abort).

do {
    let srv = startServer(port: 18786, honorRange: false, etag: "etag-unknown", sendLength: false)
    defer { killServer(srv) }
    let engine = HTTPDownloadEngine()
    let dest = tmp.appendingPathComponent("unknown-size.bin")
    let task = DownloadTask(source: URL(string: "http://127.0.0.1:18786/fixture-source.bin")!,
                            destination: dest)
    let box = StateBox(taskID: task.id)
    engine.delegate = box
    try await engine.submit(task)
    check(await waitState(box, states: [.completed], timeout: 30),
          "unknown-size download completed", "state=\(box.state) err=\(String(describing: box.error))")
    let got = (try? Data(contentsOf: dest)) ?? Data()
    check(got == fixture, "unknown-size bytes exact")
    check(engine.lastSegmentCount <= 1, "sentinel part never split (single connection)",
          "peak=\(engine.lastSegmentCount)")
}

// MARK: - 6. poisoned sidecar (cursor beyond bytes on disk) is discarded

do {
    let srv = startServer(port: 18787, honorRange: true, etag: "etag-poison")
    defer { killServer(srv) }
    let engine = HTTPDownloadEngine()
    let dest = tmp.appendingPathComponent("poison.bin")
    let task = DownloadTask(source: URL(string: "http://127.0.0.1:18787/fixture-source.bin")!,
                            destination: dest)
    let box = StateBox(taskID: task.id)
    engine.delegate = box
    try await engine.submit(task)
    await engine.setGlobalSpeedLimit(20_000)
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    await engine.pause(task.id)
    _ = await waitState(box, states: [.paused], timeout: 5)
    await engine.setGlobalSpeedLimit(nil)

    // Tamper: bump the first part's cursor far beyond the file's real size —
    // what the buggy build persisted when it split the sentinel part.
    let scURL = Sidecar.path(for: URL(fileURLWithPath: dest.path + ".part"))
    var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: scURL)) as! [String: Any]
    let parts = obj["parts"] as! [[Any]]
    var first = parts[0]
    first[1] = Int64(1) << 61
    obj["parts"] = [first] + Array(parts.dropFirst())
    try JSONSerialization.data(withJSONObject: obj).write(to: scURL)

    await engine.resume(task.id)
    check(await waitState(box, states: [.completed], timeout: 30),
          "download completed after poisoned sidecar discarded",
          "state=\(box.state) err=\(String(describing: box.error))")
    let got = (try? Data(contentsOf: dest)) ?? Data()
    check(got == fixture, "restarted download is byte-exact (poison ignored)")
}

if failCount == 0 {
    print("ALL NATIVE-HTTP-RESUME CHECKS PASSED")
} else {
    print("\(failCount) NATIVE-HTTP-RESUME CHECK(S) FAILED")
    exit(1)
}
