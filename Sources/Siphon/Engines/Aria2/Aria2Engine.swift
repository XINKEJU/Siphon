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
    private var taskToGid: [UUID: String] = [:]
    private var gidToTask: [String: UUID] = [:]
    private var pollTask: Task<Void, Never>?

    public init(endpoint: URL) { self.rpc = Aria2RPC(endpoint: endpoint) }

    public func canHandle(_ p: DownloadProtocol) -> Bool { supportedProtocols.contains(p) }

    /// Begin the 1s polling loop. Call once after aria2 is bootstrapped.
    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func suspendPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func submit(_ task: DownloadTask) async throws {
        let opts = Self.makeOptions(task)
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
                gid = try await rpc.addUri(task.source.absoluteString, options: opts)
            }
        } else {
            gid = try await rpc.addUri(task.source.absoluteString, options: opts)
        }
        taskToGid[task.id] = gid
        gidToTask[gid] = task.id
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
        opts["dir"] = task.destination.deletingLastPathComponent().path
        if !task.destination.lastPathComponent.isEmpty {
            opts["out"] = task.destination.lastPathComponent
        }
        return opts
    }

    public func pause(_ id: UUID) async {
        guard let gid = taskToGid[id] else { return }
        try? await rpc.pause(gid)
    }

    public func resume(_ id: UUID) async {
        guard let gid = taskToGid[id] else { return }
        try? await rpc.unpause(gid)
    }

    public func remove(_ id: UUID) async {
        guard let gid = taskToGid[id] else { return }
        try? await rpc.forceRemove(gid)
        taskToGid.removeValue(forKey: id)
        gidToTask.removeValue(forKey: gid)
    }

    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {
        // aria2 uses 0 to mean "unlimited".
        try? await rpc.setMaxOverallDownloadLimit(bytesPerSec ?? 0)
    }

    private func poll() async {
        let statuses: [[String: Any]]
        do {
            statuses = try await rpc.tellActive()
                + rpc.tellWaiting()
                + rpc.tellStopped()
        } catch { return }

        for s in statuses {
            guard let gid = s["gid"] as? String, let taskID = gidToTask[gid] else { continue }
            let progress = Self.progress(from: s)
            let state = Self.state(from: s)
            let err = (s["errorMessage"] as? String).flatMap { $0.isEmpty ? nil : Aria2Error.rpcFailure($0) }
            await delegate?.engineDidUpdate(taskID: taskID, progress: progress)
            await delegate?.engineDidChangeState(taskID: taskID, state: state, error: err)
        }
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
