import Foundation

// Pure parser tests for the site-adapter layer. No network: every adapter's
// `parse` is fed a sanitized HTML/JSON fixture, so the suite is deterministic
// and never fails because a public host changed its markup.

var failures = 0
func check(_ cond: Bool, _ msg: String, _ detail: String = "") {
    if cond { print("  ok  \(msg)") }
    else { failures += 1; print("  FAIL \(msg)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

/// Resolve `Tests/fixtures/sites/<name>` relative to this source file so the
/// test passes regardless of the working directory it is launched from.
func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #file)
        .deletingLastPathComponent() // SiteAdapterTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Siphon
        .appendingPathComponent("Tests/fixtures/sites/\(name)")
}
func fixtureText(_ name: String) -> String {
    (try? String(contentsOf: fixtureURL(name), encoding: .utf8)) ?? ""
}
func fixtureData(_ name: String) -> Data {
    (try? Data(contentsOf: fixtureURL(name))) ?? Data()
}

func expectThrow<T>(_ label: String, _ work: () throws -> T) {
    do { _ = try work(); check(false, "\(label): should throw") }
    catch is SiteAdapterError { check(true, "\(label): throws SiteAdapterError") }
    catch { check(false, "\(label): wrong error type \(error)") }
}

// MARK: - registry / host matching

check(SiteAdapterRegistry.adapter(for: URL(string: "https://drive.google.com/file/d/x/view")!)?.id
      == "google-drive", "registry routes drive.google.com")
check(SiteAdapterRegistry.adapter(for: URL(string: "https://www.mediafire.com/file/hash/name/file")!)?.id
      == "mediafire", "registry routes mediafire.com (with www)")
check(SiteAdapterRegistry.adapter(for: URL(string: "https://rapidgator.net/file/hash/name.html")!)?.id
      == "rapidgator", "registry routes rapidgator.net")
check(SiteAdapterRegistry.adapter(for: URL(string: "https://luluvdo.com/e/abc")!)?.id
      == "lulustream", "registry routes luluvdo.com")
check(SiteAdapterRegistry.adapter(for: URL(string: "https://gofile.io/d/abc")!)?.id
      == "gofile", "registry routes gofile.io")
check(SiteAdapterRegistry.adapter(for: URL(string: "https://archive.org/details/foo")!)?.id
      == "archive.org", "registry routes archive.org")
check(SiteAdapterRegistry.adapter(for: URL(string: "https://example.com/file.zip")!) == nil,
      "registry does not claim generic hosts")

check(SiteAdapterRegistry.matches(host: "www.drive.google.com", patterns: ["drive.google.com"]),
      "host match strips leading www.")
check(SiteAdapterRegistry.matches(host: "cdn1.mediafire.com", patterns: ["*.mediafire.com"]),
      "host match supports *. wildcard")
check(!SiteAdapterRegistry.matches(host: "evil.com", patterns: ["*.mediafire.com", "mediafire.com"]),
      "host match rejects unrelated host")

// MARK: - Google Drive

do {
    let html = fixtureText("google_drive_view.html")
    let url = URL(string: "https://drive.google.com/file/d/1A2B3C4D5E6F7G8H9I0J/view")!
    let r = try GoogleDriveAdapter.parse(html: html, url: url)
    check(r.url.absoluteString.contains("id=1A2B3C4D5E6F7G8H9I0J"), "gdrive: id in final URL", r.url.absoluteString)
    check(r.url.absoluteString.contains("confirm=t"), "gdrive: confirm token in URL")
    check(r.suggestedName == "Annual Report 2024", "gdrive: title cleaned of suffix", r.suggestedName ?? "nil")
    check(r.headers["Referer"]?.contains("google.com") == true, "gdrive: referer header set")
} catch { check(false, "gdrive parse threw: \(error)") }

do {
    let html = fixtureText("google_drive_view.html")
    let url = URL(string: "https://drive.google.com/open?id=QUERYID999")!
    let r = try GoogleDriveAdapter.parse(html: html, url: url)
    check(r.url.absoluteString.contains("id=QUERYID999"), "gdrive: ?id= query param parsed")
} catch { check(false, "gdrive query parse threw: \(error)") }

expectThrow("gdrive missing id") {
    try GoogleDriveAdapter.parse(html: fixtureText("google_drive_error.html"),
                                 url: URL(string: "https://drive.google.com/file-error")!)
}

// MARK: - MediaFire

do {
    let html = fixtureText("mediafire_page.html")
    let url = URL(string: "https://www.mediafire.com/file/hash/photos.zip/file")!
    let r = try MediaFireAdapter.parse(html: html, url: url)
    check(r.url.absoluteString.contains("download15.mediafire.com"), "mediafire: direct download URL", r.url.absoluteString)
    check(r.url.absoluteString.hasSuffix("photos.zip"), "mediafire: URL points at file")
    check(r.suggestedName == "photos.zip", "mediafire: title cleaned of '| MediaFire'", r.suggestedName ?? "nil")
} catch { check(false, "mediafire parse threw: \(error)") }

// MARK: - Rapidgator

do {
    let html = fixtureText("rapidgator_page.html")
    let url = URL(string: "https://rapidgator.net/file/hash/movie.mkv.html")!
    let r = try RapidgatorAdapter.parse(html: html, url: url)
    check(r.url.absoluteString.contains("/files/"), "rapidgator: token download link", r.url.absoluteString)
    check(r.suggestedName == "movie.mkv", "rapidgator: title cleaned of suffix", r.suggestedName ?? "nil")
} catch { check(false, "rapidgator parse threw: \(error)") }

// MARK: - Lulustream

do {
    let html = fixtureText("lulustream_page.html")
    let url = URL(string: "https://lulustream.com/e/hash123")!
    let r = try LulustreamAdapter.parse(html: html, url: url)
    check(r.url.absoluteString.hasSuffix(".mp4"), "lulustream: video source extracted", r.url.absoluteString)
    check(r.url.absoluteString.contains("lulustream.com"), "lulustream: source is an absolute URL")
    check(r.suggestedName == "Holiday Clip", "lulustream: title cleaned", r.suggestedName ?? "nil")
} catch { check(false, "lulustream parse threw: \(error)") }

// MARK: - Gofile (multi-file)

do {
    let data = fixtureData("gofile_content.json")
    let out = try GofileAdapter.parse(data: data, contentId: "abc")
    check(out.count == 2, "gofile: 2 files, folders excluded", "got \(out.count)")
    check(out.contains { $0.suggestedName == "report.pdf" }, "gofile: report.pdf present")
    check(out.contains { $0.size == 204800 }, "gofile: size parsed")
    check(out.first(where: { $0.suggestedName == "report.pdf" })?.checksum == "md5:abcdef0123456789",
          "gofile: md5 checksum normalized to algorithm:hex")
    check(out.allSatisfy { $0.url.scheme == "https" }, "gofile: all URLs https")
} catch { check(false, "gofile parse threw: \(error)") }

expectThrow("gofile empty contents") {
    try GofileAdapter.parse(data: fixtureData("gofile_empty.json"), contentId: "empty")
}

// MARK: - Archive.org (filter derivatives)

do {
    let data = fixtureData("archive_metadata.json")
    let out = try ArchiveOrgAdapter.parse(data: data, identifier: "foo")
    check(out.count == 1, "archive.org: only book.pdf kept (derivatives + thumb skipped)", "got \(out.count)")
    let pdf = out.first!
    check(pdf.suggestedName == "book.pdf", "archive.org: filename", pdf.suggestedName ?? "nil")
    check(pdf.size == 1_234_567, "archive.org: size from string")
    check(pdf.checksum == "sha1:bbb222", "archive.org: prefers sha1 over md5", pdf.checksum ?? "nil")
    check(pdf.url.absoluteString == "https://archive.org/download/foo/book.pdf", "archive.org: direct URL constructed")
} catch { check(false, "archive parse threw: \(error)") }

check(ArchiveOrgAdapter.extractIdentifier(URL(string: "https://archive.org/details/myitem/page/n5")!)
      == "myitem", "archive.org: id from /details/")
check(ArchiveOrgAdapter.extractIdentifier(URL(string: "https://archive.org/download/myitem/file.zip")!)
      == "myitem", "archive.org: id from /download/")
check(GofileAdapter.extractContentID(URL(string: "https://gofile.io/d/abc123")!) == "abc123",
      "gofile: content id from /d/")

print("SITE ADAPTER TESTS DONE (\(failures) failure(s))")
exit(Int32(failures))
