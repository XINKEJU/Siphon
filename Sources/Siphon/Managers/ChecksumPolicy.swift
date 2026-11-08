import Foundation

/// Decides whether a finished download still needs a store-side integrity check.
///
/// Only the native URLSession engine verifies the user's checksum inline before
/// reporting completion. Everything else — curl, HLS/DASH, SSH/mount, aria2
/// (BT/Metalink/SFTP), eD2K, `file:`/`data:`, and yt-dlp (whose tasks are
/// tagged `.native` but run through `YtDlpEngine`) — must be checked here.
/// The previous allow-list silently reported "completed" on those engines even
/// when a checksum was explicitly requested or the file was corrupt.
public enum ChecksumPolicy {
    public enum Outcome {
        case verified, mismatched, unverifiable
    }

    public static func needsPostCompletionChecksum(isNative: Bool,
                                                   ytdlp: Bool,
                                                   checksum: String?) -> Bool {
        guard let spec = checksum, !spec.isEmpty else { return false }
        return !isNative || ytdlp
    }
}
