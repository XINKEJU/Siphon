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

    public init(url: URL, proto: DownloadProtocol, origin: String,
                suggestedName: String? = nil, options: [String: String] = [:]) {
        self.url = url; self.proto = proto; self.origin = origin
        self.suggestedName = suggestedName; self.options = options
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
            // aria2 already speaks HTTP Basic/Digest auth embedded in the URL.
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw NormalizerError.malformedURL(input)
            }
            comps.scheme = proto == .webdavs ? "https" : "http"
            guard let target = comps.url else { throw NormalizerError.malformedURL(input) }
            return [NormalizedRequest(url: target, proto: proto, origin: input, options: options)]

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

        case .http, .https, .ftp, .sftp, .bittorrent, .metalink, .magnet,
             .ed2k, .hls, .dash, .ftps, .smb, .smbs, .nfs, .afp,
             .scp, .rsync, .file, .data, .curl:
            if !URISchemes.all.contains(scheme) && scheme != "file" && scheme != "data" {
                throw NormalizerError.unsupportedScheme(scheme)
            }
            return [NormalizedRequest(url: url, proto: proto, origin: input, options: options)]
        }
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

    /// Schemes we advertise in the UI, grouped for the "新建下载" help text.
    public static var capabilitySummary: String {
        "HTTP(S) · FTP/FTPS · SFTP/SCP · rsync · WebDAV · SMB · NFS · AFP · " +
        "BT/Magnet/Metalink · eD2K · HLS · DASH · 迅雷/快车/QQ旋风 · IPFS · S3 · " +
        "file/data · 批量列表"
    }
}
