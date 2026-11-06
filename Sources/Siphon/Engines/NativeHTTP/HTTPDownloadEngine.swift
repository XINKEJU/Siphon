import Foundation

/// Native, dependency-free download engine for HTTP/HTTPS/FTP and every URI
/// front-end (`thunder`, `webdav`, `s3`, `ipfs`, …) that `URINormalizer` rewrites
/// onto a plain HTTP(S) request. This replaces the bundled `aria2c` for those
/// protocols: no external binary, no dylibs, a smaller app bundle, and no
/// subprocess to supervise.
///
/// Strategy: `HEAD` (or a zero-length `Range` probe) to learn `Content-Length` and
/// `Accept-Ranges`. If the server honours byte ranges, the file is split into
/// concurrent segments (each a `Range` request) and written back into the output at
/// their own offsets through a single serialised file handle. Speed is throttled by
/// the shared `SpeedLimitController` token bucket — the same one aria2 used to honour.
public final class HTTPDownloadEngine: DownloadEngine {
    public let name = "native-http"
    public let supportedProtocols: Set<DownloadProtocol> =
        Set(DownloadProtocol.allCases.filter { $0.transport == .native })
    public weak var delegate: (any EngineDelegate)?

    /// Segments the last `submit` planned. Exposed for tests / diagnostics.
    public var lastSegmentCount: Int = 0
    /// Last state reported (or about to be reported) to the delegate. Polled by tests.
    public var lastState: DownloadState = .pending

    private final class Job {
        let task: DownloadTask
        var handle: Task<Void, Never>?
        var cancelled = false
        init(_ t: DownloadTask) { task = t }
    }
    private final class ProgressTracker {
        var written: Int64 = 0
        var lastReport = Date()
        var lastBytes: Int64 = 0
    }

    private var jobs: [UUID: Job] = [:]
    private let writeQueue = DispatchQueue(label: "siphon.nativehttp.write")
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    public init() {}

    public func canHandle(_ p: DownloadProtocol) -> Bool { supportedProtocols.contains(p) }

    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {
        // The global token bucket (SpeedLimitController) is already consulted by
        // every native download; there is no per-engine limit to forward.
    }

    public func submit(_ task: DownloadTask) async throws {
        let job = Job(task)
        job.handle = Task { [weak self] in
            await self?.run(job)
        }
        jobs[task.id] = job
    }

    public func pause(_ id: UUID) async {
        jobs[id]?.cancelled = true
        jobs[id]?.handle?.cancel()
        await report(.paused, for: id)
    }

    public func resume(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        job.cancelled = false
        job.handle?.cancel()
        job.handle = Task { [weak self] in
            await self?.run(job)
        }
    }

    public func remove(_ id: UUID) async {
        if let job = jobs.removeValue(forKey: id) {
            job.cancelled = true
            job.handle?.cancel()
            try? FileManager.default.removeItem(at: job.task.destination)
        }
    }

    // MARK: - core

    private func run(_ job: Job) async {
        let task = job.task
        let out = task.destination
        do {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
        } catch {
            await report(.error, for: task.id, error: error)
            return
        }

        // Short-circuit: a fully downloaded file is already complete.
        let probe = await probe(url: task.source, headers: task.options)
        if probe.length > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: out.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value, size == probe.length {
            var p = DownloadProgress()
            p.totalBytes = size; p.downloadedBytes = size
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
            await report(.completed, for: task.id)
            return
        }

        let total = probe.length
        let canRange = probe.acceptsRanges && total > 0
        let segments = planSegments(total: total, canRange: canRange)
        lastSegmentCount = segments.count

        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: out) }
        catch { await report(.error, for: task.id, error: error); return }
        defer { try? handle.close() }
        if canRange && total > 0 { try? handle.truncate(atOffset: UInt64(total)) }

        let tracker = ProgressTracker()
        await report(.active, for: task.id)

        let ok = await download(segments: segments, url: task.source, headers: task.options,
                               handle: handle, tracker: tracker, total: total, job: job)

        if job.cancelled {
            await report(.paused, for: task.id)
        } else if ok {
            var p = DownloadProgress()
            p.totalBytes = total > 0 ? total : tracker.written
            p.downloadedBytes = tracker.written
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
            await report(.completed, for: task.id)
        } else {
            await report(.error, for: task.id, error: URLError(.cannotLoadFromNetwork))
        }
    }

    private func planSegments(total: Int64, canRange: Bool) -> [(start: Int64, end: Int64)] {
        guard canRange else { return [(0, max(0, total - 1))] }
        let minSplit: Int64 = 1_048_576
        guard total >= minSplit * Int64(2) else { return [(0, max(0, total - 1))] }
        let maxSeg = 8
        let n = min(maxSeg, max(1, Int(total / minSplit)))
        let segLen = total / Int64(n)
        var segs: [(Int64, Int64)] = []
        for i in 0..<n {
            let start = Int64(i) * segLen
            let end = (i == n - 1) ? total - 1 : start + segLen - 1
            segs.append((start, end))
        }
        return segs
    }

    private func download(segments: [(start: Int64, end: Int64)], url: URL, headers: [String: String],
                         handle: FileHandle, tracker: ProgressTracker,
                         total: Int64, job: Job) async -> Bool {
        if segments.count == 1 {
            do {
                try await streamSegment(start: 0, end: max(0, total - 1), url: url,
                                        headers: headers, handle: handle, tracker: tracker,
                                        total: total, job: job, useRange: false)
                return !job.cancelled
            } catch { return false }
        }
        return await withThrowingTaskGroup(of: Bool.self) { group in
            for seg in segments {
                group.addTask {
                    do {
                        try await self.streamSegment(start: seg.start, end: seg.end, url: url,
                                                     headers: headers, handle: handle,
                                                     tracker: tracker, total: total, job: job,
                                                     useRange: true)
                        return true
                    } catch { return false }
                }
            }
            var allOk = true
            while let r = try? await group.next() { if r == false { allOk = false } }
            return allOk && !job.cancelled
        }
    }

    private func streamSegment(start: Int64, end: Int64, url: URL, headers: [String: String],
                               handle: FileHandle, tracker: ProgressTracker, total: Int64,
                               job: Job, useRange: Bool) async throws {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "GET"
        for (k, v) in headers where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if useRange && end >= start {
            req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }
        let (asyncBytes, response) = try await session.bytes(for: req)
        if useRange, let http = response as? HTTPURLResponse, http.statusCode != 206 {
            // Server advertised ranges but ignored them — writing a full body at
            // `start` would corrupt the file, so fail the segment loudly.
            throw URLError(.badServerResponse)
        }

        var buffer = Data()
        var offset = start
        let flushThreshold = 1 << 16 // 64 KiB
        for try await byte in asyncBytes {
            if job.cancelled { throw CancellationError() }
            buffer.append(byte)
            if buffer.count >= flushThreshold {
                await SpeedLimitController.shared.consume(buffer.count)
                let advanced = flushAndReport(buffer, at: offset, handle: handle,
                                             tracker: tracker, total: total, taskID: job.task.id)
                offset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if let p = advanced { await delegate?.engineDidUpdate(taskID: job.task.id, progress: p) }
            }
        }
        if !buffer.isEmpty {
            await SpeedLimitController.shared.consume(buffer.count)
            let advanced = flushAndReport(buffer, at: offset, handle: handle,
                                         tracker: tracker, total: total, taskID: job.task.id)
            offset += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if let p = advanced { await delegate?.engineDidUpdate(taskID: job.task.id, progress: p) }
        }
    }

    /// Serialised write + per-segment progress accounting. Returns a progress snapshot
    /// to surface on the main actor, or `nil` if the 250 ms throttle window is open.
    private func flushAndReport(_ data: Data, at offset: Int64, handle: FileHandle,
                                tracker: ProgressTracker, total: Int64,
                                taskID: UUID) -> DownloadProgress? {
        writeQueue.sync {
            handle.seek(toFileOffset: UInt64(offset))
            handle.write(data)
            tracker.written += Int64(data.count)
        }
        let now = Date()
        let dt = now.timeIntervalSince(tracker.lastReport)
        guard dt >= 0.25 else { return nil }
        var p = DownloadProgress()
        p.downloadedBytes = tracker.written
        p.totalBytes = total
        p.speedBytesPerSec = Int64(Double(tracker.written - tracker.lastBytes) / dt)
        tracker.lastBytes = tracker.written
        tracker.lastReport = now
        return p
    }

    private func probe(url: URL, headers: [String: String]) async
        -> (length: Int64, acceptsRanges: Bool) {
        // A bare HEAD is tried first. Only a 2xx response is trustworthy: some servers
        // (e.g. Python's BaseHTTPRequestHandler) return 501 for HEAD with an HTML error
        // body whose Content-Length would otherwise poison the length detection.
        var head = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        head.httpMethod = "HEAD"
        for (k, v) in headers where !["dir", "out"].contains(k.lowercased()) {
            head.setValue(v, forHTTPHeaderField: k)
        }
        if let (_, resp) = try? await session.data(for: head),
           let http = resp as? HTTPURLResponse,
           (200...299).contains(http.statusCode) {
            let len = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
            let ar = (http.value(forHTTPHeaderField: "Accept-Ranges")?
                        .lowercased().contains("bytes")) ?? false
            if len > 0 || ar { return (len, ar) }
        }
        // Fall back to a zero-length range GET (also covers FTP, which ignores HEAD).
        // Streamed rather than `data(for:)` so a server that ignores the Range header
        // and replies 200 with the *whole* entity is not fully downloaded during probing.
        // The transfer is implicitly cancelled when `asyncBytes` is dropped on return.
        var r2 = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        r2.httpMethod = "GET"
        r2.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let (_, resp) = try? await session.bytes(for: r2),
           let http = resp as? HTTPURLResponse {
            if http.statusCode == 206 {
                let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                var len: Int64 = 0
                if let slash = cr.firstIndex(of: "/") {
                    len = Int64(cr[cr.index(after: slash)...]) ?? 0
                }
                return (len, true)
            } else if (200...299).contains(http.statusCode) {
                // Server honoured the request but ignored the Range — single connection.
                let len = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
                return (len, false)
            }
        }
        return (0, false)
    }

    private func report(_ state: DownloadState, for id: UUID, error: Error? = nil) async {
        lastState = state
        await delegate?.engineDidChangeState(taskID: id, state: state, error: error)
    }
}
