import Foundation

// Regression: the old allow-list only post-verified curl/HLS/DASH/SSH/mount,
// so aria2, eD2K, file:/data: and yt-dlp tasks reported "completed" even when
// the user supplied a checksum and the file was corrupt.
var failures = 0
func check(_ label: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(label)")
    if !ok { failures += 1 }
}

func needs(_ isNative: Bool, _ ytdlp: Bool, _ spec: String?) -> Bool {
    ChecksumPolicy.needsPostCompletionChecksum(isNative: isNative,
                                               ytdlp: ytdlp, checksum: spec)
}

check("native engine verifies inline", !needs(true, false, "sha256:abc"))
check("yt-dlp task is not the native HTTP engine", needs(true, true, "sha256:abc"))
check("curl engine needs post-check", needs(false, false, "sha256:abc"))
check("aria2 engine needs post-check", needs(false, false, "sha256:abc"))
check("eD2K engine needs post-check", needs(false, false, "sha256:abc"))
check("local file/data engine needs post-check", needs(false, false, "sha256:abc"))
check("bare hex digest is a valid spec", needs(false, false, "deadbeef"))
check("no checksum → no post-check", !needs(false, false, nil))
check("empty checksum → no post-check", !needs(false, false, ""))
// A malformed spec must reach the verifier and fail loudly, not be skipped.
check("whitespace-only spec is surfaced as a failure", needs(false, false, "   "))

// MARK: - CompletionSizePolicy
//
// Regression: curl / file: / data: / scp / NFS engines used to read the
// destination size and declare `total = downloaded = size` → `.completed`.
// Whatever was on disk defined success, so a zero-byte or truncated result
// was indistinguishable from a healthy download.

func evidence(_ exists: Bool, _ regular: Bool, _ actual: Int64,
              reported: Int64? = nil, expected: Int64? = nil,
              allowsEmpty: Bool = false) -> CompletionSizePolicy.Evidence {
    CompletionSizePolicy.Evidence(exists: exists, isRegularFile: regular,
                                  actualBytes: actual, reportedBytes: reported,
                                  expectedBytes: expected, allowsEmpty: allowsEmpty)
}

check("exact source size completes",
      CompletionSizePolicy.failure(evidence(true, true, 4096, expected: 4096)) == nil)
check("truncated destination is refused",
      CompletionSizePolicy.failure(evidence(true, true, 100, expected: 4096)) != nil)
check("missing destination is refused",
      CompletionSizePolicy.failure(evidence(false, false, 0, expected: 4096)) != nil)
check("directory destination is refused",
      CompletionSizePolicy.failure(evidence(true, false, 4096, expected: 4096)) != nil)
check("fewer bytes on disk than curl reported is refused",
      CompletionSizePolicy.failure(evidence(true, true, 10, reported: 4096)) != nil)
check("resumed transfer (actual >= reported) completes",
      CompletionSizePolicy.failure(evidence(true, true, 8192,
                                            reported: 4096, expected: 8192)) == nil)
check("empty file is refused when emptiness is not expected",
      CompletionSizePolicy.failure(evidence(true, true, 0)) != nil)
check("legitimately empty payload completes",
      CompletionSizePolicy.failure(evidence(true, true, 0, expected: 0,
                                            allowsEmpty: true)) == nil)

// Exercise the real filesystem path used by the engines.
let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("siphon-size-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let good = root.appendingPathComponent("good.bin")
try? Data(repeating: 7, count: 128).write(to: good)
check("real file with matching expected size passes",
      CompletionSizePolicy.failure(at: good, expected: 128) == nil)
check("real file with wrong expected size fails",
      CompletionSizePolicy.failure(at: good, expected: 127) != nil)
check("real missing file fails",
      CompletionSizePolicy.failure(at: root.appendingPathComponent("nope")) != nil)
let dir = root.appendingPathComponent("folder", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
check("real directory is not a regular file",
      CompletionSizePolicy.failure(at: dir, expected: 0, allowsEmpty: true) != nil)
let link = root.appendingPathComponent("link")
try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
check("symlink destination is refused",
      CompletionSizePolicy.failure(at: link, expected: 128) != nil)

if failures == 0 { print("CHECKSUM + COMPLETION SIZE TESTS PASSED") }
else { print("CHECKSUM + COMPLETION SIZE TESTS FAILED: \(failures)"); exit(1) }
