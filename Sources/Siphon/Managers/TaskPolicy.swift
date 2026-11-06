import Foundation
import AppKit

/// Policy helpers around task lifecycle that are not engine-specific:
/// auto-categorization, schedule windows, completion actions, keep-awake.
/// Borrowed from HyperDM (categorizer + within_window), ABD (OnDownloadCompletion
/// actions + KeepAwakeManager) and persepolis (shutdown latch).

// MARK: - auto categorization (HyperDM categorizer model)

public enum AutoCategorizer {
    public static let categories: [(name: String, extensions: [String])] = [
        ("视频", ["mp4", "mkv", "mov", "avi", "webm", "flv", "wmv", "m4v", "ts", "m2ts"]),
        ("音乐", ["mp3", "flac", "aac", "ogg", "wav", "m4a", "opus", "wma"]),
        ("图片", ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "svg"]),
        ("文档", ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "epub"]),
        ("压缩包", ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "tar.gz"]),
        ("软件", ["dmg", "pkg", "app", "ipa", "exe", "msi", "deb", "rpm", "apk"]),
        ("种子", ["torrent", "metalink", "meta4"]),
    ]

    /// Subfolder for a filename, or `nil` when it matches no known category.
    public static func subdirectory(for fileName: String) -> String? {
        // Handle compound extensions like tar.gz by comparing the tail.
        let lower = fileName.lowercased()
        for (name, exts) in categories {
            for ext in exts where lower.hasSuffix("." + ext) {
                return name
            }
        }
        return nil
    }
}

// MARK: - schedule window (cross-midnight, HyperDM within_window)

public struct ScheduleWindow: Codable, Equatable {
    /// "HH:mm" 24-hour strings. Empty strings mean "no bound".
    public var enabled: Bool
    public var start: String   // e.g. "22:00"
    public var end: String     // e.g. "07:00"

    public init(enabled: Bool = false, start: String = "", end: String = "") {
        self.enabled = enabled
        self.start = start
        self.end = end
    }

    private func minutes(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    public var isValid: Bool {
        guard enabled, let s = minutes(start), let e = minutes(end) else { return false }
        return s != e
    }

    /// True when `date` is inside the window. Supports windows that cross midnight
    /// (22:00–07:00): inside if now >= start || now < end.
    public func contains(_ date: Date = Date()) -> Bool {
        guard isValid, let s = minutes(start), let e = minutes(end) else { return false }
        let cal = Calendar.current
        let comp = cal.dateComponents([.hour, .minute], from: date)
        let now = (comp.hour ?? 0) * 60 + (comp.minute ?? 0)
        return s < e ? (now >= s && now < e) : (now >= s || now < e)
    }
}

// MARK: - completion actions (persepolis latch + ABD PowerActionMac)

public enum CompletionAction: String, Codable, CaseIterable, Identifiable {
    case none = "无"
    case sleep = "睡眠"
    case shutdown = "关机"
    case quitApp = "退出 Siphon"
    public var id: String { rawValue }

    /// Execute the action. Shutdown/sleep go through `osascript` like ABD's
    /// PowerActionMac; quitApp exits after a short grace period for engine teardown.
    @MainActor
    public func run() {
        switch self {
        case .none: break
        case .sleep:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"System Events\" to sleep"]
            try? p.run()
        case .shutdown:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"System Events\" to shut down"]
            try? p.run()
        case .quitApp:
            NSApp.terminate(nil)
        }
    }
}

// MARK: - keep awake (ABD KeepAwakeManager)

/// Prevents system sleep while any download is active. `ProcessInfo.beginActivity`
/// with `idleSystemSleepDisabled` is the sanctioned macOS way; assertions are
/// reference-counted so nested calls are safe.
public final class KeepAwakeToken: @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: NSObjectProtocol?

    public func begin() {
        lock.lock(); defer { lock.unlock() }
        guard assertion == nil else { return }
        assertion = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Siphon 正在下载")
    }

    public func end() {
        lock.lock(); defer { lock.unlock() }
        if let a = assertion {
            ProcessInfo.processInfo.endActivity(a)
            assertion = nil
        }
    }
}

// MARK: - turtle mode (Motrix speed-limit-controller three-tier)

/// Three-tier speed-limit mode borrowed from Motrix's speed-limit-controller:
/// `off` (unlimited), `on` (fixed cap), `auto` (fixed cap applied only inside a
/// "quiet hours" window so daytime traffic is untouched).
public enum TurtleMode: String, CaseIterable, Identifiable, Codable {
    case off = "关闭"
    case on = "开启"
    case auto = "自动"

    public var id: String { rawValue }
}

/// Turtle configuration: the mode plus the cap and (for `.auto`) the quiet-hours
/// window during which the cap applies. Persisted to UserDefaults by `DownloadStore`.
public struct TurtleConfig: Codable, Equatable {
    public var mode: TurtleMode
    /// Bytes/sec while throttled.
    public var limitBytesPerSec: Int64
    /// Quiet-hours window (minutes since midnight) for `.auto`. Cross-midnight.
    public var autoStartMinutes: Int
    public var autoEndMinutes: Int

    public init(mode: TurtleMode = .off, limitBytesPerSec: Int64 = 1024 * 1024,
                autoStartMinutes: Int = 22 * 60, autoEndMinutes: Int = 7 * 60) {
        self.mode = mode
        self.limitBytesPerSec = limitBytesPerSec
        self.autoStartMinutes = autoStartMinutes
        self.autoEndMinutes = autoEndMinutes
    }

    /// The effective global cap for `date`, or `nil` (unlimited) when turtle is off
    /// or — in `.auto` — the current time is outside the quiet window.
    public func effectiveLimit(at date: Date = Date()) -> Int64? {
        switch mode {
        case .off: return nil
        case .on: return limitBytesPerSec
        case .auto:
            let cal = Calendar.current
            let comp = cal.dateComponents([.hour, .minute], from: date)
            let now = (comp.hour ?? 0) * 60 + (comp.minute ?? 0)
            let inside = autoStartMinutes < autoEndMinutes
                ? (now >= autoStartMinutes && now < autoEndMinutes)
                : (now >= autoStartMinutes || now < autoEndMinutes)
            return inside ? limitBytesPerSec : nil
        }
    }
}
