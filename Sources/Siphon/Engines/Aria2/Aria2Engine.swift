import Foundation

/// Drives aria2 for HTTP/HTTPS/FTP/SFTP/BitTorrent/Metalink/magnet and for every
/// URI front-end that `URINormalizer` rewrites onto those protocols (thunder,
/// WebDAV, IPFS, S3…). Tasks are mapped to aria2 GIDs; progress and state are
/// polled every second and forwarded to the main-actor delegate.
public final class Aria2Engine: DownloadEngine {
    public let name = "aria2"
    public let supportedProtocols: Set<DownloadProtocol> =
        Set(DownloadProtocol.allCases.filter { $0.transport == .aria2 })
    public weak var delegate: (any EngineDelegate)?

    private let rpc: Aria2RPC
    /// GID ↔ task bindings. Touched from submit/adopt (caller context), the
    /// WebSocket notification handler and the poll loop — all different
    /// concurrency domains — so access is serialized by a lock instead of
    /// racing bare dictionaries across actors.
    private final class GidMap: @unchecked Sendable {
        private let lock = NSLock()
        private var byTask: [UUID: String] = [:]
        private var byGid: [String: UUID] = [:]

        func bind(task: UUID, gid: String) {
            lock.lock(); defer { lock.unlock() }
            if let old = byTask[task] { byGid.removeValue(forKey: old) }
            byTask[task] = gid
            byGid[gid] = task
        }
        func gid(forTask id: UUID) -> String? {
            lock.lock(); defer { lock.unlock() }
            return byTask[id]
        }
        func task(forGid gid: String) -> UUID? {
            lock.lock(); defer { lock.unlock() }
            return byGid[gid]
        }
        func unbind(task: UUID) {
            lock.lock(); defer { lock.unlock() }
            if let gid = byTask.removeValue(forKey: task) { byGid.removeValue(forKey: gid) }
        }
        func snapshot() -> [String: UUID] {
            lock.lock(); defer { lock.unlock() }
            return byGid
        }
    }

    private let gidMap = GidMap()
    private var pollTask: Task<Void, Never>?
    /// WebSocket event listener (aria2.onDownloadComplete / …). Best-effort: the
    /// 1s poll remains the source of truth, this just shortens the latency between a
    /// real event and the UI reflecting it.
    private var wsTask: URLSessionWebSocketTask?
    private var wsLoop: Task<Void, Never>?

    public init(endpoint: URL, secret: String = "") {
        self.rpc = Aria2RPC(endpoint: endpoint, secret: secret)
    }

    public func canHandle(_ p: DownloadProtocol) -> Bool { supportedProtocols.contains(p) }

    /// Begin the polling loop and the WebSocket event listener. Call once after
    /// aria2 is bootstrapped. Polling is adaptive: 1s while any tracked download is
    /// active (progress needs polling — aria2 pushes no progress notifications),
    /// 3s idle backoff otherwise; real state changes still arrive instantly via WS.
    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let active = await self?.poll() ?? false
                try? await Task.sleep(nanoseconds: active ? 1_000_000_000 : 3_000_000_000)
            }
        }
        startWebSocket()
    }

    public func suspendPolling() {
        pollTask?.cancel()
        pollTask = nil
        stopWebSocket()
    }

    // MARK: - WebSocket event notifications (aria2 1.34+)

    /// Open a WebSocket to aria2 and stream event notifications. The loop
    /// auto-reconnects (with a 1s backoff) until `suspendPolling()` cancels it.
    private func startWebSocket() {
        wsLoop?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        let url = Aria2Bootstrap.shared.wsURL
        wsLoop = Task { [weak self] in
            while !Task.isCancelled {
                let task = URLSession.shared.webSocketTask(with: url)
                self?.wsTask = task
                task.resume()
                var alive = true
                while !Task.isCancelled, alive {
                    do {
                        let msg = try await task.receive()
                        switch msg {
                        case .string(let s): self?.handleNotification(s)
                        case .data(let d):
                            if let s = String(data: d, encoding: .utf8) { self?.handleNotification(s) }
                        @unknown default: break
                        }
                    } catch {
                        alive = false
                    }
                }
                task.cancel(with: .goingAway, reason: nil)
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopWebSocket() {
        wsLoop?.cancel()
        wsLoop = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    /// aria2 pushes `{"method":"aria2.onDownloadComplete","params":[gid,…]}` style
    /// notifications. We only use them as a trigger to refresh immediately so the
    /// state change is visible without waiting for the next poll.
    private func handleNotification(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String,
              method.hasPrefix("aria2.on"),
              let params = obj["params"] as? [Any],
              let gid = params.first as? String,
              gidMap.task(forGid: gid) != nil else { return }
        Task { _ = await self.poll() }
    }

    public func submit(_ task: DownloadTask) async throws {
        let opts = Self.makeOptions(task)
        let uri = Self.sanitize(task.source.absoluteString)
        let gid: String
        if task.source.isFileURL {
            // Local .torrent / .metalink documents must go through their dedicated
            // RPC methods; aria2.addUri does not accept a file:// pointer to them.
            switch task.source.pathExtension.lowercased() {
            case "torrent":
                gid = try await rpc.addTorrent(Data(contentsOf: task.source), options: opts)
            case "metalink", "meta4":
                gid = try await rpc.addMetalink(Data(contentsOf: task.source), options: opts)
            default:
                gid = try await rpc.addUri(uri, options: opts)
            }
        } else {
            gid = try await rpc.addUri(uri, options: opts)
        }
        gidMap.bind(task: task.id, gid: gid)
    }

    /// After a relaunch, aria2 reloaded its session file (`--input-file`): the
    /// GIDs of previously incomplete downloads are live again. Bind them back to
    /// Siphon tasks by source URI and force-pause everything — restored tasks are
    /// `.paused`, so nothing may download until the user explicitly resumes.
    ///
    /// Returns the adopted task IDs; the caller marks them as submitted so
    /// `schedule()` resumes the bound GID instead of re-adding the download.
    /// Session GIDs with no matching task (e.g. the task was removed while the
    /// app was closed) stay paused in aria2 — invisible but harmless, and they
    /// keep their place in the session file.
    @discardableResult
    public func adoptPersistedSessions(_ sourcesByTask: [UUID: String]) async -> Set<UUID> {
        try? await rpc.forcePauseAll()
        // forcePauseAll can race a lazily-loaded (--deferred-input) session entry:
        // it starts after the sweep ran. Keep sweeping until aria2 reports nothing
        // active (bounded, so a legitimately active download can't spin forever).
        for _ in 0..<10 {
            guard let active = try? await rpc.tellActive(), !active.isEmpty else { break }
            try? await rpc.forcePauseAll()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var statuses: [[String: Any]] = []
        statuses += (try? await rpc.tellActive()) ?? []
        statuses += (try? await rpc.tellWaiting()) ?? []
        statuses += (try? await rpc.tellStopped()) ?? []
        var adopted: Set<UUID> = []
        for s in statuses {
            guard let gid = s["gid"] as? String else { continue }
            // HTTP-style entries carry the submitted URI on the first file; BT
            // entries expose only their infohash, so magnets match through that.
            let uri = ((s["files"] as? [[String: Any]])?.first?["uris"]
                as? [[String: Any]])?.first?["uri"] as? String ?? ""
            let hash = (s["infoHash"] as? String)?.lowercased()
            guard let taskID = sourcesByTask.first(where: {
                $0.value == uri || (hash != nil && hash == Self.btih(of: $0.value))
            })?.key else { continue }
            gidMap.bind(task: taskID, gid: gid)
            adopted.insert(taskID)
        }
        return adopted
    }

    /// Lowercase hex infohash of a magnet link (`urn:btih:<40 hex>`), nil otherwise.
    static func btih(of uri: String) -> String? {
        guard let range = uri.range(of: "urn:btih:") else { return nil }
        let hex = uri[range.upperBound...].prefix(while: \.isHexDigit).lowercased()
        return hex.count == 40 ? hex : nil
    }

    /// Translate UI-style header keys into aria2's documented option names.
    /// Pure function so the mapping is unit-testable without a running daemon.
    public static func makeOptions(_ task: DownloadTask) -> [String: String] {
        var opts = task.options
        for (k, v) in task.options {
            let lower = k.lowercased()
            if ["user-agent", "referer", "cookie"].contains(lower) {
                opts.removeValue(forKey: k)
                opts[lower] = v
            }
        }
        // CRLF injection guard: option values land inside aria2's config surface
        // (and header values are echoed into requests). Control characters must
        // never travel with them (Motrix aria2-config-builder lesson).
        for (k, v) in opts { opts[k] = sanitize(v) }
        opts["dir"] = task.destination.deletingLastPathComponent().path
        if !task.destination.lastPathComponent.isEmpty {
            opts["out"] = sanitize(task.destination.lastPathComponent)
        }
        return opts
    }

    /// Strip control characters (everything below U+0020 except space).
    public static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value > 0x1F || $0 == " " })
    }

    public func pause(_ id: UUID) async {
        guard let gid = gidMap.gid(forTask: id) else { return }
        try? await rpc.pause(gid)
    }

    public func resume(_ id: UUID) async {
        guard let gid = gidMap.gid(forTask: id) else { return }
        try? await rpc.unpause(gid)
    }

    public func remove(_ id: UUID) async {
        guard let gid = gidMap.gid(forTask: id) else { return }
        try? await rpc.forceRemove(gid)
        gidMap.unbind(task: id)
    }

    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {
        // aria2 uses 0 to mean "unlimited".
        try? await rpc.setMaxOverallDownloadLimit(bytesPerSec ?? 0)
    }

    /// Per-task cap via `aria2.changeOption` (`max-download-limit`), keyed off the
    /// task's GID. Folds under the global limit on the aria2 side.
    public func setTaskSpeedLimit(_ id: UUID, bytesPerSec: Int64?) async {
        guard let gid = gidMap.gid(forTask: id) else { return }
        try? await rpc.setPerDownloadLimit(gid, bytesPerSec ?? 0)
    }

    // MARK: - BT file selection

    /// One entry of a multi-file torrent (`aria2.getFiles`).
    public struct BTFile: Sendable, Identifiable, Equatable {
        /// aria2's 1-based file index (the `select-file` key).
        public var index: Int
        public var path: String
        public var length: Int64
        public var selected: Bool
        public var id: Int { index }
        /// Torrent-relative name (last path component of aria2's full path).
        public var displayName: String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    /// Files of a BT task. Empty when the task is not on aria2 or its metadata
    /// has not been resolved yet (magnet still fetching the torrent).
    public func listFiles(taskID: UUID) async -> [BTFile] {
        guard let gid = gidMap.gid(forTask: taskID) else { return [] }
        guard let files = try? await rpc.getFiles(gid) else { return [] }
        return files.compactMap { f in
            guard let index = (f["index"] as? String).flatMap(Int.init) else { return nil }
            return BTFile(index: index,
                          path: f["path"] as? String ?? "",
                          length: Int64(f["length"] as? String ?? "0") ?? 0,
                          selected: f["selected"] as? String == "true")
        }
    }

    /// Apply a file selection via `aria2.changeOption select-file`. Fails (false)
    /// when metadata is not loaded yet or every file is deselected — aria2
    /// rejects an empty selection.
    @discardableResult
    public func selectFiles(taskID: UUID, indexes: [Int]) async -> Bool {
        guard let gid = gidMap.gid(forTask: taskID), !indexes.isEmpty else { return false }
        do {
            try await rpc.changeOption(gid,
                ["select-file": indexes.sorted().map(String.init).joined(separator: ",")])
            return true
        } catch { return false }
    }

    // MARK: - BitTorrent enhancements (Motrix / Gopeed model)

    /// Apply the auto-subscribed public tracker list to this aria2 session.
    public func applyBtTracker(_ trackers: [String]) async {
        try? await rpc.setBtTracker(trackers)
    }

    /// Set the global seeding ratio (0 = unlimited).
    public func applySeedRatio(_ ratio: Double) async {
        try? await rpc.setSeedRatio(ratio)
    }

    /// Set the global seeding duration in minutes (0 = unlimited).
    public func applySeedTime(_ minutes: Int) async {
        try? await rpc.setSeedTime(minutes)
    }

    /// Poll aria2 once and forward updates to the delegate. Returns whether any
    /// tracked download is currently active (drives the adaptive poll cadence).
    @discardableResult
    private func poll() async -> Bool {
        let statuses: [[String: Any]]
        do {
            statuses = try await rpc.tellActive()
                + rpc.tellWaiting()
                + rpc.tellStopped()
        } catch { return false }

        // `submit`/`remove` mutate `gidToTask` on the main actor; this loop runs on a
        // background Task. Snapshot the value-type map so this tick reads a consistent
        // view instead of racing the writer (and never tears mid-iteration).
        let gidToTask = gidMap.snapshot()
        var hasActive = false
        for s in statuses {
            guard let gid = s["gid"] as? String, let taskID = gidToTask[gid] else { continue }
            if s["status"] as? String == "active" { hasActive = true }
            let progress = Self.progress(from: s)
            let state = Self.state(from: s)
            let err = (s["errorMessage"] as? String).flatMap { $0.isEmpty ? nil : Aria2Error.rpcFailure($0) }
            await delegate?.engineDidUpdate(taskID: taskID, progress: progress)
            await delegate?.engineDidChangeState(taskID: taskID, state: state, error: err)
        }
        return hasActive
    }

    private static func progress(from s: [String: Any]) -> DownloadProgress {
        var p = DownloadProgress()
        p.totalBytes = Int64(s["totalLength"] as? String ?? "0") ?? 0
        p.downloadedBytes = Int64(s["completedLength"] as? String ?? "0") ?? 0
        p.speedBytesPerSec = Int64(s["downloadSpeed"] as? String ?? "0") ?? 0
        p.connectedPeers = (s["connections"] as? String).flatMap(Int.init)
            ?? (s["numSeeders"] as? String).flatMap(Int.init) ?? 0
        return p
    }

    private static func state(from s: [String: Any]) -> DownloadState {
        switch s["status"] as? String {
        case "active":   return .active
        case "waiting":  return .pending
        case "paused":   return .paused
        case "complete": return .completed
        case "error":    return .error
        case "removed":  return .removed
        default:         return .active
        }
    }
}
