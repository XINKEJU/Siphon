import Foundation
import CommonCrypto

/// Decrypted Click'n'Load request, kept free of app dependencies so it can be
/// compiled and tested on its own.
public struct CnLRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var sources: [URL]
    public var comment: String?
    public var password: String?
    public var receivedAt: Date

    public init(id: UUID = UUID(), sources: [URL], comment: String? = nil,
                password: String? = nil, receivedAt: Date = Date()) {
        self.id = id
        self.sources = sources
        self.comment = comment
        self.password = password
        self.receivedAt = receivedAt
    }
}

/// CnL2 decryption. Split out from the service so the crypto can be tested
/// without opening a socket.
public enum CnLCrypto {
    /// The published Click'n'Load 2 shared key.
    public static let defaultKey = "cb99b5cbc24db398"

    public enum CryptoError: Error, LocalizedError, Equatable {
        case badBase64
        case badKey
        case decryptFailed
        case notUTF8

        public var errorDescription: String? {
            switch self {
            case .badBase64: return "payload 不是有效的 Base64"
            case .badKey: return "CnL 密钥长度不正确"
            case .decryptFailed: return "CnL payload 解密失败"
            case .notUTF8: return "解密结果不是文本"
            }
        }
    }

    public static func decrypt(base64: String, key: String = defaultKey) throws -> String {
        let cleaned = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        guard let cipher = Data(base64Encoded: padded), cipher.count > 16 else {
            throw CryptoError.badBase64
        }
        let plaintext = try decryptCBC(cipher, key: Data(key.utf8))
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw CryptoError.notUTF8
        }
        return text
    }

    /// AES-128-CBC where the IV is the first 16 bytes of the payload and the
    /// remainder is PKCS#7 padded. Returns the raw plaintext bytes.
    public static func decryptCBC(_ cipher: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw CryptoError.badKey }
        guard cipher.count > kCCBlockSizeAES128 else { throw CryptoError.badBase64 }
        let iv = cipher.prefix(kCCBlockSizeAES128)
        let body = cipher.dropFirst(kCCBlockSizeAES128)

        var out = Data(count: body.count + kCCBlockSizeAES128)
        var outLength = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            guard let outBase = outBytes.bindMemory(to: UInt8.self).baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            return body.withUnsafeBytes { bodyBytes -> CCCryptorStatus in
                guard let bodyBase = bodyBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return CCCryptorStatus(kCCMemoryFailure)
                }
                return iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                    guard let ivBase = ivBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return CCCryptorStatus(kCCMemoryFailure)
                    }
                    return key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                        guard let keyBase = keyBytes.bindMemory(to: UInt8.self).baseAddress else {
                            return CCCryptorStatus(kCCMemoryFailure)
                        }
                        return CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                       CCOptions(kCCOptionPKCS7Padding),
                                       keyBase, key.count, ivBase,
                                       bodyBase, body.count, outBase, capacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.decryptFailed }
        out.removeSubrange(outLength..<out.count)
        return out
    }

    /// Encrypt for tests and for round-trip verification. Mirrors the decrypt
    /// layout: random-free IV prefix chosen by the caller.
    public static func encryptCBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw CryptoError.badKey
        }
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outLength = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            guard let outBase = outBytes.bindMemory(to: UInt8.self).baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            return plaintext.withUnsafeBytes { srcBytes -> CCCryptorStatus in
                guard let srcBase = srcBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return CCCryptorStatus(kCCMemoryFailure)
                }
                return iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                    guard let ivBase = ivBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return CCCryptorStatus(kCCMemoryFailure)
                    }
                    return key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                        guard let keyBase = keyBytes.bindMemory(to: UInt8.self).baseAddress else {
                            return CCCryptorStatus(kCCMemoryFailure)
                        }
                        return CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                       CCOptions(kCCOptionPKCS7Padding),
                                       keyBase, key.count, ivBase,
                                       srcBase, plaintext.count, outBase, capacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.decryptFailed }
        out.removeSubrange(outLength..<out.count)
        return iv + out
    }
}

/// Parses the decrypted CnL2 payload: newline-separated `key=value` lines and
/// bare links.
public enum CnLPayload {
    public static func parse(_ text: String) -> CnLRequest {
        var sources: [URL] = []
        var comment: String?
        var password: String?

        func append(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if let url = URL(string: value), url.scheme != nil {
                sources.append(url)
            } else if let decoded = value.removingPercentEncoding,
                      let url = URL(string: decoded), url.scheme != nil {
                sources.append(url)
            }
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("source=") {
                append(String(trimmed.dropFirst("source=".count)))
            } else if trimmed.hasPrefix("comment=") {
                comment = String(trimmed.dropFirst("comment=".count))
            } else if trimmed.hasPrefix("password=") {
                password = String(trimmed.dropFirst("password=".count))
            } else if trimmed.contains("=") {
                continue
            } else {
                append(trimmed)
            }
        }

        var seen = Set<String>()
        let unique = sources.filter { seen.insert($0.absoluteString).inserted }
        return CnLRequest(sources: unique, comment: comment, password: password)
    }
}