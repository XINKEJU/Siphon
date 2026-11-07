import Foundation

/// Offline regression tests for the WebDAV PROPFIND multistatus parser.
var failCount = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("PASS  \(label)") }
    else {
        print("FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failCount += 1
    }
}

// Typical RFC 4918 multistatus: prefixed namespace, one collection, two files,
// percent-encoded href, and the self-entry the server echoes back first.
let multistatus = """
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/big%20file.bin</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getcontentlength>1048576</d:getcontentlength>
        <d:displayname>big file.bin</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/subdir/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/readme.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getcontentlength>33</d:getcontentlength>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
"""

let base = URL(string: "https://user:pass@nas.example.com/dav/")!
let entries = WebDAVLister.parse(Data(multistatus.utf8), baseURL: base)
check(entries.count == 4, "parse: four responses", "got \(entries.count)")

check(entries[0].isDirectory, "self-entry is a directory")
check(entries[0].name == "dav", "self-entry name falls back to href",
      entries[0].name)

check(entries[1].name == "big file.bin", "displayname wins", entries[1].name)
check(entries[1].size == 1048576, "contentlength parsed", "\(entries[1].size)")
check(!entries[1].isDirectory, "file not a directory")
check(!entries[1].isDirectory && entries[1].href.contains("big%20file.bin"),
      "percent-encoded href preserved", entries[1].href)

check(entries[2].isDirectory, "subdir is a directory")
check(entries[3].name == "readme.txt", "name falls back to decoded href",
      entries[3].name)
check(entries[3].size == 33, "small size", "\(entries[3].size)")

// list() must drop the collection itself.
let selfFiltered = entries.filter { e in
    guard let u = URL(string: e.href, relativeTo: base)?.absoluteURL else { return false }
    var p = u.path
    if !p.hasSuffix("/") { p += "/" }
    return p != "/dav/"
}
check(selfFiltered.count == 3, "self-entry filtered against base path",
      "\(selfFiltered.count)")

// looksLikeDirectory: trailing slash detection on raw string (URL.path strips it).
check(WebDAVLister.looksLikeDirectory(URL(string: "webdav://h/d/")!), "trailing slash → dir")
check(WebDAVLister.looksLikeDirectory(URL(string: "webdav://h")!), "no path → dir")
check(!WebDAVLister.looksLikeDirectory(URL(string: "webdav://h/d/f.bin")!), "file path → not dir")

// Relative href resolution keeps the base authority (incl. credentials).
let resolved = URL(string: "/dav/big%20file.bin", relativeTo: base)?.absoluteURL
check(resolved?.absoluteString == "https://user:pass@nas.example.com/dav/big%20file.bin",
      "href resolution keeps base authority", resolved?.absoluteString ?? "nil")

if failCount == 0 { print("WebDAVTests: ALL PASS") } else { exit(1) }
