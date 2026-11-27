import Foundation
import Compression

// Stage 2 tests: package parsers, remote-ZIP parsing, archive verification,
// Click'n'Load crypto/payload and debrid response parsing. Everything here is
// pure or file-based — no test touches the network.

var failures = 0
func check(_ cond: Bool, _ msg: String, _ detail: String = "") {
    if cond { print("  ok  \(msg)") }
    else { failures += 1; print("  FAIL \(msg)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

func fixture(_ relative: String) -> URL {
    URL(fileURLWithPath: #file)
        .deletingLastPathComponent()   // Stage2Tests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("fixtures/\(relative)")
}
func fixtureText(_ relative: String) -> String {
    (try? String(contentsOf: fixture(relative), encoding: .utf8)) ?? ""
}
func fixtureData(_ relative: String) -> Data {
    (try? Data(contentsOf: fixture(relative))) ?? Data()
}

// MARK: - PackageResolver.source classification

func testSourceClassification() {
    func kind(_ s: String) -> PackageResolver.Source {
        PackageResolver.source(for: URL(string: s)!)
    }
    if case .ftp = kind("ftp://ftp.example.com/pub/") { check(true, "ftp scheme → .ftp") }
    else { check(false, "ftp scheme → .ftp") }

    if case .huggingFace(let repo, let rev) = kind("https://huggingface.co/acme/model-x") {
        check(repo == "acme/model-x" && rev == "main", "huggingface repo parsed", repo)
    } else { check(false, "huggingface repo parsed") }

    if case .huggingFace(let repo, _) = kind("https://huggingface.co/datasets/acme/data") {
        check(repo == "acme/data", "huggingface datasets repo parsed", repo)
    } else { check(false, "huggingface datasets repo parsed") }

    if case .github(let owner, let repo, let tag) = kind("https://github.com/acme/siphon/releases/tag/v1.4.0") {
        check(owner == "acme" && repo == "siphon" && tag == "v1.4.0", "github tag parsed")
    } else { check(false, "github tag parsed") }

    if case .github(let owner, let repo, let tag) = kind("https://github.com/acme/siphon/releases/latest") {
        check(owner == "acme" && repo == "siphon" && tag == nil, "github latest (no tag)")
    } else { check(false, "github latest (no tag)") }

    if case .html = kind("https://example.com/pub/files/") { check(true, "generic page → .html") }
    else { check(false, "generic page → .html") }
}

// MARK: - HTML index-of parser

func testHTMLParser() {
    let base = URL(string: "https://example.com/pub/files/")!
    let nodes = PackageParser.parseHTML(fixtureText("packages/index_of.html"), baseURL: base)
    let folders = nodes.filter(\.isFolder)
    let files = nodes.filter { !$0.isFolder }

    check(folders.count == 1, "html: exactly one folder", "got \(folders.count)")
    check(folders.first?.name == "releases", "html: folder name", folders.first?.name ?? "nil")
    check(files.count == 4, "html: four files (parent/sort/js skipped)", "got \(files.count)")
    let names = Set(files.map(\.name))
    check(names == ["manual.zip", "notes.pdf", "archive.tar.gz", "extra.bin"],
          "html: file names", names.sorted().joined(separator: ","))

    let manual = files.first { $0.name == "manual.zip" }
    check(manual?.size == 1_258_291, "html: 1.2M size parsed", "\(manual?.size ?? -1)")
    let notes = files.first { $0.name == "notes.pdf" }
    check(notes?.size == 348_160, "html: 340K size parsed", "\(notes?.size ?? -1)")
    let archive = files.first { $0.name == "archive.tar.gz" }
    check(archive?.size == 2_684_354_560, "html: 2.5 GB size parsed", "\(archive?.size ?? -1)")
    let extra = files.first { $0.name == "extra.bin" }
    check(extra?.url?.host == "cdn.example.net", "html: absolute link keeps host")
    check(extra?.size == 12_582_912, "html: 12 MB size parsed", "\(extra?.size ?? -1)")

    check(files.allSatisfy { $0.url?.scheme == "https" }, "html: all links https")
    check(!nodes.contains { $0.name.lowercased().contains("parent") }, "html: parent dir skipped")

    let empty = PackageParser.parseHTML("<html><body>nothing</body></html>", baseURL: base)
    check(empty.isEmpty, "html: no anchors → empty")
}

// MARK: - GitHub release parser

func testGitHubParser() throws {
    let nodes = try PackageParser.parseGitHubRelease(fixtureData("packages/github_release.json"),
                                                     owner: "acme", repo: "siphon")
    check(nodes.count == 4, "github: 2 assets + 2 archives", "got \(nodes.count)")
    let dmg = nodes.first { $0.name == "Siphon-1.4.0.dmg" }
    check(dmg?.size == 12_345_678, "github: asset size")
    check(dmg?.url?.absoluteString.contains("/releases/download/v1.4.0/") == true,
          "github: asset URL")
    let zip = nodes.first { $0.name == "siphon-v1.4.0.zip" }
    check(zip?.url?.absoluteString == "https://github.com/acme/siphon/archive/refs/tags/v1.4.0.zip",
          "github: source archive URL uses tag", zip?.url?.absoluteString ?? "nil")
    let tar = nodes.first { $0.name.hasSuffix(".tar.gz") }
    check(tar != nil, "github: tarball archive present")

    var threw = false
    do { _ = try PackageParser.parseGitHubRelease(Data("not json".utf8), owner: "a", repo: "b") }
    catch { threw = true }
    check(threw, "github: invalid JSON throws")
}

// MARK: - Hugging Face parser

func testHuggingFaceParser() throws {
    let root = try PackageParser.parseHuggingFaceTree(fixtureData("packages/hf_tree.json"),
                                                      repo: "acme/model-x", revision: "main")
    check(root.fileCount == 3, "hf: three files", "got \(root.fileCount)")
    let all = root.allFiles
    let model = all.first { $0.name == "model.safetensors" }
    check(model?.size == 4096, "hf: file size")
    check(model?.checksum == "sha256:abc123", "hf: LFS sha256 checksum", model?.checksum ?? "nil")
    check(model?.url?.absoluteString
          == "https://huggingface.co/acme/model-x/resolve/main/model.safetensors",
          "hf: resolve URL", model?.url?.absoluteString ?? "nil")
    let nested = all.first { $0.name == "config.json" }
    check(nested?.url?.absoluteString.contains("/resolve/main/configs/config.json") == true,
          "hf: nested file path preserved")
    let configFolder = root.children.first { $0.name == "configs" }
    check(configFolder?.isFolder == true, "hf: configs turned into a folder")
    check(root.selectedFileCount == 3, "hf: everything selected by default")

    var threw = false
    do { _ = try PackageParser.parseHuggingFaceTree(Data("[]".utf8), repo: "a/b", revision: "main") }
    catch { threw = true }
    check(threw, "hf: empty tree throws")
}

// MARK: - PackageNode tree behaviour

func testNodeTree() {
    let fileA = PackageNode(id: "a", name: "a.bin", url: URL(string: "https://x/a.bin")!,
                            size: 100, kind: .file)
    let fileB = PackageNode(id: "b", name: "b.bin", url: URL(string: "https://x/b.bin")!,
                            size: 200, kind: .file)
    let sub = PackageNode.folder(name: "sub", path: "sub", children: [fileB])
    var root = PackageNode.folder(name: "root", path: "root", children: [fileA, sub])
    root.setSelected(true)
    root.refreshFolderSelection()

    check(root.fileCount == 2, "tree: fileCount", "\(root.fileCount)")
    check(root.selectedSize == 300, "tree: selectedSize", "\(root.selectedSize)")
    check(root.selectedTransfers().count == 2, "tree: two transfers")

    let transfers = root.selectedTransfers()
    check(transfers.contains { $0.relativeDirectory == "root/sub" },
          "tree: nested relative directory",
          transfers.map(\.relativeDirectory).joined(separator: ","))

    _ = root.toggle("b")
    check(root.children[1].children[0].isSelected == false, "tree: child toggled off")
    check(root.children[1].isSelected == false, "tree: folder unchecked after child off")
    check(root.children[0].isSelected == true, "tree: sibling untouched")
    check(root.selectedSize == 100, "tree: selectedSize after toggle", "\(root.selectedSize)")

    root.children[0].setSelected(false)
    root.refreshFolderSelection()
    check(root.isSelected == false, "tree: root unchecked when all children off")

    root.setSelected(true)
    check(root.selectedFileCount == 2, "tree: select all cascades")
}

// MARK: - ZIP parsing

func testZipParsing() throws {
    check(RemoteZIPReader.crc32(Data("123456789".utf8)) == 0xCBF4_3926,
          "crc32: standard vector")
    check(RemoteZIPReader.crc32(Data("hello world".utf8)) == 0x0D4A_1185,
          "crc32: 'hello world'")

    let data = fixtureData("zip/sample.zip")
    guard let eocd = RemoteZIPReader.parseEOCD(data) else {
        check(false, "zip: EOCD parsed"); return
    }
    check(eocd.count == 2, "zip: EOCD entry count", "\(eocd.count)")
    let cdStart = Int(eocd.cdOffset)
    let cd = data.subdata(in: cdStart..<(cdStart + Int(eocd.cdSize)))
    let entries = RemoteZIPReader.parseCentralDirectory(cd, limit: 10)
    check(entries.count == 2, "zip: central directory entries", "\(entries.count)")
    let hello = entries.first { $0.path == "hello.txt" }
    check(hello?.method == 0, "zip: stored method 0")
    check(hello?.uncompressedSize == 11, "zip: hello size 11")
    check(hello?.crc32 == 0x0D4A_1185, "zip: hello crc")
    let note = entries.first { $0.path == "folder/note.txt" }
    check(note?.method == 8, "zip: deflate method 8")
    check(note?.isDirectory == false, "zip: file not directory")

    check(RemoteZIPReader.parseEOCD(Data("not a zip at all".utf8)) == nil,
          "zip: junk input rejected")
}

func testArchiveVerification() throws {
    let good = try ArchiveTestRepairService.testLocalArchive(at: fixture("zip/sample.zip"))
    check(good.members.count == 2, "archive: two members", "\(good.members.count)")
    check(good.isHealthy, "archive: good zip passes", good.failed.map(\.path).joined(separator: ","))
    check(good.okCount == 2, "archive: okCount 2")

    let bad = try ArchiveTestRepairService.testLocalArchive(at: fixture("zip/corrupt.zip"))
    check(bad.failed.count == 1, "archive: corrupt zip fails one member", "\(bad.failed.count)")
    check(!bad.isHealthy, "archive: corrupt zip is unhealthy")
    let failed = bad.failed.first
    check(failed?.path == "hello.txt", "archive: failing member identified", failed?.path ?? "nil")
    check(failed?.error?.contains("CRC") == true, "archive: failure mentions CRC",
          failed?.error ?? "nil")

    var threw = false
    do { _ = try ArchiveTestRepairService.testLocalArchive(at: URL(fileURLWithPath: "/nonexistent.zip")) }
    catch { threw = true }
    check(threw, "archive: missing file throws")
}

func testInflate() throws {
    // Round-trip through the reader's inflate using a real deflate stream built
    // by compressing known bytes, then prefixing nothing (raw DEFLATE).
    let source = Data("compress me please ".utf8 + Array(repeating: UInt8(65), count: 512))
    let compressed = try deflateRaw(source)
    let restored = try RemoteZIPReader.inflate(compressed, expectedSize: source.count)
    check(restored == source, "inflate: raw deflate round-trip", "\(restored.count) vs \(source.count)")
}

private func deflateRaw(_ data: Data) throws -> Data {
    // Apple's COMPRESSION_ZLIB emits a raw DEFLATE stream (no zlib header), which
    // is exactly what a ZIP entry stores. Return it unchanged.
    var out = Data(count: data.count + 256)
    let written = out.withUnsafeMutableBytes { dst -> Int in
        guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return data.withUnsafeBytes { src -> Int in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dstBase, dst.count, srcBase, data.count,
                                             nil, COMPRESSION_ZLIB)
        }
    }
    guard written > 0 else { throw NSError(domain: "deflate", code: 1) }
    return out.prefix(written)
}

// MARK: - Click'n'Load

func testCnL() throws {
    let key = Data(CnLCrypto.defaultKey.utf8)
    let iv = Data((0..<16).map { UInt8($0) })
    let plaintext = "source=https://example.com/a.bin\nsource=https://example.com/b.bin\ncomment=test pack\n"

    let cipher = try CnLCrypto.encryptCBC(Data(plaintext.utf8), key: key, iv: iv)
    let decrypted = try CnLCrypto.decryptCBC(cipher, key: key)
    check(String(data: decrypted, encoding: .utf8) == plaintext, "cnl: CBC round-trip")

    let base64 = cipher.base64EncodedString()
    let viaBase64 = try CnLCrypto.decrypt(base64: base64)
    check(viaBase64 == plaintext, "cnl: base64 entry point")

    let urlSafe = base64.replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    check(try CnLCrypto.decrypt(base64: urlSafe) == plaintext, "cnl: url-safe base64 accepted")

    let request = CnLPayload.parse(plaintext)
    check(request.sources.count == 2, "cnl: two sources", "\(request.sources.count)")
    check(request.comment == "test pack", "cnl: comment parsed", request.comment ?? "nil")

    let dup = CnLPayload.parse("source=https://a/x\nsource=https://a/x\nhttps://b/y")
    check(dup.sources.count == 2, "cnl: dedupes and accepts bare links", "\(dup.sources.count)")

    var threw = false
    do { _ = try CnLCrypto.decrypt(base64: "not-base64!!!") }
    catch { threw = true }
    check(threw, "cnl: invalid base64 throws")
}

// MARK: - Debrid providers

func testDebridParsing() throws {
    let rd = RealDebridProvider()
    let rdLink = try rd.parseUnrestrict(Data("""
    {"id":"ABC","filename":"movie.mkv","filesize":1234567,"download":"https://rd.example/dl/1"}
    """.utf8))
    check(rdLink.url.absoluteString == "https://rd.example/dl/1", "rd: download URL")
    check(rdLink.fileName == "movie.mkv", "rd: filename")
    check(rdLink.size == 1_234_567, "rd: size")
    let rdAccount = try rd.parseAccount(Data("""
    {"username":"neo","type":"premium","expiration":"2030-01-01T00:00:00Z"}
    """.utf8))
    check(rdAccount.username == "neo" && rdAccount.isPremium, "rd: premium account")
    check(rdAccount.expires != nil, "rd: expiration parsed")

    let ad = AllDebridProvider()
    let adLink = try ad.parseUnrestrict(Data("""
    {"status":"success","data":{"link":"https://ad.example/x","filename":"show.mkv","size":99}}
    """.utf8))
    check(adLink.url.absoluteString == "https://ad.example/x", "ad: link")
    var adThrew = false
    do { _ = try ad.parseUnrestrict(Data("""
    {"status":"error","error":{"message":"LINK_DOWN"}}
    """.utf8)) } catch { adThrew = true }
    check(adThrew, "ad: error status throws")

    let pm = PremiumizeProvider()
    let pmLink = try pm.parseUnrestrict(Data("""
    {"status":"success","content":[{"path":"/folder/album.flac","size":42,"link":"https://pm.example/f"}]}
    """.utf8))
    check(pmLink.url.absoluteString == "https://pm.example/f", "pm: link")
    check(pmLink.fileName == "album.flac", "pm: path → filename", pmLink.fileName ?? "nil")

    let tb = TorBoxProvider()
    let tbLink = try tb.parseUnrestrict(Data("""
    {"success":true,"data":{"download_url":"https://tb.example/d","name":"pack.zip","size":7}}
    """.utf8))
    check(tbLink.url.absoluteString == "https://tb.example/d", "tb: link")
    check(tbLink.fileName == "pack.zip", "tb: name")

    let md = MegaDebridProvider()
    let mdLink = try md.parseUnrestrict(Data("""
    {"response_code":200,"link":"https://md.example/l","filename":"iso.img","size":555}
    """.utf8))
    check(mdLink.url.absoluteString == "https://md.example/l", "md: link")

    // Request shape: method, bearer header and encoded form field.
    let target = URL(string: "https://host.example/file name.bin")!
    let rdRequest = try rd.unrestrictRequest(link: target, token: "tok")
    check(rdRequest.httpMethod == "POST", "rd: POST")
    check(rdRequest.value(forHTTPHeaderField: "Authorization") == "Bearer tok", "rd: bearer header")
    let body = String(data: rdRequest.httpBody ?? Data(), encoding: .utf8) ?? ""
    check(body.contains("link=https%3A%2F%2Fhost.example%2Ffile%20name.bin"),
          "rd: link form-encoded", body)

    let mdRequest = try md.unrestrictRequest(link: target, token: "tok2")
    let comps = URLComponents(url: mdRequest.url!, resolvingAgainstBaseURL: false)
    check(comps?.queryItems?.first { $0.name == "action" }?.value == "getLink", "md: action=getLink")
    check(comps?.queryItems?.first { $0.name == "token" }?.value == "tok2", "md: token in query")

    // Providers expose stable identifiers and signup URLs.
    let providers: [any DebridProvider] = [rd, ad, pm, tb, md]
    check(Set(providers.map(\.id)) == ["real-debrid", "alldebrid", "premiumize", "torbox", "mega-debrid"],
          "providers: five unique ids")
}

// MARK: - run

testSourceClassification()
testHTMLParser()
try testGitHubParser()
try testHuggingFaceParser()
testNodeTree()
try testZipParsing()
try testArchiveVerification()
try testInflate()
try testCnL()
try testDebridParsing()

print("STAGE 2 TESTS DONE (\(failures) failure(s))")
exit(Int32(failures))