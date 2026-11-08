import Foundation

// Archive extraction + file-name hardening regressions.
// Usage: <binary> <traversal.zip> <symlink.zip> <clean.zip>
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

// MARK: - destination file-name sanitizer

check("safeName keeps a plain name", ContentDisposition.safeName("a.zip") == "a.zip")
check("safeName strips parent traversal",
      ContentDisposition.safeName("../../etc/passwd") == "passwd")
check("safeName strips an absolute path",
      ContentDisposition.safeName("/tmp/report.pdf") == "report.pdf")
check("safeName strips Windows separators",
      ContentDisposition.safeName("..\\..\\evil.exe") == "evil.exe")
check("safeName rejects dot", ContentDisposition.safeName("..") == nil)
check("safeName rejects empty", ContentDisposition.safeName("") == nil)
check("safeName strips control characters",
      ContentDisposition.safeName("a\u{7}b.txt") == "ab.txt")

// MARK: - archive entry validation (pure)

check("normal zip entries accepted",
      ArchiveManager.validateEntryNames(["a.txt", "dir/b.txt", "dir/"]) == nil)
check("parent traversal entry rejected",
      ArchiveManager.validateEntryNames(["dir/../../evil.txt"]) != nil)
check("leading parent traversal rejected",
      ArchiveManager.validateEntryNames(["../evil.txt"]) != nil)
check("absolute entry rejected",
      ArchiveManager.validateEntryNames(["/etc/cron.d/evil"]) != nil)
check("backslash traversal rejected",
      ArchiveManager.validateEntryNames(["..\\evil.txt"]) != nil)
check("drive-letter path rejected",
      ArchiveManager.validateEntryNames(["C:/Windows/evil"]) != nil)
check("control character rejected",
      ArchiveManager.validateEntryNames(["a\u{1}b.txt"]) != nil)
check("entry count cap enforced",
      ArchiveManager.validateEntryNames(Array(repeating: "x", count: 20_001)) != nil)

// MARK: - listing parsers

check("zipinfo symlink entry detected",
      ArchiveManager.isSpecialListingLine(
        "lrwxr-xr-x  3.0 unx       11 bx       11 stor 26-Nov-08 11:11 evil"))
check("zipinfo regular entry is not special",
      !ArchiveManager.isSpecialListingLine(
        "-rw-r--r--  3.0 unx        3 tx        3 stor 26-Nov-08 11:11 a.txt"))
check("zipinfo header is not special",
      !ArchiveManager.isSpecialListingLine("Archive:  t.zip"))
check("tar verbose symlink detected",
      ArchiveManager.isSpecialListingLine(
        "lrwxr-xr-x  0 xinkeju wheel       0 Nov  8 11:11 evil -> /etc/passwd"))
check("zip expanded size parsed",
      ArchiveManager.zipExpandedBytes(
        ["Archive:  t.zip",
         "2 files, 14 bytes uncompressed, 14 bytes compressed:  0.0%"]) == 14)
check("tar expanded size parsed",
      ArchiveManager.tarExpandedBytes(
        ["-rw-r--r--  0 xinkeju wheel       3 Nov  8 11:11 a.txt"]) == 3)
check("gzip ISIZE is little-endian",
      ArchiveManager.gzipExpandedSize(Data([0, 0, 0, 0, 3, 0, 0, 0])) == 3)

// MARK: - real archives (python fixtures)

let args = CommandLine.arguments
if args.count >= 4 {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("siphon-archive-safety-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func copyFixture(_ source: String, named: String) -> URL? {
        let dest = root.appendingPathComponent(named)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: URL(fileURLWithPath: source), to: dest)
            return dest
        } catch { return nil }
    }

    if let evil = copyFixture(args[1], named: "traversal.zip") {
        let result = ArchiveManager.shared.extract(evil)
        check("zip with ../ entry is refused", result == nil)
        check("no file escaped the extraction directory",
              !fm.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    } else { check("traversal fixture available", false) }

    if let linked = copyFixture(args[2], named: "symlink.zip") {
        check("zip with a symlink entry is refused",
              ArchiveManager.shared.extract(linked) == nil)
    } else { check("symlink fixture available", false) }

    if let clean = copyFixture(args[3], named: "clean.zip") {
        let result = ArchiveManager.shared.extract(clean)
        check("clean zip extracts", result != nil)
        check("clean zip content is correct",
              (try? String(contentsOf: (result ?? clean).appendingPathComponent("a.txt"),
                           encoding: .utf8)) == "hello")
    } else { check("clean fixture available", false) }
} else {
    check("fixture paths supplied", false, "expected 3 zip paths")
}

if failures == 0 { print("ARCHIVE SAFETY TESTS PASSED") }
else { print("ARCHIVE SAFETY TESTS FAILED: \(failures)"); exit(1) }
