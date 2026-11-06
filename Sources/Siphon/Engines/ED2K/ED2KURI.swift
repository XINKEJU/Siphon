import Foundation

/// Parsed `ed2k://` file link.
public struct ED2KLink: Sendable {
    public let fileName: String
    public let fileSize: Int64
    public let hashHex: String
    /// Optional `|sources,host:port,...|` entries.
    public let sources: [(host: String, port: Int)]
    public let raw: String
}

public enum ED2KParseError: Error, LocalizedError {
    case notAnED2KLink
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notAnED2KLink: return "不是有效的 ed2k:// 链接。"
        case .malformed(let s): return "ed2k 链接格式错误：\(s)"
        }
    }
}

/// Parses eMule-style links, e.g.
/// `ed2k://|file|Ubuntu.iso|5368709120|0123456789ABCDEF0123456789ABCDEF|/`
/// `ed2k://|file|Name.zip|12345|AABB..|/|sources,1.2.3.4:4662|/`
public enum ED2KURI {
    public static func parse(_ url: URL) throws -> ED2KLink {
        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard raw.lowercased().hasPrefix("ed2k://") else { throw ED2KParseError.notAnED2KLink }
        return try parse(raw)
    }

    public static func parse(_ raw: String) throws -> ED2KLink {
        // Strip the scheme, then split on "|" keeping empty fields so we can
        // recognise the terminating "/".
        let body = raw.hasPrefix("ed2k://") ? String(raw.dropFirst("ed2k://".count)) : raw
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, parts[0].isEmpty, parts[1] == "file" else {
            throw ED2KParseError.malformed("期望 ed2k://|file|...|/")
        }
        let name = parts[2]
        guard let size = Int64(parts[3]) else { throw ED2KParseError.malformed("文件大小无效") }
        let hash = parts[4].uppercased()
        guard hash.count == 32, hash.allSatisfy({ $0.isHexDigit }) else {
            throw ED2KParseError.malformed("eD2K 哈希必须是 32 位十六进制")
        }

        var sources: [(host: String, port: Int)] = []
        for p in parts.dropFirst(5) {
            guard p.hasPrefix("sources,") else { continue }
            for entry in p.dropFirst("sources,".count).split(separator: ",") {
                let hp = entry.split(separator: ":", maxSplits: 1)
                if hp.count == 2, let port = Int(hp[1]) {
                    sources.append((String(hp[0]), port))
                }
            }
        }
        return ED2KLink(fileName: name, fileSize: size, hashHex: hash, sources: sources, raw: raw)
    }
}
