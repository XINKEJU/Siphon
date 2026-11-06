import Foundation

/// Batch import: M3U / M3U8-text / PLS / ASX / WPL / plain URL lists / JSON arrays.
///
/// A download manager is expected to accept "a list of links", not just one link.
/// This parser deliberately does not interpret `.m3u8` *media playlists* as batches —
/// those are HLS streams and belong to HLSEngine. Only classic playlist formats and
/// newline-separated URL lists are expanded here.
public enum PlaylistImporter {
    public struct Entry: Sendable {
        public let url: URL
        public let name: String?
        public init(url: URL, name: String? = nil) { self.url = url; self.name = name }
    }

    /// Parse playlist text. `baseURL` resolves relative entries.
    public static func parse(_ text: String, baseURL: URL? = nil) -> [Entry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("[") , let json = parseJSON(trimmed, baseURL: baseURL) { return json }
        if trimmed.hasPrefix("<"), let xml = parseXML(trimmed, baseURL: baseURL) { return xml }
        if trimmed.lowercased().hasPrefix("[playlist]") { return parsePLS(trimmed, baseURL: baseURL) }

        // M3U / plain text: one URL per line, `#EXTINF` carries the display name.
        var result: [Entry] = []
        var pendingName: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                // #EXTINF:123,Artist - Title
                if let comma = line.firstIndex(of: ",") {
                    let n = String(line[line.index(after: comma)...])
                        .trimmingCharacters(in: .whitespaces)
                    pendingName = n.isEmpty ? nil : n
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            if let url = makeURL(line, baseURL: baseURL) {
                result.append(Entry(url: url, name: pendingName))
            }
            pendingName = nil
        }
        return result
    }

    /// Extract plaintext URLs from arbitrary multi-line text (e.g. pasted from a page).
    public static func extractURLs(from text: String, limit: Int = 500) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for line in text.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let u = makeURL(s, baseURL: nil),
                  let scheme = u.scheme?.lowercased(), !scheme.isEmpty else { continue }
            let key = u.absoluteString
            if seen.insert(key).inserted {
                out.append(Entry(url: u))
                if out.count >= limit { break }
            }
        }
        return out
    }

    // MARK: - formats
    private static func parsePLS(_ text: String, baseURL: URL?) -> [Entry] {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).lowercased()
            let value = String(line[line.index(after: eq)...])
            if key.hasPrefix("file"), let n = Int(key.dropFirst("file".count)) { files[n] = value }
            if key.hasPrefix("title"), let n = Int(key.dropFirst("title".count)) { titles[n] = value }
        }
        return files.keys.sorted().compactMap { n in
            guard let s = files[n], let u = makeURL(s, baseURL: baseURL) else { return nil }
            return Entry(url: u, name: titles[n])
        }
    }

    private static func parseXML(_ text: String, baseURL: URL?) -> [Entry]? {
        // ASX <ref href="…">, WPL <media src="…">, XSPF <location>…</location>.
        let patterns = [
            #"(?i)<ref[^>]+href\s*=\s*["']([^"']+)["']"#,
            #"(?i)<media[^>]+src\s*=\s*["']([^"']+)["']"#,
            #"(?i)<location>\s*([^<]+?)\s*</location>"#
        ]
        var out: [Entry] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges > 1 {
                let s = ns.substring(with: m.range(at: 1))
                if let u = makeURL(s, baseURL: baseURL) { out.append(Entry(url: u)) }
            }
        }
        return out.isEmpty ? nil : dedupe(out)
    }

    private static func parseJSON(_ text: String, baseURL: URL?) -> [Entry]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var strings: [String] = []
        if let arr = obj as? [Any] {
            for item in arr {
                if let s = item as? String { strings.append(s) }
                else if let d = item as? [String: Any], let s = d["url"] as? String { strings.append(s) }
            }
        } else if let d = obj as? [String: Any], let arr = d["urls"] as? [String] {
            strings = arr
        }
        let out = strings.compactMap { s -> Entry? in
            guard let u = makeURL(s, baseURL: baseURL) else { return nil }
            return Entry(url: u)
        }
        return out.isEmpty ? nil : dedupe(out)
    }

    private static func dedupe(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.url.absoluteString).inserted }
    }

    private static func makeURL(_ s: String, baseURL: URL?) -> URL? {
        let value = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
        let u = URL(string: value, relativeTo: baseURL) ?? URL(string: value)
        guard let u, let scheme = u.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        return u.absoluteURL
    }
}
