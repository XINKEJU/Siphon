import Foundation
import CommonCrypto

/// AWS Signature V4 pre-signed GET URL generator (S3, MinIO, Cloudflare R2,
/// Wasabi, Backblaze B2 S3 API, Google Cloud Storage XML API…).
///
/// A pre-signed URL is a plain HTTP(S) URL, so once it is produced the *existing*
/// aria2 transport can download it — no extra engine, no credential handling in
/// the download loop. Credentials never leave the local settings store.
public enum S3Signer {
    public enum Error: Swift.Error, LocalizedError {
        case missingCredentials
        case invalidEndpoint(String)
        case invalidURI(String)

        public var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "S3 凭据未配置。请在「设置 → 协议网关」填写 Access Key / Secret Key / Region。"
            case .invalidEndpoint(let s): return "无效的 S3 Endpoint：\(s)"
            case .invalidURI(let s): return "无效的 s3:// 链接：\(s)"
            }
        }
    }

    public struct Config: Sendable {
        public var endpoint: String      // host, optionally with :port, no scheme
        public var region: String
        public var accessKey: String
        public var secretKey: String
        public var useHTTPS: Bool

        public init(endpoint: String = "s3.amazonaws.com", region: String = "us-east-1",
                    accessKey: String = "", secretKey: String = "", useHTTPS: Bool = true) {
            self.endpoint = endpoint; self.region = region
            self.accessKey = accessKey; self.secretKey = secretKey
            self.useHTTPS = useHTTPS
        }
    }

    /// `s3://bucket/path/to/key` → signed HTTPS URL valid for `expires` seconds.
    public static func presignedGET(
        s3URI: URL, config: Config, expires: Int = 3600,
        date: Date = Date()
    ) throws -> URL {
        guard !config.accessKey.isEmpty, !config.secretKey.isEmpty else {
            throw Error.missingCredentials
        }
        guard let bucket = s3URI.host, !bucket.isEmpty else {
            throw Error.invalidURI(s3URI.absoluteString)
        }
        let key = s3URI.path.hasPrefix("/") ? String(s3URI.path.dropFirst()) : s3URI.path
        let host = config.endpoint
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !host.isEmpty else { throw Error.invalidEndpoint(config.endpoint) }

        let (amzDate, dateStamp) = timestamps(date)
        let scope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let canonicalURI = "/" + uriEncodePath(bucket) + "/" + uriEncodePath(key)

        let query: [String: String] = [
            "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
            "X-Amz-Credential": "\(config.accessKey)/\(scope)",
            "X-Amz-Date": amzDate,
            "X-Amz-Expires": String(min(max(expires, 1), 604800)),
            "X-Amz-SignedHeaders": "host"
        ]
        // A session token (STS / R2 API tokens) is part of the canonical query.
        let canonicalQuery = query.keys.sorted().map { k in
            "\(rfc3986(k))=\(rfc3986(query[k]!))"
        }.joined(separator: "&")

        let canonicalHeaders = "host:\(host)\n"
        let canonicalRequest = [
            "GET", canonicalURI, canonicalQuery, canonicalHeaders,
            "host", "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let kDate = hmacSHA256(key: Data("AWS4\(config.secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(config.region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let scheme = config.useHTTPS ? "https" : "http"
        let urlString = "\(scheme)://\(host)\(canonicalURI)?\(canonicalQuery)&X-Amz-Signature=\(signature)"
        guard let url = URL(string: urlString) else { throw Error.invalidEndpoint(urlString) }
        return url
    }

    // MARK: - crypto helpers (CommonCrypto, no external dependency)
    public static func hmacSHA256(key: Data, data: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { k in
            data.withUnsafeBytes { d in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       k.baseAddress, key.count, d.baseAddress, data.count, &out)
            }
        }
        return Data(out)
    }

    public static func sha256Hex(_ data: Data) -> String {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &out) }
        return out.map { String(format: "%02x", $0) }.joined()
    }

    public static func timestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let amz = String(format: "%04d%02d%02dT%02d%02d%02dZ",
                         c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                         c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let stamp = String(format: "%04d%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        return (amz, stamp)
    }

    /// RFC 3986 unreserved characters plus the sub-delims AWS SigV4 leaves
    /// unencoded (matching the AWS SDK `UriEncoder`).
    ///
    /// Critically, `*` MUST stay literal: encoding it as `%2A` makes the locally
    /// computed signature diverge from what S3 expects, yielding a
    /// `403 SignatureDoesNotMatch`. The default `addingPercentEncoding` encodes
    /// `*` (it is not in `url*Allowed`), which is the bug being fixed here.
    public static func rfc3986(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        allowed.insert(charactersIn: "!#$&'()*+,:;=?@[]")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func uriEncodePath(_ s: String) -> String {
        s.components(separatedBy: "/").map { rfc3986($0) }.joined(separator: "/")
    }
}
