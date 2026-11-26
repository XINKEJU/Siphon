import Foundation

/// The output of a site adapter: a normalized, ready-to-download description of
/// one file exposed by a host page / API. Short-lived (signed / expiring) URLs
/// are carried here and only consumed at execution time; the original URL is
/// always retained separately so a failed fetch can be re-resolved.
public struct SiteAdapterResolution: Sendable, Equatable {
    public let url: URL
    public let suggestedName: String?
    public let headers: [String: String]
    public let size: Int64?
    /// `"algorithm:hex"` (e.g. `"md5:..."`, `"sha1:..."`); nil when unknown.
    public let checksum: String?

    public init(url: URL, suggestedName: String? = nil,
                headers: [String: String] = [:], size: Int64? = nil,
                checksum: String? = nil) {
        self.url = url
        self.suggestedName = suggestedName
        self.headers = headers
        self.size = size
        self.checksum = checksum
    }
}

public enum SiteAdapterError: Error, LocalizedError, Equatable {
    case notFound(String)
    case parseFailed(String)
    case upstream(String)
    case unsupported(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let s): return "链接不存在或已被移除：\(s)"
        case .parseFailed(let s): return "无法解析站点页面：\(s)"
        case .upstream(let s): return "站点返回错误：\(s)"
        case .unsupported(let s): return "该站点暂不支持：\(s)"
        case .network(let s): return "网络请求失败：\(s)"
        }
    }
}

/// A host-specific resolver. Implementations must be stateless and `Sendable`
/// so they can be invoked from the normalization entry point on any executor.
public protocol SiteAdapter: Sendable {
    /// Stable identifier persisted alongside a task so a short-lived URL can be
    /// re-resolved from the original link if it expires mid-transfer.
    var id: String { get }
    func matches(_ url: URL) -> Bool
    /// Resolve the public page/API into one or more downloadable files.
    /// Throw a `SiteAdapterError` on a real failure; never fabricate success.
    func resolve(_ url: URL, options: [String: String], session: URLSession) async throws -> [SiteAdapterResolution]
}

/// The single registry of site adapters. `URINormalizer` consults it for every
/// HTTP(S) link; the first matching adapter wins. Adding a new host is a one-
/// line append here plus a new adapter type.
public enum SiteAdapterRegistry {
    /// Order matters: more specific hosts must precede broader ones.
    public static let adapters: [SiteAdapter] = [
        GoogleDriveAdapter(),
        MediaFireAdapter(),
        RapidgatorAdapter(),
        LulustreamAdapter(),
        GofileAdapter(),
        ArchiveOrgAdapter()
    ]

    public static func adapter(for url: URL) -> SiteAdapter? {
        adapters.first { $0.matches(url) }
    }

    /// Returns `nil` when no adapter matches (caller falls back to a plain
    /// request). Throws when an adapter matches but resolution fails — the
    /// caller surfaces the real error instead of enqueuing a doomed task.
    public static func resolve(_ url: URL, options: [String: String] = [:])
        async throws -> [SiteAdapterResolution]? {
        guard let adapter = adapter(for: url) else { return nil }
        return try await adapter.resolve(url, options: options, session: .shared)
    }

    // MARK: - host matching

    /// `patterns` entries are exact hosts (`example.com`) or wildcard prefixes
    /// (`*.example.com`). Comparison is case-insensitive and ignores a leading
    /// `www.` on both sides.
    public static func matches(host: String, patterns: [String]) -> Bool {
        let h = host.lowercased().deletingPrefix("www.")
        return patterns.contains { p in
            let pat = p.lowercased().deletingPrefix("www.")
            if pat.hasPrefix("*.") {
                return h.hasSuffix(String(pat.dropFirst(2))) ||
                    h == String(pat.dropFirst(2))
            }
            return h == pat
        }
    }

    /// Convenience: does any registered adapter claim this host? (Used by the
    /// UI to show a "site adapter" badge without doing network I/O.)
    public static func isKnownSite(_ url: URL) -> Bool {
        adapter(for: url) != nil
    }
}

// MARK: - shared fetching + HTML helpers

internal enum SiteAdapterHTTP {
    /// Fetch with a short timeout and a desktop UA; follows redirects. Returns
    /// the body bytes and the HTTP response. Throws `SiteAdapterError.network`
    /// / `.upstream` so callers report real failures.
    static func fetch(_ url: URL, headers: [String: String],
                      session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.timeoutInterval = 20
        req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers where k.lowercased() != "user-agent" {
            req.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw SiteAdapterError.network("无效响应")
            }
            guard (200...399).contains(http.statusCode) else {
                throw SiteAdapterError.upstream("HTTP \(http.statusCode)")
            }
            return (data, http)
        } catch let e as SiteAdapterError {
            throw e
        } catch {
            throw SiteAdapterError.network(error.localizedDescription)
        }
    }

    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

internal enum HTML {
    /// `<title>...</title>` (first occurrence), trimmed and HTML-decoded.
    static func title(_ html: String) -> String? {
        guard let r = range(html, pattern: #"(?is)<title[^>]*>(.*?)</title>"#, group: 1) else { return nil }
        return decode(stripTags(r)).nilIfEmpty
    }

    /// `<meta property="og:title" content="...">` or `name=...`.
    static func meta(_ html: String, property: String? = nil, name: String? = nil) -> String? {
        let key = property.map { "property=\"\($0)\"" } ?? name.map { "name=\"\($0)\"" } ?? ""
        let pattern = #"(?is)<meta[^>]*\#(key)[^>]*content="([^"]*)""#
        return (range(html, pattern: pattern, group: 1)).flatMap(decode)?.nilIfEmpty
    }

    /// Value of an `<input name="..." value="...">`.
    static func inputValue(_ html: String, name: String) -> String? {
        let pattern = #"(?is)<input[^>]*name="\#(name)"[^>]*value="([^"]*)""#
        return (range(html, pattern: pattern, group: 1)).flatMap(decode)?.nilIfEmpty
            ?? (range(html, pattern: #"(?is)<input[^>]*value="([^"]*)"[^>]*name="\#(name)""#, group: 1)).flatMap(decode)?.nilIfEmpty
    }

    /// All `href` / `src` attribute values whose text matches `needle`.
    static func links(_ html: String, containing needle: String, attr: String = "href") -> [String] {
        let pattern = #"(?is)\#(attr)="([^"]*\#(NSRegularExpression.escapedPattern(for: needle))[^"]*)""#
        return matches(html, pattern: pattern, group: 1)
    }

    // MARK: - regex plumbing

    private static func range(_ s: String, pattern: String, group: Int) -> String? {
        matches(s, pattern: pattern, group: group).first
    }

    private static func matches(_ s: String, pattern: String, group: Int) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(s.startIndex..., in: s)
        var out: [String] = []
        re.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m, let r = Range(m.range(at: group), in: s) else { return }
            out.append(String(s[r]))
        }
        return out
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    static func decode(_ s: String) -> String {
        // Minimal entity decode for the handful of entities page titles use.
        var out = s
        let entities = [
            "&amp;": "&", "&quot;": "\"", "&#34;": "\"", "&apos;": "'",
            "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#32;": " "
        ]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    func deletingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

internal extension String {
    /// Strip a trailing site suffix like " - Google Drive" / " | MediaFire".
    func removingTrailingSiteSuffixes(_ suffixes: [String]) -> String {
        var s = self
        for suf in suffixes {
            if let r = s.range(of: suf, options: [.backwards, .caseInsensitive]) {
                s = String(s[..<r.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
