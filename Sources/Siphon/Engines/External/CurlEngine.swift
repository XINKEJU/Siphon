import Foundation

/// Bridges protocols the bundled aria2 cannot speak but the macOS system libcurl
/// can: FTPS, SMB/SMBS, TFTP, Gopher, RTSP, DICT, IMAP/POP3/SMTP/LDAP (URL fetch),
/// and IPFS/IPNS via `--ipfs-gateway`.
///
/// The system `/usr/bin/curl` is used as a subprocess — no bundled dependency, no
/// extra signature, and it inherits the user's system trust store / Kerberos / keychain.
public final class CurlEngine: DownloadEngine {
    public let name = "curl"
    public let supportedProtocols: Set<DownloadProtocol> =
        [.ftps, .smb, .smbs, .curl]
    public weak var delegate: (any EngineDelegate)?

    private var runners: [UUID: ExternalRunner] = [:]
    private var tasks: [UUID: DownloadTask] = [:]
    private var limit: Int64?
    private var perTaskLimit: [UUID: Int64] = [:]

    public init() {}
    public func canHandle(_ p: DownloadProtocol) -> Bool { supportedProtocols.contains(p) }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async { limit = bytesPerSec }

    /// Hot-updatable per-task cap. curl's `--limit-rate` only takes effect at
    /// process start, so changing it mid-flight relaunches the runner with the
    /// folded value (`min(global, perTask)`).
    public func setTaskSpeedLimit(_ id: UUID, bytesPerSec: Int64?) async {
        perTaskLimit[id] = bytesPerSec
        // Relaunch to apply; `launch` re-reads `effectiveLimit(for:)`.
        if tasks[id] != nil {
            launch(tasks[id]!, resume: true)
        }
    }

    private func effectiveLimit(for id: UUID) -> Int64? {
        let g = limit
        let t = perTaskLimit[id]
        switch (g, t) {
        case (.some(let a), .some(let b)): return min(a, b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        case (.none, .none): return nil
        }
    }

    public func submit(_ task: DownloadTask) async throws {
        tasks[task.id] = task
        launch(task, resume: false)
    }

    public func pause(_ id: UUID) async { runners[id]?.cancel() }

    public func resume(_ id: UUID) async {
        guard let task = tasks[id] else { return }
        launch(task, resume: true)
    }

    public func remove(_ id: UUID) async {
        runners.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)
        perTaskLimit.removeValue(forKey: id)
    }

    private func launch(_ task: DownloadTask, resume: Bool) {
        runners[task.id]?.cancel()
        let fm = FileManager.default
        try? fm.createDirectory(at: task.destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let settings = ProtocolSettings.load()
        let curl = URL(fileURLWithPath: settings.curlPath)

        var args: [String] = [
            "--globoff", "--location", "--fail", "--silent", "--show-error",
            "--no-progress-meter", "--output", task.destination.path,
            "--write-out", "%{size_download}"
        ]
        if resume || (fm.fileExists(atPath: task.destination.path)) {
            args += ["--continue-at", "-"]
        }
        if let eff = effectiveLimit(for: task.id), eff > 0 {
            args += ["--limit-rate", String(eff)]
        }
        for (k, v) in task.options where !["dir", "out"].contains(k.lowercased()) {
            args += ["--header", "\(k): \(v)"]
        }
        args.append(task.source.absoluteString)

        let runner = ExternalRunner(executable: curl, arguments: args,
                                    destination: task.destination) { [weak self] bytes in
            guard let self else { return }
            Task { @MainActor in
                var p = DownloadProgress()
                p.downloadedBytes = bytes
                p.totalBytes = 0
                self.delegate?.engineDidUpdate(taskID: task.id, progress: p)
            }
        }
        do {
            try runner.start()
            runners[task.id] = runner
        } catch {
            Task { @MainActor in
                self.delegate?.engineDidChangeState(taskID: task.id,
                                                    state: .error, error: error)
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await runner.wait()
            await self.finish(task: task, outcome: outcome)
        }
    }

    @MainActor
    private func finish(task: DownloadTask, outcome: ExternalRunner.Outcome) {
        runners.removeValue(forKey: task.id)
        if outcome.wasCancelled {
            delegate?.engineDidChangeState(taskID: task.id, state: .paused, error: nil)
            return
        }
        guard outcome.exitCode == 0 else {
            let msg = outcome.stderr.isEmpty ? "exit=\(outcome.exitCode)" : outcome.stderr
            delegate?.engineDidChangeState(taskID: task.id, state: .error,
                                           error: ExternalRunnerError.transferFailed(msg))
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: task.destination.path)
        let size = Int64(outcome.stdout) ?? (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var p = DownloadProgress()
        p.totalBytes = size
        p.downloadedBytes = size
        delegate?.engineDidUpdate(taskID: task.id, progress: p)
        delegate?.engineDidChangeState(taskID: task.id, state: .completed, error: nil)
    }
}
