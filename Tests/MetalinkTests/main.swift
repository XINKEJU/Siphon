import Foundation

/// Offline regression tests for the Metalink v3/v4 parser.
var failCount = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("PASS  \(label)") }
    else {
        print("FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failCount += 1
    }
}

// RFC 5854 v4: two files, priorities, sha-256 + md5.
let v4 = """
<?xml version="1.0" encoding="utf-8"?>
<metalink xmlns="urn:ietf:params:xml:ns:metalink">
  <file name="debian-12.iso">
    <size>3789457408</size>
    <hash type="md5">aaaabbbbccccdddd1111222233334444</hash>
    <hash type="sha-256">0011223344556677889900aabbccddeeff0011223344556677889900aabbccdd</hash>
    <url priority="3" location="jp">https://jp.example.com/debian-12.iso</url>
    <url priority="1" location="cn">https://cn.example.com/debian-12.iso</url>
    <url priority="2">https://mirror.example.org/debian-12.iso</url>
  </file>
  <file name="debian-12.iso.sig">
    <size>833</size>
    <url>https://cn.example.com/debian-12.iso.sig</url>
  </file>
</metalink>
"""
let f4 = MetalinkParser.parse(v4)
check(f4.count == 2, "v4: two files", "got \(f4.count)")
check(f4[0].name == "debian-12.iso", "v4: file name attribute", f4[0].name)
check(f4[0].size == 3789457408, "v4: size", "\(f4[0].size)")
check(f4[0].urls.count == 3, "v4: three mirrors", "\(f4[0].urls.count)")
check(f4[0].urls.first?.absoluteString == "https://cn.example.com/debian-12.iso",
      "v4: priority 1 first", f4[0].urls.first?.absoluteString ?? "nil")
check(f4[0].urls.last?.absoluteString == "https://jp.example.com/debian-12.iso",
      "v4: priority 3 last", f4[0].urls.last?.absoluteString ?? "nil")
check(f4[0].checksum == "sha256:0011223344556677889900aabbccddeeff0011223344556677889900aabbccdd",
      "v4: sha-256 preferred over md5", f4[0].checksum ?? "nil")
check(f4[1].checksum == nil, "v4: file without hash → nil checksum", f4[1].checksum ?? "nil")

// Metalink v3: hash nested inside <verification>, own namespace prefix.
let v3 = """
<?xml version="1.0" encoding="utf-8"?>
<metalink version="3.0" xmlns="http://www.metalinker.org/">
  <files>
    <file name="app.dmg">
      <size>1048576</size>
      <verification>
        <hash type="sha1">1234567890abcdef1234567890abcdef12345678</hash>
      </verification>
      <resources>
        <url type="http" preference="90">https://a.example.com/app.dmg</url>
        <url type="http" preference="100">https://b.example.com/app.dmg</url>
      </resources>
    </file>
  </files>
</metalink>
"""
let f3 = MetalinkParser.parse(v3)
check(f3.count == 1, "v3: one file", "got \(f3.count)")
check(f3[0].urls.count == 2, "v3: two urls", "\(f3[0].urls.count)")
check(f3[0].urls.first?.absoluteString == "https://b.example.com/app.dmg",
      "v3: order preserved", f3[0].urls.first?.absoluteString ?? "nil")
check(f3[0].checksum == "sha1:1234567890abcdef1234567890abcdef12345678",
      "v3: verification hash picked up", f3[0].checksum ?? "nil")

// Unsupported hash algorithm is dropped; duplicate URLs deduped; bad URL skipped.
let mixed = """
<metalink xmlns="urn:ietf:params:xml:ns:metalink">
  <file name="x.bin">
    <hash type="crc32">ffffffff</hash>
    <url>https://x.example.com/x.bin</url>
    <url>https://x.example.com/x.bin</url>
    <url>http://&lt;invalid&gt;</url>
    <url>https://y.example.com/x.bin</url>
  </file>
</metalink>
"""
let fm = MetalinkParser.parse(mixed)
check(fm.count == 1, "mixed: parsed", "got \(fm.count)")
check(fm[0].checksum == nil, "mixed: unsupported hash dropped", fm[0].checksum ?? "nil")
check(fm[0].urls.count == 2, "mixed: dedup + skip invalid", "\(fm[0].urls.count)")

// SHA-512 is supported and preferred over weaker hashes.
let strong512 = String(repeating: "f", count: 128)
let strong = """
<metalink xmlns="urn:ietf:params:xml:ns:metalink">
  <file name="y.bin">
    <hash type="md5">0123456789abcdef0123456789abcdef</hash>
    <hash type="sha-512">\(strong512)</hash>
    <url>https://y.example.com/y.bin</url>
  </file>
</metalink>
"""
let fs = MetalinkParser.parse(strong)
check(fs.count == 1, "strong: parsed", "got \(fs.count)")
check(fs[0].checksum == "sha512:" + strong512,
      "strong: sha-512 preferred", fs[0].checksum ?? "nil")

// Pieces: sha-1 piece list captured; unsupported type/short hashes dropped.
let withPieces = """
<metalink xmlns="urn:ietf:params:xml:ns:metalink">
  <file name="p.bin">
    <size>6</size>
    <pieces length="3" type="sha-1">
      <hash>1111111111111111111111111111111111111111</hash>
      <hash>2222222222222222222222222222222222222222</hash>
    </pieces>
    <hash type="sha-256">aabb00112233445566778899aabbccddeeff00112233445566778899aabbccdd</hash>
    <url>https://x.example.com/p.bin</url>
  </file>
  <file name="q.bin">
    <pieces length="4" type="md5">
      <hash>33333333333333333333333333333333</hash>
    </pieces>
    <url>https://x.example.com/q.bin</url>
  </file>
</metalink>
"""
let fp = MetalinkParser.parse(withPieces)
check(fp.count == 2, "pieces: two files", "got \(fp.count)")
check(fp[0].pieces == ["1111111111111111111111111111111111111111",
                       "2222222222222222222222222222222222222222"],
      "pieces: sha-1 list captured", "\(fp[0].pieces)")
check(fp[0].pieceLength == 3, "pieces: length", "\(fp[0].pieceLength)")
check(fp[0].checksum?.hasPrefix("sha256:") == true, "pieces: whole-file hash separate",
      fp[0].checksum ?? "nil")
check(fp[1].pieces.isEmpty && fp[1].pieceLength == 0, "pieces: md5 type rejected")

// Garbage input yields no files (caller falls back to passthrough).
check(MetalinkParser.parse("<html>404</html>").isEmpty, "non-metalink: empty result")
check(MetalinkParser.parse("").isEmpty, "empty input: empty result")

if failCount == 0 { print("MetalinkTests: ALL PASS") } else { exit(1) }
