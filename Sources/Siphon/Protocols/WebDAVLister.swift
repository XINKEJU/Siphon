import Foundation

/// WebDAV directory browsing (RFC 4918 `PROPFIND`, `Depth: 1`).
///
/// A directory URL (`webdav://host/path/`, i.e. anything with a trailing slash)
/// expands into one download task per contained file — mirroring the FTP
/// directory expansion in `URINormalizer`. Wire work goes through URLSession on
/// the rewritten http(s) URL, so Basic/Digest credentials embedded in the
/// original `webdav(s)://user:pass@host/…` link keep working.
public enum WebDAVLister {

    public struct Entry: Sendable, Equatable {
        public let name: String
        /// `href` as reported by the server (absolute path or full URL).
        public let href: String
        public let isDirectory: Bool
        public let size: Int64
    }

    public enum ListerError: Error, LocalizedError {
        case notWebDAV
        case listFailed(String)

        public var errorDescription: String {
            switch self {
            case .notWebDAV: return "不是 WebDAV 链接"
            case .listFailed(let s): return "列出 WebDAV 目录失败：\(s)"
            }
        }
    }

    /// A trailing "/" marks a directory. `URL.path` strips it, so consult the
    /// raw string's path portion (same technique as `FTPDirectoryLister`).
    public static func looksLikeDirectory(_ url: URL) -> Bool {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        guard let s = comps?.string, let sep = s.range(of: "://") else {
            return url.path.isEmpty || url.path == "/"
        }
        let after = s[sep.upperBound...]
        guard let slash = after.firstIndex(of: "/") else { return true } // no path
        return after[slash...].hasSuffix("/")
    }

    /// Fetch the listing (PROPFIND Depth:1) and return child entries,
    /// excluding the collection itself.
    public static func list(_ url: URL, options: [String: String] = [:]) async throws -> [Entry] {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"""
<?xml version="1.0" encoding="utf-8"?>
<propfind xmlns="DAV:"><prop><resourcetype/><getcontentlength/><displayname/></prop></propfind>
"""#.utf8)
        for (k, v) in options where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ListerError.listFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let all = parse(data, baseURL: url)
        let basePath = url.path.hasSuffix("/") ? url.path : url.path + "/"
        // Drop the collection itself: servers echo the requested href first.
        return all.filter { e in
            guard let u = URL(string: e.href, relativeTo: url)?.absoluteURL else { return false }
            var p = u.path
            if !p.hasSuffix("/") { p += "/" }
            return p != basePath
        }
    }

    // MARK: - multistatus parsing

    public static func parse(_ data: Data, baseURL: URL) -> [Entry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []

        private var href = ""
        private var displayName = ""
        private var size: Int64 = 0
        private var isDir = false
        private var capture: Capture?
        private var buffer = ""

        private enum Capture { case href, displayname, contentlength }

        private func local(_ elementName: String) -> String {
            elementName.components(separatedBy: ":").last ?? elementName
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch local(elementName) {
            case "response":
                href = ""; displayName = ""; size = 0; isDir = false
            case "href":
                capture = .href; buffer = ""
            case "displayname":
                capture = .displayname; buffer = ""
            case "getcontentlength":
                capture = .contentlength; buffer = ""
            case "collection":
                // Empty element inside <resourcetype> — no end-tag payload.
                isDir = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capture != nil else { return }
            buffer += string
            switch capture {
            case .href: href += string
            case .displayname: displayName += string
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch local(elementName) {
            case "getcontentlength":
                size = Int64(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                capture = nil; buffer = ""
            case "href", "displayname":
                capture = nil; buffer = ""
            case "response":
                let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = href.split(separator: "/").last
                    .flatMap { $0.removingPercentEncoding } ?? href
                entries.append(Entry(name: name.isEmpty ? fallback : name,
                                     href: href, isDirectory: isDir, size: size))
            default:
                break
            }
        }
    }
}
