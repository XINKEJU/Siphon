import Foundation

/// yt-dlp 下载引擎（借鉴 HyperDM `ytdlp_downloader.py`）：
///  * 直接调用 yt-dlp 下载页面地址，`-f` 选择画质，音视频分离时由 ffmpeg 合并；
///  * `--concurrent-fragments 8` 加速 HLS/DASH 分片；
///  * `--newline --progress-template` 输出结构化进度，解析后喂给 UI；
///  * 暂停/续传使用 `--continue`，已下载分片不重来。
///
/// 该引擎不参与协议路由：仅在任务带 `ytdlp` 标记时由 `DownloadStore` 直接投递。
public final class YtDlpEngine: DownloadEngine {
    public let name = "yt-dlp"
    /// 不注册到协议表：由 store 依据 `task.ytdlp` 显式投递。
    public let supportedProtocols: Set<DownloadProtocol> = []
    public weak var delegate: (any EngineDelegate)?

    private var runners: [UUID: ExternalRunner] = [:]
    private var tasks: [UUID: DownloadTask] = [:]
    private var lastEmit: [UUID: Date] = [:]

    private static let progressPrefix = "SIPHONPROG:"

    public init() {}

    public func canHandle(_ p: DownloadProtocol) -> Bool { false }
    public func segmentSnapshot(for id: UUID) -> [SegmentSnapshot] { [] }
    /// yt-dlp 自带的限速参数需要重启进程，暂不参与全局限速。
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {}

    public func submit(_ task: DownloadTask) async throws {
        guard YtDlpResolver.binaryPath() != nil else {
            throw YtDlpResolver.ResolverError.unavailable
        }
        tasks[task.id] = task
        launch(task, resume: false)
    }

    public func pause(_ id: UUID) async {
        runners[id]?.cancel()
    }

    public func resume(_ id: UUID) async {
        guard let task = tasks[id] else { return }
        // 旧进程完全退出后再启动，避免两个 yt-dlp 同时写同一个目标。
        if let old = runners[id] {
            old.cancel()
            _ = await old.wait()
        }
        launch(task, resume: true)
    }

    public func remove(_ id: UUID) async {
        runners.removeValue(forKey: id)?.cancel()
        if let task = tasks.removeValue(forKey: id) {
            let fm = FileManager.default
            // 未完成的中间文件；已完成文件保持“移除任务不删文件”的语义。
            try? fm.removeItem(at: task.destination)
            try? fm.removeItem(atPath: task.destination.path + ".part")
        }
        lastEmit.removeValue(forKey: id)
    }

    // MARK: - process

    private func launch(_ task: DownloadTask, resume: Bool) {
        runners[task.id]?.cancel()
        guard let bin = YtDlpResolver.binaryPath() else {
            Task { @MainActor in
                self.delegate?.engineDidChangeState(
                    taskID: task.id, state: .error,
                    error: YtDlpResolver.ResolverError.unavailable)
            }
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: task.destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        let ext = task.destination.pathExtension.lowercased()
        let mergeFormat = ["mp4", "mkv", "webm", "mov"].contains(ext) ? ext : "mkv"

        var args: [String] = [
            "--no-warnings", "--newline", "--no-playlist",
            "--concurrent-fragments", "8",
            "--progress",
            "--progress-template",
            "\(Self.progressPrefix)%(progress.downloaded_bytes)s|"
                + "%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|"
                + "%(progress.speed)s",
            "-f", task.ytdlpFormat ?? YtDlpResolver.Quality.auto.selector,
            "--merge-output-format", mergeFormat,
            "-o", task.destination.path
        ]
        if resume || fm.fileExists(atPath: task.destination.path) {
            args.append("--continue")
        }
        if let ffmpeg = Self.ffmpegPath() {
            args += ["--ffmpeg-location", ffmpeg]
        }
        for (k, v) in task.options where !["dir", "out"].contains(k.lowercased()) {
            args += ["--add-header", "\(k): \(v)"]
        }
        args.append(task.source.absoluteString)

        let runner = ExternalRunner(
            executable: URL(fileURLWithPath: bin),
            arguments: args,
            destination: task.destination,
            onBytes: { [weak self] bytes in
                guard let self else { return }
                Task { @MainActor in
                    guard let p = self.currentProgress(taskID: task.id, bytes: bytes) else { return }
                    self.delegate?.engineDidUpdate(taskID: task.id, progress: p)
                }
            },
            onOutput: { [weak self] text in
                guard let self else { return }
                Task { @MainActor in
                    guard let p = Self.parseProgress(text) else { return }
                    self.delegate?.engineDidUpdate(taskID: task.id, progress: p)
                }
            })
        do {
            try runner.start()
            runners[task.id] = runner
        } catch {
            Task { @MainActor in
                self.delegate?.engineDidChangeState(taskID: task.id, state: .error,
                                                    error: error)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await runner.wait()
            await self.finish(task: task, runner: runner, outcome: outcome)
        }
    }

    @MainActor
    private func finish(task: DownloadTask, runner: ExternalRunner,
                        outcome: ExternalRunner.Outcome) {
        // 续传/限速会替换 runner；旧的退出回调不能再改新进程的状态。
        guard runners[task.id] === runner else { return }
        runners.removeValue(forKey: task.id)
        lastEmit.removeValue(forKey: task.id)
        if outcome.wasCancelled {
            delegate?.engineDidChangeState(taskID: task.id, state: .paused, error: nil)
            return
        }
        guard outcome.exitCode == 0 else {
            let msg = outcome.stderr.isEmpty
                ? "yt-dlp 退出码 \(outcome.exitCode)" : String(outcome.stderr.suffix(400))
            delegate?.engineDidChangeState(taskID: task.id, state: .error,
                                           error: YtDlpResolver.ResolverError.resolveFailed(msg))
            return
        }
        let size = fileSize(task.destination)
        guard size > 0 else {
            let msg = outcome.stderr.isEmpty
                ? "yt-dlp 已退出，但目标文件不存在"
                : String(outcome.stderr.suffix(400))
            delegate?.engineDidChangeState(taskID: task.id, state: .error,
                                           error: YtDlpResolver.ResolverError.resolveFailed(msg))
            return
        }
        var p = DownloadProgress()
        p.downloadedBytes = size
        p.totalBytes = size
        delegate?.engineDidUpdate(taskID: task.id, progress: p)
        delegate?.engineDidChangeState(taskID: task.id, state: .completed, error: nil)
        // 完成后不再持有任务：之后“移除任务”不会误删已完成文件。
        tasks.removeValue(forKey: task.id)
    }

    // MARK: - progress

    @MainActor
    private func currentProgress(taskID: UUID, bytes: Int64) -> DownloadProgress? {
        // 目标文件尺寸回调与结构化进度可能同时到达；节流到 ~2 Hz。
        if let last = lastEmit[taskID], Date().timeIntervalSince(last) < 0.5 { return nil }
        lastEmit[taskID] = Date()
        var p = DownloadProgress()
        p.downloadedBytes = bytes
        return p
    }

    /// 解析 `SIPHONPROG:downloaded|total|estimate|speed` 这一行。
    static func parseProgress(_ text: String) -> DownloadProgress? {
        // yt-dlp 可能给模板行加 `[download] ` 前缀，所以在整行里查找标记。
        guard let line = text.split(whereSeparator: \.isNewline)
            .last(where: { $0.contains(progressPrefix) }),
              let mark = line.range(of: progressPrefix) else { return nil }
        let fields = line[mark.upperBound...].split(separator: "|")
        guard fields.count >= 3 else { return nil }
        func number(_ i: Int) -> Int64 {
            guard i < fields.count else { return 0 }
            let raw = fields[i].trimmingCharacters(in: .whitespaces)
            if raw == "NA" || raw.isEmpty { return 0 }
            return Int64(Double(raw) ?? 0)
        }
        var p = DownloadProgress()
        p.downloadedBytes = max(0, number(0))
        p.totalBytes = max(0, max(number(1), number(2)))
        p.speedBytesPerSec = max(0, number(3))
        guard p.downloadedBytes > 0 || p.totalBytes > 0 else { return nil }
        return p
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? NSNumber)?.int64Value ?? 0
    }

    static func ffmpegPath() -> String? {
        if let p = ProcessInfo.processInfo.environment["SIPHON_FFMPEG_PATH"],
           FileManager.default.isExecutableFile(atPath: p) { return p }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                          "/usr/bin/ffmpeg", "/opt/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        guard let which = try? Process.runAndCollect("/usr/bin/which", ["ffmpeg"]) else {
            return nil
        }
        let path = which.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
