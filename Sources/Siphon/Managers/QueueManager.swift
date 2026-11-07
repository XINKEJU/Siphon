import Foundation
import Observation

/// A named queue with a concurrency limit, an optional active time window,
/// a scheduling priority and an aggregate speed cap.
/// Inspired by AB Download Manager's queues/schedulers and HyperDM's schedule window.
public struct DownloadQueue: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var maxConcurrent: Int
    public var isSequential: Bool
    /// Optional schedule, e.g. 00:00–07:00. `nil` means always active.
    public var startHour: Int?
    public var endHour: Int?
    /// Higher-priority queues win pending slots before lower ones.
    public var priority: Int
    /// Aggregate cap for this queue in bytes/s; `0` means unlimited. The
    /// store divides it among the queue's active tasks.
    public var speedLimit: Int64

    public init(id: UUID = UUID(), name: String, maxConcurrent: Int = 3,
                isSequential: Bool = false, startHour: Int? = nil, endHour: Int? = nil,
                priority: Int = 0, speedLimit: Int64 = 0) {
        self.id = id; self.name = name; self.maxConcurrent = maxConcurrent
        self.isSequential = isSequential; self.startHour = startHour; self.endHour = endHour
        self.priority = priority
        self.speedLimit = speedLimit
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, maxConcurrent, isSequential, startHour, endHour, priority, speedLimit
    }

    /// Custom decode so queues persisted before priority/speed existed still
    /// load with sane defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        maxConcurrent = (try? c.decode(Int.self, forKey: .maxConcurrent)) ?? 3
        isSequential = (try? c.decode(Bool.self, forKey: .isSequential)) ?? false
        startHour = try? c.decodeIfPresent(Int.self, forKey: .startHour)
        endHour = try? c.decodeIfPresent(Int.self, forKey: .endHour)
        priority = (try? c.decode(Int.self, forKey: .priority)) ?? 0
        speedLimit = (try? c.decode(Int64.self, forKey: .speedLimit)) ?? 0
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
    private let globalKey = "Siphon.globalConcurrent"

    public init() {
        let saved = UserDefaults.standard.integer(forKey: globalKey)
        globalConcurrent = saved > 0 ? saved : 5
        load()
    }

    public func setGlobalConcurrent(_ n: Int) {
        globalConcurrent = max(1, n)
        UserDefaults.standard.set(globalConcurrent, forKey: globalKey)
    }

    public func add(name: String, maxConcurrent: Int = 3, isSequential: Bool = false,
                    startHour: Int? = nil, endHour: Int? = nil,
                    priority: Int = 0, speedLimit: Int64 = 0) {
        queues.append(DownloadQueue(name: name, maxConcurrent: maxConcurrent,
                                    isSequential: isSequential,
                                    startHour: startHour, endHour: endHour,
                                    priority: priority, speedLimit: speedLimit))
        save()
    }

    public func update(_ queue: DownloadQueue) {
        if let i = queues.firstIndex(where: { $0.id == queue.id }) { queues[i] = queue; save() }
    }

    /// Replace the whole set (Settings edits a local draft, then commits).
    /// The Default queue is the reassignment anchor — always keep one.
    public func replaceAll(_ newQueues: [DownloadQueue]) {
        guard !newQueues.isEmpty else { return }
        var q = newQueues
        if !q.contains(where: { $0.name == "Default" }) {
            q.append(DownloadQueue(name: "Default", maxConcurrent: 3))
        }
        queues = q
        save()
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
    /// Order: task priority desc → queue priority desc → creation time.
    public func nextToStart(from tasks: [DownloadTask], slots: Int) -> [UUID] {
        let activeByQueue = Dictionary(grouping: tasks.filter { $0.state == .active }) { $0.queueName }
            .mapValues(\.count)
        let globalActive = tasks.filter { $0.state == .active }.count
        var remaining = max(0, min(slots, globalConcurrent - globalActive))
        guard remaining > 0 else { return [] }

        var result: [UUID] = []
        var queuedByQueue: [String: Int] = [:]
        let pending = tasks.filter { $0.state == .pending }.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let pa = queue(named: a.queueName)?.priority ?? 0
            let pb = queue(named: b.queueName)?.priority ?? 0
            if pa != pb { return pa > pb }
            return a.createdAt < b.createdAt
        }
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
