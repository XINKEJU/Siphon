import Foundation

// MARK: - Google Drive

public struct GoogleDriveAdapter: SiteAdapter {
    public let id = "google-drive"

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return SiteAdapterRegistry.matches(host: host, patterns: [
            "drive.google.com", "docs.google.com", "drive.usercontent.google.com"
        ])
    }

    public func resolve(_ url: URL, options: [String: String], session: URLSession)
        async throws -> [SiteAdapterResolution] {
        let (data, _) = try await SiteAdapterHTTP.fetch(url, headers: options, session: session)
        guard let html = String(data: data, encoding: .utf8) else {
            throw SiteAdapterError.parseFailed("页面不是 UTF-8 文本")
        }
        return [try Self.parse(html: html, url: url)]
    }

    static func parse(html: String, url: URL) throws -> SiteAdapterResolution {
        guard let fileID = extractFileID(from: url) ?? extractFileID(fromHTML: html) else {
            throw SiteAdapterError.parseFailed("未找到文件 ID")
        }
        let rawTitle = HTML.meta(html, property: "og:title") ?? HTML.title(html) ?? ""
        let name = rawTitle.removingTrailingSiteSuffixes([
            " - Google Drive", " - Google Docs", " - Google Sheets",
            " - Google Slides", " - Google 云端硬盘"
        ])
        let confirm = HTML.inputValue(html, name: "confirm") ?? "t"
        guard let final = URL(string: "https://drive.usercontent.google.com/download" +
                                   "?id=\(fileID)&export=download&confirm=\(confirm)") else {
            throw SiteAdapterError.parseFailed("无法构造下载链接")
        }
        return SiteAdapterResolution(url: final,
                                     suggestedName: name.isEmpty ? nil : name,
                                     headers: ["Referer": "https://drive.google.com/"])
    }

    private static func extractFileID(from url: URL) -> String? {
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty {
            return id
        }
        let parts = url.pathComponents
        if let dIndex = parts.firstIndex(of: "d"), dIndex + 1 < parts.count {
            let candidate = parts[dIndex + 1]
            if candidate != "view", candidate != "edit", !candidate.isEmpty {
                return candidate
            }
        }
        // `/file/<id>` form (no /d/ segment)
        if parts.first == "/", parts.count > 2, parts[1] == "file" {
            return parts[2]
        }
        return nil
    }

    private static func extractFileID(fromHTML html: String) -> String? {
        // `https://drive.google.com/file/d/<ID>/` embedded anywhere in the page.
        let pattern = #"drive\.google\.com/file/d/([A-Za-z0-9_-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(html.startIndex..., in: html)
        guard let m = re.firstMatch(in: html, range: r),
              let s = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[s])
    }
}

// MARK: - MediaFire

public struct MediaFireAdapter: SiteAdapter {
    public let id = "mediafire"

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return SiteAdapterRegistry.matches(host: host, patterns: ["mediafire.com", "*.mediafire.com"])
    }

    public func resolve(_ url: URL, options: [String: String], session: URLSession)
        async throws -> [SiteAdapterResolution] {
        let (data, _) = try await SiteAdapterHTTP.fetch(url, headers: options, session: session)
        guard let html = String(data: data, encoding: .utf8) else {
            throw SiteAdapterError.parseFailed("页面不是 UTF-8 文本")
        }
        return [try Self.parse(html: html, url: url)]
    }

    static func parse(html: String, url: URL) throws -> SiteAdapterResolution {
        let direct = HTML.attribute(html, elementID: "downloadButton", attr: "href")
            ?? HTML.links(html, containing: ".mediafire.com").first
            ?? HTML.links(html, containing: "/download/").first
        guard let link = direct, let directURL = URL(string: link) else {
            throw SiteAdapterError.upstream("未找到下载链接（可能需要登录或文件已删除）")
        }
        let name = (HTML.meta(html, property: "og:title") ?? HTML.title(html) ?? "")
            .removingTrailingSiteSuffixes([" | MediaFire", " - MediaFire"])
        return SiteAdapterResolution(url: directURL, suggestedName: name.isEmpty ? nil : name)
    }
}

// MARK: - Rapidgator

public struct RapidgatorAdapter: SiteAdapter {
    public let id = "rapidgator"

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return SiteAdapterRegistry.matches(host: host, patterns: ["rapidgator.net", "rapidgator.com"])
    }

    public func resolve(_ url: URL, options: [String: String], session: URLSession)
        async throws -> [SiteAdapterResolution] {
        let (data, _) = try await SiteAdapterHTTP.fetch(url, headers: options, session: session)
        guard let html = String(data: data, encoding: .utf8) else {
            throw SiteAdapterError.parseFailed("页面不是 UTF-8 文本")
        }
        return [try Self.parse(html: html, url: url)]
    }

    static func parse(html: String, url: URL) throws -> SiteAdapterResolution {
        // Direct download token links look like `…/files/<token>/<name>` or the
        // premium download button href.
        let candidate = HTML.attribute(html, elementID: "dl_link", attr: "href")
            ?? HTML.links(html, containing: "/files/").first
            ?? HTML.links(html, containing: "/download/").first
        guard let link = candidate, let directURL = URL(string: link, relativeTo: url)?.absoluteURL else {
            throw SiteAdapterError.upstream("未解析到下载链接（免费下载可能需要等待或验证码，付费链接请登录账号）")
        }
        let name = (HTML.title(html) ?? "")
            .removingTrailingSiteSuffixes([" - Rapidgator", " - rapidgator.net", " | Rapidgator"])
        return SiteAdapterResolution(url: directURL, suggestedName: name.isEmpty ? nil : name)
    }
}

// MARK: - Lulustream (video host → direct mp4 / m3u8)

public struct LulustreamAdapter: SiteAdapter {
    public let id = "lulustream"

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return SiteAdapterRegistry.matches(host: host, patterns: [
            "lulustream.com", "luluvdo.com", "*.lulustream.com"
        ])
    }

    public func resolve(_ url: URL, options: [String: String], session: URLSession)
        async throws -> [SiteAdapterResolution] {
        let (data, _) = try await SiteAdapterHTTP.fetch(url, headers: options, session: session)
        guard let html = String(data: data, encoding: .utf8) else {
            throw SiteAdapterError.parseFailed("页面不是 UTF-8 文本")
        }
        return [try Self.parse(html: html, url: url)]
    }

    static func parse(html: String, url: URL) throws -> SiteAdapterResolution {
        let source = extractVideoSource(html)
        guard let raw = source, let videoURL = URL(string: raw, relativeTo: url)?.absoluteURL else {
            throw SiteAdapterError.parseFailed("未找到视频源（可能需要登录或已移除）")
        }
        let name = (HTML.meta(html, property: "og:title") ?? HTML.title(html) ?? "")
            .removingTrailingSiteSuffixes([" - Lulustream", " - Watch online", " | Lulustream"])
        return SiteAdapterResolution(url: videoURL, suggestedName: name.isEmpty ? nil : name)
    }

    private static func extractVideoSource(_ html: String) -> String? {
        // <source src="…">
        if let s = HTML.attribute(html, elementTag: "source", attr: "src") { return s }
        // "file":"https://….mp4" or .m3u8 inside a player config
        let pattern = #"(?i)"file"\s*:\s*"(https?://[^"]+\.(?:mp4|m3u8|webm|flv)[^"]*)""#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            return String(html[r])
        }
        // file: '…' (single-quoted)
        let p2 = #"(?i)file\s*:\s*'(https?://[^']+\.(?:mp4|m3u8|webm|flv)[^']*)'"#
        if let re = try? NSRegularExpression(pattern: p2),
           let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            return String(html[r])
        }
        return nil
    }
}

// MARK: - Gofile (public folder API → multiple files)

public struct GofileAdapter: SiteAdapter {
    public let id = "gofile"

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return SiteAdapterRegistry.matches(host: host, patterns: ["gofile.io", "gofile.me", "*.gofile.io"])
    }

    public func resolve(_ url: URL, options: [String: String], session: URLSession)
        async throws -> [SiteAdapterResolution] {
        guard let contentId = Self.extractContentID(url) else {
            throw SiteAdapterError.parseFailed("未找到 Gofile 内容 ID")
        }
        guard let api = URL(string: "https://api.gofile.io/getContent?contentId=\(contentId)") else {
            throw SiteAdapterError.parseFailed("无法构造 API 地址")
        }
        let (data, _) = try await SiteAdapterHTTP.fetch(api, headers: options, session: session)
        return try Self.parse(data: data, contentId: contentId)
    }

    static func extractContentID(_ url: URL) -> String? {
        let parts = url.pathComponents
        if let i = parts.firstIndex(where: { ["d", "downloads"].contains($0) }),
           i + 1 < parts.count {
            return parts[i + 1]
        }
        // gofile.io/d/<id> with trailing slash may leave last component empty
        return parts.count > 2 ? parts[parts.count - 1] : nil
    }

    static func parse(data: Data, contentId: String) throws -> [SiteAdapterResolution] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = obj["data"] as? [String: Any],
              let contents = dataDict["contents"] as? [String: [String: Any]] else {
            // Maybe `contents` is an array, or status is not ok.
            throw SiteAdapterError.parseFailed("Gofile API 响应无法解析（可能是私有内容或需要 Token）")
        }
        var out: [SiteAdapterResolution] = []
        for (_, file) in contents {
            guard let type = file["type"] as? String, type == "file",
                  let link = file["link"] as? String,
                  let fileURL = URL(string: link) else { continue }
            let name = file["name"] as? String
            let size = (file["size"] as? Int64) ?? (file["size"] as? Int).map(Int64.init)
            let md5 = file["md5"] as? String
            out.append(SiteAdapterResolution(
                url: fileURL,
                suggestedName: name,
                size: size,
                checksum: md5.map { "md5:\($0)" }))
            if out.count >= 200 { break }
        }
        guard !out.isEmpty else {
            throw SiteAdapterError.notFound("Gofile 内容为空或已删除：\(contentId)")
        }
        return out
    }
}

// MARK: - Archive.org (metadata API → original files)

public struct ArchiveOrgAdapter: SiteAdapter {
    public let id = "archive.org"

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return SiteAdapterRegistry.matches(host: host, patterns: ["archive.org", "*.archive.org"])
    }

    public func resolve(_ url: URL, options: [String: String], session: URLSession)
        async throws -> [SiteAdapterResolution] {
        guard let identifier = Self.extractIdentifier(url) else {
            throw SiteAdapterError.parseFailed("未找到 archive.org 标识符")
        }
        guard let api = URL(string: "https://archive.org/metadata/\(identifier)") else {
            throw SiteAdapterError.parseFailed("无法构造元数据地址")
        }
        let (data, _) = try await SiteAdapterHTTP.fetch(api, headers: options, session: session)
        return try Self.parse(data: data, identifier: identifier)
    }

    static func extractIdentifier(_ url: URL) -> String? {
        let parts = url.pathComponents
        if let i = parts.firstIndex(where: { ["details", "download", "stream"].contains($0) }),
           i + 1 < parts.count, !parts[i + 1].isEmpty {
            return parts[i + 1]
        }
        return nil
    }

    static func parse(data: Data, identifier: String) throws -> [SiteAdapterResolution] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = obj["files"] as? [[String: Any]] else {
            throw SiteAdapterError.parseFailed("archive.org 元数据无法解析")
        }
        var out: [SiteAdapterResolution] = []
        for file in files {
            let name = file["name"] as? String ?? ""
            guard !name.isEmpty else { continue }
            let source = (file["source"] as? String) ?? ""
            // Only originals are user-facing downloads; derivatives (thumbnails,
            // derived text/zips, metadata, generated torrent) are skipped. Items
            // that omit `source` entirely are kept so an incomplete metadata
            // record still yields its files.
            if source != "original" && source != "" { continue }
            if name.hasSuffix("_thumb.jpg") || name.hasSuffix("_itemimage.jpg") { continue }
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            guard let fileURL = URL(string: "https://archive.org/download/\(identifier)/\(encoded)") else {
                continue
            }
            let size = (file["size"] as? String).flatMap(Int64.init)
                ?? (file["size"] as? Int).map(Int64.init)
            let sha1 = file["sha1"] as? String
            let md5 = file["md5"] as? String
            let checksum: String? = sha1.map { "sha1:\($0)" } ?? md5.map { "md5:\($0)" }
            out.append(SiteAdapterResolution(url: fileURL, suggestedName: name,
                                             size: size, checksum: checksum))
            if out.count >= 200 { break }
        }
        guard !out.isEmpty else {
            throw SiteAdapterError.notFound("archive.org 条目无可下载文件：\(identifier)")
        }
        return out
    }
}

// MARK: - extra HTML attribute helpers

internal extension HTML {
    /// `href`/`src` of an element carrying `id="…"` (attribute order agnostic).
    static func attribute(_ html: String, elementID: String, attr: String) -> String? {
        let p1 = #"(?is)<\w[^>]*\bid="\#(NSRegularExpression.escapedPattern(for: elementID))"[^>]*\#(attr)="([^"]*)""#
        let p2 = #"(?is)<\w[^>]*\#(attr)="([^"]*)"[^>]*\bid="\#(NSRegularExpression.escapedPattern(for: elementID))""#
        return firstMatch(html, pattern: p1, group: 1) ?? firstMatch(html, pattern: p2, group: 1)
    }

    /// First occurrence of `<tag … attr="…">`.
    static func attribute(_ html: String, elementTag: String, attr: String) -> String? {
        let pattern = #"(?is)<\#(elementTag)[^>]*\#(attr)="([^"]*)""#
        return firstMatch(html, pattern: pattern, group: 1)
    }

    private static func firstMatch(_ s: String, pattern: String, group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }
}
