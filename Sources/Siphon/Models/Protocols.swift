import Foundation

/// Which concrete transport owns a task once its URI has been normalized.
///
/// Several "protocols" are really URI front-ends: `thunder://`, `ipfs://`, `webdav://`,
/// `s3://` are all resolved to a plain HTTP(S) request before they reach an engine.
/// Those keep their original `DownloadProtocol` for the UI badge, but their
/// `transport` says which code actually moves the bytes.
public enum TransportKind: String, Sendable {
    case aria2, hls, dash, ed2k, curl, ssh, mount, local, native

    public var displayName: String {
        switch self {
        case .aria2: return "aria2 (JSON-RPC)"
        case .hls:   return "Swift 原生 HLS"
        case .dash:  return "Swift 原生 DASH"
        case .ed2k:  return "eD2K 后端"
        case .curl:  return "系统 libcurl"
        case .ssh:   return "OpenSSH / rsync"
        case .mount: return "macOS 文件系统挂载"
        case .local: return "本地文件"
        case .native: return "Swift 原生 HTTP"
        }
    }
}

/// Protocol families the app understands.
///
/// `http/https/ftp` and every URI front-end (`thunder`, `webdav`, `s3`, `ipfs`, …)
/// are served by the dependency-free native `HTTPDownloadEngine` (URLSession +
/// byte-range segmentation). `bittorrent/metalink/magnet/sftp` stay on the optional
/// external aria2 (only if the user installs it). `hls/dash/ed2k` are native Swift
/// engines. Everything else is a transport bridged to a system tool (libcurl /
/// OpenSSH / rsync / mount_*). See `URINormalizer`.
public enum DownloadProtocol: String, CaseIterable, Identifiable, Sendable {
    // aria2 core
    case http, https, ftp, sftp, bittorrent, metalink, magnet
    // native Swift engines
    case hls, dash, ed2k
    // Chinese vendor link wrappers -> HTTP(S)
    case thunder, flashget, qqdl
    // storage / enterprise front-ends
    case ftps, webdav, webdavs, s3
    // LAN / distributed
    case smb, smbs, nfs, afp, ipfs, ipns
    // SSH family
    case scp, rsync
    // local / batch
    case file, data, playlist
    // catch-all for the remaining libcurl schemes (tftp, gopher, rtsp, dict, ...)
    case curl

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .thunder: return "迅雷"
        case .flashget: return "快车"
        case .qqdl: return "QQ旋风"
        case .webdav: return "WebDAV"
        case .webdavs: return "WebDAVS"
        case .s3: return "S3"
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .ed2k: return "eD2K"
        case .bittorrent: return "BT"
        case .metalink: return "Metalink"
        case .magnet: return "Magnet"
        case .file: return "本地文件"
        case .data: return "Data URI"
        case .playlist: return "批量列表"
        case .curl: return "libcurl"
        default: return rawValue.uppercased()
        }
    }

    public var transport: TransportKind {
        switch self {
        case .ftps, .smb, .smbs, .curl: return .curl
        case .hls:  return .hls
        case .dash: return .dash
        case .ed2k: return .ed2k
        case .scp, .rsync: return .ssh
        case .nfs, .afp: return .mount
        case .file, .data, .playlist: return .local
        case .http, .https, .ftp: return .native
        case .thunder, .flashget, .qqdl, .webdav, .webdavs, .s3, .ipfs, .ipns: return .native
        default: return .aria2
        }
    }

    /// Protocols whose bytes are moved by the aria2 subprocess after normalization.
    public var requiresAria2: Bool { transport == .aria2 }

    public var isP2P: Bool {
        switch self {
        case .bittorrent, .ed2k, .magnet, .ipfs, .ipns: return true
        default: return false
        }
    }

    /// True for schemes that are wrappers/gateways rather than wire protocols.
    public var isFrontEnd: Bool {
        switch self {
        case .thunder, .flashget, .qqdl, .webdav, .webdavs, .s3, .ipfs, .ipns, .playlist:
            return true
        default: return false
        }
    }

    /// Best-effort detection from a URL / string.
    public static func detect(from url: URL) -> DownloadProtocol {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https": return classifyHTTP(url)
        case "ftp":   return .ftp
        case "ftps":  return .ftps
        case "sftp":  return .sftp
        case "scp":   return .scp
        case "rsync": return .rsync
        case "magnet":return .magnet
        case "ed2k":  return .ed2k
        case "thunder": return .thunder
        case "flashget": return .flashget
        case "qqdl":  return .qqdl
        case "webdav":  return .webdav
        case "webdavs": return .webdavs
        case "smb":   return .smb
        case "smbs":  return .smbs
        case "nfs":   return .nfs
        case "afp":   return .afp
        case "ipfs":  return .ipfs
        case "ipns":  return .ipns
        case "s3":    return .s3
        case "file":  return classifyLocalFile(url)
        case "data":  return .data
        default:
            if URISchemes.all.contains(scheme) { return .curl }
            return .https
        }
    }

    private static func classifyHTTP(_ url: URL) -> DownloadProtocol {
        let s = url.absoluteString.lowercased()
        let path = s.components(separatedBy: "?").first ?? s
        if path.contains(".m3u8") { return .hls }
        if path.contains(".mpd") { return .dash }
        if path.hasSuffix(".torrent") { return .bittorrent }
        if path.hasSuffix(".metalink") || path.hasSuffix(".meta4") { return .metalink }
        if path.hasSuffix(".m3u") || path.hasSuffix(".pls") || path.hasSuffix(".asx")
            || path.hasSuffix(".wpl") || path.hasSuffix(".lst") { return .playlist }
        return url.scheme?.lowercased() == "http" ? .http : .https
    }

    private static func classifyLocalFile(_ url: URL) -> DownloadProtocol {
        switch url.pathExtension.lowercased() {
        case "torrent": return .bittorrent
        case "metalink", "meta4": return .metalink
        case "m3u8": return .hls
        case "mpd": return .dash
        case "m3u", "pls", "asx", "wpl", "lst", "txt", "nzb": return .playlist
        default: return .file
        }
    }
}

/// Canonical scheme tables. Kept in one place so clipboard monitoring, Info.plist,
/// detection and the UI all agree on what the app claims to accept.
public enum URISchemes {
    /// Wrapped onto HTTP(S) by `URINormalizer`, then served by the native engine.
    public static let frontEnds: Set<String> =
        ["thunder", "flashget", "qqdl", "webdav", "webdavs", "s3", "ipfs", "ipns"]

    /// Handled by the system libcurl subprocess.
    public static let libcurlOnly: Set<String> =
        ["ftps", "smb", "smbs", "tftp", "gopher", "gophers", "rtsp", "dict",
         "imap", "imaps", "pop3", "pop3s", "smtp", "smtps", "ldap", "ldaps", "mqtt"]

    /// Handled by OpenSSH / rsync / macOS mount helpers.
    public static let systemTools: Set<String> = ["scp", "rsync", "nfs", "afp"]

    /// Schemes aria2 understands natively. Kept only as a recognised-scheme
    /// whitelist; actual routing is decided by `DownloadProtocol.transport`
    /// (http/https/ftp/file/data now go to the native engine).
    public static let aria2: Set<String> =
        ["http", "https", "ftp", "sftp", "magnet", "ed2k", "file", "data"]

    public static var all: Set<String> {
        frontEnds.union(libcurlOnly).union(systemTools).union(aria2)
    }

    /// Schemes registered as `CFBundleURLTypes` so Finder / browsers can hand links over.
    /// Must stay in sync with Resources/Info.plist; `verify.sh` asserts the equality.
    /// `libcurlOnly` catch-all schemes are included so every protocol we claim to
    /// accept can actually be delivered to the app from a browser.
    public static let registered: [String] = [
        "magnet", "ed2k", "thunder", "flashget", "qqdl",
        "sftp", "scp", "rsync", "webdav", "webdavs",
        "smb", "smbs", "nfs", "afp", "ipfs", "ipns", "s3", "ftps",
        "tftp", "gopher", "gophers", "rtsp", "dict",
        "imap", "imaps", "pop3", "pop3s", "smtp", "smtps",
        "ldap", "ldaps", "mqtt"
    ]
}
