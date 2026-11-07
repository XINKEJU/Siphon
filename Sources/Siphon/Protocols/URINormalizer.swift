import Foundation

/// The single place where a pasted link becomes one or more concrete download requests.
///
/// Design goal: keep the *transport* layer small. Vendor wrappers, gateways and
/// batch playlists are all reduced here to plain URLs plus headers, so aria2 / libcurl /
/// the native engines only ever see something they already know how to fetch.
public struct NormalizedRequest: Sendable {
    public var url: URL
    /// Original protocol, kept for the UI badge even after rewriting the URL.
    public var proto: DownloadProtocol
    /// Exactly what the user pasted (used by the detail view and for retry).
    public var origin: String
    public var suggestedName: String?
    public var options: [String: String]
    /// Expected integrity hash ("algorithm:hex"), e.g. from a Metalink document.
    public var checksum: String?
    /// Per-piece SHA-1 hashes + piece length (Metalink `<pieces>`), for
    /// block-wise verification with surgical bad-range re-download.
    public var pieceHashes: [String]
    public var pieceLength: Int64
    /// Alternative sources for the same file (Metalink mirror list).
    public var mirrors: [URL]

    public init(url: URL, proto: DownloadProtocol, origin: String,
                suggestedName: String? = nil, options: [String: String] = [:],
                checksum: String? = nil, mirrors: [URL] = [],
                pieceHashes: [String] = [], pieceLength: Int64 = 0) {
        self.url = url; self.proto = proto; self.origin = origin
        self.suggestedName = suggestedName; self.options = options
        self.checksum = checksum; self.mirrors = mirrors
        self.pieceHashes = pieceHashes; self.pieceLength = pieceLength
    }
}

public enum NormalizerError: Error, LocalizedError {
    case emptyInput
    case malformedURL(String)
    case unsupportedScheme(String)
    case playlistEmpty(String)
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "链接为空"
        case .malformedURL(let s): return "无法解析链接：\(s)"
        case .unsupportedScheme(let s): return "不支持的协议：\(s)://"
        case .playlistEmpty(let s): return "列表中没有可用链接：\(s)"
        case .fetchFailed(let s): return "无法读取列表：\(s)"
        }
    }
}

public enum URINormalizer {
    /// Resolve one user input into one or many requests. Playlists and multi-line
    /// pastes expand; everything else returns exactly one request.
    public static func normalize(
        _ raw: String,
        options: [String: String] = [:],
        settings: ProtocolSettings = .load(),
        depth: Int = 0
    ) async throws -> [NormalizedRequest] {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw NormalizerError.emptyInput }
        guard depth < 3 else { throw NormalizerError.playlistEmpty("嵌套层数过多") }

        // Multi-line paste = a batch (M3U / URL list), unless it is a data: URI.
        if input.contains("\n") && !input.lowercased().hasPrefix("data:") {
            let entries = PlaylistImporter.parse(input)
            guard !entries.isEmpty else { throw NormalizerError.playlistEmpty("多行文本") }
            return try await expand(entries, origin: input, options: options,
                                    settings: settings, depth: depth)
        }

        // Parameterized URI (aria2/curl): `img_{001..100}.jpg`, `{a,b,c}.zip`
        // expand into one request per variant. Capped so a typo cannot flood
        // the queue; a single `{...}` group that yields one variant passes
        // through untouched.
        if input.contains("{"), !input.lowercased().hasPrefix("data:") {
            let expanded = expandBraces(input)
            if expanded.count > 1 {
                let entries = expanded.compactMap(URL.init(string:))
                    .map { PlaylistImporter.Entry(url: $0) }
                guard !entries.isEmpty else { throw NormalizerError.malformedURL(input) }
                return try await expand(entries, origin: input, options: options,
                                        settings: settings, depth: depth)
            }
        }

        guard let url = URL(string: input), url.scheme != nil else {
            throw NormalizerError.malformedURL(input)
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let proto = DownloadProtocol.detect(from: url)

        switch proto {
        case .thunder, .flashget, .qqdl:
            let inner = try SpecialLinks.decode(input)
            var reqs = try await normalize(inner.absoluteString, options: options,
                                           settings: settings, depth: depth + 1)
            for i in reqs.indices {
                reqs[i].proto = proto
                reqs[i].origin = input
            }
            return reqs

        case .ipfs, .ipns:
            let gateway = settings.ipfsGateway
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let kind = proto == .ipfs ? "ipfs" : "ipns"
            let cid = url.host ?? ""
            // `ipfs://CID` has no path (or just "/"). Appending "/" produces
            // `<gateway>/ipfs/CID/`, which public gateways answer with 404.
            // Only a real sub-path may be forwarded.
            let path = url.path
            let sub: String
            if path.isEmpty || path == "/" { sub = "" }
            else { sub = path.hasPrefix("/") ? path : "/" + path }
            guard !gateway.isEmpty, !cid.isEmpty,
                  let target = URL(string: "\(gateway)/\(kind)/\(cid)\(sub)") else {
                throw NormalizerError.malformedURL(input)
            }
            return [NormalizedRequest(url: target, proto: proto, origin: input,
                                      suggestedName: url.lastPathComponent.isEmpty
                                        ? nil : url.lastPathComponent,
                                      options: options)]

        case .webdav, .webdavs:
            // The native HTTP engine speaks HTTP Basic/Digest auth embedded in the URL.
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw NormalizerError.malformedURL(input)
            }
            comps.scheme = proto == .webdavs ? "https" : "http"
            guard let target = comps.url else { throw NormalizerError.malformedURL(input) }
            // Directory URLs (trailing "/") expand into one task per contained
            // file via PROPFIND Depth:1 — the WebDAV counterpart of the FTP
            // directory expansion.
            if WebDAVLister.looksLikeDirectory(target) {
                let entries = try await WebDAVLister.list(target, options: options)
                let files = entries.filter { !$0.isDirectory }
                guard !files.isEmpty else {
                    throw NormalizerError.fetchFailed("WebDAV 目录仅含子目录：\(input)")
                }
                return files.compactMap { e in
                    guard let fileURL = URL(string: e.href, relativeTo: target)?.absoluteURL
                    else { return nil }
                    return NormalizedRequest(
                        url: fileURL,
                        proto: proto == .webdavs ? .https : .http,
                        origin: input, suggestedName: e.name, options: options)
                }
            }
            return [NormalizedRequest(url: target, proto: proto, origin: input, options: options)]

        case .afp:
            // Apple removed the AFP client (mount_afp / NetFS afp.bundle) in
            // modern macOS; NetFSMountURLSync(afp://) now returns ENOTSUP. AFP
            // servers almost always expose the same share over SMB, which the
            // system curl handles natively, so rewrite instead of dropping the
            // protocol entirely. The original link is kept in `origin` for retry.
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw NormalizerError.malformedURL(input)
            }
            comps.scheme = "smb"
            guard let target = comps.url else { throw NormalizerError.malformedURL(input) }
            return [NormalizedRequest(url: target, proto: .smb, origin: input, options: options)]

        case .s3:
            let signed = try S3Signer.presignedGET(s3URI: url, config: settings.s3)
            return [NormalizedRequest(url: signed, proto: proto, origin: input,
                                      suggestedName: url.lastPathComponent.isEmpty
                                        ? nil : url.lastPathComponent,
                                      options: options)]

        case .playlist:
            let text: String
            if scheme == "file" {
                guard let d = try? Data(contentsOf: url),
                      let s = String(data: d, encoding: .utf8) else {
                    throw NormalizerError.fetchFailed(url.path)
                }
                text = s
            } else {
                var req = URLRequest(url: url)
                for (k, v) in options where !["dir", "out"].contains(k.lowercased()) {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                guard let (d, _) = try? await URLSession.shared.data(for: req),
                      let s = String(data: d, encoding: .utf8) else {
                    throw NormalizerError.fetchFailed(input)
                }
                text = s
            }
            let entries = PlaylistImporter.parse(text, baseURL: scheme == "file" ? nil : url)
            guard !entries.isEmpty else { throw NormalizerError.playlistEmpty(input) }
            return try await expand(entries, origin: input, options: options,
                                    settings: settings, depth: depth)

        case .ftp:
            // Directory URLs expand into one task per file (recursive listing).
            // aria2 cannot do this; curl's MLSD/EPSV backend handles the wire work.
            guard !URISchemes.all.contains(scheme) else {
                throw NormalizerError.unsupportedScheme(scheme)
            }
            if FTPDirectoryLister.looksLikeDirectory(url) {
                let entries = try await FTPDirectoryLister.list(url, options: options)
                guard !entries.isEmpty else {
                    throw NormalizerError.fetchFailed("FTP 目录为空：\(input)")
                }
                var out: [NormalizedRequest] = []
                for e in entries where !e.isDirectory {
                    let fileURL = url.appendingPathComponent(e.name)
                    out.append(NormalizedRequest(url: fileURL, proto: .ftp,
                                                 origin: input,
                                                 suggestedName: e.name,
                                                 options: options))
                }
                // If the listing surfaced only subdirectories (no files), surface an
                // error rather than silently enqueuing nothing.
                if out.isEmpty { throw NormalizerError.fetchFailed("FTP 目录仅含子目录：\(input)") }
                return out
            }
            return [NormalizedRequest(url: url, proto: proto, origin: input, options: options)]

        case .metalink:
            // Expand Metalink v3/v4 documents natively: one task per <file> with
            // priority-ordered mirrors + checksum, so the native HTTP engine gets
            // multi-CDN failover and integrity verification (RFC 5854). If the
            // document cannot be fetched/parsed (HTML error page, redirect to a
            // plain file), fall back to the plain passthrough request.
            if let reqs = await expandMetalink(url, origin: input, options: options) {
                return reqs
            }
            return [NormalizedRequest(url: url, proto: proto, origin: input, options: options)]

        case .http, .https, .sftp, .bittorrent, .magnet,
             .ed2k, .hls, .dash, .ftps, .smb, .smbs, .nfs,
             .scp, .rsync, .file, .data, .curl:
            if !URISchemes.all.contains(scheme) && scheme != "file" && scheme != "data" {
                throw NormalizerError.unsupportedScheme(scheme)
            }
            return [NormalizedRequest(url: url, proto: proto, origin: input, options: options)]
        }
    }

    /// Fetch (or read from disk) a Metalink document and expand it into one
    /// request per `<file>`. Returns `nil` when the input is not a parseable
    /// Metalink document, so the caller can fall back to the plain path.
    private static func expandMetalink(_ url: URL, origin: String,
                                       options: [String: String]) async -> [NormalizedRequest]? {
        let text: String
        if url.isFileURL {
            guard let d = try? Data(contentsOf: url),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            text = s
        } else {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            for (k, v) in options where !["dir", "out"].contains(k.lowercased()) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            guard let (d, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let s = String(data: d, encoding: .utf8),
                  s.localizedCaseInsensitiveContains("metalink") else { return nil }
            text = s
        }
        let files = MetalinkParser.parse(text)
        guard !files.isEmpty else { return nil }
        var out: [NormalizedRequest] = []
        for f in files {
            guard let primary = f.urls.first else { continue }
            out.append(NormalizedRequest(
                url: primary, proto: DownloadProtocol.detect(from: primary),
                origin: origin, suggestedName: f.name.isEmpty ? nil : f.name,
                options: options, checksum: f.checksum,
                mirrors: Array(f.urls.dropFirst()),
                pieceHashes: f.pieces, pieceLength: f.pieceLength))
        }
        return out.isEmpty ? nil : out
    }

    private static func expand(
        _ entries: [PlaylistImporter.Entry], origin: String,
        options: [String: String], settings: ProtocolSettings, depth: Int
    ) async throws -> [NormalizedRequest] {
        var out: [NormalizedRequest] = []
        for e in entries.prefix(500) {
            var reqs = try await normalize(e.url.absoluteString, options: options,
                                           settings: settings, depth: depth + 1)
            for i in reqs.indices where reqs[i].suggestedName == nil {
                reqs[i].suggestedName = e.name
            }
            out.append(contentsOf: reqs)
        }
        guard !out.isEmpty else { throw NormalizerError.playlistEmpty(origin) }
        return out
    }

    // MARK: - parameterized URI (brace) expansion

    /// Expand `{...}` groups left to right. A group body is either comma
    /// alternatives (`a,b,c`) or a numeric range (`001..100`, leading zeros
    /// define the padding). Nested groups take the cartesian product. Results
    /// are capped at 1000.
    static func expandBraces(_ s: String, limit: Int = 1000) -> [String] {
        guard let open = s.firstIndex(of: "{"),
              let close = s[open...].firstIndex(of: "}") else { return [s] }
        let body = String(s[s.index(after: open)..<close])
        let variants: [String]
        if let range = numericRange(body) {
            variants = range
        } else if body.contains(",") {
            variants = body.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            // Not a parameterized group (e.g. an opaque token) — leave as-is.
            return [s]
        }
        let prefix = String(s[..<open])
        let suffix = String(s[s.index(after: close)...])
        var out: [String] = []
        for v in variants {
            let candidate = prefix + v + suffix
            let sub = candidate.contains("{")
                ? expandBraces(candidate, limit: limit - out.count) : [candidate]
            out.append(contentsOf: sub)
            if out.count >= limit { break }
        }
        return out.isEmpty ? [s] : out
    }

    /// `001..100` → ["001","002",…]; nil when the body is not a numeric range.
    /// Ascending direction is enforced (aria2 lists ranges low→high).
    private static func numericRange(_ body: String) -> [String]? {
        let parts = body.components(separatedBy: "..")
        guard parts.count == 2,
              let a = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let b = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let width = parts[0].hasPrefix("0") ? parts[0].count : 0
        let (lo, hi) = a <= b ? (a, b) : (b, a)
        return (lo...hi).prefix(1000).map { n in
            width > 0 ? String(format: "%0\(width)d", n) : String(n)
        }
    }

    /// Schemes we advertise in the UI, grouped for the "新建下载" help text.
    public static var capabilitySummary: String {
        "HTTP(S) · FTP/FTPS · SFTP/SCP · rsync · WebDAV · SMB (AFP 链接自动转 SMB) · " +
        "NFS · BT/Magnet/Metalink · eD2K · HLS · DASH · 迅雷/快车/QQ旋风 · IPFS · S3 · " +
        "file/data · 批量列表 · libcurl 兜底协议"
    }
}
