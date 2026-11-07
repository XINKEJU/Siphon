import Foundation
import CryptoKit

/// Identifies the playlist/manifest a segment run belongs to. It lets a run be
/// resumed across an app relaunch: the assembler additionally hashes the segment
/// URL sequence (and byte ranges), so a changed playlist invalidates the old
/// progress instead of splicing two different streams together.
public struct SegmentResumeContext: Sendable {
    public let kind: String
    public let source: String
    public init(kind: String, source: String) {
        self.kind = kind
        self.source = source
    }
}

/// One HTTP range request contributing to a segmented download.
public struct SegmentRequest: Sendable {
    public let url: URL
    public let byteRange: (length: Int, offset: Int)?
    /// Media sequence number of this segment (HLS). Used to derive the AES-128
    /// default IV for live recordings, where the request index no longer equals
    /// the media sequence (the sliding window continuously appends new segments).
    public let mediaSequence: Int64?
    public init(url: URL, byteRange: (length: Int, offset: Int)? = nil,
                mediaSequence: Int64? = nil) {
        self.url = url
        self.byteRange = byteRange
        self.mediaSequence = mediaSequence
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
        var requests: [SegmentRequest]
        var handle: FileHandle
        let outURL: URL
        let headers: [String: String]
        /// URL the headers were captured for (the playlist / manifest). Segments
        /// and init/key URLs on another site must not receive its credentials.
        let credentialOrigin: URL
        let transform: (@Sendable (Data, SegmentRequest) -> Data)?
        var writtenCount: Int
        /// Real payload bytes written to disk. Progress, speed and ETA must be
        /// byte-based — segment counts made a 1.4 MB stream report "180 / 180".
        var writtenBytes: Int64
        var cancelled = false
        /// Live mode: keep the run loop alive and wait for `appendSegments` to add
        /// new requests (HLS/DASH live recording). When false the loop exits after
        /// the initial batch, exactly as before.
        var live = false
        var lastBytes: Int64 = 0
        var lastTime = Date()
        var task: Task<Void, Never>?
        /// Resume sidecar (`<out>.siphon-resume.json`); nil for live recordings,
        /// whose sliding window makes a persisted offset meaningless.
        let sidecarURL: URL?
        let resumeKind: String?
        let resumeSource: String?
        let fingerprint: String?
        var lastSidecarWrite = Date.distantPast
        /// Set by `remove`: the run loop may still be unwinding, and it must not
        /// write a sidecar (or keep one) for a task the user deleted.
        var removed = false
        /// 正常跑完（非取消）时置 true；`remove` 只在未完成时删除输出文件，
        /// 避免「移除 / 清理已完成」误删成品。
        var completed = false

        private let appendLock = NSLock()
        private var pendingAppends: [[SegmentRequest]] = []
        func queueAppend(_ new: [SegmentRequest]) {
            appendLock.lock(); defer { appendLock.unlock() }
            pendingAppends.append(new)
        }
        /// Run-loop only: folds queued live-refresh segments into `requests`.
        func drainAppends() -> [SegmentRequest] {
            appendLock.lock(); defer { appendLock.unlock() }
            let out = pendingAppends.flatMap { $0 }
            pendingAppends.removeAll()
            return out
        }

        init(requests: [SegmentRequest], handle: FileHandle, outURL: URL,
             headers: [String: String], credentialOrigin: URL,
             transform: (@Sendable (Data, SegmentRequest) -> Data)?,
             writtenCount: Int, writtenBytes: Int64 = 0,
             sidecarURL: URL? = nil, resumeKind: String? = nil,
             resumeSource: String? = nil, fingerprint: String? = nil) {
            self.requests = requests; self.handle = handle; self.outURL = outURL
            self.headers = headers; self.credentialOrigin = credentialOrigin
            self.transform = transform
            self.writtenCount = writtenCount; self.writtenBytes = writtenBytes
            self.sidecarURL = sidecarURL; self.resumeKind = resumeKind
            self.resumeSource = resumeSource; self.fingerprint = fingerprint
            self.lastTime = Date()
        }
    }

    public weak var delegate: (any EngineDelegate)?
    private var active: [UUID: Active] = [:]
    private let session = CredentialScope.session
    private let concurrency: Int

    public init(concurrency: Int = 6) { self.concurrency = max(1, concurrency) }

    /// - Parameter credentialOrigin: URL the supplied headers belong to (normally
    ///   the playlist / manifest URL). Defaults to the first request's URL, which
    ///   is right when every segment shares that host; pass it explicitly whenever
    ///   segments may live on another CDN.
    /// - Parameter resumeContext: enables segment-level resume across relaunches.
    ///   When a sidecar matches this context and the exact segment sequence, the
    ///   output is kept and fetching continues at the recorded segment; otherwise
    ///   the output is truncated and the download starts from zero.
    public func start(taskID: UUID, destination: URL, requests: [SegmentRequest],
                      headers: [String: String] = [:],
                      credentialOrigin: URL? = nil,
                      transform: (@Sendable (Data, SegmentRequest) -> Data)? = nil,
                      resume: Bool = false,
                      resumeContext: SegmentResumeContext? = nil) throws {
        if requests.isEmpty { return }
        let sidecarURL = Self.sidecarURL(for: destination)
        let fingerprint = resumeContext.map { _ in Self.fingerprint(for: requests) }

        var resumeFrom = resume ? (active[taskID]?.writtenCount ?? 0) : 0
        var resumeBytes: Int64 = 0
        // Only a fully consistent sidecar is trusted: same playlist kind/source,
        // an identical segment sequence, and a file whose size is exactly the
        // payload recorded for that segment count. Anything else restarts cleanly.
        if !resume, let ctx = resumeContext, let fingerprint,
           let saved = Self.loadSidecar(at: sidecarURL),
           saved.kind == ctx.kind, saved.source == ctx.source,
           saved.fingerprint == fingerprint,
           saved.writtenCount > 0, saved.writtenCount <= requests.count,
           let size = Self.fileSize(destination), size == saved.writtenBytes {
            resumeFrom = saved.writtenCount
            resumeBytes = size
        }

        let existing = !FileManager.default.fileExists(atPath: destination.path)
        if existing { FileManager.default.createFile(atPath: destination.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: destination)
        let appending = resume || resumeFrom > 0
        if appending { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
        // A truncated output makes any previously recorded offset meaningless.
        if !appending { try? FileManager.default.removeItem(at: sidecarURL) }

        let written = resumeFrom
        var alreadyWritten = resumeBytes
        if resume, alreadyWritten == 0, let size = Self.fileSize(destination) {
            alreadyWritten = size
        }
        let state = Active(requests: requests, handle: handle, outURL: destination,
                          headers: headers,
                          credentialOrigin: credentialOrigin ?? requests[0].url,
                          transform: transform, writtenCount: written,
                          writtenBytes: alreadyWritten,
                          sidecarURL: resumeContext == nil ? nil : sidecarURL,
                          resumeKind: resumeContext?.kind,
                          resumeSource: resumeContext?.source,
                          fingerprint: fingerprint)
        state.task = Task.detached(priority: .utility) { [weak self] in
            await self?.run(state, taskID: taskID)
        }
        active[taskID] = state
    }

    public func pause(_ id: UUID) {
        active[id]?.cancelled = true
        active[id]?.task?.cancel()
    }

    /// Re-arm after a pause. The previous run closed the handle on unwind, so
    /// this waits for it to fully exit, then reopens the file in append mode —
    /// starting a second run against the old (still-open or just-closed) handle
    /// would interleave two writers on the same output.
    public func resume(_ id: UUID) async throws {
        guard let s = active[id] else { return }
        s.cancelled = false
        let old = s.task
        s.task = Task.detached(priority: .utility) { [weak self] in
            _ = await old?.value
            await self?.reopenAndRun(s, taskID: id)
        }
    }

    private func reopenAndRun(_ s: Active, taskID: UUID) async {
        let h: FileHandle
        do {
            h = try FileHandle(forWritingTo: s.outURL)
            try h.seekToEnd()
        } catch {
            await delegate?.engineDidChangeState(taskID: taskID, state: .error, error: error)
            return
        }
        s.handle = h
        await run(s, taskID: taskID)
    }

    public func remove(_ id: UUID) {
        guard let s = active.removeValue(forKey: id) else { return }
        s.removed = true
        s.cancelled = true
        s.task?.cancel()
        discardSidecar(s)
        try? s.handle.close()
        if !s.completed { try? FileManager.default.removeItem(at: s.outURL) }
    }

    // MARK: - live (HLS/DASH live recording)

    /// Switch a running assembly into live mode: the run loop stays alive and waits
    /// for new segments instead of reporting completion after the initial batch.
    public func setLive(_ on: Bool) {
        active.values.forEach { $0.live = on }
    }

    /// Append new segments for a live playlist refresh. New requests are appended to
    /// the end of the request list; the in-flight run loop picks them up on its next
    /// pump. Safe to call from a different task than the one running `run`.
    /// Live refresh: appends are queued behind a lock; the run loop drains them
    /// itself, so `requests` is only ever mutated on the run-loop task (no
    /// cross-thread CoW racing with the fetch pump).
    public func appendSegments(_ new: [SegmentRequest]) {
        active.values.forEach { $0.queueAppend(new) }
    }

    // MARK: - ordered, bounded-concurrency assembly
    private func run(_ s: Active, taskID: UUID) async {
        var completed: [Int: Data] = [:]
        var nextToWrite = s.writtenCount
        var nextToFetch = s.writtenCount

        do {
            // For live playlists the loop stays alive, waiting for `appendSegments`
            // to add new requests. For VOD the loop runs once and exits — behaviour
            // is identical to before `live` was introduced.
            while !s.cancelled {
                s.requests.append(contentsOf: s.drainAppends())
                guard nextToFetch < s.requests.count else {
                    if s.live {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    break
                }
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
                                let d = try await self.fetch(req, headers: s.headers,
                                                             origin: s.credentialOrigin)
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
                            let final = s.transform?(d, s.requests[nextToWrite]) ?? d
                            // HLS/DASH 总大小通常未知，无法在开始前预检；
                            // 改为每段落盘前检查，空间耗尽时停在干净的段边界。
                            try DiskSpaceGuard.ensureCapacity(
                                total: Int64(final.count), alreadyWritten: 0,
                                directory: s.outURL.deletingLastPathComponent())
                            try s.handle.write(contentsOf: final)
                            nextToWrite += 1
                            s.writtenCount = nextToWrite
                            s.writtenBytes += Int64(final.count)
                            self.persistSidecar(s)
                            await self.report(s, taskID: taskID)
                        }
                        pump()
                    }
                }
            }
            try s.handle.close()
            if s.cancelled {
                // Persist the exact segment boundary before unwinding: the throttled
                // periodic write may be up to a second stale, and resuming from a
                // stale count would append duplicate segments to the output.
                persistSidecar(s, force: true)
                await delegate?.engineDidChangeState(taskID: taskID, state: .paused, error: nil)
            } else {
                s.completed = true
                discardSidecar(s)
                var p = DownloadProgress()
                p.totalBytes = s.writtenBytes
                p.downloadedBytes = s.writtenBytes
                await delegate?.engineDidUpdate(taskID: taskID, progress: p)
                await delegate?.engineDidChangeState(taskID: taskID, state: .completed, error: nil)
            }
        } catch is CancellationError {
            persistSidecar(s, force: true)
            try? s.handle.close()
            await delegate?.engineDidChangeState(taskID: taskID, state: .paused, error: nil)
        } catch {
            persistSidecar(s, force: true)
            try? s.handle.close()
            await delegate?.engineDidChangeState(taskID: taskID, state: .error, error: error)
        }
    }

    private func report(_ s: Active, taskID: UUID) async {
        var p = DownloadProgress()
        let written = s.writtenBytes
        p.downloadedBytes = written
        // Segment sizes are unknown up front. Estimate the total from the mean
        // of the segments already written, clamped to at least `written` so the
        // progress bar never overshoots 100%.
        if s.writtenCount > 0 {
            let mean = written / Int64(s.writtenCount)
            p.totalBytes = max(written, mean * Int64(s.requests.count))
        }
        let now = Date()
        let dt = now.timeIntervalSince(s.lastTime)
        if dt > 0 {
            p.speedBytesPerSec = Int64(Double(written - s.lastBytes) / dt)
        }
        s.lastBytes = written
        s.lastTime = now
        await delegate?.engineDidUpdate(taskID: taskID, progress: p)
    }

    // MARK: - resume sidecar

    /// Persisted progress for one segmented download (v1). `writtenCount` is the
    /// number of segments fully appended; `writtenBytes` is the exact file size
    /// those segments produced, so a resumed run can reject a truncated output.
    private struct ResumeSidecar: Codable {
        let kind: String
        let source: String
        let totalSegments: Int
        let writtenCount: Int
        let writtenBytes: Int64
        let fingerprint: String
        let updatedAt: Double
    }

    private static func sidecarURL(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + ".siphon-resume.json")
    }

    /// SHA-256 over the ordered segment URLs (and range offsets). Any playlist
    /// edit that changes the segment list yields a different fingerprint.
    private static func fingerprint(for requests: [SegmentRequest]) -> String {
        var material = ""
        for r in requests {
            material += r.url.absoluteString
            if let (len, off) = r.byteRange { material += "#\(off)+\(len)" }
            material += "\n"
        }
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private static func loadSidecar(at url: URL) -> ResumeSidecar? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResumeSidecar.self, from: d)
    }

    /// Writes progress at most once per second (and always when forced at a
    /// pause/error boundary). A write only happens after the segment has been
    /// appended, so the recorded count never runs ahead of the file.
    private func persistSidecar(_ s: Active, force: Bool = false) {
        guard !s.removed,
              let url = s.sidecarURL,
              let kind = s.resumeKind, let source = s.resumeSource,
              let fingerprint = s.fingerprint else { return }
        let now = Date()
        if !force && now.timeIntervalSince(s.lastSidecarWrite) < 1 { return }
        s.lastSidecarWrite = now
        let record = ResumeSidecar(kind: kind, source: source,
                                   totalSegments: s.requests.count,
                                   writtenCount: s.writtenCount,
                                   writtenBytes: s.writtenBytes,
                                   fingerprint: fingerprint,
                                   updatedAt: now.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func discardSidecar(_ s: Active) {
        guard let url = s.sidecarURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func fetch(_ req: SegmentRequest, headers: [String: String],
                       origin: URL) async throws -> Data {
        var r = URLRequest(url: req.url)
        r.httpMethod = "GET"
        if let (len, off) = req.byteRange {
            r.setValue("bytes=\(off)-\(off + len - 1)", forHTTPHeaderField: "Range")
        }
        let scoped = CredentialScope.headers(headers, from: origin, to: req.url)
        for (k, v) in scoped where !["dir", "out"].contains(k.lowercased()) {
            r.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: r)
        // A 404/403 error page must never be concatenated into the output as a
        // media segment.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NetFailure.httpStatus(http.statusCode)
        }
        return data
    }
}
