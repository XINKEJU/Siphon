import Foundation

// YtDlpResolver tests. The real yt-dlp binary is never required: a stub shell
// script is installed and pointed at via SIPHON_YTDLP_PATH, emitting canned
// `yt-dlp -J` JSON. This keeps the resolver logic (format scoring, playlist
// expansion, error surfaces) testable offline.

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("ytdlp-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// MARK: - stub binary

func installStub(fixtureJSON: String, exitCode: Int32) throws {
    let fixture = tmp.appendingPathComponent("fixture.json")
    try fixtureJSON.write(to: fixture, atomically: true, encoding: .utf8)
    let script = """
    #!/bin/sh
    # Ignore args entirely; emit the canned `yt-dlp -J` payload.
    cat "$SIPHON_STUB_FIXTURE"
    exit \(exitCode)
    """
    let url = tmp.appendingPathComponent("yt-dlp")
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: url.path)
    setenv("SIPHON_YTDLP_PATH", url.path, 1)
    setenv("SIPHON_STUB_FIXTURE", fixture.path, 1)
}

func runCase(fixtureJSON: String, exitCode: Int32 = 0) async throws -> [YtDlpResolver.Media] {
    try installStub(fixtureJSON: fixtureJSON, exitCode: exitCode)
    return try await YtDlpResolver.resolve("https://www.youtube.com/watch?v=test")
}

// Fixture: one video, formats ranked by height; a 1080p video-only stream must
// LOSE to the 720p progressive (audio+video) stream because we cannot merge.
let videoJSON = """
{"_type":"video","title":"Test Video","ext":"mp4","formats":[
 {"url":"https://cdn.test/1080-video-only","height":1080,"vbr":4000,"acodec":"none","vcodec":"avc1","protocol":"https","ext":"mp4"},
 {"url":"https://cdn.test/720-progressive","height":720,"vbr":2500,"abr":128,"acodec":"mp4a","vcodec":"avc1","protocol":"https","ext":"mp4"},
 {"url":"https://cdn.test/480-progressive","height":480,"vbr":1200,"abr":96,"acodec":"mp4a","vcodec":"avc1","protocol":"https","ext":"mp4"}
]}
"""
// Fixture: a playlist with two fully resolved entries.
let playlistJSON = """
{"_type":"playlist","title":"List","entries":[
 {"_type":"video","title":"First","ext":"mp4","formats":[
   {"url":"https://cdn.test/first","height":360,"acodec":"mp4a","vcodec":"avc1","protocol":"https","ext":"mp4"}]},
 {"_type":"video","title":"Second","ext":"mp4","formats":[
   {"url":"https://cdn.test/second","height":720,"acodec":"mp4a","vcodec":"avc1","protocol":"https","ext":"mp4"}]}
]}
"""
// Fixture: failure exit code.
let failFixture = "ERROR: nope"

// MARK: - host matching (pure, no binary needed)

check(YtDlpResolver.isSupported(URL(string: "https://www.youtube.com/watch?v=x")!),
      "youtube matched")
check(YtDlpResolver.isSupported(URL(string: "https://b23.tv/abc")!), "b23.tv matched")
check(YtDlpResolver.isSupported(URL(string: "https://x.com/user/status/1")!),
      "x.com matched")
check(!YtDlpResolver.isSupported(URL(string: "https://example.com/file.zip")!),
      "plain hosts not matched")
check(!YtDlpResolver.isSupported(URL(string: "https://notyoutube.com/file")!),
      "suffix lookalike not matched")

// MARK: - single video: progressive stream preferred over higher-res video-only

do {
    let medias = try await runCase(fixtureJSON: videoJSON)
    check(medias.count == 1, "single video resolves to one media")
    check(medias.first?.url == "https://cdn.test/720-progressive",
          "progressive 720p beats video-only 1080p (no merge path)",
          "got \(medias.first?.url ?? "nil")")
    check(medias.first?.title == "Test Video", "title captured")
    check(medias.first?.ext == "mp4", "ext captured")
}

// MARK: - playlist: expanded per entry

do {
    let medias = try await runCase(fixtureJSON: playlistJSON)
    check(medias.count == 2, "playlist expands to two entries", "got \(medias.count)")
    check(medias.map { $0.url } == ["https://cdn.test/first", "https://cdn.test/second"],
          "playlist entry order preserved")
    check(medias[1].title == "Second", "entry title captured")
}

// MARK: - yt-dlp failure surfaces as error

do {
    do {
        _ = try await runCase(fixtureJSON: failFixture, exitCode: 1)
        check(false, "non-zero exit throws resolveFailed")
    } catch {
        check(true, "non-zero exit throws resolveFailed", "\(type(of: error))")
    }
}

// MARK: - missing binary → unavailable

do {
    unsetenv("SIPHON_YTDLP_PATH")
    // Point PATH away so `which yt-dlp` finds nothing even if brew is installed.
    setenv("PATH", "/usr/bin:/bin", 1)
    check(!YtDlpResolver.available(), "unavailable when no binary found")
    do {
        _ = try await YtDlpResolver.resolve("https://www.youtube.com/watch?v=x")
        check(false, "resolve without binary throws")
    } catch {
        check(true, "resolve without binary throws")
    }
    // Restore.
    setenv("PATH", ProcessInfo.processInfo.environment["ORIG_PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", 1)
}

try? FileManager.default.removeItem(at: tmp)

if failures == 0 { print("YT-DLP RESOLVER TESTS PASSED") }
else { print("YT-DLP RESOLVER TESTS FAILED: \(failures)"); exit(1) }
