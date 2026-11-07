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

    /// 仅用于测试轮询的诊断字段。worker 会写、测试线程会读，所以统一放进
    /// 一个锁里，避免无保护的跨线程读写。
    private struct DiagnosticState {
        var segmentCount = 0
        var state: DownloadState = .pending
    }
    private let diagnostics = OSAllocatedUnfairLock(initialState: DiagnosticState())

    /// Peak concurrent connections used by the last `submit`.
    public var lastSegmentCount: Int { diagnostics.withLock { $0.segmentCount } }
    /// Last state reported (or about to be reported) to the delegate.
    public var lastState: DownloadState { diagnostics.withLock { $0.state } }

    /// 当前传输的分段快照（包含尚未开始与正在写的位置）。
    public func segmentSnapshot(for id: UUID) -> [SegmentSnapshot] {
        coordinators.withLock { $0[id] }?.snapshot() ?? []
    }

    // Tuning constants (FluxDown segment_advisor.rs, ABD DEFAULT_MIN_PART_SIZE).
    private static let minSplit: Int64 = 1_048_576        // a split is only worth ≥ 1 MiB
    private static let stealThreshold: Int64 = 2_097_152  // stolen tail must be ≥ 2 MiB
    private static let flushThreshold = 1 << 16           // 64 KiB
    private static let maxRetriesPerPart = 5
    private static let maxResumeAttempts = 3              // circuit breaker (aria2)
    private static let maxPieceRepairRounds = 2           // ChunkChecksum re-fetch budget
    private static let rampInterval: UInt64 = 2_000_000_000 // slow start doubles every 2 s
    /// Mirrors are only worth probing (HEAD) for multi-source distribution above
    /// this size; below it the sequential failover chain is cheaper.
    private static let mirrorProbeMinSize: Int64 = 16 << 20
    /// Multi-NIC aggregation kicks in only for large range-capable downloads.
    static let multiNicMinSize: Int64 = 256 << 20
    static let multiNicKey = "Siphon.multiNic"

    /// A curl worker bound to a secondary network interface, fetching a fixed
    /// byte range into a temp file (FluxDown multi_nic model). The native engine
    /// downloads the head half concurrently on the default route; on failure the
    /// tail falls back to a native pass, so a dead second path costs nothing.
    final class SecondaryPath: @unchecked Sendable {
        let range: Range<Int64>
        let tmp: URL
        let interface: String
        private let runner: ExternalRunner
        private let task: Task<Bool, Never>

        init?(url: URL, headers: [String: String], range: Range<Int64>,
              directory: URL, interface: String) {
            guard range.lowerBound < range.upperBound else { return nil }
            let curl = Self.curlPath
            guard FileManager.default.isExecutableFile(atPath: curl) else { return nil }
            self.range = range
            self.interface = interface
            let tmp = directory.appendingPathComponent(".siphon-mnic-\(UUID().uuidString).part")
            self.tmp = tmp
            var args = ["--globoff", "--silent", "--show-error", "--fail", "--location",
                        "--connect-timeout", "20",
                        "--interface", interface,
                        "--range", "\(range.lowerBound)-\(range.upperBound - 1)"]
            for (k, v) in headers where !["dir", "out"].contains(k.lowercased()) {
                args += ["--header", "\(k): \(v)"]
            }
            args.append(url.absoluteString)
            let runner = ExternalRunner(executable: URL(fileURLWithPath: curl),
                                        arguments: args, destination: tmp)
            self.runner = runner
            do { try runner.start() } catch { return nil }
            let expected = range.upperBound - range.lowerBound
            self.task = Task { [weak runner] in
                guard let runner else { return false }
                let outcome = await runner.wait()
                let got = ((try? FileManager.default.attributesOfItem(
                    atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? 0
                return outcome.exitCode == 0 && got == expected
            }
        }

        func awaitCompletion() async -> Bool { await task.value }
        func cancel() { runner.cancel() }

        static var curlPath: String {
            let configured = ProtocolSettings.load().curlPath.trimmingCharacters(in: .whitespaces)
            if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
                return configured
            }
            return "/usr/bin/curl"
        }
    }

    /// One usable source for multi-source segment distribution, with headers
    /// already credential-scoped for that origin (CredentialScope).
    struct MirrorEndpoint {
        let url: URL
        let headers: [String: String]
    }

    private final class Job {
        let task: DownloadTask
        /// Per-task speed limit (bytes/s); `nil` = unlimited. Hot-updatable.
        var throttle: TaskThrottler = TaskThrottler()
        /// Active source URL for this attempt (primary or a mirror). Defaults to
        /// `task.source`; overridden by the multi-CDN failover loop.
        var sourceOverride: URL?
        /// Position of this source in the [primary] + mirrors list (diagnostics).
        var mirrorIndex: Int = 0
        /// Headers actually sent, after per-host overrides (User-Agent, …) are merged.
        /// Only written before workers start, so no lock is needed.
        var effectiveHeaders: [String: String]
        var source: URL { sourceOverride ?? task.source }

        /// Terminal outcome of the last transfer, so the failover loop can decide
        /// whether to continue to the next mirror or stop.
        enum Outcome { case completed, failed, paused }

        /// 控制字段会被主线程（pause/resume/remove）与各下载 worker 同时读写，
        /// 必须加锁：否则取消标志可能读到旧值、lastOutcome 可能在判空时撕裂。
        private let stateLock = NSLock()
        private var _handle: Task<Void, Never>?
        private var _cancelled = false
        private var _lastOutcome: Outcome?
        private var _lowSpeedSince: Date?

        var handle: Task<Void, Never>? {
            get { stateLock.lock(); defer { stateLock.unlock() }; return _handle }
            set { stateLock.lock(); defer { stateLock.unlock() }; _handle = newValue }
        }

        var cancelled: Bool {
            get { stateLock.lock(); defer { stateLock.unlock() }; return _cancelled }
            set { stateLock.lock(); defer { stateLock.unlock() }; _cancelled = newValue }
        }

        var lastOutcome: Outcome? {
            get { stateLock.lock(); defer { stateLock.unlock() }; return _lastOutcome }
            set { stateLock.lock(); defer { stateLock.unlock() }; _lastOutcome = newValue }
        }

        /// 低速计时起点；任一 worker 报告恢复速度后清空。
        var lowSpeedSince: Date? {
            get { stateLock.lock(); defer { stateLock.unlock() }; return _lowSpeedSince }
            set { stateLock.lock(); defer { stateLock.unlock() }; _lowSpeedSince = newValue }
        }

        init(_ t: DownloadTask) {
            task = t
            effectiveHeaders = t.options
        }
    }

    /// Async-safe job table (OSAllocatedUnfairLock instead of NSLock because these
    /// methods are called from async contexts).
    private let jobsState = OSAllocatedUnfairLock<[UUID: Job]>(initialState: [:])
    /// 正在传输的分段协调器，供检查器读取实时分段快照。
    private let coordinators = OSAllocatedUnfairLock<[UUID: SegmentCoordinator]>(initialState: [:])
    private let writeQueue = DispatchQueue(label: "siphon.nativehttp.write")
    private let session: URLSession = CredentialScope.makeSession { c in
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 60
    }

    /// Per-proxy sessions (FluxDown PAC / auto-proxy model). When the system PAC
    /// resolves a host to a proxy, that host's requests run on a dedicated session
    /// carrying the proxy dictionary; `DIRECT` hosts use the default session.
    private let proxySessions = OSAllocatedUnfairLock<[String: URLSession]>(initialState: [:])

    private func session(for url: URL) -> URLSession {
        guard let dict = ProxyRouter.shared.proxyDictionary(for: url) else { return session }
        let key = dict.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        if let existing = proxySessions.withLock({ $0[key] }) { return existing }
        let s = CredentialScope.makeSession { c in
            c.httpMaximumConnectionsPerHost = 8
            c.timeoutIntervalForRequest = 60
            c.connectionProxyDictionary = dict
        }
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
        let handle = job?.handle
        handle?.cancel()
        // Unwind the old run fully before reporting: the unwind path writes the
        // sidecar checkpoint, and coordinator cursors must not be saved while a
        // writeChunk is still in flight (they run ahead of the disk).
        await handle?.value
        await report(.paused, for: id)
    }

    public func resume(_ id: UUID) async {
        dbg("resume \(id)")
        guard let job = jobsState.withLock({ $0[id] }) else { return }
        job.cancelled = false
        let old = job.handle
        job.handle = Task { [weak self] in
            // The previous run must fully unwind before a new coordinator
            // touches the same .part file — two concurrent writers corrupt the
            // sidecar bookkeeping and each other's bytes.
            await old?.value
            await self?.run(job)
        }
    }

    public func remove(_ id: UUID) async {
        let job = jobsState.withLock { $0.removeValue(forKey: id) }
        if let job {
            job.cancelled = true
            job.handle?.cancel()
            // 已完成的任务只从列表移除，成品文件必须保留；只有未完成的中途数据
            // （.part / 续传 sidecar）才随任务一起清理。
            if job.lastOutcome != .completed {
                try? FileManager.default.removeItem(at: job.task.destination)
                let writing = writingURL(for: job.task.destination)
                try? FileManager.default.removeItem(at: writing)
                Sidecar.clear(for: writing)
                Sidecar.clear(for: job.task.destination)
            }
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

        // Multi-CDN failover (FluxDown multi_cdn model): try sources fastest-first
        // by observed speed (aria2 AdaptiveURISelector), then in document order.
        // A hard failure (unreachable host, fatal status, persistent resume
        // failure) advances to the next source.
        let candidates = [task.source] + task.mirrors.filter { $0 != task.source }
        for (index, source) in MirrorSelector.shared.ranked(candidates).enumerated() {
            let attempt = Job(task)
            attempt.cancelled = job.cancelled
            attempt.throttle = job.throttle
            attempt.sourceOverride = source
            attempt.mirrorIndex = index
            // Keep the run-task handle on the attempt: pause()/resume() look the
            // Job up by id and cancel/await that handle. A fresh Job here would
            // carry handle == nil and pause would return while the old run was
            // still streaming.
            attempt.handle = job.handle
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
                // Block-wise verification first (Metalink <pieces>): bad pieces
                // are surgically re-fetched — a corrupted 1 MiB block must not
                // cost a full 4 GB re-download (aria2 ChunkChecksum model).
                if !job.task.pieceHashes.isEmpty, job.task.pieceLength > 0 {
                    var rounds = 0
                    while true {
                        let bad: [Range<Int64>]
                        do { bad = try Self.badPieceRanges(fileAt: out, pieceLength: job.task.pieceLength,
                                                           hashes: job.task.pieceHashes) }
                        catch { break } // unreadable file → whole-file checksum reports it
                        guard !bad.isEmpty else { break }
                        if rounds >= Self.maxPieceRepairRounds {
                            job.lastOutcome = .failed
                            await report(.error, for: job.task.id, error:
                                NetFailure.checksumMismatch)
                            return
                        }
                        rounds += 1
                        dbg("piece verify: \(bad.count) bad piece(s), repair round \(rounds)")
                        guard await repairRanges(job, fileAt: out, ranges: bad) else {
                            job.lastOutcome = .failed
                            await report(.error, for: job.task.id, error:
                                NetFailure.checksumMismatch)
                            return
                        }
                    }
                }
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
                HostHealthStore.shared.markHealthy(host: job.source.host ?? "")
                await report(.completed, for: job.task.id)
                return
            case .failed(let error):
                HostHealthStore.shared.recordFailure(host: job.source.host ?? "")
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
        // Stale multi-NIC temp files from a crashed session are garbage: the
        // tail is re-planned (or fetched natively) on resume.
        let dir = out.deletingLastPathComponent()
        if let stale = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for f in stale where f.lastPathComponent.hasPrefix(".siphon-mnic-")
                    && f.lastPathComponent.hasSuffix(".part") {
                try? FileManager.default.removeItem(at: f)
            }
        }

        // Per-host overrides (AB DM PerHostSettingsManager): merge any custom
        // User-Agent into the headers actually sent for this transfer.
        let perHost = PerHostSettings.shared.rule(for: job.source.host ?? "")
        var headers = task.options
        if let ua = perHost?.userAgent, !ua.isEmpty {
            headers["User-Agent"] = ua
        }
        // Credentials were issued for `task.source`. A mirror on another site must
        // not receive them; redirects are re-scoped per hop by the session delegate.
        job.effectiveHeaders = CredentialScope.headers(headers, from: task.source, to: job.source)

        // Probe remote size / range support / validators.
        let info: ProbeInfo
        do { info = try await probe(url: job.source, headers: job.effectiveHeaders) }
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

        // Conditional GET (aria2 --conditional-get): the destination file
        // already exists from an earlier download. Ask the server whether it
        // changed since the file's mtime — 304 means the local copy is current:
        // finish the task without transferring. A pending sidecar means this is
        // a real resume, so the check is skipped then.
        if let mtime = try? FileManager.default.attributesOfItem(
                atPath: finalURL.path)[.modificationDate] as? Date,
           Sidecar.load(for: out)?.parts.isEmpty != false {
            var cond = job.effectiveHeaders
            cond["If-Modified-Since"] = Self.httpDate(mtime)
            if await notModified(url: job.source, headers: cond) {
                dbg("conditional-get: 304, local file is current")
                let existing = fileSize(finalURL) ?? 0
                var p = DownloadProgress()
                p.totalBytes = existing; p.downloadedBytes = existing
                await delegate?.engineDidUpdate(taskID: task.id, progress: p)
                return .completed
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
            // Sidecar sanity: every recorded cursor must be backed by bytes on
            // disk (preallocated file when the size is known, high-water mark
            // otherwise). A cursor beyond the file size means the sidecar was
            // written by a buggy build — discard it rather than resume into
            // astronomical offsets.
            let unchanged = sc.total == info.total
                && sc.etag == info.etag && sc.lastModified == info.lastModified
                && (fileSize(out) ?? 0) >= maxPartCursor(sc)
            if !unchanged {
                // Remote changed or sidecar is junk: start over, cleanly.
                Sidecar.clear(for: out)
                try? FileManager.default.removeItem(at: out)
                sidecar = nil
            }
        }

        let canRange = info.canRange
        // Multi-source segment distribution (aria2 hybrid multi-source): when
        // the task carries mirrors and the primary is range-capable, probe each
        // mirror and keep those serving the same file. Workers then pull
        // different ranges from different sources, weighted by observed speed
        // (MirrorSelector). Credentials are re-scoped per mirror origin.
        var endpoints = [MirrorEndpoint(url: job.source, headers: job.effectiveHeaders)]
        if canRange, info.total >= Self.mirrorProbeMinSize, !task.mirrors.isEmpty {
            let probed = await Self.probeMirrors(task.mirrors, primary: job.source,
                                                 primaryEtag: info.etag, total: info.total,
                                                 baseHeaders: headers)
            endpoints += probed
            dbg("mirror probe: \(probed.count)/\(task.mirrors.count) usable")
        }

        // Known-zero-length body: there is nothing for the coordinator to
        // observe — a 0-byte part never advances `cursor`, so the worker loop
        // would spin forever. Publish an empty file and complete immediately.
        if info.knownTotal, info.total == 0 {
            dbg("probe: known 0-byte body, completing immediately")
            if !FileManager.default.fileExists(atPath: finalURL.path) {
                FileManager.default.createFile(atPath: finalURL.path, contents: nil)
            }
            try? FileManager.default.removeItem(at: out)
            Sidecar.clear(for: out)
            Sidecar.clear(for: finalURL)
            let p = DownloadProgress()
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
            return .completed
        }

        var parts: [SegmentCoordinator.Part]
        var multiNicTail: SecondaryPath?
        if canRange, let sc = sidecar, !sc.parts.isEmpty {
            parts = sc.parts.map { SegmentCoordinator.Part(start: $0[0], cursor: $0[1], end: $0[2]) }
            // A multi-NIC download's curl half lives outside the sidecar; a
            // resumed task must re-claim the uncovered tail natively.
            let covered = parts.map { $0.end }.max() ?? -1
            if info.total > 0, covered >= 0, covered < info.total - 1 {
                parts.append(SegmentCoordinator.Part(start: covered + 1, cursor: covered + 1,
                                                     end: info.total - 1))
            }
        } else if canRange, info.total >= Self.minSplit * 2 {
            // Multi-NIC aggregation: with ≥2 usable interfaces and a large
            // download, curl on a second interface pulls the tail half while the
            // native engine handles the head half (FluxDown multi_nic model).
            if let tail = Self.planSecondaryPath(url: job.source,
                                                 headers: job.effectiveHeaders,
                                                 total: info.total,
                                                 directory: out.deletingLastPathComponent()) {
                multiNicTail = tail
                parts = [SegmentCoordinator.Part(start: 0, cursor: 0,
                                                 end: tail.range.lowerBound - 1)]
                dbg("multi-NIC: \(tail.range.lowerBound)..<\(tail.range.upperBound) via \(tail.interface)")
            } else {
                parts = [SegmentCoordinator.Part(start: 0, cursor: 0, end: info.total - 1)]
            }
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

        // 每任务并发连接数（默认 8，可在任务检查器中调整 1...32）。
        let requestedConnections = max(1, min(32, job.task.connections))
        let coordinator = SegmentCoordinator(parts: parts,
                                             maxConnections: requestedConnections,
                                             minSplit: Self.minSplit,
                                             stealThreshold: Self.stealThreshold)
        // Resume accounting: bytes already on disk from previous sessions count
        // toward progress; otherwise a successful resume reports incompleteBody.
        let alreadyWritten = parts.reduce(Int64(0)) { $0 + max(0, $1.cursor - $1.start) }
        // Slow start: honour a learned per-domain cap and a positive hint ramp.
        let host = job.source.host ?? ""
        var cap = DomainConnPolicy.shared.effectiveMax(host: host,
                                                       requested: requestedConnections)
        // 主机健康度熔断：反复失败或历史吞吐很差时先降到 1~2 条连接。
        cap = HostHealthStore.shared.suggestedConnections(host: host, requested: cap)
        coordinator.effectiveCap = cap
        // Per-host connection cap / speed limit overrides (AB DM per-host model).
        if let ph = perHost {
            coordinator.effectiveCap = max(1, min(coordinator.effectiveCap, ph.maxConnections))
            if ph.speedLimitBytesPerSec > 0 {
                job.throttle.setLimit(ph.speedLimitBytesPerSec)
            }
        }
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
        coordinators.withLock { $0[task.id] = coordinator }
        let result = await coordinateWorkers(job, url: job.source, handle: handle,
                                             coordinator: coordinator, tracker: tracker,
                                             total: info.total, canRange: canRange,
                                             sidecarSaver: sidecarSaver,
                                             sizePlan: sizePlan,
                                             endpoints: endpoints)
        _ = coordinators.withLock { $0.removeValue(forKey: task.id) }

        // Persist learnings for the domain.
        if case .done = result {
            DomainConnPolicy.shared.recordSuccess(host: host,
                                                  connections: coordinator.peakConnections)
        }

        let finalTotal = sizePlan.plannedTotal
        dbg("pool result: \(result) written=\(tracker.written)/\(finalTotal) peak=\(coordinator.peakConnections) remaining=\(coordinator.remainingBytes)")
        if let tail = multiNicTail {
            var nativeDone = false
            if case .done = result { nativeDone = true }
            if job.cancelled || !nativeDone { tail.cancel() }
        }
        if job.cancelled {
            sidecarSaver.forceSave()
            dbg("cancelled mid-transfer")
            return .failed(CancellationError())
        }
        switch result {
        case .done:
            // Join the multi-NIC tail: splice curl's output into the preallocated
            // file, or fall back to a native pass over the same ranges.
            if let tail = multiNicTail {
                let ok = await tail.awaitCompletion()
                if ok, splice(fileAt: tail.tmp, into: handle,
                              at: tail.range.lowerBound, expected: Int64(tail.range.count),
                              tracker: tracker) {
                    try? FileManager.default.removeItem(at: tail.tmp)
                    dbg("multi-NIC tail spliced (\(tail.range.count) bytes)")
                } else {
                    try? FileManager.default.removeItem(at: tail.tmp)
                    dbg("multi-NIC tail failed; native fallback pass")
                    // Head parts are 100% done here: persist the main sidecar
                    // now and keep the tail's bookkeeping in a separate file,
                    // so a crash mid-tail never clobbers head progress.
                    sidecarSaver.forceSave()
                    let tailDest = URL(fileURLWithPath: out.path + ".tail-meta")
                    let tailParts = [SegmentCoordinator.Part(
                        start: tail.range.lowerBound, cursor: tail.range.lowerBound,
                        end: tail.range.upperBound - 1)]
                    let tailCoord = SegmentCoordinator(parts: tailParts,
                                                       maxConnections: requestedConnections,
                                                       minSplit: Self.minSplit,
                                                       stealThreshold: Self.stealThreshold)
                    let tailTracker = ProgressTracker()
                    let tailSaver = SidecarSaver(destination: tailDest, coordinator: tailCoord,
                                                 etag: info.etag, lastModified: info.lastModified,
                                                 total: info.total)
                    _ = await coordinateWorkers(job, url: job.source, handle: handle,
                                                    coordinator: tailCoord, tracker: tailTracker,
                                                    total: info.total, canRange: true,
                                                    sidecarSaver: tailSaver, sizePlan: sizePlan,
                                                    endpoints: endpoints)
                    Sidecar.clear(for: tailDest)
                    if let f = tailCoord.fatalError { return .failed(f) }
                    guard tailCoord.remainingBytes == 0 else {
                        return .failed(NetFailure.incompleteBody)
                    }
                    writeQueue.sync { tracker.written += Int64(tail.range.count) }
                }
            }
            if tracker.written != finalTotal && finalTotal > 0 {
                return .failed(NetFailure.incompleteBody)
            }
            diagnostics.withLock { $0.segmentCount = coordinator.peakConnections }
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
                                   sizePlan: SizePlan,
                                   endpoints: [MirrorEndpoint]) async -> PoolResult {
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
                                          sizePlan: sizePlan,
                                          endpoints: endpoints)
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

    /// Weighted least-connections source choice (aria2 URI selection): highest
    /// observed speed with an active-connection penalty, so a fast mirror gets
    /// most workers but usage spreads as connections pile up. Untested sources
    /// score 0 and are tried in list order (primary first).
    static func pickEndpoint(_ endpoints: [MirrorEndpoint], usage: inout [URL: Int]) -> MirrorEndpoint {
        guard endpoints.count > 1 else { return endpoints[0] }
        let chosen = endpoints.min { a, b in
            let sa = MirrorSelector.shared.score(a.url) / Double(1 + (usage[a.url] ?? 0))
            let sb = MirrorSelector.shared.score(b.url) / Double(1 + (usage[b.url] ?? 0))
            return sa > sb
        } ?? endpoints[0]
        usage[chosen.url, default: 0] += 1
        return chosen
    }

    /// HEAD-probe mirrors concurrently; keep only those that answer and serve a
    /// file of the same size (and, when both sides expose an ETag, the same one).
    static func probeMirrors(_ mirrors: [URL], primary: URL, primaryEtag: String?,
                             total: Int64,
                             baseHeaders: [String: String]) async -> [MirrorEndpoint] {
        await withTaskGroup(of: MirrorEndpoint?.self) { group in
            for m in mirrors where m != primary {
                group.addTask {
                    let h = CredentialScope.headers(baseHeaders, from: primary, to: m)
                    var req = URLRequest(url: m, cachePolicy: .reloadIgnoringLocalCacheData)
                    req.httpMethod = "HEAD"
                    for (k, v) in h where !["dir", "out"].contains(k.lowercased()) {
                        req.setValue(v, forHTTPHeaderField: k)
                    }
                    guard let (_, resp) = try? await URLSession.shared.data(for: req),
                          let http = resp as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else { return nil }
                    let t = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
                    if t > 0, total > 0, t != total { return nil }
                    let etag = http.value(forHTTPHeaderField: "ETag")
                    if let etag, let primaryEtag, !etag.isEmpty, !primaryEtag.isEmpty, etag != primaryEtag {
                        return nil
                    }
                    return MirrorEndpoint(url: m, headers: h)
                }
            }
            var out: [MirrorEndpoint] = []
            for await e in group { if let e { out.append(e) } }
            return out
        }
    }

    private func workerLoop(_ job: Job, url: URL, handle: FileHandle,
                            coordinator: SegmentCoordinator, tracker: ProgressTracker,
                            total: Int64, canRange: Bool,
                            sidecarSaver: SidecarSaver,
                            sizePlan: SizePlan,
                            endpoints: [MirrorEndpoint]) async {
        var usage: [URL: Int] = [:]
        while !job.cancelled {
            guard let part = coordinator.claim() else {
                if coordinator.isDrained { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            let endpoint = Self.pickEndpoint(endpoints, usage: &usage)
            dbg("worker claimed part \(part.start)..\(part.end) from \(part.cursor) via \(endpoint.url.host ?? "?")")
            let started = Date()
            do {
                let bytes = try await streamPart(part, url: endpoint.url, headers: endpoint.headers,
                                     handle: handle, tracker: tracker,
                                     total: total, job: job,
                                     coordinator: coordinator, canRange: canRange,
                                     sidecarSaver: sidecarSaver,
                                     sizePlan: sizePlan)
                usage[endpoint.url, default: 0] -= 1
                let elapsed = Date().timeIntervalSince(started)
                MirrorSelector.shared.record(endpoint.url, bytes: bytes, duration: elapsed)
                HostHealthStore.shared.record(host: endpoint.url.host ?? url.host ?? "",
                                              bytes: bytes, duration: elapsed)
                dbg("worker finished part \(part.start)..\(part.end)")
            } catch is CancellationError {
                usage[endpoint.url, default: 0] -= 1
                coordinator.requeueRemainder(of: part)
                return
            } catch {
                usage[endpoint.url, default: 0] -= 1
                MirrorSelector.shared.recordFailure(endpoint.url)
                HostHealthStore.shared.recordFailure(host: endpoint.url.host ?? url.host ?? "")
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

    /// Plan a secondary-interface curl path for the tail half of a large
    /// download; nil when disabled, too small, single-homed, or curl is absent.
    static func planSecondaryPath(url: URL, headers: [String: String], total: Int64,
                                  directory: URL) -> SecondaryPath? {
        guard total >= multiNicMinSize,
              UserDefaults.standard.object(forKey: multiNicKey) as? Bool ?? true else { return nil }
        let ifaces = NetworkInterfaces.usableIPv4()
        guard ifaces.count >= 2 else { return nil }
        let mid = total / 2
        return SecondaryPath(url: url, headers: headers,
                             range: mid..<total, directory: directory,
                             interface: ifaces[1])
    }

    /// Copy a completed secondary-path temp file into the preallocated .part at
    /// `offset`, in 1 MiB chunks (never the whole tail in memory). Succeeds only
    /// when exactly `expected` bytes landed.
    private func splice(fileAt tmp: URL, into handle: FileHandle, at offset: Int64,
                        expected: Int64, tracker: ProgressTracker) -> Bool {
        guard let src = try? FileHandle(forReadingFrom: tmp) else { return false }
        defer { try? src.close() }
        var written: Int64 = 0
        var failed = false
        writeQueue.sync {
            do {
                try handle.seek(toOffset: UInt64(offset))
                while true {
                    let chunk: Data
                    do { chunk = try src.read(upToCount: 1 << 20) ?? Data() }
                    catch { failed = true; break }
                    if chunk.isEmpty { break }
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                }
            } catch {
                failed = true
            }
            tracker.written += written
        }
        return !failed && written == expected
    }

    // MARK: - single part streaming

    /// Streaming chunk pump for part bodies. `URLSession.AsyncBytes` exposes
    /// byte-wise iteration only, which dominated CPU at high throughput; this
    /// yields network-sized chunks instead. Delegate methods not implemented
    /// here keep URLSession's default behavior (redirect follow, auth reuse),
    /// and the session configuration is copied from the engine's proxied
    /// session so per-host settings still apply.
    private final class ChunkedSource: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let chunks: AsyncThrowingStream<Data, Error>
        private let chunkCont: AsyncThrowingStream<Data, Error>.Continuation
        private var responseCont: CheckedContinuation<URLResponse, Error>?
        private var session: URLSession?
        private var dataTask: URLSessionDataTask?

        private override init() {
            var cont: AsyncThrowingStream<Data, Error>.Continuation!
            chunks = AsyncThrowingStream { cont = $0 }
            chunkCont = cont
            super.init()
            // When the consuming task is cancelled (pause/remove), the stream
            // terminates; kill the underlying dataTask so a stalled read wakes
            // up instead of waiting for data that never comes.
            cont.onTermination = { [weak self] _ in
                self?.dataTask?.cancel()
                self?.invalidate()
            }
        }

        static func connect(request: URLRequest, baseSession: URLSession) async throws
            -> (ChunkedSource, URLResponse) {
            let src = ChunkedSource()
            let session = URLSession(configuration: baseSession.configuration,
                                     delegate: src, delegateQueue: nil)
            src.session = session
            let task = session.dataTask(with: request)
            src.dataTask = task
            let response: URLResponse = try await withCheckedThrowingContinuation { k in
                src.responseCont = k
                task.resume()
            }
            return (src, response)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            completionHandler(.allow)
            responseCont?.resume(returning: response)
            responseCont = nil
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Split delivery bursts: one giant didReceive (localhost can hand
            // over hundreds of KB at once) would hold a single writeChunk for
            // many seconds under throttling, delaying pause response.
            var start = data.startIndex
            while start < data.endIndex {
                let end = data.index(start, offsetBy: 16 << 10, limitedBy: data.endIndex)
                    ?? data.endIndex
                chunkCont.yield(data[start..<end])
                start = end
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let responseCont {
                responseCont.resume(throwing: error ?? URLError(.unknown))
                return
            }
            if let error { chunkCont.finish(throwing: error) } else { chunkCont.finish() }
        }

        func invalidate() {
            session?.invalidateAndCancel()
            session = nil
        }
    }

    private func streamPart(_ part: SegmentCoordinator.Part, url: URL,
                            headers: [String: String], handle: FileHandle,
                            tracker: ProgressTracker, total: Int64, job: Job,
                            coordinator: SegmentCoordinator, canRange: Bool,
                            sidecarSaver: SidecarSaver,
                            sizePlan: SizePlan) async throws -> Int64 {
        // No Range header only when the server cannot range at all. A
        // size-unknown part still ranges — open-ended `bytes=N-` — so a
        // resumed unknown-total download continues from its cursor; the old
        // `bytes=N-2^62` sentinel end was an invalid header.
        let singleStream = !canRange
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "GET"
        for (k, v) in headers where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !singleStream {
            if part.end == SegmentCoordinator.unknownEnd {
                req.setValue("bytes=\(part.cursor)-", forHTTPHeaderField: "Range")
            } else {
                req.setValue("bytes=\(part.cursor)-\(part.end)", forHTTPHeaderField: "Range")
            }
        }
        let (source, response) = try await ChunkedSource.connect(request: req, baseSession: session(for: url))
        defer { source.invalidate() }
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
        var byteCount = Int64(0)
        for try await chunk in source.chunks {
            if job.cancelled { throw CancellationError() }
            byteCount += Int64(chunk.count)
            buffer.append(chunk)
            if buffer.count >= Self.flushThreshold {
                let requested = Int64(buffer.count)
                let approved = coordinator.approveWrite(offset: offset, requested: requested)
                if approved == 0 { return byteCount } // tail stolen or part finished elsewhere
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
                if approved < requested { return byteCount }
            }
        }
        // Cancellation surfaced as a clean stream end, not a throw: stop here so
        // the unwind forceSave records exactly the bytes already on disk.
        if job.cancelled { throw CancellationError() }
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
        if part.end == SegmentCoordinator.unknownEnd {
            // EOF on a size-unknown stream is the completion signal: remaining
            // is the sentinel, so completePart alone would never retire it.
            coordinator.completeUnknownPart()
        }
        coordinator.completePart(through: offset)
        sidecarSaver.requestSave()
        return byteCount
    }

    private func writeChunk(_ data: Data, at offset: Int64, handle: FileHandle,
                            tracker: ProgressTracker, total: Int64, job: Job,
                            coordinator: SegmentCoordinator,
                            sidecarSaver: SidecarSaver) async throws {
        await SpeedLimitController.shared.consume(data.count)
        await job.throttle.consume(data.count)
        let advanced = try flushAndReport(data, at: offset, handle: handle,
                                          tracker: tracker, total: total, taskID: job.task.id)
        if let p = advanced {
            // 低速熔断（aria2 lowest-speed-limit）：持续低于阈值 10 秒就放弃当前来源。
            let limit = LowSpeedPolicy.limit
            if limit > 0 {
                if p.speedBytesPerSec < limit {
                    if let since = job.lowSpeedSince {
                        if Date().timeIntervalSince(since) >= LowSpeedPolicy.sustainedSeconds {
                            throw NetFailure.lowSpeed
                        }
                    } else {
                        job.lowSpeedSince = Date()
                    }
                } else {
                    job.lowSpeedSince = nil
                }
            }
            await delegate?.engineDidUpdate(taskID: job.task.id, progress: p)
        }
        sidecarSaver.maybeSave()
    }

    /// Serialised write + throttled progress snapshot (250 ms window).
    /// Uses the throwing FileHandle APIs exclusively: the legacy `write(_:)` /
    /// `seek(toFileOffset:)` raise NSExceptions, which cannot unwind through a
    /// dispatch barrier sync and abort the process (the 2026-11 crash).
    private func flushAndReport(_ data: Data, at offset: Int64, handle: FileHandle,
                                tracker: ProgressTracker, total: Int64,
                                taskID: UUID) throws -> DownloadProgress? {
        // 计数与测速快照全部放进 writeQueue：多个 worker 并发写入时，
        // 在锁外读 written/lastBytes/lastReport 会把速度算成重复的尖峰。
        var progress: DownloadProgress?
        do {
            try writeQueue.sync {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
                tracker.written += Int64(data.count)
                let now = Date()
                let dt = now.timeIntervalSince(tracker.lastReport)
                guard dt >= 0.25 else { return }
                var p = DownloadProgress()
                p.downloadedBytes = tracker.written
                p.totalBytes = total
                p.speedBytesPerSec = Int64(Double(tracker.written - tracker.lastBytes) / dt)
                tracker.lastBytes = tracker.written
                tracker.lastReport = now
                progress = p
            }
        } catch {
            throw NetFailure.diskWrite("\(error)")
        }
        return progress
    }

    // MARK: - piece verification (aria2 ChunkChecksum model)

    /// Verify each `pieceLength` block of the file against its SHA-1 hex hash.
    /// Returns the byte ranges of bad pieces ([] when all good). Pieces beyond
    /// EOF are ignored (size-unknown downloads).
    static func badPieceRanges(fileAt url: URL, pieceLength: Int64,
                               hashes: [String]) throws -> [Range<Int64>] {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bad: [Range<Int64>] = []
        for (i, hex) in hashes.enumerated() {
            let start = Int64(i) * pieceLength
            guard start < size else { break }
            _ = try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: Int(min(pieceLength, size - start))) ?? Data()
            let digest = Insecure.SHA1.hash(data: data)
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            if actual != hex.lowercased() {
                bad.append(start..<min(start + pieceLength, size))
            }
        }
        return bad
    }

    /// Re-download specific byte ranges into an existing (complete-size) file
    /// through the normal coordinator pipeline. Used by piece repair.
    private func repairRanges(_ job: Job, fileAt file: URL, ranges: [Range<Int64>]) async -> Bool {
        guard let handle = try? FileHandle(forWritingTo: file) else { return false }
        defer { try? handle.close() }
        let parts = ranges.map {
            SegmentCoordinator.Part(start: $0.lowerBound, cursor: $0.lowerBound,
                                    end: $0.upperBound - 1)
        }
        let coordinator = SegmentCoordinator(parts: parts,
                                             maxConnections: max(1, min(32, job.task.connections)),
                                             minSplit: Self.minSplit,
                                             stealThreshold: Self.stealThreshold)
        let tracker = ProgressTracker()
        let sizePlan = SizePlan(total: Int64(ranges.map { Int($0.count) }.reduce(0, +)))
        let saver = SidecarSaver(destination: file, coordinator: coordinator,
                                 etag: nil, lastModified: nil, total: 0)
        await report(.active, for: job.task.id)
        let result = await coordinateWorkers(job, url: job.source, handle: handle,
                                             coordinator: coordinator, tracker: tracker,
                                             total: 0, canRange: true,
                                             sidecarSaver: saver, sizePlan: sizePlan,
                                             endpoints: [MirrorEndpoint(url: job.source,
                                                                        headers: job.effectiveHeaders)])
        Sidecar.clear(for: file)
        if let f = coordinator.fatalError { dbg("piece repair failed: \(f)"); return false }
        if case .done = result, coordinator.remainingBytes == 0 { return true }
        return false
    }

    // MARK: - checksum

    private func verifyChecksum(fileAt url: URL, spec: String) throws -> Bool {
        try ChecksumVerifier.verify(fileAt: url, spec: spec)
    }

    // MARK: - probe

    struct ProbeInfo {
        var total: Int64 = 0
        var canRange = false
        var etag: String?
        var lastModified: String?
        /// True when the server explicitly reported the size (Content-Length or
        /// a Content-Range total). total == 0 alone is ambiguous with "unknown".
        var knownTotal = false
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
            if http.value(forHTTPHeaderField: "Content-Length") != nil { result.knownTotal = true }
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
                    let denom = String(cr[cr.index(after: slash)...])
                        .trimmingCharacters(in: .whitespaces)
                    if denom != "*" {
                        result.knownTotal = true
                        result.total = Int64(denom) ?? 0
                    }
                }
                result.etag = http.value(forHTTPHeaderField: "ETag")
                result.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            } else if (200...299).contains(http.statusCode) {
                result.total = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
                result.canRange = false
                result.knownTotal = http.value(forHTTPHeaderField: "Content-Length") != nil
            }
        }
        return result
    }

    /// Conditional-request probe (aria2 --conditional-get): HEAD with
    /// If-Modified-Since; true only on an explicit 304. Any failure or 200
    /// means "download normally".
    private func notModified(url: URL, headers: [String: String]) async -> Bool {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "HEAD"
        for (k, v) in headers where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        guard let (_, resp) = try? await session(for: url).data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 304
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private static func httpDate(_ date: Date) -> String {
        httpDateFormatter.string(from: date)
    }

    private func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    private func maxPartCursor(_ sc: DownloadSidecar) -> Int64 {
        sc.parts.map { $0[1] }.max() ?? 0
    }

    private func report(_ state: DownloadState, for id: UUID, error: Error? = nil) async {
        diagnostics.withLock { $0.state = state }
        await delegate?.engineDidChangeState(taskID: id, state: state, error: error)
    }
}

// MARK: - Data helper

private extension Data {
    mutating func truncatePrefix(_ n: Int) {
        if n < count { self = prefix(n) }
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
    /// Per-segment throughput history (FluxDown speed_history model): EWMA of the
    /// observed write rate per active part, keyed by `Part.start`. Drives the
    /// steal policy: work migrates from slow to fast connections.
    private struct SpeedSample {
        var ewma: Double = 0
        var windowBytes: Int64 = 0
        var windowStart = Date()
    }
    private var speeds: [Int64: SpeedSample] = [:]

    var effectiveCap: Int = 8
    var activeConnections: Int { lock.lock(); defer { lock.unlock() }; return active.count }
    var isDrained: Bool { lock.lock(); defer { lock.unlock() }; return pending.isEmpty && active.isEmpty }
    var hasServerIgnoredRanges: Bool { lock.lock(); defer { lock.unlock() }; return serverIgnoredRanges }
    var fatalError: Error? { lock.lock(); defer { lock.unlock() }; return fatal }
    var remainingBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return (pending + active).reduce(Int64(0)) { $0 + ($1.end + 1 - $1.cursor) }
    }

    /// 一致性快照：按起始字节排序，未知总大小的分段用 `end = -1` 表示。
    func snapshot() -> [SegmentSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return (pending + active)
            .sorted { $0.start < $1.start }
            .map { SegmentSnapshot(start: $0.start,
                                   end: $0.end == Self.unknownEnd ? -1 : $0.end,
                                   cursor: $0.cursor) }
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

    /// A worker asks for work. May split an active part's tail. The victim is
    /// the part with the longest projected time-to-finish (remaining / observed
    /// speed) so a stalled source donates work to a faster connection; before
    /// any speed sample exists this degrades to "largest remaining".
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
        // Slow start beyond the first connection: steal from the slowest part.
        guard active.count < rampTarget, active.count < effectiveCap else { return nil }
        // A size-unknown sentinel part (end == unknownEnd) must never be split:
        // its "remaining" is a fictitious 2^62, and cutting it produces writes at
        // astronomical offsets (EFBIG). Unknown sizes stay single-stream until EOF.
        let splittable = active.indices.filter {
            active[$0].end != Self.unknownEnd && remaining(active[$0]) >= stealThreshold * 2
        }
        guard let idx = pickVictim(among: splittable) else { return nil }
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

    /// Index of the active part to steal from, or nil when nothing qualifies.
    private func pickVictim(among indices: [Int]) -> Int? {
        guard !indices.isEmpty else { return nil }
        guard !speeds.isEmpty else {
            return indices.max(by: { remaining(active[$0]) < remaining(active[$1]) })
        }
        let known = speeds.values.map(\.ewma).filter { $0 > 0 }.sorted()
        let fallback = known.isEmpty ? 0 : known[known.count / 2]
        func timeLeft(_ i: Int) -> Double {
            let s = speeds[active[i].start]?.ewma ?? fallback
            return Double(remaining(active[i])) / max(s, 65_536)
        }
        return indices.max(by: { timeLeft($0) < timeLeft($1) })
    }

    /// Approve a write of `requested` bytes at `offset`; returns the approved count
    /// (may be smaller if the part was split mid-flight, or 0 if nothing is ours).
    /// Also feeds the per-part speed history.
    func approveWrite(offset: Int64, requested: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let idx = active.firstIndex(where: { offset >= $0.cursor && offset <= $0.end }) else {
            return 0
        }
        let approved = min(requested, active[idx].end + 1 - offset)
        if approved > 0 {
            active[idx].cursor = offset + approved
            noteSpeed(active[idx].start, bytes: approved)
        }
        if remaining(active[idx]) <= 0 {
            speeds.removeValue(forKey: active[idx].start)
            active.remove(at: idx)
        }
        return approved
    }

    /// EWMA update for one part's observed throughput (2 s measurement windows).
    private func noteSpeed(_ key: Int64, bytes: Int64) {
        var s = speeds[key] ?? SpeedSample()
        s.windowBytes += bytes
        let dt = Date().timeIntervalSince(s.windowStart)
        if dt >= 2.0, s.windowBytes > 0 {
            let inst = Double(s.windowBytes) / dt
            s.ewma = s.ewma == 0 ? inst : s.ewma * 0.7 + inst * 0.3
            s.windowBytes = 0
            s.windowStart = Date()
        }
        speeds[key] = s
    }

    /// Worker finished streaming to `offset` without error.
    func completePart(through offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        if let idx = active.firstIndex(where: { $0.cursor <= offset && offset <= $0.end + 1 }) {
            if remaining(active[idx]) <= 0 {
                speeds.removeValue(forKey: active[idx].start)
                active.remove(at: idx)
            }
        }
    }

    /// EOF on a size-unknown single stream: retire its sentinel part outright.
    func completeUnknownPart() {
        lock.lock(); defer { lock.unlock() }
        for idx in active.indices.reversed() where active[idx].end == Self.unknownEnd {
            speeds.removeValue(forKey: active[idx].start)
            active.remove(at: idx)
        }
        pending.removeAll { $0.end == Self.unknownEnd }
    }

    /// Network error: put the un-fetched remainder back into the pending queue.
    /// A retry without byte progress bumps the failure counter (ABD semantics);
    /// too many fruitless retries is a hard stop for the whole download.
    func requeueRemainder(of part: Part) {
        lock.lock(); defer { lock.unlock() }
        speeds.removeValue(forKey: part.start)
        let idx = active.firstIndex(where: { $0.start == part.start && $0.cursor >= part.cursor })
        let remainder: Part?
        if let idx {
            let p = active.remove(at: idx)
            remainder = (p.end + 1 > p.cursor)
                ? Part(start: p.start, cursor: p.cursor, end: p.end) : nil
        } else if part.end + 1 > part.cursor {
            remainder = Part(start: part.start, cursor: part.cursor, end: part.end)
        } else {
            remainder = nil
        }
        // Keep the original `start` on a requeued part: the sidecar's byte
        // accounting (alreadyWritten = Σ cursor−start) relies on start marking
        // the beginning of the covered region. Resetting start to cursor made
        // every pause look like zero progress for the prefix already on disk.
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
        // Atomic: .atomic writes a temp file then renames it over the target —
        // never a half-written sidecar, and never a window with no sidecar.
        guard let data = try? JSONEncoder().encode(sc) else { return }
        try? data.write(to: path(for: destination), options: .atomic)
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

/// 低速熔断阈值（aria2 `lowest-speed-limit` 的最小版）。
/// 0 = 关闭；持续低于阈值超过 `sustainedSeconds` 才判断开，避免瞬时抖动误杀。
enum LowSpeedPolicy {
    static let key = "Siphon.lowSpeedLimit"
    static let sustainedSeconds: TimeInterval = 10

    static var limit: Int64 {
        get { max(0, Int64(UserDefaults.standard.integer(forKey: key))) }
        set { UserDefaults.standard.set(Int(max(0, newValue)), forKey: key) }
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
