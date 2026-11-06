import Foundation

// MD4 RFC 1320 official test vectors + eD2K hash + ed2k:// link parsing.
// Run via `scripts/verify.sh`. Exits non-zero on any failure.

var failures = 0
func check(_ label: String, _ got: String, _ expected: String) {
    let ok = got == expected
    print("\(ok ? "PASS" : "FAIL")  \(label): \(got)")
    if !ok { print("      expected: \(expected)"); failures += 1 }
}

let vectors: [(String, String)] = [
    ("", "31d6cfe0d16ae931b73c59d7e0c089c0"),
    ("a", "bde52cb31de33e46245e05fbdbd6fb24"),
    ("abc", "a448017aaf21d8525fc10ae87aa6729d"),
    ("message digest", "d9130a8164549fe818874806e1c7014b"),
    ("abcdefghijklmnopqrstuvwxyz", "d79e1c308aa5bbcdeea8ed63df412da9"),
    ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "043f8582f241db351ce627e153e7f0e4"),
    ("12345678901234567890123456789012345678901234567890123456789012345678901234567890", "e33b4ddc9c38f2199c3e7b164fcc0536"),
]
for (input, expected) in vectors {
    check("MD4(\"\(input.prefix(12))\")",
          MD4.hex(MD4.hash(input.data(using: .utf8)!)), expected)
}

// eD2K single chunk == MD4(whole file)
check("eD2K single-chunk",
      ED2KHash.hex(ED2KHash.hash("abc".data(using: .utf8)!)),
      "a448017aaf21d8525fc10ae87aa6729d")

// eD2K multi chunk == MD4(MD4(chunk0) || MD4(chunk1))
let big = Data(repeating: 0x41, count: ED2KHash.chunkSize + 10)
var concat = MD4.hash(big.subdata(in: 0..<ED2KHash.chunkSize))
concat.append(MD4.hash(big.subdata(in: ED2KHash.chunkSize..<big.count)))
check("eD2K multi-chunk", ED2KHash.hex(ED2KHash.hash(big)), MD4.hex(MD4.hash(concat)))

// Streaming hash must equal in-memory hash
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("siphon-hash-test.bin")
try? big.write(to: tmp)
check("eD2K streaming", ED2KHash.hex(try! ED2KHash.hash(fileAt: tmp)), ED2KHash.hex(ED2KHash.hash(big)))
try? FileManager.default.removeItem(at: tmp)

// ed2k:// link
do {
    let l = try ED2KURI.parse("ed2k://|file|Ubuntu.iso|5368709120|0123456789ABCDEF0123456789ABCDEF|/|sources,1.2.3.4:4662|/")
    check("ed2k name", l.fileName, "Ubuntu.iso")
    check("ed2k size", String(l.fileSize), "5368709120")
    check("ed2k hash", l.hashHex, "0123456789ABCDEF0123456789ABCDEF")
    check("ed2k sources", "\(l.sources.count)@\(l.sources.first?.host ?? "-"):\(l.sources.first?.port ?? 0)", "1@1.2.3.4:4662")
} catch {
    print("FAIL  ed2k parse threw: \(error)"); failures += 1
}

print(failures == 0 ? "VectorTests: ALL PASS" : "VectorTests: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
