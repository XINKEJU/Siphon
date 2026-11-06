import Foundation

/// One HTTP range request contributing to a segmented download.
public struct SegmentRequest: Sendable {
    public let url: URL
    public let byteRange: (length: Int, offset: Int)?
    public init(url: URL, byteRange: (length: Int, offset: Int)? = nil) {
        self.url = url
        self.byteRange = byteRange
    }
}

/// Shared engine for all "playlist → N segments → ordered concatenation" protocols
/// (HLS, DASH, and future HLS/fMP4). This is the piece that both engines had in
/// duplicate; centralising it keeps behaviour identical and the code small.
///
/// Guarantees:
/// - bounded concurrency (6 in-flight requests by default)
/// - strictly ordered writes, so the output container stays valid
/// - resume by skipping already-written segments (segment-level transforms are stateless)
/// - per-segment transform hook (used by HLS AES-128 decryption)
public final class SegmentAssembler {
    private final class Active {
        let requests: [SegmentRequest]
        let handle: FileHandle
        let outURL: URL
        let headers: [String: String]
        let transform: (@Sendable (Data, Int) -> Data)?
        var writtenCount: Int
        var cancelled = false
        var lastBytes: Int64 = 0
        var lastTime = Date()
        var task: Task<Void, Never>?

        init(requests: [SegmentRequest], handle: FileHandle, outURL: URL,
             headers: [String: String], transform: (@Sendable (Data, Int) -> Data)?,
             writtenCount: Int) {
            self.requests = requests; self.handle = handle; self.outURL = outURL
            self.headers = headers; self.transform = transform
            self.writtenCount = writtenCount; self.lastTime = Date()
        }
    }

    public weak var delegate: (any EngineDelegate)?
    private var active: [UUID: Active] = [:]
    private let session = URLSession.shared
    private let concurrency: Int

    public init(concurrency: Int = 6) { self.concurrency = max(1, concurrency) }

    public func start(taskID: UUID, destination: URL, requests: [SegmentRequest],
                      headers: [String: String] = [:],
                      transform: (@Sendable (Data, Int) -> Data)? = nil,
                      resume: Bool = false) throws {
        if requests.isEmpty { return }
        let existing = !FileManager.default.fileExists(atPath: destination.path)
        if existing { FileManager.default.createFile(atPath: destination.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: destination)
        if resume { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }

        let written = resume ? (active[taskID]?.writtenCount ?? 0) : 0
        let state = Active(requests: requests, handle: handle, outURL: destination,
                          headers: headers, transform: transform, writtenCount: written)
        state.task = Task.detached(priority: .utility) { [weak self] in
            await self?.run(state, taskID: taskID)
        }
        active[taskID] = state
    }

    public func pause(_ id: UUID) {
        active[id]?.cancelled = true
        active[id]?.task?.cancel()
    }

    /// Re-arm after a pause. The file handle is kept open in append mode.
    public func resume(_ id: UUID) throws {
        guard let s = active[id] else { return }
        s.cancelled = false
        try s.handle.seekToEnd()
        s.task?.cancel()
        s.task = Task.detached(priority: .utility) { [weak self] in
            await self?.run(s, taskID: id)
        }
    }

    public func remove(_ id: UUID) {
        guard let s = active.removeValue(forKey: id) else { return }
        s.cancelled = true
        s.task?.cancel()
        try? s.handle.close()
        try? FileManager.default.removeItem(at: s.outURL)
    }

    // MARK: - ordered, bounded-concurrency assembly
    private func run(_ s: Active, taskID: UUID) async {
        var completed: [Int: Data] = [:]
        var nextToWrite = s.writtenCount
        var nextToFetch = s.writtenCount

        do {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var inFlight = 0
                func pump() {
                    while nextToFetch < s.requests.count && inFlight < concurrency {
                        let req = s.requests[nextToFetch]
                        let order = nextToFetch
                        nextToFetch += 1
                        inFlight += 1
                        group.addTask { [weak self] in
                            guard let self else { return (order, Data()) }
                            let d = try await self.fetch(req, headers: s.headers)
                            await SpeedLimitController.shared.consume(d.count)
                            return (order, d)
                        }
                    }
                }
                pump()
                while let (order, data) = try await group.next() {
                    inFlight -= 1
                    if s.cancelled { group.cancelAll(); break }
                    completed[order] = data
                    while let d = completed.removeValue(forKey: nextToWrite) {
                        let final = s.transform?(d, nextToWrite) ?? d
                        try s.handle.write(contentsOf: final)
                        nextToWrite += 1
                        s.writtenCount = nextToWrite
                        await self.report(s, taskID: taskID)
                    }
                    pump()
                }
            }
            try s.handle.close()
            if s.cancelled {
                await delegate?.engineDidChangeState(taskID: taskID, state: .paused, error: nil)
            } else {
                var p = DownloadProgress()
                p.totalBytes = Int64(s.requests.count)
                p.downloadedBytes = Int64(s.requests.count)
                await delegate?.engineDidUpdate(taskID: taskID, progress: p)
                await delegate?.engineDidChangeState(taskID: taskID, state: .completed, error: nil)
            }
        } catch is CancellationError {
            try? s.handle.close()
            await delegate?.engineDidChangeState(taskID: taskID, state: .paused, error: nil)
        } catch {
            try? s.handle.close()
            await delegate?.engineDidChangeState(taskID: taskID, state: .error, error: error)
        }
    }

    private func report(_ s: Active, taskID: UUID) async {
        var p = DownloadProgress()
        p.totalBytes = Int64(s.requests.count)
        p.downloadedBytes = Int64(s.writtenCount)
        let now = Date()
        let dt = now.timeIntervalSince(s.lastTime)
        if dt > 0 {
            p.speedBytesPerSec = Int64(Double(Int64(s.writtenCount) - s.lastBytes) / dt)
        }
        s.lastBytes = Int64(s.writtenCount)
        s.lastTime = now
        await delegate?.engineDidUpdate(taskID: taskID, progress: p)
    }

    private func fetch(_ req: SegmentRequest, headers: [String: String]) async throws -> Data {
        var r = URLRequest(url: req.url)
        r.httpMethod = "GET"
        if let (len, off) = req.byteRange {
            r.setValue("bytes=\(off)-\(off + len - 1)", forHTTPHeaderField: "Range")
        }
        for (k, v) in headers where !["dir", "out"].contains(k.lowercased()) {
            r.setValue(v, forHTTPHeaderField: k)
        }
        let (data, _) = try await session.data(for: r)
        return data
    }
}
