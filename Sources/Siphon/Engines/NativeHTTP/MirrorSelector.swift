import Foundation

/// Speed-driven mirror/source selection (aria2 AdaptiveURISelector model).
///
/// Tracks an EWMA of observed per-segment throughput plus failure counts per
/// source URL. The HTTP engine consults it (a) to order the failover chain and
/// (b) to distribute segment workers across mirrors so the fastest source gets
/// the most work. Knowledge is in-memory with a TTL: it survives across tasks
/// within a session (like `DomainConnPolicy`) but never outlives the process.
final class MirrorSelector: @unchecked Sendable {
    static let shared = MirrorSelector()

    private struct Entry {
        var ewma: Double = 0      // bytes/sec
        var failures: Int = 0
        var samples: Int = 0
        var updated: Date
    }

    private let lock = NSLock()
    private var table: [URL: Entry] = [:]
    private let ttl: TimeInterval = 3_600

    /// Candidates ordered best-first. Stable: equal scores keep input order
    /// (document/priority order from the Metalink or the mirror list).
    func ranked(_ candidates: [URL]) -> [URL] {
        lock.lock()
        let now = Date()
        let scores = Dictionary(uniqueKeysWithValues:
            candidates.map { ($0, score($0, now: now)) })
        lock.unlock()
        return candidates.enumerated()
            .sorted { a, b in
                scores[a.element] != scores[b.element]
                    ? scores[a.element]! > scores[b.element]!
                    : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Raw score for external multi-criteria choices (higher = better).
    /// Negative = observed failures; 0 = untested.
    func score(_ url: URL) -> Double {
        lock.lock(); defer { lock.unlock() }
        return score(url, now: Date())
    }

    private func score(_ url: URL, now: Date) -> Double {
        // 主机级失败先验（跨任务、跨重启）参与排序：连续失败过的源明显降权。
        let health = HostHealthStore.shared.penalty(host: url.host ?? "") * 1_000_000_000
        guard let e = table[url], now.timeIntervalSince(e.updated) < ttl else { return health }
        guard e.failures == 0 else { return health - Double(e.failures) }
        return health + e.ewma
    }

    func record(_ url: URL, bytes: Int64, duration: TimeInterval) {
        guard bytes > 0, duration > 0.05 else { return }
        let speed = Double(bytes) / duration
        lock.lock(); defer { lock.unlock() }
        var e = table[url] ?? Entry(updated: Date())
        e.ewma = e.samples == 0 ? speed : e.ewma * 0.7 + speed * 0.3
        e.samples += 1
        e.failures = 0
        e.updated = Date()
        table[url] = e
    }

    func recordFailure(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        var e = table[url] ?? Entry(updated: Date())
        e.failures += 1
        e.updated = Date()
        table[url] = e
    }
}
