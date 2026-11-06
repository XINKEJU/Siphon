import Foundation
import CryptoKit
import os

/// Native, dependency-free download engine for HTTP/HTTPS/FTP and every URI
/// front-end (`thunder`, `webdav`, `s3`, `ipfs`, …) that `URINormalizer` rewrites
/// onto a plain HTTP(S) request.
///
/// Engine features (borrowed from aria2 / ABD / FluxDown / gopeed / HyperDM):
///  * **Dynamic segmentation with work stealing** — a coordinator hands out byte
///    ranges; finished connections split the largest in-flight range and steal its
///    tail, so slow tails never idle the pool. Written ranges are approved by the
///    coordinator, making mid-flight splits safe.
///  * **Slow start** — connections ramp 2 → 4 → … up to the effective cap instead
///    of opening all at once (gopeed's slowStart model).
///  * **Domain connection policy cache** — servers that reject multi-connection
///    requests (403/429) get a negative cap; healthy servers get a positive hint.
///    Persisted with a 24 h TTL (FluxDown's domain_conn_caps).
///  * **Resumability with pinning** — an atomic sidecar stores ETag /
///    Last-Modified / total size / part cursors; a resume is refused (and restarted
///    cleanly) if the remote file changed (gopeed If-Range pinning + HyperDM
///    sidecar). Every 206 response's Content-Range start is verified; a server
///    that answers 200 to a Range request downgrades to a single stream.
///  * **Typed failures & smart retries** — errors map to `NetFailure` (never
///    string matching); retries use exponential backoff with jitter, reset on
///    progress, wait only on 503/timeouts, and a repeated resume failure restarts
///    from scratch (aria2's resume-failure circuit breaker).
///  * **Checksum verification** — when the task carries a checksum (MD5/SHA-1/
///    SHA-256) the finished file is verified; a mismatch triggers one clean
///    re-download before failing.
public final class HTTPDownloadEngine: DownloadEngine {
    public let name = "native-http"
    public let supportedProtocols: Set<DownloadProtocol> =
        Set(DownloadProtocol.allCases.filter { $0.transport == .native })
    public weak var delegate: (any EngineDelegate)?

    /// Peak concurrent connections used by the last `submit`. Exposed for tests.
    public var lastSegmentCount: Int = 0
    /// Last state reported (or about to be reported) to the delegate. Polled by tests.
    public var lastState: DownloadState = .pending

    // Tuning constants (FluxDown segment_advisor.rs, ABD DEFAULT_MIN_PART_SIZE).
    private static let minSplit: Int64 = 1_048_576        // a split is only worth ≥ 1 MiB
    private static let stealThreshold: Int64 = 2_097_152  // stolen tail must be ≥ 2 MiB
    private static let maxConnections = 8
    private static let flushThreshold = 1 << 16           // 64 KiB
    private static let maxRetriesPerPart = 5
    private static let maxResumeAttempts = 3              // circuit breaker (aria2)
    private static let rampInterval: UInt64 = 2_000_000_000 // slow start doubles every 2 s

    private final class Job {
        let task: DownloadTask
        var handle: Task<Void, Never>?
        var cancelled = false
        /// Per-task speed limit (bytes/s); `nil` = unlimited. Hot-updatable.
        var throttle: TaskThrottler = TaskThrottler()
        /// Active source URL for this attempt (primary or a mirror). Defaults to
        /// `task.source`; overridden by the multi-CDN failover loop.
        var sourceOverride: URL?
        /// Position of this source in the [primary] + mirrors list (diagnostics).
        var mirrorIndex: Int = 0
        /// Terminal outcome of the last transfer, so the failover loop can decide
        /// whether to continue to the next mirror or stop.
        enum Outcome { case completed, failed, paused }
        var lastOutcome: Outcome?
        var source: URL { sourceOverride ?? task.source }
        init(_ t: DownloadTask) { task = t }
    }

    /// Async-safe job table (OSAllocatedUnfairLock instead of NSLock because these
    /// methods are called from async contexts).
    private let jobsState = OSAllocatedUnfairLock<[UUID: Job]>(initialState: [:])
    private let writeQueue = DispatchQueue(label: "siphon.nativehttp.write")
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    /// Per-proxy sessions (FluxDown PAC / auto-proxy model). When the system PAC
    /// resolves a host to a proxy, that host's requests run on a dedicated session
    /// carrying the proxy dictionary; `DIRECT` hosts use the default session.
    private let proxySessions = OSAllocatedUnfairLock<[String: URLSession]>(initialState: [:])

    private func session(for url: URL) -> URLSession {
        guard let dict = ProxyRouter.shared.proxyDictionary(for: url) else { return session }
        let key = dict.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        if let existing = proxySessions.withLock({ $0[key] }) { return existing }
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 60
        c.connectionProxyDictionary = dict
        let s = URLSession(configuration: c)
        proxySessions.withLock { $0[key] = s }
        return s
    }

    public init() {}

    static let debug = ProcessInfo.processInfo.environment["SIPHON_HTTP_DEBUG"] != nil
    func dbg(_ s: String) {
        if Self.debug { print("[http-engine] \(s)") }
    }

    public func canHandle(_ p: DownloadProtocol) -> Bool { supportedProtocols.contains(p) }

    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {
        SpeedLimitController.shared.setLimit(bytesPerSec)
    }

    /// Hot-updatable per-task speed limit (bytes/s), like persepolis' limitSpeed.
    public func setTaskSpeedLimit(_ id: UUID, bytesPerSec: Int64?) async {
        jobsState.withLock { $0[id]?.throttle.setLimit(bytesPerSec) }
    }

    public func submit(_ task: DownloadTask) async throws {
        dbg("submit \(task.source)")
        let job = Job(task)
        jobsState.withLock { $0[task.id] = job }
        job.handle = Task { [weak self] in
            await self?.run(job)
        }
    }

    public func pause(_ id: UUID) async {
        dbg("pause \(id)")
        let job = jobsState.withLock { $0[id] }
        job?.cancelled = true
        job?.handle?.cancel()
        await report(.paused, for: id)
    }

    public func resume(_ id: UUID) async {
        dbg("resume \(id)")
        let job = jobsState.withLock { $0[id] }
        guard let job else { return }
        job.cancelled = false
        job.handle?.cancel()
        job.handle = Task { [weak self] in
            await self?.run(job)
        }
    }

    public func remove(_ id: UUID) async {
        let job = jobsState.withLock { $0.removeValue(forKey: id) }
        if let job {
            job.cancelled = true
            job.handle?.cancel()
            try? FileManager.default.removeItem(at: job.task.destination)
            let writing = writingURL(for: job.task.destination)
            try? FileManager.default.removeItem(at: writing)
            Sidecar.clear(for: writing)
            Sidecar.clear(for: job.task.destination)
        }
    }

    // MARK: - core flow

    /// Unfinished data lives at `<dest>.part` (ABD's AppendExtensionToIncomplete
    /// pattern): users never double-click a half-written file, and the atomic
    /// rename on completion is the publish moment.
    private func writingURL(for destination: URL) -> URL {
        destination.appendingPathExtension("part")
    }

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

        // An already-renamed complete file short-circuits everything.
        if fileSize(out) != nil, Sidecar.load(for: writingURL(for: out)) == nil,
           Sidecar.load(for: out) == nil,
           let attrs = try? FileManager.default.attributesOfItem(atPath: out.path),
           (attrs[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
            var p = DownloadProgress()
            p.totalBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            p.downloadedBytes = p.totalBytes
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
            await report(.completed, for: task.id)
            return
        }

        // Multi-CDN failover (FluxDown multi_cdn model): try the primary source
        // first, then each mirror in order. A hard failure (unreachable host,
        // fatal status, persistent resume failure) advances to the next source.
        let candidates = [task.source] + task.mirrors.filter { $0 != task.source }
        for (index, source) in candidates.enumerated() {
            let attempt = Job(task)
            attempt.cancelled = job.cancelled
            attempt.throttle = job.throttle
            attempt.sourceOverride = source
            attempt.mirrorIndex = index
            jobsState.withLock { $0[task.id] = attempt }
            await runWithChecksumRetry(attempt, destination: out, failover: index < candidates.count - 1)
            // runWithChecksumRetry reports its own terminal state; stop on success.
            let cur = jobsState.withLock { $0[task.id] }
            if cur?.lastOutcome == .completed || cur?.lastOutcome == .paused {
                return
            }
        }
        // All sources exhausted: the last attempt already reported the final error.
    }

    /// Outer loop: run the transfer; if the task carries a checksum and the
    /// finished file does not match, wipe and re-download exactly once (gopeed's
    /// checksum-aware retry) before reporting a hard error. When `failover` is
    /// true, a hard failure is not reported — the caller advances to the next
    /// mirror — but a checksum mismatch still fails immediately (the bytes are
    /// wrong regardless of source).
    private func runWithChecksumRetry(_ job: Job, destination out: URL, failover: Bool) async {
        var checksumRetried = false
        while true {
            let outcome = await transfer(job, destination: out)
            if job.cancelled {
                job.lastOutcome = .paused
                await report(.paused, for: job.task.id)
                return
            }
            switch outcome {
            case .completed:
                if let checksum = job.task.checksum, !checksum.isEmpty {
                    let ok = (try? verifyChecksum(fileAt: out, spec: checksum)) ?? false
                    if !ok {
                        if checksumRetried {
                            job.lastOutcome = .failed
                            await report(.error, for: job.task.id, error:
                                NetFailure.checksumMismatch)
                            return
                        }
                        checksumRetried = true
                        try? FileManager.default.removeItem(at: out)
                        Sidecar.clear(for: out)
                        continue // one clean re-download
                    }
                }
                job.lastOutcome = .completed
                await report(.completed, for: job.task.id)
                return
            case .failed(let error):
                if failover {
                    job.lastOutcome = .failed
                    // Swallow this source's failure; the caller tries the next
                    // mirror. Wipe the partial file so the next source starts clean.
                    dbg("source \(job.sourceOverride?.absoluteString ?? "?") failed: \(error) — failing over")
                    try? FileManager.default.removeItem(at: out)
                    Sidecar.clear(for: out)
                    return
                }
                job.lastOutcome = .failed
                await report(.error, for: job.task.id, error: error)
                return
            }
        }
    }

    private enum TransferOutcome {
        case completed
        case failed(Error)
    }

    /// One full transfer attempt: probe → resume validation → workers → finish.
    private func transfer(_ job: Job, destination finalURL: URL) async -> TransferOutcome {
        let task = job.task
        let out = writingURL(for: finalURL)

        // Probe remote size / range support / validators.
        let info: ProbeInfo
        do { info = try await probe(url: job.source, headers: task.options) }
        catch { dbg("probe failed: \(error)"); return .failed(error) }
        dbg("probe total=\(info.total) canRange=\(info.canRange) etag=\(info.etag ?? "nil")")

        // Disk space precheck (FluxDown disk_space.rs): fail with a clear error
        // instead of dying at 99%.
        if info.total > 0 {
            let existing: Int64 = ((try? FileManager.default.attributesOfItem(
                atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let needed = info.total - existing
            if let fs = try? FileManager.default.attributesOfFileSystem(
                forPath: out.deletingLastPathComponent().path),
               let free = (fs[.systemFreeSize] as? NSNumber)?.int64Value,
               free < needed {
                return .failed(NetFailure.unknown("磁盘空间不足：需要约 \(needed / 1_048_576) MB"))
            }
        }

        // Already complete on disk? The output file is PRE-ALLOCATED to the full
        // size (truncate), so file size alone proves nothing — trust the sidecar:
        // absent sidecar (never started, or completed-and-cleared) or a sidecar
        // with an empty part list (nothing remaining) means complete.
        if info.total > 0, fileSize(out) == info.total {
            let sc = Sidecar.load(for: out)
            if sc == nil || sc?.parts.isEmpty == true {
                dbg("short-circuit: size matches total and no pending parts")
                var p = DownloadProgress()
                p.totalBytes = info.total; p.downloadedBytes = info.total
                await delegate?.engineDidUpdate(taskID: task.id, progress: p)
                Sidecar.clear(for: out)
                // Publish: .part → final name (only if it actually lives at .part).
                if out != finalURL {
                    try? FileManager.default.removeItem(at: finalURL)
                    try? FileManager.default.moveItem(at: out, to: finalURL)
                }
                return .completed
            }
            dbg("size matches but sidecar has \(sc!.parts.count) pending part(s) — resuming")
        }

        // --- resume validation: pin the remote file identity ---
        var sidecar = Sidecar.load(for: out)
        if let sc = sidecar {
            let unchanged = sc.total == info.total
                && sc.etag == info.etag && sc.lastModified == info.lastModified
                && (info.total <= 0 || (fileSize(out) ?? 0) >= maxPartCursor(sc) )
            if !unchanged {
                // Remote changed or sidecar is junk: start over, cleanly.
                Sidecar.clear(for: out)
                try? FileManager.default.removeItem(at: out)
                sidecar = nil
            }
        }

        let canRange = info.canRange
        var parts: [SegmentCoordinator.Part]
        if canRange, let sc = sidecar, !sc.parts.isEmpty {
            parts = sc.parts.map { SegmentCoordinator.Part(start: $0[0], cursor: $0[1], end: $0[2]) }
        } else if canRange, info.total >= Self.minSplit * 2 {
            parts = [SegmentCoordinator.Part(start: 0, cursor: 0, end: info.total - 1)]
        } else {
            // Single stream — either the server has no ranges or the size is unknown;
            // unknown sizes use a sentinel end so approveWrite never truncates early.
            let end = info.total > 0 ? info.total - 1 : SegmentCoordinator.unknownEnd
            parts = [SegmentCoordinator.Part(start: 0, cursor: 0, end: end)]
        }

        // Create the output ONLY when missing: createFile *overwrites* an existing
        // file, which would wipe everything a resume is about to continue.
        if !FileManager.default.fileExists(atPath: out.path) {
            FileManager.default.createFile(atPath: out.path, contents: nil)
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: out) }
        catch { return .failed(error) }
        defer { try? handle.close() }
        if canRange && info.total > 0 { try? handle.truncate(atOffset: UInt64(info.total)) }

        let coordinator = SegmentCoordinator(parts: parts,
                                             maxConnections: Self.maxConnections,
                                             minSplit: Self.minSplit,
                                             stealThreshold: Self.stealThreshold)
        // Resume accounting: bytes already on disk from previous sessions count
        // toward progress; otherwise a successful resume reports incompleteBody.
        let alreadyWritten = parts.reduce(Int64(0)) { $0 + max(0, $1.cursor - $1.start) }
        // Slow start: honour a learned per-domain cap and a positive hint ramp.
        let host = job.source.host ?? ""
        coordinator.effectiveCap = DomainConnPolicy.shared.effectiveMax(host: host,
                                                                       requested: Self.maxConnections)
        let tracker = ProgressTracker()
        tracker.written = alreadyWritten
        let sidecarSaver = SidecarSaver(destination: out, coordinator: coordinator,
                                        etag: info.etag, lastModified: info.lastModified,
                                        total: info.total)
        let sizePlan = SizePlan(total: info.total)
        dbg("transfer: about to report active")
        await report(.active, for: task.id)
        dbg("transfer: active reported")

        var resumeFailure = sidecar?.resumeAttempts ?? 0
        let result = await coordinateWorkers(job, url: job.source, handle: handle,
                                             coordinator: coordinator, tracker: tracker,
                                             total: info.total, canRange: canRange,
                                             sidecarSaver: sidecarSaver,
                                             sizePlan: sizePlan)

        // Persist learnings for the domain.
        if case .done = result {
            DomainConnPolicy.shared.recordSuccess(host: host,
                                                  connections: coordinator.peakConnections)
        }

        let finalTotal = sizePlan.plannedTotal
        dbg("pool result: \(result) written=\(tracker.written)/\(finalTotal) peak=\(coordinator.peakConnections) remaining=\(coordinator.remainingBytes)")
        if job.cancelled {
            sidecarSaver.forceSave()
            dbg("cancelled mid-transfer")
            return .failed(CancellationError())
        }
        switch result {
        case .done:
            if tracker.written != finalTotal && finalTotal > 0 {
                return .failed(NetFailure.incompleteBody)
            }
            lastSegmentCount = coordinator.peakConnections
            Sidecar.clear(for: out)
            // Publish: .part → final name via atomic rename.
            if out != finalURL {
                try? FileManager.default.removeItem(at: finalURL)
                try? FileManager.default.moveItem(at: out, to: finalURL)
            }
            var p = DownloadProgress()
            p.totalBytes = finalTotal > 0 ? finalTotal : tracker.written
            p.downloadedBytes = tracker.written
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
            return .completed
        case .serverIgnoredRanges:
            // Server advertises ranges but sends 200 full bodies: downgrade to one
            // non-range stream (HyperDM's 200-fallback), counting circuit trips.
            resumeFailure += 1
            if resumeFailure > Self.maxResumeAttempts {
                Sidecar.clear(for: out)
                return .failed(NetFailure.resumeUnsupported)
            }
            Sidecar.clear(for: out)
            try? FileManager.default.removeItem(at: out)
            let fresh = Job(task)
            fresh.cancelled = job.cancelled
            fresh.throttle = job.throttle
            fresh.sourceOverride = job.sourceOverride
            fresh.mirrorIndex = job.mirrorIndex
            jobsState.withLock { $0[task.id] = fresh }
            return await transfer(fresh, destination: finalURL)
        case .fatal(let error):
            return .failed(error)
        }
    }

    private enum PoolResult {
        case done
        case serverIgnoredRanges
        case fatal(Error)
    }

    /// Worker pool: each worker loops claim → stream → approve writes. Slow start
    /// is enforced inside `coordinator.claim` via the ramping target, so a fixed
    /// task pool naturally opens connections gradually.
    private func coordinateWorkers(_ job: Job, url: URL, handle: FileHandle,
                                   coordinator: SegmentCoordinator, tracker: ProgressTracker,
                                   total: Int64, canRange: Bool,
                                   sidecarSaver: SidecarSaver,
                                   sizePlan: SizePlan) async -> PoolResult {
        let workers = max(1, coordinator.effectiveCap)
        dbg("coordinateWorkers: spawning \(workers) workers, cap=\(coordinator.effectiveCap)")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.workerLoop(job, url: url, handle: handle,
                                          coordinator: coordinator, tracker: tracker,
                                          total: total, canRange: canRange,
                                          sidecarSaver: sidecarSaver,
                                          sizePlan: sizePlan)
                }
            }
            // Wait for every worker to finish (they exit when no work remains).
            for await _ in group { }
        }

        if let f = coordinator.fatalError { return .fatal(f) }
        if coordinator.hasServerIgnoredRanges { return .serverIgnoredRanges }
        if coordinator.remainingBytes > 0 && !job.cancelled { return .fatal(NetFailure.incompleteBody) }
        return .done
    }

    private func workerLoop(_ job: Job, url: URL, handle: FileHandle,
                            coordinator: SegmentCoordinator, tracker: ProgressTracker,
                            total: Int64, canRange: Bool,
                            sidecarSaver: SidecarSaver,
                            sizePlan: SizePlan) async {
        while !job.cancelled {
            guard let part = coordinator.claim() else {
                if coordinator.isDrained { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            dbg("worker claimed part \(part.start)..\(part.end) from \(part.cursor)")
            do {
                try await streamPart(part, url: url, headers: job.task.options,
                                     handle: handle, tracker: tracker,
                                     total: total, job: job,
                                     coordinator: coordinator, canRange: canRange,
                                     sidecarSaver: sidecarSaver,
                                     sizePlan: sizePlan)
                dbg("worker finished part \(part.start)..\(part.end)")
            } catch is CancellationError {
                coordinator.requeueRemainder(of: part)
                return
            } catch {
                let failure = NetFailure.classify(error)
                coordinator.recordFailure(failure, attemptedConnections: coordinator.activeConnections,
                                          host: url.host ?? "")
                if case .serverIgnoredRanges = failure {
                    coordinator.flagServerIgnoredRanges()
                    coordinator.requeueRemainder(of: part)
                    return
                }
                if failure.isFatal {
                    coordinator.flagFatal(failure)
                    return
                }
                // Retry with exponential backoff + jitter; progress resets the count
                // (ABD's downloadFailedRetryOrPause semantics).
                if let delay = failure.retryDelay(jittered: true) {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                coordinator.requeueRemainder(of: part)
            }
        }
    }

    // MARK: - single part streaming

    private func streamPart(_ part: SegmentCoordinator.Part, url: URL,
                            headers: [String: String], handle: FileHandle,
                            tracker: ProgressTracker, total: Int64, job: Job,
                            coordinator: SegmentCoordinator, canRange: Bool,
                            sidecarSaver: SidecarSaver,
                            sizePlan: SizePlan) async throws {
        let singleStream = !canRange || (total <= 0 && part.start == 0 && part.end == 0)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "GET"
        for (k, v) in headers where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !singleStream {
            req.setValue("bytes=\(part.cursor)-\(part.end)", forHTTPHeaderField: "Range")
        }
        let (asyncBytes, response) = try await session(for: url).bytes(for: req)
        dbg("stream \(part.cursor)-\(part.end): status \((response as? HTTPURLResponse)?.statusCode ?? -1)")

        if !singleStream, let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 206:
                // Verify the Content-Range start matches what we asked for; a
                // mismatched stream would silently corrupt the file (ABD's
                // connectAndVerify).
                let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let rangePart = cr.split(separator: "/").first.map(String.init) ?? ""
                let bounds = rangePart.split(separator: "-").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                if bounds.count == 2 && bounds[0] != part.cursor {
                    throw NetFailure.rangeMismatch
                }
                // In-place size expansion (FluxDown MAX_SIZE_EXPANSIONS): if the
                // server reports a larger total than we planned, extend the file
                // and append a tail segment instead of failing incomplete.
                if let slash = cr.firstIndex(of: "/") {
                    let denom = String(cr[cr.index(after: slash)...])
                        .trimmingCharacters(in: .whitespaces)
                    if let reported = Int64(denom), reported > sizePlan.plannedTotal {
                        let oldTotal = sizePlan.plannedTotal
                        if let newTotal = sizePlan.expand(to: reported) {
                            try? handle.truncate(atOffset: UInt64(newTotal))
                            _ = coordinator.appendTail(from: oldTotal, to: newTotal - 1)
                            dbg("size expansion: total \(oldTotal) -> \(newTotal) (expansions=\(sizePlan.expansions))")
                        } else {
                            // Expansion budget exhausted: fail explicitly.
                            throw NetFailure.sizeExpansionExhausted
                        }
                    }
                }
            case 200:
                // Ignored our Range header.
                if part.cursor == 0 && coordinator.isOnlyActiveConnection() {
                    // Safe to consume as a full single stream.
                    coordinator.convertToSingleStream(end: total > 0 ? total - 1 : -1)
                } else {
                    throw NetFailure.serverIgnoredRanges
                }
            default:
                throw NetFailure.httpStatus(http.statusCode)
            }
        }

        var buffer = Data()
        var offset = part.cursor
        var byteCount = 0
        for try await byte in asyncBytes {
            if job.cancelled { throw CancellationError() }
            byteCount += 1
            buffer.append(byte)
            if buffer.count >= Self.flushThreshold {
                let requested = Int64(buffer.count)
                let approved = coordinator.approveWrite(offset: offset, requested: requested)
                if approved == 0 { return } // tail stolen or part finished elsewhere
                if approved < requested {
                    // Partial approval: our slice ends mid-buffer; the rest of the
                    // buffer belongs to the connection that split us. Write only
                    // what is ours, then exit — the thief continues from the cut.
                    buffer.truncatePrefix(Int(approved))
                }
                try await writeChunk(buffer, at: offset, handle: handle, tracker: tracker,
                                     total: total, job: job, coordinator: coordinator,
                                     sidecarSaver: sidecarSaver)
                offset += approved
                buffer.removeAll(keepingCapacity: true)
                if approved < requested { return }
            }
        }
        if !buffer.isEmpty {
            let requested = Int64(buffer.count)
            let approved = coordinator.approveWrite(offset: offset, requested: requested)
            if approved > 0 {
                if approved < requested { buffer.truncatePrefix(Int(approved)) }
                try await writeChunk(buffer, at: offset, handle: handle, tracker: tracker,
                                     total: total, job: job, coordinator: coordinator,
                                     sidecarSaver: sidecarSaver)
                offset += approved
            }
        }
        dbg("stream \(part.start): body ended, got \(byteCount) bytes, offset now \(offset)")
        coordinator.completePart(through: offset)
        sidecarSaver.requestSave()
    }

    private func writeChunk(_ data: Data, at offset: Int64, handle: FileHandle,
                            tracker: ProgressTracker, total: Int64, job: Job,
                            coordinator: SegmentCoordinator,
                            sidecarSaver: SidecarSaver) async throws {
        await SpeedLimitController.shared.consume(data.count)
        await job.throttle.consume(data.count)
        let advanced = flushAndReport(data, at: offset, handle: handle,
                                      tracker: tracker, total: total, taskID: job.task.id)
        if let p = advanced { await delegate?.engineDidUpdate(taskID: job.task.id, progress: p) }
        sidecarSaver.maybeSave()
    }

    /// Serialised write + throttled progress snapshot (250 ms window).
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

    // MARK: - checksum

    private func verifyChecksum(fileAt url: URL, spec: String) throws -> Bool {
        let s = spec.trimmingCharacters(in: .whitespaces)
        let (algo, expected): (String, String)
        if let colon = s.firstIndex(of: ":") {
            algo = String(s[s.startIndex..<colon]).lowercased()
            expected = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else {
            algo = "sha256" // bare hex defaults to SHA-256
            expected = s
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher: any HashFunction
        switch algo {
        case "md5": hasher = Insecure.MD5()
        case "sha1", "sha-1": hasher = Insecure.SHA1()
        case "sha256", "sha-256": hasher = SHA256()
        default: throw NetFailure.unsupportedChecksum(algo)
        }
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        return actual.lowercased() == expected.lowercased()
    }

    // MARK: - probe

    struct ProbeInfo {
        var total: Int64 = 0
        var canRange = false
        var etag: String?
        var lastModified: String?
    }

    private func probe(url: URL, headers: [String: String]) async throws -> ProbeInfo {
        var result = ProbeInfo()
        var head = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        head.httpMethod = "HEAD"
        for (k, v) in headers where !["dir", "out"].contains(k.lowercased()) {
            head.setValue(v, forHTTPHeaderField: k)
        }
        if let (_, resp) = try? await session(for: url).data(for: head),
           let http = resp as? HTTPURLResponse,
           (200...299).contains(http.statusCode) {
            result.total = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
            result.canRange = (http.value(forHTTPHeaderField: "Accept-Ranges")?
                .lowercased().contains("bytes")) ?? false
            result.etag = http.value(forHTTPHeaderField: "ETag")
            result.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            if result.total > 0 || result.canRange { return result }
        }
        // Zero-length Range GET fallback (also covers FTP, which ignores HEAD).
        var r2 = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        r2.httpMethod = "GET"
        r2.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let (_, resp) = try? await session(for: url).bytes(for: r2),
           let http = resp as? HTTPURLResponse {
            if http.statusCode == 206 {
                result.canRange = true
                let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                if let slash = cr.firstIndex(of: "/") {
                    result.total = Int64(cr[cr.index(after: slash)...]) ?? 0
                }
                result.etag = http.value(forHTTPHeaderField: "ETag")
                result.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            } else if (200...299).contains(http.statusCode) {
                result.total = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
                result.canRange = false
            }
        }
        return result
    }

    private func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    private func maxPartCursor(_ sc: DownloadSidecar) -> Int64 {
        sc.parts.map { $0[1] }.max() ?? 0
    }

    private func report(_ state: DownloadState, for id: UUID, error: Error? = nil) async {
        lastState = state
        await delegate?.engineDidChangeState(taskID: id, state: state, error: error)
    }
}

// MARK: - Data helper

private extension Data {
    mutating func truncatePrefix(_ n: Int) {
        if n < count { self = prefix(n) }
    }
}

// MARK: - typed network failures (FluxDown net_failure.rs model)

enum NetFailure: Error {
    case timeout
    case connectFailed
    case dns
    case connectionReset
    case httpStatus(Int)          // includes 403 / 429 / 503 …
    case rangeMismatch            // 206 Content-Range start ≠ requested
    case serverIgnoredRanges      // 200 to a Range request
    case checksumMismatch
    case unsupportedChecksum(String)
    case incompleteBody
    case resumeUnsupported
    case sizeExpansionExhausted
    case cancelled
    case unknown(String)

    static func classify(_ error: Error) -> NetFailure {
        if let f = error as? NetFailure { return f }
        if let ue = error as? URLError {
            switch ue.code {
            case .timedOut: return .timeout
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .dns
            case .cannotLoadFromNetwork: return .connectFailed
            case .networkConnectionLost: return .connectionReset
            case .cancelled: return .cancelled
            default: return .unknown(ue.code.rawValue.description)
            }
        }
        if error is POSIXError { return .connectFailed }
        return .unknown("\(error)")
    }

    /// Whether retrying is pointless for this failure class.
    var isFatal: Bool {
        switch self {
        case .checksumMismatch, .unsupportedChecksum, .dns: return true
        default: return false
        }
    }

    /// Fixed wait only for rate-limiting / timeouts (aria2: only 503 waits).
    func retryDelay(jittered: Bool) -> TimeInterval? {
        let base: TimeInterval?
        switch self {
        case .timeout, .connectionReset: base = 0.5
        case .httpStatus(503): base = 1.0
        case .httpStatus(429): base = 2.0
        default: base = nil
        }
        guard var d = base else { return nil }
        if jittered { d += Double.random(in: 0...(d * 0.25)) }
        return d
    }
}

extension NetFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout: return "连接超时"
        case .connectFailed: return "无法连接服务器"
        case .dns: return "域名解析失败"
        case .connectionReset: return "连接被重置"
        case .httpStatus(let code): return "服务器返回 HTTP \(code)"
        case .rangeMismatch: return "服务器返回的 Range 与请求不一致"
        case .serverIgnoredRanges: return "服务器不支持分段下载（忽略 Range）"
        case .checksumMismatch: return "校验和不匹配：下载内容与预期不符"
        case .unsupportedChecksum(let a): return "不支持的校验算法：\(a)"
        case .incompleteBody: return "下载不完整"
        case .resumeUnsupported: return "服务器不支持断点续传"
        case .sizeExpansionExhausted: return "文件大小持续增长，无法完成下载"
        case .cancelled: return "已取消"
        case .unknown(let s): return "网络错误：\(s)"
        }
    }
}

// MARK: - per-task token bucket (hot-updatable)

/// Token-bucket throttler for a single task; the limit can be changed while a
/// download is running (persepolis' limitSpeed). Uses OSAllocatedUnfairLock so it
/// is callable from async contexts without warnings.
final class TaskThrottler: @unchecked Sendable {
    private struct State {
        var limit: Int64?
        var tokens: Double = 0
        var lastRefill = Date()
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    func setLimit(_ bytesPerSec: Int64?) {
        state.withLock { $0.limit = bytesPerSec }
    }

    func consume(_ bytes: Int) async {
        let waitNs = state.withLock { s -> UInt64 in
            guard let limit = s.limit, limit > 0 else { return 0 }
            let now = Date()
            s.tokens = min(Double(limit),
                           s.tokens + now.timeIntervalSince(s.lastRefill) * Double(limit))
            s.lastRefill = now
            if s.tokens >= Double(bytes) {
                s.tokens -= Double(bytes)
                return 0
            }
            let missing = Double(bytes) - s.tokens
            s.tokens = 0
            return UInt64(max(0, missing / Double(limit)) * 1_000_000_000)
        }
        if waitNs > 0 { try? await Task.sleep(nanoseconds: waitNs) }
    }
}

// MARK: - domain connection policy cache (FluxDown domain_conn_caps)

public final class DomainConnPolicy: @unchecked Sendable {
    public static let shared = DomainConnPolicy()

    struct Entry: Codable {
        var cap: Int?       // negative learning: servers that reject multi-conn
        var hint: Int?      // positive learning: connections that worked
        var updated: Date
    }

    private let lock = NSLock()
    private var table: [String: Entry] = [:]
    private let ttl: TimeInterval = 86_400
    private static let key = "Siphon.domainConnCaps"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            table = decoded
        }
    }

    private func fresh(_ e: Entry) -> Bool {
        Date().timeIntervalSince(e.updated) < ttl
    }

    public func effectiveMax(host: String, requested: Int) -> Int {
        guard !host.isEmpty else { return requested }
        lock.lock(); defer { lock.unlock() }
        guard let e = table[host], fresh(e) else { return requested }
        var v = requested
        if let cap = e.cap { v = min(v, max(1, cap)) }
        return max(1, v)
    }

    /// A server rejected our connection count (403/429): remember a lower cap.
    public func recordRejection(host: String, attempted: Int) {
        guard !host.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var e = table[host] ?? Entry(cap: nil, hint: nil, updated: Date())
        e.cap = min(max(1, attempted - 1), e.cap ?? Int.max)
        e.updated = Date()
        table[host] = e
        save()
    }

    /// A download finished cleanly using N connections: remember the hint.
    public func recordSuccess(host: String, connections: Int) {
        guard !host.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var e = table[host] ?? Entry(cap: nil, hint: nil, updated: Date())
        e.hint = max(e.hint ?? 0, connections)
        e.updated = Date()
        table[host] = e
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - segment coordinator (dynamic splitting + work stealing)

final class SegmentCoordinator: @unchecked Sendable {
    /// Sentinel end for downloads whose total size is unknown.
    static let unknownEnd: Int64 = Int64(1) << 62

    struct Part {
        let start: Int64
        var cursor: Int64   // next byte to fetch+write
        var end: Int64      // inclusive
    }

    private let lock = NSLock()
    private var pending: [Part] = []
    private var active: [Part] = []
    private let minSplit: Int64
    private let stealThreshold: Int64
    private var rampTarget = 2                    // slow start: 2 → 4 → …
    private var lastRamp = Date()
    private(set) var peakConnections = 0
    private var serverIgnoredRanges = false
    private var fatal: Error?
    /// Per-part retry counters keyed by `start`; a retry without byte progress counts.
    private var retries: [Int64: Int] = [:]
    private let maxRetriesPerPart = 5

    var effectiveCap: Int = 8
    var activeConnections: Int { lock.lock(); defer { lock.unlock() }; return active.count }
    var isDrained: Bool { lock.lock(); defer { lock.unlock() }; return pending.isEmpty && active.isEmpty }
    var hasServerIgnoredRanges: Bool { lock.lock(); defer { lock.unlock() }; return serverIgnoredRanges }
    var fatalError: Error? { lock.lock(); defer { lock.unlock() }; return fatal }
    var remainingBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return (pending + active).reduce(Int64(0)) { $0 + ($1.end + 1 - $1.cursor) }
    }

    init(parts: [Part], maxConnections: Int, minSplit: Int64, stealThreshold: Int64) {
        self.pending = parts.filter { $0.cursor <= $0.end }
        self.minSplit = minSplit
        self.stealThreshold = stealThreshold
        self.rampTarget = min(2, max(1, maxConnections))
        self.effectiveCap = max(1, maxConnections)
    }

    private func remaining(_ p: Part) -> Int64 { p.end + 1 - p.cursor }

    /// Slow-start tick: double the ramp target every interval, capped.
    private func tickRamp() {
        guard Date().timeIntervalSince(lastRamp) >= 2.0, rampTarget < effectiveCap else { return }
        lastRamp = Date()
        rampTarget = min(effectiveCap, rampTarget * 2)
    }

    /// A worker asks for work. May split the largest active part's tail.
    func claim() -> Part? {
        lock.lock(); defer { lock.unlock() }
        tickRamp()
        guard fatal == nil, !serverIgnoredRanges else { return nil }
        if !pending.isEmpty {
            let p = pending.removeFirst()
            active.append(p)
            peakConnections = max(peakConnections, active.count)
            return p
        }
        // Slow start beyond the first connection: split the largest active part.
        guard active.count < rampTarget, active.count < effectiveCap,
              let idx = active.indices.max(by: { remaining(active[$0]) < remaining(active[$1]) }),
              remaining(active[idx]) >= stealThreshold * 2 else { return nil }
        var victim = active[idx]
        let rem = remaining(victim)
        let cut = victim.cursor + rem / 2
        guard cut - victim.cursor >= minSplit, victim.end + 1 - cut >= minSplit else { return nil }
        let stolen = Part(start: cut, cursor: cut, end: victim.end)
        victim.end = cut - 1
        active[idx] = victim
        active.append(stolen)
        peakConnections = max(peakConnections, active.count)
        return stolen
    }

    /// Approve a write of `requested` bytes at `offset`; returns the approved count
    /// (may be smaller if the part was split mid-flight, or 0 if nothing is ours).
    func approveWrite(offset: Int64, requested: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let idx = active.firstIndex(where: { offset >= $0.cursor && offset <= $0.end }) else {
            return 0
        }
        let approved = min(requested, active[idx].end + 1 - offset)
        if approved > 0 { active[idx].cursor = offset + approved }
        if remaining(active[idx]) <= 0 { active.remove(at: idx) }
        return approved
    }

    /// Worker finished streaming to `offset` without error.
    func completePart(through offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        if let idx = active.firstIndex(where: { $0.cursor <= offset && offset <= $0.end + 1 }) {
            if remaining(active[idx]) <= 0 { active.remove(at: idx) }
        }
    }

    /// Network error: put the un-fetched remainder back into the pending queue.
    /// A retry without byte progress bumps the failure counter (ABD semantics);
    /// too many fruitless retries is a hard stop for the whole download.
    func requeueRemainder(of part: Part) {
        lock.lock(); defer { lock.unlock() }
        let idx = active.firstIndex(where: { $0.start == part.start && $0.cursor >= part.cursor })
        let remainder: Part?
        if let idx {
            let p = active.remove(at: idx)
            remainder = (p.end + 1 > p.cursor)
                ? Part(start: p.cursor, cursor: p.cursor, end: p.end) : nil
        } else if part.end + 1 > part.cursor {
            remainder = Part(start: part.cursor, cursor: part.cursor, end: part.end)
        } else {
            remainder = nil
        }
        guard let rem = remainder else { return }
        let progressed = rem.cursor > part.cursor
        if progressed {
            retries[rem.start] = 0
        } else {
            retries[rem.start] = (retries[rem.start] ?? 0) + 1
            if retries[rem.start]! > maxRetriesPerPart, fatal == nil {
                fatal = NetFailure.unknown("同一分段连续 \(maxRetriesPerPart) 次无进展重试失败")
            }
        }
        pending.append(rem)
    }

    func recordFailure(_ failure: NetFailure, attemptedConnections: Int, host: String) {
        switch failure {
        case .httpStatus(403), .httpStatus(429):
            DomainConnPolicy.shared.recordRejection(host: host, attempted: attemptedConnections)
            lock.lock()
            effectiveCap = max(1, attemptedConnections - 1)
            rampTarget = min(rampTarget, effectiveCap)
            lock.unlock()
        default: break
        }
    }

    func flagServerIgnoredRanges() {
        lock.lock(); serverIgnoredRanges = true; lock.unlock()
    }

    /// Append a new tail segment `[from, to]` (inclusive) as pending work.
    /// Used by in-place size expansion when the server reports a larger total
    /// mid-download (FluxDown MAX_SIZE_EXPANSIONS). Returns false if a segment
    /// covering `from` already exists (an overlap would corrupt the file).
    func appendTail(from: Int64, to: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard from <= to else { return false }
        let overlaps = (pending + active).contains {
            $0.start <= from && from <= $0.end
        } || (pending + active).contains {
            $0.start <= to && to <= $0.end
        }
        guard !overlaps else { return false }
        pending.append(Part(start: from, cursor: from, end: to))
        return true
    }

    func flagFatal(_ error: Error) {
        lock.lock(); if fatal == nil { fatal = error }; lock.unlock()
    }

    /// 200-to-Range downgrade on the first (single active) connection: the whole
    /// body belongs to that stream.
    func convertToSingleStream(end: Int64) {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll()
        if let idx = active.indices.first {
            active[idx].end = max(active[idx].cursor - 1, end)
        }
    }

    func isOnlyActiveConnection() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.count == 1 && pending.isEmpty
    }

    /// Snapshot all parts for sidecar persistence: [start, cursor, end].
    func snapshot() -> [[Int64]] {
        lock.lock(); defer { lock.unlock() }
        return (pending + active)
            .map { [$0.start, $0.cursor, $0.end] }
            .filter { $0[1] <= $0[2] }
    }
}

// MARK: - resume sidecar (HyperDM chunk_manager model)

struct DownloadSidecar: Codable {
    var version = 1
    var total: Int64
    var etag: String?
    var lastModified: String?
    var resumeAttempts: Int = 0
    var parts: [[Int64]]   // [start, cursor, end]
}

enum Sidecar {
    static func path(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + ".siphon-meta")
    }

    static func load(for destination: URL) -> DownloadSidecar? {
        guard let data = try? Data(contentsOf: path(for: destination)) else { return nil }
        return try? JSONDecoder().decode(DownloadSidecar.self, from: data)
    }

    static func save(_ sc: DownloadSidecar, for destination: URL) {
        // Atomic: write to .tmp then rename (never a half-written sidecar).
        let target = path(for: destination)
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        guard let data = try? JSONEncoder().encode(sc) else { return }
        if (try? data.write(to: tmp, options: .atomic)) != nil {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: tmp, to: target)
        }
    }

    static func clear(for destination: URL) {
        try? FileManager.default.removeItem(at: path(for: destination))
    }
}

/// Throttled sidecar writer: saves at most once per 2 s, plus explicit forceSave
/// on pause. Digest-dedup like aria2's control-file writer would be overkill here
/// because snapshot() changes as cursors move.
final class SidecarSaver: @unchecked Sendable {
    private let destination: URL
    private let coordinator: SegmentCoordinator
    private let etag: String?
    private let lastModified: String?
    private let total: Int64
    private let lock = NSLock()
    private var lastSave = Date.distantPast

    init(destination: URL, coordinator: SegmentCoordinator,
         etag: String?, lastModified: String?, total: Int64) {
        self.destination = destination
        self.coordinator = coordinator
        self.etag = etag
        self.lastModified = lastModified
        self.total = total
    }

    func maybeSave() {
        lock.lock()
        guard Date().timeIntervalSince(lastSave) >= 2.0 else { lock.unlock(); return }
        lastSave = Date()
        lock.unlock()
        persist()
    }

    func requestSave() { persist() }
    func forceSave() { persist() }

    private func persist() {
        var sc = DownloadSidecar(total: total, etag: etag, lastModified: lastModified,
                                 parts: coordinator.snapshot())
        sc.resumeAttempts = 0
        Sidecar.save(sc, for: destination)
    }
}

// MARK: - job plumbing kept simple

private extension HTTPDownloadEngine {
    final class ProgressTracker {
        var written: Int64 = 0
        var lastReport = Date()
        var lastBytes: Int64 = 0
    }
}

// MARK: - in-place size expansion (FluxDown MAX_SIZE_EXPANSIONS)

/// Shared, thread-safe view of the *planned* total size for a single transfer.
///
/// A multi-segment download normally trusts the up-front probe, but a server can
/// report a **larger** total in a mid-flight `206 Content-Range` denominator
/// (a file that finished uploading while we were pulling it, or a pathological
/// growing resource). Instead of failing with an incomplete body, we extend the
/// preallocated file and append a tail segment — already-downloaded bytes are
/// never discarded. The expansion count is capped (`maxExpansions`) so a server
/// that inflates its denominator forever terminates with an explicit error.
final class SizePlan: @unchecked Sendable {
    private struct State {
        var plannedTotal: Int64
        var expansions = 0
        var maxExpansions = 3
    }
    private let lock = NSLock()
    private var state: State

    init(total: Int64, maxExpansions: Int = 3) {
        state = State(plannedTotal: total, maxExpansions: maxExpansions)
    }

    var plannedTotal: Int64 {
        lock.lock(); defer { lock.unlock() }; return state.plannedTotal
    }

    var expansions: Int {
        lock.lock(); defer { lock.unlock() }; return state.expansions
    }

    /// Attempt to raise the planned total to `newTotal`. Returns the new total on
    /// success, or `nil` when the expansion budget is exhausted (caller should
    /// fail the transfer). A `newTotal` at or below the current plan is a no-op.
    func expand(to newTotal: Int64) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard newTotal > state.plannedTotal else { return state.plannedTotal }
        guard state.expansions < state.maxExpansions else { return nil }
        state.plannedTotal = newTotal
        state.expansions += 1
        return newTotal
    }
}
