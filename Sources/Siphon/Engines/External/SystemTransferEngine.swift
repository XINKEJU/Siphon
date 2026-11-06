import Foundation

/// Bridges SSH-family and macOS network-filesystem protocols using tools Apple
/// already ships: `/usr/bin/scp`, `/usr/bin/rsync`, `/sbin/mount_nfs`,
/// `/sbin/mount_afp`, `/sbin/umount`.
///
/// SFTP itself is handled by aria2 (which is built with libssh2); SCP and rsync
/// are not part of aria2's URI grammar, and NFS/AFP have no userspace client in
/// libcurl, so they need this bridge.
public final class SystemTransferEngine: DownloadEngine {
    public let name = "system"
    public let supportedProtocols: Set<DownloadProtocol> = [.scp, .rsync, .nfs, .afp]
    public weak var delegate: (any EngineDelegate)?

    private var runners: [UUID: ExternalRunner] = [:]
    private var tasks: [UUID: DownloadTask] = [:]
    private var limit: Int64?

    public init() {}
    public func canHandle(_ p: DownloadProtocol) -> Bool { supportedProtocols.contains(p) }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async { limit = bytesPerSec }

    public func submit(_ task: DownloadTask) async throws {
        tasks[task.id] = task
        switch task.protocol {
        case .nfs, .afp: try await mountAndCopy(task)
        default: try launchSSH(task)
        }
    }

    public func pause(_ id: UUID) async { runners[id]?.cancel() }

    public func resume(_ id: UUID) async {
        guard let task = tasks[id] else { return }
        switch task.protocol {
        case .nfs, .afp:
            do { try await mountAndCopy(task) } catch {
                await fail(task.id, error)
            }
        default:
            do { try launchSSH(task) } catch { await fail(task.id, error) }
        }
    }

    public func remove(_ id: UUID) async {
        runners.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)
    }

    // MARK: - scp / rsync
    private func launchSSH(_ task: DownloadTask) throws {
        runners[task.id]?.cancel()
        try? FileManager.default.createDirectory(
            at: task.destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let url = task.source
        let isRsync = task.protocol == .rsync
        let remote = remoteSpecifier(url)
        let executable = URL(fileURLWithPath: isRsync ? "/usr/bin/rsync" : "/usr/bin/scp")
        var args: [String]
        if isRsync {
            args = ["-q", "--partial", "--protect-args"]
            if let limit, limit > 0 { args += ["--bwlimit", String(max(1, limit / 1024))] }
            args += [remote, task.destination.path]
        } else {
            args = ["-q", "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=15"]
            if let port = url.port { args += ["-P", String(port)] }
            if let limit, limit > 0 { args += ["-l", String(max(1, limit / 1024 * 8))] }
            args += [remote, task.destination.path]
        }

        let runner = ExternalRunner(executable: executable, arguments: args,
                                    destination: task.destination) { [weak self] bytes in
            guard let self else { return }
            Task { @MainActor in
                var p = DownloadProgress()
                p.downloadedBytes = bytes
                self.delegate?.engineDidUpdate(taskID: task.id, progress: p)
            }
        }
        try runner.start()
        runners[task.id] = runner
        Task { [weak self] in
            guard let self else { return }
            let outcome = await runner.wait()
            await self.finish(task: task, outcome: outcome)
        }
    }

    /// `scp://user@host:2222/path` → `user@host:/path`; `rsync://host/path` → `host:/path`.
    private func remoteSpecifier(_ url: URL) -> String {
        var host = url.host ?? ""
        if let user = url.user { host = "\(user)@\(host)" }
        let path = url.path.isEmpty ? "/" : url.path
        return "\(host):\(path)"
    }

    // MARK: - NFS / AFP mount bridge
    private func mountAndCopy(_ task: DownloadTask) async throws {
        let fm = FileManager.default
        let mountPoint = fm.temporaryDirectory
            .appendingPathComponent("Siphon-Mount-\(task.id.uuidString)", isDirectory: true)
        try? fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let url = task.source
        let isNFS = task.protocol == .nfs
        let executable = URL(fileURLWithPath: isNFS ? "/sbin/mount_nfs" : "/sbin/mount_afp")
        let spec: String
        if isNFS {
            let host = url.host ?? ""
            spec = "\(host):\(url.path.isEmpty ? "/" : url.path)"
        } else {
            // mount_afp wants the original afp:// URL (including credentials).
            spec = url.absoluteString
        }
        let args = (isNFS ? ["-o", "ro", spec] : [spec]) + [mountPoint.path]

        let mountRunner = ExternalRunner(executable: executable, arguments: args,
                                         destination: nil)
        try mountRunner.start()
        runners[task.id] = mountRunner
        let outcome = await mountRunner.wait()
        runners.removeValue(forKey: task.id)
        guard outcome.exitCode == 0 else {
            try? fm.removeItem(at: mountPoint)
            throw ExternalRunnerError.transferFailed(
                "mount 失败（需要本机挂载权限）：\(outcome.stderr)")
        }

        do {
            let wanted = url.lastPathComponent
            let candidate = mountPoint.appendingPathComponent(wanted)
            let source: URL
            if fm.fileExists(atPath: candidate.path) {
                source = candidate
            } else {
                let entries = (try? fm.contentsOfDirectory(at: mountPoint,
                        includingPropertiesForKeys: nil)) ?? []
                guard let first = entries.first else {
                    throw ExternalRunnerError.transferFailed("挂载点为空")
                }
                source = first
            }
            try? fm.createDirectory(at: task.destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: task.destination)
            try fm.copyItem(at: source, to: task.destination)
            try? await unmount(mountPoint)
            let attrs = try? fm.attributesOfItem(atPath: task.destination.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            var p = DownloadProgress(); p.totalBytes = size; p.downloadedBytes = size
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
            await delegate?.engineDidChangeState(taskID: task.id, state: .completed, error: nil)
        } catch {
            try? await unmount(mountPoint)
            await fail(task.id, error)
        }
    }

    private func unmount(_ point: URL) async throws {
        let runner = ExternalRunner(
            executable: URL(fileURLWithPath: "/sbin/umount"),
            arguments: [point.path], destination: nil)
        try? runner.start()
        _ = await runner.wait()
        try? FileManager.default.removeItem(at: point)
    }

    // MARK: - state
    @MainActor
    private func finish(task: DownloadTask, outcome: ExternalRunner.Outcome) {
        runners.removeValue(forKey: task.id)
        if outcome.wasCancelled {
            delegate?.engineDidChangeState(taskID: task.id, state: .paused, error: nil)
            return
        }
        guard outcome.exitCode == 0 else {
            delegate?.engineDidChangeState(taskID: task.id, state: .error,
                error: ExternalRunnerError.transferFailed(
                    outcome.stderr.isEmpty ? "exit=\(outcome.exitCode)" : outcome.stderr))
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: task.destination.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var p = DownloadProgress(); p.totalBytes = size; p.downloadedBytes = size
        delegate?.engineDidUpdate(taskID: task.id, progress: p)
        delegate?.engineDidChangeState(taskID: task.id, state: .completed, error: nil)
    }

    private func fail(_ id: UUID, _ error: Error) async {
        await delegate?.engineDidChangeState(taskID: id, state: .error, error: error)
    }
}
