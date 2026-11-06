import Foundation

/// Shared, locale-aware formatters. Kept out of views so they are cheap to reuse.
enum Formatting {
    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: max(0, value))
    }

    static func speed(_ bytesPerSec: Int64) -> String {
        guard bytesPerSec > 0 else { return "—" }
        return bytes(bytesPerSec) + "/s"
    }

    static func eta(downloaded: Int64, total: Int64, speed: Int64) -> String {
        guard speed > 0, total > downloaded else { return "—" }
        let seconds = Double(total - downloaded) / Double(speed)
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        return String(format: "%.1f 小时", seconds / 3600)
    }

    static func percent(_ p: Double) -> String {
        String(format: "%.1f%%", p * 100)
    }
}
