import Foundation

/// Resolves video-site URLs (YouTube, Bilibili, Twitter, …) into direct media
/// URLs via `yt-dlp -J`, following the ABD/persepolis approach: yt-dlp is a URL
/// *resolver*, not a transfer engine — the resolved stream URL is handed to the
/// native HTTP engine like any other download.
///
/// The binary is optional: when absent, video-site URLs simply download the
/// page as before. `SIPHON_YTDLP_PATH` overrides the binary location (tests use
/// this to inject a stub).
public enum YtDlpResolver {

    public struct Media: Sendable, Equatable {
        public let url: String
        public let title: String
        public let ext: String?
    }

    public enum ResolverError: Error, LocalizedError {
        case unavailable
        case resolveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "未找到 yt-dlp（brew install yt-dlp 或在设置中指定路径）"
            case .resolveFailed(let m): return "视频解析失败：\(m)"
            }
        }
    }

    /// Known video hosts that benefit from resolution. Kept short on purpose —
    /// yt-dlp itself supports 1000+ sites, and unknown hosts fall through to a
    /// plain download; these are the ones users actually paste.
    static let knownHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com",
        "music.youtube.com",
        "bilibili.com", "www.bilibili.com", "m.bilibili.com", "b23.tv",
        "x.com", "twitter.com", "vimeo.com", "dailymotion.com",
        "douyin.com", "www.douyin.com", "www.ixigua.com", "ixigua.com",
        "tiktok.com", "www.tiktok.com", "twitch.tv", "www.twitch.tv",
        "iq.com", "weibo.com", "www.weibo.com", "m.weibo.cn",
    ]

    public static func isSupported(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return knownHosts.contains(host)
    }

    /// Locate yt-dlp: env override first, then the usual Homebrew / system spots,
    /// then PATH via `which`.
    public static func binaryPath() -> String? {
        if let p = ProcessInfo.processInfo.environment["SIPHON_YTDLP_PATH"],
           FileManager.default.isExecutableFile(atPath: p) { return p }
        for candidate in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
                          "/usr/bin/yt-dlp", "/opt/local/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        guard let which = try? Process.runAndCollect("/usr/bin/which", ["yt-dlp"]),
              !which.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return which.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func available() -> Bool { binaryPath() != nil }

    /// Resolve a video-site URL into direct media URLs. Playlist submissions
    /// expand to one Media per entry (capped so a 500-entry playlist doesn't
    /// flood the queue; matches persepolis's practical limit).
    public static func resolve(_ urlString: String) async throws -> [Media] {
        guard let bin = binaryPath() else { throw ResolverError.unavailable }
        let runner = ExternalRunner(
            executable: URL(fileURLWithPath: bin),
            arguments: ["-J", "--no-warnings", "--playlist-items", "1:50", urlString],
            destination: nil)
        try runner.start()
        let outcome = await runner.wait()
        guard outcome.exitCode == 0, !outcome.stdout.isEmpty else {
            throw ResolverError.resolveFailed(outcome.stderr.isEmpty
                ? "yt-dlp 退出码 \(outcome.exitCode)" : outcome.stderr)
        }

        let data = Data(outcome.stdout.utf8)
        // -J with --flat-playlist may yield either a single video info dict or a
        // playlist wrapper with an "entries" array.
        if let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = top["_type"] as? String, entries == "playlist" {
            let list = (top["entries"] as? [[String: Any]]) ?? []
            let medias = list.compactMap {
                bestFormat(from: $0, title: $0["title"] as? String ?? "")
            }.prefix(50)
            if medias.isEmpty { throw ResolverError.resolveFailed("播放列表为空") }
            return Array(medias)
        }
        guard let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = bestFormat(from: info, title: info["title"] as? String ?? "") else {
            throw ResolverError.resolveFailed("无法从输出中提取媒体地址")
        }
        return [media]
    }

    // MARK: - format selection

    /// Pick the best stream from an info dict. Preference order mirrors yt-dlp's
    /// own default (`bestvideo*+bestaudio` needs merging we can't do yet, so we
    /// take the highest-resolution *progressive* stream that carries both audio
    /// and video; if none exists, best audio-only).
    static func bestFormat(from info: [String: Any], title: String) -> Media? {
        let formats = (info["formats"] as? [[String: Any]]) ?? []
        if formats.isEmpty {
            // Entry with no format list: trust its url only if it is NOT a
            // watch-page pointer (those need a second -J pass we skip).
            if let url = info["url"] as? String, !url.isEmpty,
               (info["_type"] as? String) != "url" {
                return Media(url: url, title: title, ext: info["ext"] as? String)
            }
            return nil
        }

        func score(_ f: [String: Any]) -> Double {
            let height = ((f["height"] as? NSNumber)?.doubleValue) ?? 0
            let abr = ((f["abr"] as? NSNumber)?.doubleValue) ?? 0
            let vbr = ((f["vbr"] as? NSNumber)?.doubleValue) ?? 0
            let a = f["acodec"] as? String
            let v = f["vcodec"] as? String
            let hasBoth: Bool = (a != nil && a != "none") && (v != nil && v != "none")
            let protocolOK: Bool = (f["protocol"] as? String) != "m3u8" // HLS handled natively anyway
            let bonus: Double = hasBoth ? 1_000_000 : 0
            let protoBonus: Double = protocolOK ? 0 : -10
            let weightedHeight: Double = height * 1000
            let weightedVbr: Double = vbr * 10
            return bonus + weightedHeight + weightedVbr + abr + protoBonus
        }
        let ordered = formats.sorted { score($0) > score($1) }
        guard let best = ordered.first,
              let url = best["url"] as? String, !url.isEmpty else { return nil }
        let ext = (best["ext"] as? String) ?? (info["ext"] as? String)
        return Media(url: url, title: title, ext: ext)
    }
}

extension Process {
    /// Small synchronous helper for `which`-style lookups (short-lived, bounded
    /// output — no deadlock risk).
    static func runAndCollect(_ path: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
