import Foundation
import Observation

/// 持久化的传输统计（借鉴 Motrix 仪表盘）：按天累计下载字节数、完成/失败任务数。
/// 保存在 Application Support/Siphon/stats.json，最多保留 90 天。
@MainActor
@Observable
public final class TransferStats {
    public struct DayRecord: Codable, Identifiable, Sendable, Equatable {
        public var day: String          // yyyy-MM-dd
        public var bytes: Int64 = 0
        public var completed: Int = 0
        public var failed: Int = 0
        public var id: String { day }
    }

    public static let shared = TransferStats()

    public private(set) var days: [DayRecord] = []
    private let keepDays = 90
    private let fileURL: URL
    private var lastSave = Date.distantPast
    private var saveScheduled = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Siphon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("stats.json")
        load()
    }

    // MARK: - 汇总

    public var todayBytes: Int64 { todayRecord?.bytes ?? 0 }
    public var todayCompleted: Int { todayRecord?.completed ?? 0 }
    public var last7DaysBytes: Int64 {
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }.reduce(0) { $0 + $1.bytes }
    }
    public var totalBytes: Int64 { days.reduce(0) { $0 + $1.bytes } }
    public var totalCompleted: Int { days.reduce(0) { $0 + $1.completed } }

    private var todayRecord: DayRecord? {
        days.last(where: { $0.day == Self.dayKey(Date()) })
    }

    // MARK: - 记账

    public func addDownloaded(_ bytes: Int64) {
        guard bytes > 0 else { return }
        mutateToday { $0.bytes += bytes }
    }

    public func recordCompletion(success: Bool) {
        mutateToday { if success { $0.completed += 1 } else { $0.failed += 1 } }
    }

    private func mutateToday(_ body: (inout DayRecord) -> Void) {
        let key = Self.dayKey(Date())
        var rec = days.last(where: { $0.day == key }) ?? DayRecord(day: key)
        body(&rec)
        if let i = days.firstIndex(where: { $0.day == key }) {
            days[i] = rec
        } else {
            days.append(rec)
        }
        days.sort { $0.day < $1.day }
        if days.count > keepDays { days.removeFirst(days.count - keepDays) }
        saveThrottled()
    }

    // MARK: - 持久化

    private func saveThrottled() {
        if Date().timeIntervalSince(lastSave) >= 10 {
            save()
        } else if !saveScheduled {
            saveScheduled = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                self.saveScheduled = false
                self.save()
            }
        }
    }

    public func flush() { save() }

    private func save() {
        lastSave = Date()
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([DayRecord].self, from: data) else { return }
        days = Array(saved.sorted { $0.day < $1.day }.suffix(keepDays))
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
