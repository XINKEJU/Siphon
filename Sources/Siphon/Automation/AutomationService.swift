import Foundation

/// Unified automation command contract shared by CLI, REST, MCP, MDXP and the
/// remote HTTPS server. Every entry point converges on this service so there is
/// exactly one place where task state is mutated and errors are mapped.
@MainActor
public final class AutomationService {
    public static let shared = AutomationService()

    public weak var store: DownloadStore?

    private init() {}

    // MARK: - Errors

    public enum AutomationError: Error, Codable, Sendable {
        case invalidParams(String)
        case unauthorized
        case forbidden
        case notFound(String)
        case conflict(String)
        case idempotencyConflict
        case upstreamFailure(String)
        case internalError(String)

        public var code: String {
            switch self {
            case .invalidParams: return "invalid_params"
            case .unauthorized: return "unauthorized"
            case .forbidden: return "forbidden"
            case .notFound: return "not_found"
            case .conflict: return "conflict"
            case .idempotencyConflict: return "idempotency_conflict"
            case .upstreamFailure: return "upstream_failure"
            case .internalError: return "internal_error"
            }
        }

        public var message: String {
            switch self {
            case .invalidParams(let s): return s
            case .unauthorized: return "Authentication required"
            case .forbidden: return "Permission denied"
            case .notFound(let s): return s
            case .conflict(let s): return s
            case .idempotencyConflict: return "Idempotency key already used with a different request"
            case .upstreamFailure(let s): return s
            case .internalError(let s): return s
            }
        }

        public var httpStatus: Int {
            switch self {
            case .invalidParams: return 400
            case .unauthorized: return 401
            case .forbidden: return 403
            case .notFound: return 404
            case .conflict, .idempotencyConflict: return 409
            case .upstreamFailure: return 502
            case .internalError: return 500
            }
        }
    }

    // MARK: - Idempotency

    private struct IdempotencyRecord: Codable {
        let principal: String
        let key: String
        let requestHash: String
        let responseData: Data
        let createdAt: Date
    }

    private var idempotencyCache: [String: IdempotencyRecord] = [:]
    private let idempotencyLimit = 256
    private let idempotencyFile = "automation-idempotency.json"

    /// Execute `work` idempotently. Same `(principal, key, requestHash)` returns the
    /// cached response; same key with a different hash yields 409; concurrent calls
    /// with the same key are coalesced into one execution.
    public func executeIdempotent<T: Codable>(
        principal: String,
        key: String?,
        requestHash: String,
        work: () async throws -> T
    ) async throws -> T {
        guard let key, !key.isEmpty else { return try await work() }
        let cacheKey = "\(principal):\(key)"
        if let record = idempotencyCache[cacheKey] {
            if record.requestHash == requestHash {
                return try JSONDecoder().decode(T.self, from: record.responseData)
            }
            throw AutomationError.idempotencyConflict
        }
        let result = try await work()
        let data = try JSONEncoder().encode(result)
        let record = IdempotencyRecord(principal: principal, key: key,
                                       requestHash: requestHash,
                                       responseData: data, createdAt: Date())
        idempotencyCache[cacheKey] = record
        if idempotencyCache.count > idempotencyLimit {
            let sorted = idempotencyCache.sorted { $0.value.createdAt < $1.value.createdAt }
            for item in sorted.prefix(idempotencyCache.count - idempotencyLimit) {
                idempotencyCache.removeValue(forKey: item.key)
            }
        }
        persistIdempotency()
        return result
    }

    private func persistIdempotency() {
        let dir = MDMProduct.dataDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(idempotencyFile)
        let records = Array(idempotencyCache.values)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func loadIdempotency() {
        let url = MDMProduct.dataDirectory().appendingPathComponent(idempotencyFile)
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([IdempotencyRecord].self, from: data) else { return }
        for r in records {
            idempotencyCache["\(r.principal):\(r.key)"] = r
        }
    }

    // MARK: - Commands

    public struct AddCommand: Codable, Sendable {
        public var url: String
        public var dir: String?
        public var name: String?
        public var category: String?
        public var queue: String?
        public var checksum: String?
        public var later: Bool?

        public init(url: String, dir: String? = nil, name: String? = nil,
                    category: String? = nil, queue: String? = nil,
                    checksum: String? = nil, later: Bool? = nil) {
            self.url = url; self.dir = dir; self.name = name
            self.category = category; self.queue = queue
            self.checksum = checksum; self.later = later
        }
    }

    public struct TaskIDCommand: Codable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }

    public struct ListQuery: Codable, Sendable {
        public var state: String?
        public var queue: String?
        public var category: String?
        public var query: String?
        public init(state: String? = nil, queue: String? = nil,
                    category: String? = nil, query: String? = nil) {
            self.state = state; self.queue = queue; self.category = category; self.query = query
        }
    }

    public func add(_ cmd: AddCommand) async throws -> MDMAddAnswer {
        guard let store else { throw AutomationError.internalError("Store not ready") }
        guard URL(string: cmd.url) != nil else {
            throw AutomationError.invalidParams("Invalid URL")
        }
        let mdm = MDMCommand(url: cmd.url, dir: cmd.dir, name: cmd.name,
                             description: nil, checksum: cmd.checksum,
                             later: cmd.later, category: cmd.category, queue: cmd.queue)
        let answer = await store.addMDMCommand(mdm)
        if !answer.ok {
            throw AutomationError.upstreamFailure(answer.note ?? "Add failed")
        }
        return answer
    }

    public func list(_ query: ListQuery = ListQuery()) -> MDMListAnswer {
        guard let store else { return MDMListAnswer(downloads: [], speed: 0, queues: [], categories: [], free: nil) }
        var tasks = store.tasks
        if let state = query.state {
            tasks = tasks.filter { MDMStatus($0.state).rawValue == state }
        }
        if let queue = query.queue {
            tasks = tasks.filter { $0.queueName == queue }
        }
        if let category = query.category {
            tasks = tasks.filter { ($0.category ?? MDMCategory.categorize(fileName: $0.name).rawValue) == category }
        }
        if let q = query.query?.lowercased(), !q.isEmpty {
            tasks = tasks.filter { $0.name.lowercased().contains(q) || $0.source.absoluteString.lowercased().contains(q) }
        }
        let downloads = tasks.map(MDMDownloadInfo.init)
        let speed = tasks.reduce(Int64(0)) { $0 + $1.progress.speedBytesPerSec }
        let queues = Array(Set(tasks.map(\.queueName))).sorted()
        let categories = CategoryStore.shared.categories.map(\.key)
        return MDMListAnswer(downloads: downloads, speed: speed, queues: queues,
                             categories: categories, free: nil)
    }

    public func pause(_ id: String) async throws {
        guard let uuid = UUID(uuidString: id) else { throw AutomationError.invalidParams("Invalid task id") }
        guard let store, store.tasks.contains(where: { $0.id == uuid }) else {
            throw AutomationError.notFound("Task not found")
        }
        store.pause(uuid)
    }

    public func resume(_ id: String) async throws {
        guard let uuid = UUID(uuidString: id) else { throw AutomationError.invalidParams("Invalid task id") }
        guard let store, store.tasks.contains(where: { $0.id == uuid }) else {
            throw AutomationError.notFound("Task not found")
        }
        store.resume(uuid)
    }

    public func remove(_ id: String, deleteFile: Bool = false) async throws {
        guard let uuid = UUID(uuidString: id) else { throw AutomationError.invalidParams("Invalid task id") }
        guard let store, store.tasks.contains(where: { $0.id == uuid }) else {
            throw AutomationError.notFound("Task not found")
        }
        if deleteFile {
            store.deleteTasks([uuid])
        } else {
            store.removeTasks([uuid])
        }
    }

    public func startQueue() async throws {
        guard let store else { throw AutomationError.internalError("Store not ready") }
        store.resumeAll()
    }

    public func stopQueue() async throws {
        guard let store else { throw AutomationError.internalError("Store not ready") }
        store.pauseAll()
    }

    public func schema() -> [String: Any] {
        AutomationSchema.document
    }
}
