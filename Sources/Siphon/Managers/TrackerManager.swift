import Foundation
import Combine

/// BitTorrent tracker auto-subscription (Motrix `tracker-manager` / Gopeed `trackers`).
///
/// Periodically fetches well-known public tracker lists, deduplicates, drops
/// blacklisted entries, and pushes the merged set to aria2 via
/// `changeGlobalOption` → `bt-tracker`. This is the single biggest BT
/// experience win and is pure Swift with no extra dependencies.
///
/// Note: aria2 applies `bt-tracker` globally. True "private torrent" protection
/// (skip global trackers for `private` torrents) lives in `Aria2Engine.makeOptions`
/// where the torrent metadata is known; see the comment there.
public final class TrackerManager: @unchecked Sendable {
    public static let shared = TrackerManager()

    /// Well-known public tracker list mirrors. More than one improves coverage
    /// when a single source is rate-limited or down.
    public var sources: [URL] = [
        URL(string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt")!,
        URL(string: "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt")!,
        URL(string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt")!,
    ]

    public var blacklist: Set<String> = []
    public var autoUpdateEnabled: Bool = true
    public private(set) var lastTrackers: [String] = []
    public private(set) var lastError: String?

    /// Pushed to the store, which forwards to the live aria2 RPC.
    public var onUpdate: (@Sendable ([String]) -> Void)?

    private let lock = NSLock()
    private var timer: AnyCancellable?
    private let refreshInterval: TimeInterval = 6 * 3600
    private static let sourcesKey = "Siphon.trackerSources"
    private static let blacklistKey = "Siphon.trackerBlacklist"
    private static let autoKey = "Siphon.trackerAutoUpdate"

    private init() { load() }

    public func start() {
        if autoUpdateEnabled {
            Task { await refresh() }
            timer = Timer.publish(every: refreshInterval, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in Task { await self?.refresh() } }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func refresh() async {
        var collected = Set<String>()
        for src in sources {
            guard let (data, _) = try? await URLSession.shared.data(from: src),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !t.hasPrefix("#"),
                      t.hasPrefix("udp://") || t.hasPrefix("http://")
                      || t.hasPrefix("https://") || t.hasPrefix("wss://") else { continue }
                collected.insert(t)
            }
        }
        lock.lock()
        let black = blacklist
        let merged = collected.filter { !black.contains($0) }.sorted()
        lastTrackers = merged
        lastError = collected.isEmpty ? "所有 Tracker 源均未返回数据（可能离线或被拦截）" : nil
        lock.unlock()
        save()
        onUpdate?(merged)
    }

    // MARK: - persistence
    public func setAutoUpdate(_ on: Bool) {
        autoUpdateEnabled = on
        UserDefaults.standard.set(on, forKey: Self.autoKey)
        if on { start() } else { stop() }
    }

    public func setBlacklist(_ raw: String) {
        let set = Set(raw.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        blacklist = set
        UserDefaults.standard.set(Array(set), forKey: Self.blacklistKey)
        // Re-apply with the new blacklist immediately.
        lock.lock(); let current = lastTrackers; lock.unlock()
        onUpdate?(current)
    }

    private func load() {
        autoUpdateEnabled = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
        if let arr = UserDefaults.standard.array(forKey: Self.blacklistKey) as? [String] {
            blacklist = Set(arr)
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(blacklist), forKey: Self.blacklistKey)
    }
}
