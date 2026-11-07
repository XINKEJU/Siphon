import Foundation
import Observation

/// A named queue with a concurrency limit and an optional active time window.
/// Inspired by AB Download Manager's queues/schedulers and HyperDM's schedule window.
public struct DownloadQueue: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var maxConcurrent: Int
    public var isSequential: Bool
    /// Optional schedule, e.g. 00:00–07:00. `nil` means always active.
    public var startHour: Int?
    public var endHour: Int?

    public init(id: UUID = UUID(), name: String, maxConcurrent: Int = 3,
                isSequential: Bool = false, startHour: Int? = nil, endHour: Int? = nil) {
        self.id = id; self.name = name; self.maxConcurrent = maxConcurrent
        self.isSequential = isSequential; self.startHour = startHour; self.endHour = endHour
    }

    public func isActive(at date: Date = Date()) -> Bool {
        guard let s = startHour, let e = endHour else { return true }
        let hour = Calendar.current.component(.hour, from: date)
        // Window may wrap midnight (e.g. 23:00–07:00).
        if s <= e { return hour >= s && hour < e }
        return hour >= s || hour < e
    }
}

/// Owns queue definitions and decides which pending task may start next.
@MainActor
@Observable
public final class QueueManager {
    public var queues: [DownloadQueue] = [DownloadQueue(name: "Default", maxConcurrent: 3)]
    public var globalConcurrent: Int = 5

    private let defaultsKey = "Siphon.queues"

    public init() { load() }

    public func add(name: String, maxConcurrent: Int = 3, isSequential: Bool = false,
                    startHour: Int? = nil, endHour: Int? = nil) {
        queues.append(DownloadQueue(name: name, maxConcurrent: maxConcurrent,
                                    isSequential: isSequential,
                                    startHour: startHour, endHour: endHour))
        save()
    }

    public func update(_ queue: DownloadQueue) {
        if let i = queues.firstIndex(where: { $0.id == queue.id }) { queues[i] = queue; save() }
    }

    public func remove(_ id: UUID) {
        queues.removeAll { $0.id == id }
        save()
    }

    public func queue(named name: String) -> DownloadQueue? {
        queues.first { $0.name == name }
    }

    /// Select up to `slots` pending tasks that are allowed to start, respecting each
    /// queue's concurrency, sequential mode, schedule window, and the global cap.
    public func nextToStart(from tasks: [DownloadTask], slots: Int) -> [UUID] {
        let activeByQueue = Dictionary(grouping: tasks.filter { $0.state == .active }) { $0.queueName }
            .mapValues(\.count)
        let globalActive = tasks.filter { $0.state == .active }.count
        var remaining = max(0, min(slots, globalConcurrent - globalActive))
        guard remaining > 0 else { return [] }

        var result: [UUID] = []
        var queuedByQueue: [String: Int] = [:]
        let pending = tasks.filter { $0.state == .pending }.sorted { $0.createdAt < $1.createdAt }
        for task in pending {
            guard remaining > 0 else { break }
            guard let q = queue(named: task.queueName), q.isActive() else { continue }
            let limit = q.isSequential ? 1 : q.maxConcurrent
            let running = activeByQueue[task.queueName, default: 0]
                + (queuedByQueue[task.queueName] ?? 0)
            if running < limit {
                result.append(task.id)
                queuedByQueue[task.queueName, default: 0] += 1
                remaining -= 1
            }
        }
        return result
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(queues) else { return }
        UserDefaults.standard.set(d, forKey: defaultsKey)
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([DownloadQueue].self, from: d),
              !decoded.isEmpty else { return }
        queues = decoded
    }
}
