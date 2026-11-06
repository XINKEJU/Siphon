import Foundation

/// Protocol families the app understands. `http/https/ftp/sftp/bittorrent/metalink/magnet`
/// are handled by the bundled aria2 core; `ed2k/hls/dash` are handled by native Swift engines.
public enum DownloadProtocol: String, CaseIterable, Identifiable, Sendable {
    case http, https, ftp, sftp
    case bittorrent, metalink, magnet
    case ed2k, hls, dash

    public var id: String { rawValue }
    public var displayName: String { rawValue.uppercased() }

    /// Protocols served by the aria2 subprocess rather than a native engine.
    public var requiresAria2: Bool {
        switch self {
        case .http, .https, .ftp, .sftp, .bittorrent, .metalink, .magnet: return true
        case .ed2k, .hls, .dash: return false
        }
    }

    public var isP2P: Bool { self == .bittorrent || self == .ed2k || self == .magnet }

    /// Best-effort protocol detection from a URL / string.
    public static func detect(from url: URL) -> DownloadProtocol {
        switch url.scheme?.lowercased() ?? "" {
        case "http":  return .http
        case "https": return .https
        case "ftp":   return .ftp
        case "sftp":  return .sftp
        case "magnet":return .magnet
        case "ed2k":  return .ed2k
        default: break
        }
        let s = url.absoluteString.lowercased()
        if s.contains(".m3u8") { return .hls }
        if s.contains(".mpd") { return .dash }
        if s.hasSuffix(".torrent") || s.contains("bittorrent") || s.contains("announce") { return .bittorrent }
        return url.scheme?.hasPrefix("http") == true ? .https : .https
    }
}
