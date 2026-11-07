import Foundation
import CryptoKit

/// Whole-file integrity verification shared by every engine.
///
/// `HTTPDownloadEngine` verifies inline before it reports completion. Engines
/// that hand bytes to an external process (curl / OpenSSH / mount_* / HLS /
/// DASH) never see the finished bytes, so `DownloadStore` runs this verifier
/// once on the completed file instead. Specs accept `"algorithm:hex"` or bare
/// hex (defaults to SHA-256), matching `DownloadTask.checksum`.
/// Supported algorithms: md5, sha1, sha256, sha384, sha512.
public enum ChecksumVerifier {
    /// Normalize a user-supplied spec into `(algorithm, lowercase hex)`.
    public static func normalize(_ spec: String) throws -> (algorithm: String, hex: String) {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let (rawAlgo, expected): (String, String)
        if let colon = s.firstIndex(of: ":") {
            rawAlgo = String(s[s.startIndex..<colon]).lowercased()
            expected = String(s[s.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            rawAlgo = "sha256"
            expected = s
        }
        let algo: String
        switch rawAlgo {
        case "md5": algo = "md5"
        case "sha1", "sha-1": algo = "sha1"
        case "sha256", "sha-256": algo = "sha256"
        case "sha384", "sha-384": algo = "sha384"
        case "sha512", "sha-512": algo = "sha512"
        default: throw NetFailure.unsupportedChecksum(rawAlgo)
        }
        guard !expected.isEmpty, expected.allSatisfy(\.isHexDigit) else {
            throw NetFailure.unsupportedChecksum("非法哈希值")
        }
        return (algo, expected.lowercased())
    }

    /// Stream the file in 1 MiB chunks so memory stays flat for multi-GB files.
    public static func verify(fileAt url: URL, spec: String) throws -> Bool {
        let (algo, expected) = try normalize(spec)
        var hasher: any HashFunction
        switch algo {
        case "md5": hasher = Insecure.MD5()
        case "sha1": hasher = Insecure.SHA1()
        case "sha384": hasher = SHA384()
        case "sha512": hasher = SHA512()
        default: hasher = SHA256()
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return actual.lowercased() == expected
    }

    /// aria2's `--checksum=TYPE:DIGEST` syntax. Returns nil when the spec uses
    /// an algorithm aria2 cannot verify, so the task still runs and Siphon
    /// verifies the finished file itself.
    public static func aria2Spec(_ spec: String) -> String? {
        guard let (algo, hex) = try? normalize(spec) else { return nil }
        switch algo {
        case "md5": return "md5:\(hex)"
        case "sha1": return "sha-1:\(hex)"
        case "sha384": return "sha-384:\(hex)"
        case "sha512": return "sha-512:\(hex)"
        default: return "sha-256:\(hex)"
        }
    }
}
