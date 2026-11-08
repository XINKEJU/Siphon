import Darwin
import Foundation

// MARK: - 偏好键与默认值

/// 系统集成的开关集中在这里声明，避免设置页、SystemPresence、DownloadStore
/// 三处各写一份字符串键（漂移之后「开关点了没反应」几乎必然发生）。
public enum PresenceDefaults {
    public static let dockProgressKey = "Siphon.dockProgress"
    public static let menuBarStyleKey = "Siphon.menuBarStyle"
    public static let recordWhereFromsKey = "Siphon.recordWhereFroms"
    public static let pauseWhenOfflineKey = "Siphon.pauseWhenOffline"
    public static let pauseWhenMeteredKey = "Siphon.pauseWhenMetered"

    /// `object(forKey:) == nil` 才是「用户没设置过」，此时用产品默认值。
    /// `bool(forKey:)` 会把「没设置」和「显式关」都读成 false，无法区分。
    public static func bool(_ key: String, default fallback: Bool) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else { return fallback }
        return value
    }
}

// MARK: - Dock 进度

/// Dock 只关心「活跃/暂停 + 字节数」，与完整任务模型解耦，方便单测。
public struct DockProgressItem: Equatable, Sendable {
    public var isActive: Bool
    public var isPaused: Bool
    public var totalBytes: Int64
    public var downloadedBytes: Int64

    public init(isActive: Bool, isPaused: Bool, totalBytes: Int64, downloadedBytes: Int64) {
        self.isActive = isActive
        self.isPaused = isPaused
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
    }
}

public struct DockProgressSummary: Equatable, Sendable {
    /// 0...1，已按字节加权。
    public var fraction: Double
    /// 总大小未知（chunked / HLS live）时不该画成 0%，改为画一段不确定态。
    public var isIndeterminate: Bool
    /// 只剩暂停任务：进度条用中性色，避免看起来像在下载。
    public var isPausedOnly: Bool
    public var activeCount: Int
    public var pausedCount: Int
    /// 有活跃任务时的百分比标签；暂停/空闲时为 nil。
    public var percentLabel: String?
}

public enum DockProgressModel {
    /// 返回 nil 表示 Dock 上不该有任何进度（没有活跃任务，也没有可展示的暂停进度）。
    public static func summarize(_ items: [DockProgressItem]) -> DockProgressSummary? {
        let active = items.filter(\.isActive)
        let paused = items.filter { $0.isPaused && $0.downloadedBytes > 0 }
        guard !active.isEmpty || !paused.isEmpty else { return nil }

        // 有活跃任务就只统计活跃的：把暂停任务混进分母会让进度在暂停/继续时跳变。
        let pool = active.isEmpty ? paused : active
        let known = pool.filter { $0.totalBytes > 0 }
        var fraction = 0.0
        if !known.isEmpty {
            let total = known.reduce(Int64(0)) { $0 + $1.totalBytes }
            let done = known.reduce(Int64(0)) { $0 + min(max($1.downloadedBytes, 0), $1.totalBytes) }
            if total > 0 { fraction = min(max(Double(done) / Double(total), 0), 1) }
        }
        return DockProgressSummary(
            fraction: fraction,
            isIndeterminate: known.isEmpty,
            isPausedOnly: active.isEmpty,
            activeCount: active.count,
            pausedCount: active.isEmpty ? paused.count : 0,
            percentLabel: active.isEmpty ? nil : "\(Int((fraction * 100).rounded()))%")
    }
}

// MARK: - 菜单栏

public enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case speed
    case percent
    case icon

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .speed: return "下载速度"
        case .percent: return "完成百分比"
        case .icon: return "仅图标"
        }
    }
}

public enum MenuBarTitle {
    public static func text(style: MenuBarStyle,
                            summary: DockProgressSummary?,
                            speedBytesPerSec: Int64) -> String {
        guard let summary else { return "" }
        switch style {
        case .icon:
            return ""
        case .percent:
            if let percent = summary.percentLabel { return percent }
            return summary.isPausedOnly ? "已暂停" : "\(summary.activeCount)"
        case .speed:
            if summary.isPausedOnly { return "已暂停" }
            return compactSpeed(speedBytesPerSec)
        }
    }

    /// 菜单栏空间宝贵：`1.4 MB/s` 而不是 ByteCountFormatter 的长串。
    public static func compactSpeed(_ bytesPerSec: Int64) -> String {
        guard bytesPerSec > 0 else { return "0 KB/s" }
        let units = ["KB/s", "MB/s", "GB/s"]
        var value = Double(bytesPerSec) / 1024
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let number = value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(number) \(units[index])"
    }
}

// MARK: - 网络状态

public struct NetworkStatus: Equatable, Sendable {
    public var isOnline: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var interfaceName: String

    public init(isOnline: Bool, isExpensive: Bool, isConstrained: Bool, interfaceName: String) {
        self.isOnline = isOnline
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaceName = interfaceName
    }

    /// 状态栏/菜单里的一句话提示；正常时返回 nil，避免噪音。
    public var displayText: String? {
        if !isOnline { return "网络已断开" }
        if isExpensive { return "计费网络" }
        if isConstrained { return "低数据模式" }
        return nil
    }

    public var symbolName: String {
        if !isOnline { return "wifi.slash" }
        if isExpensive { return "wifi.exclamationmark" }
        return "wifi"
    }
}

public enum NetworkPauseReason: String, Equatable, Sendable {
    case offline
    case metered

    public var displayText: String {
        switch self {
        case .offline: return "网络断开，已自动暂停"
        case .metered: return "计费网络，已按设置暂停"
        }
    }
}

public enum NetworkPolicy {
    public struct Settings: Equatable, Sendable {
        public var pauseWhenOffline: Bool
        public var pauseWhenMetered: Bool

        public init(pauseWhenOffline: Bool, pauseWhenMetered: Bool) {
            self.pauseWhenOffline = pauseWhenOffline
            self.pauseWhenMetered = pauseWhenMetered
        }

        public static var current: Settings {
            Settings(
                pauseWhenOffline: PresenceDefaults.bool(PresenceDefaults.pauseWhenOfflineKey, default: true),
                pauseWhenMetered: PresenceDefaults.bool(PresenceDefaults.pauseWhenMeteredKey, default: false))
        }
    }

    /// 只回答「现在该不该暂停」，恢复由调用方按「自己暂停的才恢复」执行，
    /// 这样用户手动暂停的任务不会被网络事件偷偷继续。
    public static func pauseReason(for status: NetworkStatus,
                                   settings: Settings) -> NetworkPauseReason? {
        if !status.isOnline, settings.pauseWhenOffline { return .offline }
        if status.isExpensive, settings.pauseWhenMetered { return .metered }
        return nil
    }
}

// MARK: - 下载来源（Finder「简介」里的“来自何处”）

public enum DownloadOriginMetadata {
    /// Finder / Spotlight 读取的扩展属性名。
    public static let attribute = "com.apple.metadata:kMDItemWhereFroms"

    /// macOS 对该属性使用二进制 plist 字符串数组（第一个是下载地址，第二个是来源页）。
    public static func plist(for sources: [String]) -> Data? {
        let values = sources.filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: values, format: .binary, options: 0)
    }

    @discardableResult
    public static func write(source: String, referrer: String?, to file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var values = [source]
        // 只接受真正的 URL 作为“来源页”；`origin` 也可能是 "rss:标题" 这类标记。
        if let referrer, referrer != source, referrer.hasPrefix("http") {
            values.append(referrer)
        }
        guard let data = plist(for: values) else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return setxattr(file.path, attribute, base, data.count, 0, 0) == 0
        }
    }
}

// MARK: - 系统服务（Services 菜单）

public enum ServiceLinkExtractor {
    public static let schemes: Set<String> = [
        "http", "https", "ftp", "ftps", "sftp", "magnet", "ed2k",
        "thunder", "qqdl", "flashget", "webdav", "webdavs", "s3", "ipfs", "ipns"
    ]

    /// 从任意 App 选中的文本里挑出可下载链接。
    ///
    /// 不能用「按空白切词再判断前缀」：真实文本里链接常常粘着中文冒号、
    /// 句号或括号（`看这个：https://…。`），切出来的第一段不是 scheme。
    /// 直接从 `scheme:` 起扫描，再剥掉尾部标点/不成对的收尾括号。
    public static func links(in text: String, limit: Int = 200) -> [String] {
        guard limit > 0, !text.isEmpty else { return [] }
        let pattern = #"(?i)\b(?:https?|ftps?|sftp|magnet|ed2k|thunder|qqdl|flashget|webdavs?|s3|ipfs|ipns):(?://)?[^\s<>"'“”‘’，。；：！？」』《》]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        // 防止把一整本剪贴板内容丢进正则；200 条链接远小于这个上限。
        let haystack = text.count > 200_000 ? String(text.prefix(200_000)) : text
        let matches = regex.matches(in: haystack,
                                    range: NSRange(haystack.startIndex..., in: haystack))
        var found: [String] = []
        var seen = Set<String>()
        for match in matches {
            guard let range = Range(match.range, in: haystack) else { continue }
            let candidate = trimTrailing(String(haystack[range]))
            guard candidate.count > 12,
                  seen.insert(candidate).inserted else { continue }
            found.append(candidate)
            if found.count >= limit { break }
        }
        return found
    }

    private static func trimTrailing(_ input: String) -> String {
        var value = input
        let always = CharacterSet(charactersIn: ".,;:!?、。，；：！？\"'")
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
        var changed = true
        while changed {
            changed = false
            while let last = value.unicodeScalars.last, always.contains(last) {
                value.unicodeScalars.removeLast()
                changed = true
            }
            guard let last = value.last else { break }
            for (open, close) in pairs where last == close {
                let opens = value.filter { $0 == open }.count
                let closes = value.filter { $0 == close }.count
                if closes > opens {
                    value.removeLast()
                    changed = true
                }
            }
        }
        return value
    }

    /// 选中文本 → 可交给 `DownloadStore.addDroppedText` 的规范化结果。
    public static func normalizedText(in text: String) -> String? {
        let links = links(in: text)
        return links.isEmpty ? nil : links.joined(separator: "\n")
    }
}
