import Foundation

/// RFC 6266 / RFC 5987 `Content-Disposition` filename parsing.
///
/// Servers commonly expose a friendly name only in the header (`filename*=UTF-8''…`),
/// while the URL path is an opaque id (`/download?id=123`). Without this parser
/// such downloads land as `download` / `123` with no extension.
public enum ContentDisposition {
    /// Extract a safe, single-component filename from a header value.
    public static func filename(from value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var params: [String: String] = [:]
        for part in splitParameters(value) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(part[part.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") {
                val.removeFirst()
                if val.hasSuffix("\"") { val.removeLast() }
            }
            params[key] = val
        }
        // RFC 5987 extended parameter wins over the plain fallback.
        if let extended = params["filename*"], let decoded = decodeExtended(extended) {
            return safeName(decoded)
        }
        if let plain = params["filename"] {
            return safeName(plain.replacingOccurrences(of: "\\\"", with: "\""))
        }
        return nil
    }

    /// Split `attachment; filename="a;b"; size=1` on semicolons that are not
    /// inside a quoted string.
    private static func splitParameters(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for ch in value {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && quoted {
                escaped = true
                current.append(ch)
                continue
            }
            if ch == "\"" { quoted.toggle() }
            if ch == ";" && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// `UTF-8''%E4%B8%AD.mp4` → `中.mp4`; unsupported charsets fall back to UTF-8.
    private static func decodeExtended(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("\"") { value.removeFirst() }
        if value.hasSuffix("\"") { value.removeLast() }
        var charset = "utf-8"
        var encoded = value
        if let first = value.firstIndex(of: "'") {
            charset = String(value[..<first]).lowercased()
            let rest = value[value.index(after: first)...]
            if let second = rest.firstIndex(of: "'") {
                encoded = String(rest[rest.index(after: second)...])
            } else {
                encoded = String(rest)
            }
        }
        encoded = encoded.replacingOccurrences(of: "+", with: " ")
        if charset == "iso-8859-1" || charset == "latin1" {
            let bytes = encoded.removingPercentEncoding ?? encoded
            return String(bytes: Array(bytes.utf8), encoding: .isoLatin1) ?? bytes
        }
        return encoded.removingPercentEncoding ?? encoded
    }

    /// Keep only the last path component and strip control characters so a
    /// hostile header can never escape the download directory.
    public static func safeName(_ raw: String) -> String? {
        var name = raw
        name = name.replacingOccurrences(of: "\\", with: "/")
        name = name.split(separator: "/").last.map(String.init) ?? name
        name = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "." || name == ".." || name.isEmpty { return nil }
        // Windows reserved names are harmless on APFS, but leading dots create
        // invisible files in Finder; strip them.
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }
}
