import Foundation

// Regression / end-to-end test for the native eD2K transport.
// Talks to Tests/fixtures-ed2k/ed2k_peer.py, an INDEPENDENT implementation of
// the eDonkey TCP framing, so a bug shared between client and mock cannot pass.

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

// MARK: - 1. Wire codec unit tests

do {
    let f = ED2KFrame(opcode: 0x46, payload: Data([0xAA, 0xBB]))
    let bytes = f.encoded()
    check(bytes.count == 8, "frame length = 5 header + 1 opcode + 2 payload", "\(bytes.count)")
    check(bytes[0] == ED2KProto.edonkey, "frame marker 0xE3")
    let size = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8)
        | (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 24)
    check(size == 3, "size field counts opcode byte", "size=\(size)")
    check(bytes[5] == 0x46, "opcode at byte 5")

    var w = ED2KWriter()
    w.u16(0x1234); w.u32(0xDEADBEEF)
    var r = ED2KReader(w.data)
    check((try? r.u16()) == 0x1234, "u16 little-endian round-trip")
    check((try? r.u32()) == 0xDEADBEEF, "u32 little-endian round-trip")
    check(r.remaining == 0, "reader consumed every byte")
}

do {
    // The critical layout: three STARTS then three ENDS, never interleaved.
    let hash = Data(repeating: 0x7F, count: 16)
    let f = ED2KMessages.requestParts(fileHash: hash,
        ranges: [(start: 0, end: 10), (start: 20, end: 30)])
    var r = ED2KReader(f.payload)
    let gotHash = try r.bytes(16)
    var vals: [UInt32] = []
    for _ in 0..<6 { vals.append(try r.u32()) }
    check(gotHash == hash, "REQUESTPARTS carries file hash")
    check(vals == [0, 20, 0, 10, 30, 0],
          "REQUESTPARTS = 3 starts then 3 ends, unused slots zero", "\(vals)")
    check(f.payload.count == 16 + 24, "REQUESTPARTS payload is 40 bytes",
          "\(f.payload.count)")
}

do {
    let hash = Data(repeating: 0x11, count: 16)
    let f = ED2KMessages.requestParts64(fileHash: hash,
        ranges: [(start: 5_000_000_000, end: 5_000_100_000)])
    check(f.marker == ED2KProto.emuleExt, "64-bit request uses 0xC5 marker")
    check(f.opcode == ED2KOpcode.requestParts64, "64-bit request opcode 0xA3")
    var r = ED2KReader(f.payload)
    _ = try r.bytes(16)
    var a: UInt64 = 0
    for i in 0..<8 { a |= UInt64(try r.u8()) << UInt64(i * 8) }
    check(a == 5_000_000_000, "64-bit start offset beyond 4 GiB", "\(a)")
}

do {
    var payload = Data(repeating: 0x22, count: 16)
    payload.append(2)
    payload.append(contentsOf: [127, 0, 0, 1])
    payload.append(contentsOf: [0x12, 0x48])   // 18450 = 0x4812
    let sources = ED2KMessages.parseSources(payload)
    check(sources.count == 1 && sources[0].host == "127.0.0.1" && sources[0].port == 18450,
          "FOUND_SOURCES parses network-order IP + LE port", "\(sources)")
}

do {
    let hash = Data(repeating: 0x33, count: 16)
    var p = hash
    p.append(contentsOf: [0x10, 0x00, 0x00, 0x00])
    p.append(contentsOf: [0x18, 0x00, 0x00, 0x00])
    p.append(contentsOf: [UInt8](repeating: 0x5A, count: 8))
    let part = try ED2KMessages.parsePart(p)
    check(part.start == 16 && part.end == 24 && part.data.count == 8,
          "SENDINGPART parses hash/start/end/data")
}

// MARK: - 2. Real TCP transfer against an independent peer

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var last = DownloadProgress()
    private(set) var count = 0
    func record(_ p: DownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        last = p; count += 1
    }
    func snapshot() -> (DownloadProgress, Int) {
        lock.lock(); defer { lock.unlock() }
        return (last, count)
    }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("siphon-ed2k-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// Both sides read the SAME on-disk fixture, so byte equality is meaningful:
// the peer cannot accidentally "agree" with a client-generated buffer.
let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/fixtures-ed2k/fixture.bin")
let fixture: Data
do {
    fixture = try Data(contentsOf: fixtureURL)
} catch {
    check(false, "shared fixture file exists", "\(error)")
    print("1 ED2K-NATIVE CHECK(S) FAILED")
    exit(1)
}
let fixtureSize = fixture.count
let hashHex = ED2KHash.hex(ED2KHash.hash(fixture))

let linkRaw = "ed2k://|file|source.bin|\(fixtureSize)|\(hashHex)|/|sources,127.0.0.1:18770|/"
let link: ED2KLink
do {
    link = try ED2KURI.parse(linkRaw)
    check(link.sources.count == 1 && link.sources[0].port == 18770,
          "link parses embedded source", "\(link.sources)")
    check(link.fileSize == fixtureSize, "link parses file size", "\(link.fileSize)")
    check(link.hashHex == hashHex.uppercased(), "link parses 16-byte hash")
} catch {
    check(false, "link parses", "\(error)")
    print("1 ED2K-NATIVE CHECK(S) FAILED")
    exit(1)
}

let dest = tmp.appendingPathComponent("downloaded.bin")
let box = ProgressBox()
let sem = DispatchSemaphore(value: 0)
var transferError: Error?
Task {
    do {
        let backend = NativeED2KBackend()
        try await backend.connect()
        try await backend.download(link, destination: dest) { p in box.record(p) }
    } catch {
        transferError = error
    }
    sem.signal()
}
if sem.wait(timeout: .now() + 30) != .success {
    check(false, "native eD2K transfer completed within 30s", "timed out")
} else {
    check(transferError == nil, "native eD2K transfer succeeded",
          transferError.map { "\($0)" } ?? "")
    if let data = try? Data(contentsOf: dest) {
        check(data.count == fixtureSize, "downloaded size matches source",
              "\(data.count) vs \(fixtureSize)")
        check(data == fixture, "downloaded bytes exactly match source")
        let verified = (try? ED2KHash.verify(fileAt: dest, matchesHex: hashHex)) ?? false
        check(verified, "final file verifies against the link's eD2K hash")
    } else {
        check(false, "downloaded file exists")
    }
    let (last, count) = box.snapshot()
    check(count > 0, "progress callback fired", "count=\(count)")
    check(last.downloadedBytes == fixtureSize && last.totalBytes == fixtureSize,
          "progress reaches 100%", "\(last.downloadedBytes)/\(last.totalBytes)")
    check(last.connectedPeers >= 1, "progress reports a connected peer",
          "\(last.connectedPeers)")
}

// MARK: - 3. Honest failure: a link with no sources must not fake success

do {
    let noSource = try ED2KURI.parse(
        "ed2k://|file|none.bin|\(fixtureSize)|\(hashHex)|/")
    let sem2 = DispatchSemaphore(value: 0)
    var thrown: Error?
    Task {
        do {
            try await NativeED2KBackend().download(noSource,
                destination: tmp.appendingPathComponent("nope.bin")) { _ in }
        } catch { thrown = error }
        sem2.signal()
    }
    _ = sem2.wait(timeout: .now() + 10)
    check(thrown != nil, "source-less link fails explicitly (no fabricated bytes)")
    if let e = thrown as? ED2KTransportError {
        if case .noSources = e { check(true, "failure is the explicit noSources error") }
        else { check(false, "failure is the explicit noSources error", "\(e)") }
    } else {
        check(false, "failure is ED2KTransportError", "\(String(describing: thrown))")
    }
    check(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("nope.bin").path),
          "failed transfer created no output file")
}

print(failures == 0
      ? "ED2KNativeTests: ALL PASS"
      : "\(failures) ED2K-NATIVE CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
