import Foundation

// Protocol-layer verification: vendor links, playlists, SigV4, normalization,
// HLS fMP4, aria2 option mapping, and real end-to-end transfers through the
// local/libcurl/native engines. Run by scripts/verify.sh.

var passed = 0
var failures = 0

func check(_ ok: Bool, _ label: String) {
    if ok { passed += 1; print("  ok   \(label)") }
    else { failures += 1; print("  FAIL \(label)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    check(a == b, "\(label) (got \(a), expected \(b))")
}
func url(_ s: String) -> URL { URL(string: s)! }

// MARK: - 1. protocol detection
print("[1] protocol detection")
let detection: [(String, DownloadProtocol)] = [
    ("https://example.com/a.zip", .https),
    ("http://example.com/a.zip", .http),
    ("ftp://example.com/a.zip", .ftp),
    ("ftps://example.com/a.zip", .ftps),
    ("sftp://user@host/a.zip", .sftp),
    ("scp://user@host/a.zip", .scp),
    ("rsync://host/mod/a.zip", .rsync),
    ("magnet:?xt=urn:btih:ABCD", .magnet),
    ("ed2k://%7Cfile%7Ca.zip%7C1%7CABC%7C/", .ed2k),
    ("thunder://QUFodHRwOi8vZXhhbXBsZS5jb20vYS56aXBaWg==", .thunder),
    ("flashget://W0ZMQVNIR0VUXWh0dHA6Ly9leGFtcGxlLmNvbS9hLnppcFtGTEFTSEdFVF0=", .flashget),
    ("qqdl://aHR0cDovL2V4YW1wbGUuY29tL2Euemlw", .qqdl),
    ("webdav://host/dav/a.zip", .webdav),
    ("webdavs://host/dav/a.zip", .webdavs),
    ("smb://host/share/a.zip", .smb),
    ("smbs://host/share/a.zip", .smbs),
    ("nfs://host/export/a.zip", .nfs),
    ("afp://host/share/a.zip", .afp),
    ("ipfs://bafybeigdyrztabc/a.bin", .ipfs),
    ("ipns://example.eth/a.bin", .ipns),
    ("s3://bucket/a.bin", .s3),
    ("tftp://host/a.bin", .curl),
    ("gopher://host/1/a", .curl),
    ("rtsp://host/stream", .curl),
    ("https://host/master.m3u8", .hls),
    ("https://host/manifest.mpd", .dash),
    ("https://host/a.torrent", .bittorrent),
    ("https://host/a.meta4", .metalink),
    ("https://host/list.m3u", .playlist),
    ("file:///tmp/a.zip", .file),
    ("data:text/plain;base64,SGlwaG9u", .data)
]
for (raw, expected) in detection {
    eq(DownloadProtocol.detect(from: url(raw)), expected, "detect \(raw)")
}
eq(DownloadProtocol.thunder.displayName, "迅雷", "vendor display name")
eq(DownloadProtocol.smb.transport, .curl, "smb -> libcurl transport")
eq(DownloadProtocol.thunder.requiresAria2, true, "vendor link -> aria2")
eq(DownloadProtocol.nfs.transport, .mount, "nfs -> mount transport")
eq(URISchemes.registered.count, 18, "registered URL schemes")

// MARK: - 2. vendor link codec
print("[2] vendor link decoding")
let plain = "https://example.com/%E6%96%87%E4%BB%B6.zip"
for scheme in ["thunder", "flashget", "qqdl"] {
    let link = SpecialLinks.encode(plain, as: scheme)
    let decoded = try! SpecialLinks.decode(link)
    eq(decoded.absoluteString, plain, "\(scheme) round-trip")
}
// real-world variants: missing padding and flashget port trailer
let noPad = "thunder://" + Data("AAhttps://example.com/a.binZZ".utf8)
    .base64EncodedString().replacingOccurrences(of: "=", with: "")
eq(try! SpecialLinks.decode(noPad).absoluteString, "https://example.com/a.bin",
   "thunder without base64 padding")
let fgPort = SpecialLinks.encode("http://example.com/a.bin", as: "flashget") + "&1926"
eq(try! SpecialLinks.decode(fgPort).absoluteString, "http://example.com/a.bin",
   "flashget with port trailer")
do {
    _ = try SpecialLinks.decode("thunder://!!!!")
    check(false, "malformed link must throw")
} catch { check(true, "malformed link throws") }

// MARK: - 3. playlist / batch import
print("[3] playlist import")
let m3u = """
#EXTM3U
#EXTINF:120,First Track
https://a.example/1.mp3
#EXTINF:90,Second Track
https://a.example/2.mp3
"""
let m3uEntries = PlaylistImporter.parse(m3u)
eq(m3uEntries.count, 2, "M3U entry count")
eq(m3uEntries[0].name, "First Track", "M3U EXTINF name")
eq(m3uEntries[1].url.absoluteString, "https://a.example/2.mp3", "M3U second URL")

let pls = """
[playlist]
NumberOfEntries=2
File1=http://a.example/one.bin
Title1=One
File2=ftp://a.example/two.bin
Title2=Two
"""
let plsEntries = PlaylistImporter.parse(pls)
eq(plsEntries.count, 2, "PLS entry count")
eq(plsEntries[0].name, "One", "PLS title")
eq(plsEntries[1].url.absoluteString, "ftp://a.example/two.bin", "PLS second URL")

let asx = """
<ASX version="3.0"><entry><ref href="https://a.example/x.mp4"/></entry>
<entry><ref href="https://a.example/y.mp4"/></entry></ASX>
"""
eq(PlaylistImporter.parse(asx).count, 2, "ASX refs")
let wpl = """
<?xml version="1.0"?><smil><body><seq>
<media src="https://a.example/a.bin"/><media src="https://a.example/b.bin"/>
</seq></body></smil>
"""
eq(PlaylistImporter.parse(wpl).count, 2, "WPL media")
eq(PlaylistImporter.parse("[\"https://a.example/1\", \"https://a.example/2\"]").count, 2,
   "JSON URL array")
eq(PlaylistImporter.parse("https://a.example/1\n# comment\nhttps://a.example/2\n").count, 2,
   "plain URL list")
let relative = PlaylistImporter.parse("a.bin\nb.bin", baseURL: url("https://a.example/dir/list.m3u"))
eq(relative.count, 2, "relative entries")
eq(relative[0].url.absoluteString, "https://a.example/dir/a.bin", "relative URL resolution")

// MARK: - 4. AWS SigV4 (independent Python reference implementation)
print("[4] S3 SigV4 pre-signing")
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(secondsFromGMT: 0)!
let fixed = utc.date(from: DateComponents(year: 2013, month: 5, day: 24,
                                          hour: 0, minute: 0, second: 0))!
var cfg = S3Signer.Config()
cfg.accessKey = "AKIAIOSFODNN7EXAMPLE"
cfg.secretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
cfg.region = "us-east-1"
cfg.endpoint = "s3.amazonaws.com"
let signed = try! S3Signer.presignedGET(s3URI: url("s3://examplebucket/test.txt"),
                                        config: cfg, expires: 86400, date: fixed)
let expected = "https://s3.amazonaws.com/examplebucket/test.txt" +
    "?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
    "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" +
    "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host" +
    "&X-Amz-Signature=733255ef022bec3f2a8701cd61d4b371f3f28c9f193a1f02279211d48d5193d7"
eq(signed.absoluteString, expected, "SigV4 canonical vector")
eq(S3Signer.timestamps(fixed).amzDate, "20130524T000000Z", "AMZ date")
eq(S3Signer.sha256Hex(Data("abc".utf8)),
   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 vector")
do {
    let bad = S3Signer.Config()
    _ = try S3Signer.presignedGET(s3URI: url("s3://b/k"), config: bad)
    check(false, "missing credentials must throw")
} catch { check(true, "missing credentials throws") }

// MARK: - 5. data: URI
print("[5] data URI")
let payload = Data("Siphon-protocol-OK".utf8)
eq(String(data: try! DataURICodec.decode(DataURICodec.encode(payload)), encoding: .utf8),
   "Siphon-protocol-OK", "base64 data URI round-trip")
eq(String(data: try! DataURICodec.decode("data:text/plain,Hello%20World"), encoding: .utf8),
   "Hello World", "percent-encoded data URI")
do {
    _ = try DataURICodec.decode("https://example.com")
    check(false, "non-data URI must throw")
} catch { check(true, "non-data URI throws") }

// MARK: - 6. HLS EXT-X-MAP / fMP4
print("[6] HLS fMP4 init segment")
let fmp4 = """
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.0,
seg1.m4s
#EXTINF:4.0,
seg2.m4s
"""
let pl = HLSParser.parse(fmp4, baseURL: url("https://a.example/hls/stream.m3u8"))
check(pl.isFMP4, "playlist recognised as fMP4")
eq(pl.mapURL?.lastPathComponent, "init.mp4", "EXT-X-MAP URI")
eq(pl.mapByteRange?.length, 720, "EXT-X-MAP byterange length")
eq(pl.mapByteRange?.offset, 0, "EXT-X-MAP byterange offset")
eq(pl.segments.count, 2, "fMP4 fragment count")
eq(pl.segments[0].url.lastPathComponent, "seg1.m4s", "first fragment")
let tsPlaylist = HLSParser.parse("#EXTM3U\n#EXTINF:4.0,\na.ts\n",
                                 baseURL: url("https://a.example/x.m3u8"))
check(!tsPlaylist.isFMP4, "TS playlist is not fMP4")

// MARK: - 7. aria2 option mapping
print("[7] aria2 options")
let optTask = DownloadTask(source: url("https://example.com/a.bin"),
                           destination: url("/tmp/Siphon/a.bin"),
                           options: ["User-Agent": "Siphon/1.0", "Referer": "https://ref.example"])
let opts = Aria2Engine.makeOptions(optTask)
eq(opts["user-agent"], "Siphon/1.0", "User-Agent mapped to aria2 option")
eq(opts["referer"], "https://ref.example", "Referer mapped to aria2 option")
eq(opts["out"], "a.bin", "output filename")
eq(opts["dir"], "/tmp/Siphon", "output directory")
check(opts["User-Agent"] == nil, "raw header key removed")

// MARK: - 8. async: normalization + real engine transfers
@MainActor
final class MockDelegate: EngineDelegate {
    var states: [UUID: DownloadState] = [:]
    var progress: [UUID: DownloadProgress] = [:]
    var errors: [UUID: String] = [:]
    func engineDidUpdate(taskID: UUID, progress: DownloadProgress) {
        self.progress[taskID] = progress
    }
    func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) {
        states[taskID] = state
        if let error { errors[taskID] = error.localizedDescription }
    }
}

@MainActor
func waitState(_ delegate: MockDelegate, _ id: UUID, timeout: TimeInterval = 12) async -> DownloadState? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let s = delegate.states[id] { return s }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
}

@MainActor
func asyncTests() async {
    print("[8] URI normalization (async)")
    let settings = ProtocolSettings(ipfsGateway: "https://gw.example", s3: cfg,
                                    curlPath: "/usr/bin/curl")
    let thunder = SpecialLinks.encode("https://example.com/movie.mp4", as: "thunder")
    let r1 = try! await URINormalizer.normalize(thunder, settings: settings)
    eq(r1.count, 1, "thunder resolves to one request")
    eq(r1[0].url.absoluteString, "https://example.com/movie.mp4", "thunder target URL")
    eq(r1[0].proto, .thunder, "thunder badge preserved")
    eq(r1[0].origin, thunder, "original link preserved")

    let r2 = try! await URINormalizer.normalize("ipfs://bafyCID123/path/a.bin", settings: settings)
    eq(r2[0].url.absoluteString, "https://gw.example/ipfs/bafyCID123/path/a.bin", "IPFS gateway")
    let r3 = try! await URINormalizer.normalize("ipns://name.eth/a.bin", settings: settings)
    eq(r3[0].url.absoluteString, "https://gw.example/ipns/name.eth/a.bin", "IPNS gateway")
    let r4 = try! await URINormalizer.normalize(
        "webdavs://alice:secret@dav.example/remote/a.zip", settings: settings)
    eq(r4[0].url.scheme, "https", "WebDAVS -> https")
    eq(r4[0].proto, .webdavs, "WebDAVS badge preserved")
    check(r4[0].url.absoluteString.contains("alice:secret@"), "WebDAV credentials kept")

    let r5 = try! await URINormalizer.normalize("s3://examplebucket/test.txt", settings: settings)
    eq(r5[0].proto, .s3, "S3 badge preserved")
    check(r5[0].url.absoluteString.contains("X-Amz-Signature="), "S3 URL is signed")

    let r6 = try! await URINormalizer.normalize(
        "https://a.example/1.bin\nhttps://a.example/2.bin\n", settings: settings)
    eq(r6.count, 2, "multi-line batch expands")

    let r7 = try! await URINormalizer.normalize("data:text/plain,hello", settings: settings)
    eq(r7[0].proto, .data, "data URI passthrough")

    // Regression: a bare `ipfs://CID` used to be rewritten with a trailing
    // slash, which public gateways answer with 404 ("Resource not found").
    let rIPFS1 = try! await URINormalizer.normalize("ipfs://bafyCID123", settings: settings)
    eq(rIPFS1[0].url.absoluteString, "https://gw.example/ipfs/bafyCID123",
       "bare IPFS CID has no trailing slash")
    let rIPFS2 = try! await URINormalizer.normalize("ipfs://bafyCID123/", settings: settings)
    eq(rIPFS2[0].url.absoluteString, "https://gw.example/ipfs/bafyCID123",
       "IPFS root slash is normalized")
    let rIPFS3 = try! await URINormalizer.normalize("ipns://name.eth", settings: settings)
    eq(rIPFS3[0].url.absoluteString, "https://gw.example/ipns/name.eth",
       "bare IPNS name has no trailing slash")

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("Siphon-ProtocolTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let listURL = tmp.appendingPathComponent("links.m3u")
    try! "#EXTM3U\nhttps://a.example/1.bin\nhttps://a.example/2.bin\n"
        .write(to: listURL, atomically: true, encoding: .utf8)
    let r8 = try! await URINormalizer.normalize(listURL.absoluteString, settings: settings)
    eq(r8.count, 2, "local M3U expands into tasks")

    print("[9] LocalEngine end-to-end")
    let local = LocalEngine()
    let delegate = MockDelegate()
    local.delegate = delegate

    let src = tmp.appendingPathComponent("source.bin")
    let reference = Data((0..<40_000).map { UInt8($0 % 251) })
    try! reference.write(to: src)
    let copyDest = tmp.appendingPathComponent("copy.bin")
    let fileTask = DownloadTask(source: src, destination: copyDest, protoOverride: .file)
    try! await local.submit(fileTask)
    let s1 = await waitState(delegate, fileTask.id)
    eq(s1, .completed, "file:// copy completes")
    eq(try! Data(contentsOf: copyDest), reference, "file:// bytes identical")

    let dataTask = DownloadTask(source: url(DataURICodec.encode(payload)),
                                destination: tmp.appendingPathComponent("data.bin"),
                                protoOverride: .data)
    try! await local.submit(dataTask)
    let s2 = await waitState(delegate, dataTask.id)
    eq(s2, .completed, "data: write completes")
    eq(try! Data(contentsOf: dataTask.destination), payload, "data: bytes identical")

    print("[10] CurlEngine end-to-end (local HTTP fixture)")
    let curl = CurlEngine()
    let curlDelegate = MockDelegate()
    curl.delegate = curlDelegate
    let curlDest = tmp.appendingPathComponent("curl.bin")
    let curlTask = DownloadTask(source: url("http://127.0.0.1:18765/seg0.ts"),
                                destination: curlDest, protoOverride: .curl)
    try! await curl.submit(curlTask)
    let s3 = await waitState(curlDelegate, curlTask.id)
    eq(s3, .completed, "libcurl transfer completes")
    let fixture = URL(fileURLWithPath:
        FileManager.default.currentDirectoryPath + "/Tests/fixtures/seg0.ts")
    let expectedBytes = try! Data(contentsOf: fixture)
    eq(try! Data(contentsOf: curlDest), expectedBytes, "libcurl bytes identical")
    check((curlDelegate.progress[curlTask.id]?.downloadedBytes ?? -1) >= 0,
          "libcurl reports progress")

    print("[11] thunder:// -> normalization -> real aria2 -> verified bytes")
    do {
        let bootstrap = Aria2Bootstrap.shared
        // Never share port 6800 with a running Siphon.app instance.
        bootstrap.port = 6801
        try bootstrap.start()
        defer { bootstrap.stop() }
        let aria2 = Aria2Engine(endpoint: bootstrap.rpcURL)
        let aria2Delegate = MockDelegate()
        aria2.delegate = aria2Delegate
        aria2.startPolling()
        defer { aria2.suspendPolling() }
        check((try? await Aria2RPC(endpoint: bootstrap.rpcURL).tellActive()) != nil,
              "tellActive RPC signature (regression)")

        let fixtureURL = "http://127.0.0.1:18765/seg0.ts"
        let link = SpecialLinks.encode(fixtureURL, as: "thunder")
        let req = try await URINormalizer.normalize(link, settings: settings)
        eq(req.count, 1, "vendor link resolves to exactly one request")
        eq(req[0].url.absoluteString, fixtureURL, "vendor link target URL")
        let dest = tmp.appendingPathComponent("thunder.ts")
        let verdict = DownloadTask(source: req[0].url, destination: dest,
                                   origin: link, protoOverride: req[0].proto)
        try await aria2.submit(verdict)
        let state = await waitState(aria2Delegate, verdict.id)
        if state != .completed {
            let probe = Aria2RPC(endpoint: bootstrap.rpcURL)
            do {
                let a = try await probe.tellActive()
                let w = try await probe.tellWaiting()
                let s = try await probe.tellStopped()
                print("       diagnostic states=\(aria2Delegate.states) " +
                      "active=\(a.count) waiting=\(w.count) stopped=\(s.count) " +
                      "gids=\(s.compactMap { $0["gid"] as? String })")
            } catch {
                print("       diagnostic rpc error=\(error)")
            }
        }
        check(state == .completed, "aria2 completes the vendor-link download")
        check((try? Data(contentsOf: dest)) == expectedBytes,
              "vendor-link bytes identical")
    } catch {
        check(false, "vendor-link aria2 E2E threw: \(error)")
    }
}

final class Done { var value = false }
let done = Done()
Task { @MainActor in
    await asyncTests()
    done.value = true
}
while !done.value {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}

print("")
if failures == 0 {
    print("PROTOCOL TESTS PASSED: \(passed) assertions")
} else {
    print("PROTOCOL TESTS FAILED: \(failures) failures / \(passed) passed")
    exit(1)
}
