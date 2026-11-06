import Foundation

/// Decoder for the three vendor "encrypted" link formats used by Chinese download
/// managers. They are not encryption at all: a fixed prefix/suffix is glued to the
/// real URL and the whole thing is base64-encoded.
///
///   thunder://  = base64( "AA" + url + "ZZ" )
///   flashget:// = base64( "[FLASHGET]" + url + "[FLASHGET]" )
///   qqdl://     = base64( url )
///
/// Decoding is deliberately tolerant: links in the wild omit base64 padding, add
/// `&<port>` trailers, use mixed case, and sometimes wrap the URL in quotes.
public enum SpecialLinks {
    public enum Error: Swift.Error, LocalizedError {
        case emptyPayload
        case invalidBase64
        case noURLFound
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .emptyPayload: return "专用链为空"
            case .invalidBase64: return "专用链的 base64 内容无法解码"
            case .noURLFound: return "专用链中没有找到可用的下载链接"
            case .unsupported(let s): return "不支持的专用链格式：\(s)"
            }
        }
    }

    public static let schemes: Set<String> = ["thunder", "flashget", "qqdl"]

    /// Encode a plain URL, mainly for tests and for exporting links.
    public static func encode(_ url: String, as scheme: String) -> String {
        let payload: String
        switch scheme.lowercased() {
        case "thunder":  payload = "AA" + url + "ZZ"
        case "flashget": payload = "[FLASHGET]" + url + "[FLASHGET]"
        case "qqdl":     payload = url
        default:         payload = url
        }
        return scheme.lowercased() + "://" + Data(payload.utf8).base64EncodedString()
    }

    /// Decode any of the three formats into the underlying URL.
    public static func decode(_ raw: String) throws -> URL {
        guard let marker = raw.range(of: "://") else { throw Error.unsupported(raw) }
        let scheme = String(raw[raw.startIndex..<marker.lowerBound]).lowercased()
        guard schemes.contains(scheme) else { throw Error.unsupported(scheme) }

        var payload = String(raw[marker.upperBound...])
        // flashget links sometimes carry "&<port>" or a trailing query after the base64 blob.
        if scheme == "flashget", let amp = payload.firstIndex(of: "&") {
            payload = String(payload[..<amp])
        }
        if let q = payload.firstIndex(of: "?") {
            // Only strip a query when it cannot be part of the base64 blob.
            let head = String(payload[..<q])
            if !head.contains("=") { payload = head }
        }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { throw Error.emptyPayload }

        // Restore padding; URL-safe base64 is occasionally used too.
        var b64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64.removeAll { $0 == "\r" || $0 == "\n" || $0 == " " }
        let rem = b64.count % 4
        if rem == 2 { b64 += "==" } else if rem == 3 { b64 += "=" } else if rem == 1 {
            throw Error.invalidBase64
        }
        guard let data = Data(base64Encoded: b64), !data.isEmpty else { throw Error.invalidBase64 }
        // Lossy decoding is intentional: the wrapper bytes are ASCII, but a broken
        // producer may inject garbage around the URL.
        let text = String(decoding: data, as: UTF8.self)

        guard let url = firstURL(in: text) else { throw Error.noURLFound }
        return url
    }

    /// Pull the first plausible download URL out of a decoded blob.
    public static func firstURL(in text: String) -> URL? {
        let pattern = #"(?i)(?:https?|ftp|ftps|ed2k|magnet|thunder|flashget|qqdl)(?::|\?)[^\s"'<>\\\[\]]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var candidate = ns.substring(with: m.range)
        // thunder wraps the payload as "AA" + URL + "ZZ". The regex is greedy,
        // so the trailing marker would otherwise become part of the URL.
        let blob = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if blob.hasPrefix("AA") && blob.hasSuffix("ZZ"), candidate.hasSuffix("ZZ") {
            candidate.removeLast(2)
        }
        // trim common wrapper punctuation
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ",;)]}\""))
        guard let u = URL(string: candidate), u.scheme != nil else { return nil }
        return u
    }
}
