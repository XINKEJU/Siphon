import Foundation
import OSLog

private let hostHealthLog = Logger(subsystem: "com.xinkeju.siphon.macos", category: "host-health")

/// 主机级健康度（借鉴 FluxDown `cdn/health.rs` 的节点先验模型）。
///
/// URLSession 无法直接指定 CDN 节点 IP，所以这里退一步按主机（host）记录：
///  * 吞吐 **EWMA**：跨任务、跨重启保留，新样本权重 0.3；
///  * **24h TTL**：过期条目自动淘汰；
///  * **熔断**：连续失败达到阈值时把并发连接数降到 1~2，成功后自动恢复；
///  * **上限裁剪**：最多保留 200 条，按更新时间保留最新。
/// 数据写入 Application Support 下的 `Siphon/host_health.json`。
final class HostHealthStore: @unchecked Sendable {
    static let shared = HostHealthStore()

    struct Entry: Codable {
        var ewma: Double = 0
        var samples: Int = 0
        var failureStreak: Int = 0
        var updated: Date = Date()
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 24 * 3600
    private let maxEntries = 200
    private let degradeSpeed: Double = 64 * 1024   // 低于 64 KiB/s 视为明显退化
    private let fileURL: URL
    private var lastSave = Date.distantPast

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Siphon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("host_health.json")
        load()
    }

    /// 记录一次成功的传输样本（字节数 / 耗时）。
    func record(host: String, bytes: Int64, duration: TimeInterval) {
        guard !host.isEmpty, !Self.isLocal(host), bytes > 0, duration > 0.05 else { return }
        let speed = Double(bytes) / duration
        lock.lock()
        var e = entries[host] ?? Entry()
        e.ewma = e.samples == 0 ? speed : e.ewma * 0.7 + speed * 0.3
        e.samples += 1
        e.failureStreak = 0
        e.updated = Date()
        entries[host] = e
        lock.unlock()
        maybeSave()
    }

    /// 记录一次失败，用于熔断。
    func recordFailure(host: String) {
        guard !host.isEmpty, !Self.isLocal(host) else { return }
        lock.lock()
        var e = entries[host] ?? Entry()
        e.failureStreak += 1
        e.updated = Date()
        entries[host] = e
        lock.unlock()
        maybeSave()
    }

    /// 成功完成后清除失败连击，让熔断尽快恢复。
    func markHealthy(host: String) {
        guard !host.isEmpty, !Self.isLocal(host) else { return }
        lock.lock()
        if var e = entries[host] {
            e.failureStreak = 0
            e.updated = Date()
            entries[host] = e
        }
        lock.unlock()
    }

    /// 根据健康度收紧并发连接数（熔断）。未知主机原样返回。
    func suggestedConnections(host: String, requested: Int) -> Int {
        guard !host.isEmpty, !Self.isLocal(host) else { return requested }
        lock.lock()
        pruneLocked(now: Date())
        let e = entries[host]
        lock.unlock()
        guard let e, Date().timeIntervalSince(e.updated) < ttl else { return requested }
        if e.failureStreak >= 3 { return 1 }
        if e.failureStreak == 2 { return min(requested, 2) }
        if e.samples >= 2, e.ewma < degradeSpeed { return min(requested, 2) }
        return requested
    }

    /// 镜像排序用的健康度惩罚（负值 = 越差），0 表示没有先验。
    func penalty(host: String) -> Double {
        guard !host.isEmpty, !Self.isLocal(host) else { return 0 }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[host],
              Date().timeIntervalSince(e.updated) < ttl,
              e.failureStreak >= 2 else { return 0 }
        return -Double(e.failureStreak)
    }

    /// 本机回环地址不参与健康度：测试与本地服务不该被熔断。
    private static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    // MARK: - 持久化

    private func pruneLocked(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.updated) < ttl }
        if entries.count > maxEntries {
            let keep = entries.sorted { $0.value.updated > $1.value.updated }
                .prefix(maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private func maybeSave() {
        lock.lock()
        let due = Date().timeIntervalSince(lastSave) >= 5
        if due { lastSave = Date() }
        pruneLocked(now: Date())
        let snapshot = due ? entries : nil
        lock.unlock()
        guard let snapshot,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            hostHealthLog.error("host health persistence failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        let now = Date()
        entries = saved.filter { now.timeIntervalSince($0.value.updated) < ttl }
        pruneLocked(now: now)
    }
}
