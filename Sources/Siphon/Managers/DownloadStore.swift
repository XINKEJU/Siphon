import Foundation
import SwiftUI
import Combine

/// Central, main-actor store. Owns the task list, routes each task to the right engine,
/// and funnels engine callbacks into SwiftUI state.
@MainActor
@Observable
public final class DownloadStore: EngineDelegate {
    public var tasks: [DownloadTask] = []
    public var selectedTaskID: UUID?
    public var filter: TaskFilter = .all
    public var aria2Status: String = "未启动"
    /// Prefer this over string-matching `aria2Status`: the human-readable status
    /// text changes, but the readiness flag stays a reliable source of truth.
    public var aria2Ready: Bool = false
    public var startupError: String?
    /// Last link-normalization failure (bad vendor link, missing S3 credentials, …).
    public var lastError: String?
    public var speedLimitText: String = ""
    public var clipboardEnabled = false
    public var browserCaptureEnabled = false
    public var mcpEnabled = false
    /// Per-task speed caps (bytes/s). `nil` / absent = unlimited. Folds under the
    /// global (and turtle) cap: effective = min(global, perTask).
    public var taskSpeedLimits: [UUID: Int64] = [:]
    /// Turtle three-tier mode config (Motrix speed-limit-controller).
    public var turtleConfig: TurtleConfig = {
        if let d = UserDefaults.standard.data(forKey: PrefKey.turtle),
           let c = try? JSONDecoder().decode(TurtleConfig.self, from: d) { return c }
        return TurtleConfig()
    }() {
        didSet {
            if let d = try? JSONEncoder().encode(turtleConfig) {
                UserDefaults.standard.set(d, forKey: PrefKey.turtle)
            }
            applySpeedLimit(speedLimitText) // re-fold global cap
        }
    }
    public var downloadDirectory: URL = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }()

    public let queues = QueueManager()
    public let clipboard = ClipboardMonitor()

    private var engines: [DownloadProtocol: DownloadEngine] = [:]
    private var aria2: Aria2Engine?
    private var nativeMessaging: NativeMessagingServer?
    private var mcpServer: MCPServer?
    /// id→index cache for engineDidUpdate. Progress ticks are high-frequency;
    /// a shifted array (insert/delete) is caught by the id check and rebuilt.
    private var indexByID: [UUID: Int] = [:]
    private let defaultsKey = "Siphon.tasks"
    /// Auto-categorize on when enabled: route the file into a type subfolder.
    private func categorizedDirectory(for fileName: String) -> URL {
        var dir = downloadDirectory
        if UserDefaults.standard.bool(forKey: PrefKey.autoCategorize),
           let sub = AutoCategorizer.subdirectory(for: fileName) {
            dir = dir.appendingPathComponent(sub, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    private enum PrefKey {
        static let clipboard = "Siphon.clipboardEnabled"
        static let browser = "Siphon.browserCaptureEnabled"
        static let mcp = "Siphon.mcpEnabled"
        static let schedule = "Siphon.scheduleWindow"
        static let actionFired = "Siphon.completionActionFired"
        static let autoCategorize = "Siphon.autoCategorize"
        static let ytdlp = "Siphon.ytdlp"
        static let turtle = "Siphon.turtleConfig"
    }
    /// Tasks already handed to an engine. Resuming these must call `resume(id)`,
    /// never `submit(task)` again (that would create a duplicate aria2 GID).
    private var submitted: Set<UUID> = []
    private var didStart = false
    private var isScheduling = false
    private var needsReschedule = false
    private var lastTurtleEffective: Int64?

    /// Rolling aggregate-speed samples for the live sparkline (HyperDM speed_graph).
    public var speedHistory: [Int64] = []
    private var speedTimer: AnyCancellable?
    private let speedHistoryMax = 120

    public enum TaskFilter: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", completed = "已完成", paused = "已暂停"
        public var id: String { rawValue }
    }

    public init() {
        load()
        clipboard.onURLDetected = { [weak self] url in
            Task { @MainActor in self?.handleDetectedURL(url) }
        }
        // RSS subscriptions: new feed entries become download tasks automatically.
        feedManager.onNewItems = { [weak self] feed, items in
            Task { @MainActor in self?.enqueueFeedItems(feed, items) }
        }
    }

    // MARK: - lifecycle
    /// Idempotent: `.task` modifiers can fire more than once, and Settings can request
    /// a restart. Registering engines twice would create duplicate RPC polling loops
    /// and replace live engine instances (losing their in-flight task state).
    public func start() async {
        guard !didStart else { return }
        didStart = true

        let nativeEngines: [any DownloadEngine] = [
            HLSEngine(), DASHEngine(), ED2KEngine(),
            CurlEngine(), SystemTransferEngine(), LocalEngine(),
            HTTPDownloadEngine()
        ]
        for engine in nativeEngines {
            engine.delegate = self
            for p in engine.supportedProtocols { engines[p] = engine }
        }
        await startAria2()
        restoreIntegrations()
        startSchedulerTick()
        startFeedPolling()
        startSpeedTimer()
        // BitTorrent tracker auto-subscription: push merged trackers into aria2 and
        // keep them refreshed (Motrix tracker-manager model).
        TrackerManager.shared.onUpdate = { [weak self] trackers in
            Task { await self?.aria2?.applyBtTracker(trackers) }
        }
        TrackerManager.shared.start()
    }

    /// 1 Hz sample of aggregate throughput for the live sparkline.
    private func startSpeedTimer() {
        guard speedTimer == nil else { return }
        speedTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                var h = self.speedHistory
                h.append(self.aggregateSpeed)
                if h.count > self.speedHistoryMax { h.removeFirst() }
                self.speedHistory = h
            }
    }

    // MARK: - RSS subscriptions
    public let feedManager = FeedManager()
    private var feedRefreshTimer: AnyCancellable?

    /// Refresh feeds now, then poll every 30 min while the app runs.
    private func startFeedPolling() {
        guard feedRefreshTimer == nil else { return }
        feedRefreshTimer = Timer.publish(every: 1800, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.tasks.contains(where: { $0.state == .active }) else { return }
                Task { await self.feedManager.refreshAll() }
            }
        // Seed refresh shortly after launch (deferred so engine startup wins the race).
        Task { try? await Task.sleep(nanoseconds: 10_000_000_000)
            await self.feedManager.refreshAll() }
    }

    /// New feed entries → one task per item, named from the entry title.
    private func enqueueFeedItems(_ feed: FeedManager.Feed, _ items: [FeedItem]) {
        for item in items {
            guard let url = URL(string: item.link), url.scheme != nil else { continue }
            let title = item.title.isEmpty ? url.lastPathComponent : item.title
            let fileName = title.replacingOccurrences(of: "/", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = uniqueDestination(for: fileName, in: categorizedDirectory(for: fileName))
            add(DownloadTask(name: fileName, source: url, destination: destination,
                             queueName: "Default", options: [:],
                             origin: "rss:\(feed.title)", checksum: nil))
        }
    }

    // MARK: - policy state (schedule window / completion action / keep-awake)
    public var scheduleWindow = ScheduleWindow() {
        didSet { UserDefaults.standard.set(
            (try? JSONEncoder().encode(scheduleWindow)) ?? Data(), forKey: PrefKey.schedule) }
    }
    public var completionAction: CompletionAction = {
        CompletionAction(rawValue: UserDefaults.standard.string(
            forKey: "Siphon.completionAction") ?? "") ?? .none
    }() {
        didSet { UserDefaults.standard.set(completionAction.rawValue,
                                           forKey: "Siphon.completionAction") }
    }
    /// Tasks auto-paused by the schedule window; resumed when it reopens.
    private var autoPausedByWindow: Set<UUID> = []
    private var schedulerTimer: AnyCancellable?
    private let keepAwake = KeepAwakeToken()

    /// 15-second tick (HyperDM): enforce the download window and completion actions.
    private func startSchedulerTick() {
        if let d = UserDefaults.standard.data(forKey: PrefKey.schedule),
           let w = try? JSONDecoder().decode(ScheduleWindow.self, from: d) {
            scheduleWindow = w
        }
        schedulerTimer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let window = scheduleWindow
        if window.isValid {
            if window.contains() {
                // Reopen: resume everything we auto-paused.
                let ids = autoPausedByWindow
                autoPausedByWindow.removeAll()
                for id in ids where tasks.first(where: { $0.id == id })?.state == .paused {
                    resume(id)
                }
            } else {
                for t in tasks where t.state == .active {
                    autoPausedByWindow.insert(t.id)
                    pause(t.id)
                }
            }
        }
        // Keep-awake while anything is active (ABD KeepAwakeManager).
        if tasks.contains(where: { $0.state == .active }) { keepAwake.begin() }
        else { keepAwake.end() }
        // Turtle `.auto`: re-fold the global cap when the quiet-hours window flips,
        // so daytime traffic is released and night traffic re-throttled without a
        // manual toggle.
        if turtleConfig.mode == .auto,
           turtleConfig.effectiveLimit() != lastTurtleEffective {
            lastTurtleEffective = turtleConfig.effectiveLimit()
            applyEffectiveGlobalLimit()
        }
        // Completion action: everything terminal → run the configured action once.
        if completionAction != .none,
           !tasks.isEmpty,
           !tasks.contains(where: { $0.state == .active || $0.state == .pending }),
           UserDefaults.standard.object(forKey: PrefKey.actionFired) == nil {
            UserDefaults.standard.set(true, forKey: PrefKey.actionFired)
            let action = completionAction
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000) // engine teardown grace
                action.run()
            }
        }
    }

    public func resetCompletionLatch() {
        UserDefaults.standard.removeObject(forKey: PrefKey.actionFired)
    }

    /// Integration switches are user preferences, so they must survive relaunch.
    /// Restore through the same setters used by Settings to avoid a second
    /// listener/server instance getting out of sync with the published state.
    private func restoreIntegrations() {
        let d = UserDefaults.standard
        if d.bool(forKey: PrefKey.browser) { setBrowserCaptureEnabled(true) }
        if d.bool(forKey: PrefKey.clipboard) { setClipboardEnabled(true) }
        if d.bool(forKey: PrefKey.mcp) { setMCPEnabled(true) }
    }

    public func restartAria2() async {
        Aria2Bootstrap.shared.stop()
        await startAria2()
    }

    private func startAria2() async {
        aria2Ready = false
        do {
            try await Aria2Bootstrap.shared.start()
            let engine = Aria2Engine(endpoint: Aria2Bootstrap.shared.rpcURL,
                                     secret: Aria2Bootstrap.shared.rpcSecret)
            engine.delegate = self
            engine.startPolling()
            aria2 = engine
            // aria2 handles only the P2P family (BT / Magnet / Metalink / SFTP);
            // every other protocol is owned by the native / curl / system engines.
            for p in engine.supportedProtocols { engines[p] = engine }
            aria2Status = "已连接 aria2（用于 BT/Magnet/Metalink/SFTP）"
            aria2Ready = true
            startupError = nil
            // aria2 reloaded its session file (--input-file): re-bind the persisted
            // GIDs to the restored tasks and keep them paused until the user resumes.
            let sourcesByTask = Dictionary(tasks.map { ($0.id, $0.source.absoluteString) },
                                           uniquingKeysWith: { a, _ in a })
            let adopted = await engine.adoptPersistedSessions(sourcesByTask)
            submitted.formUnion(adopted)
            // Apply persisted seeding preferences (0 = unlimited) once aria2 is up.
            let ratio = UserDefaults.standard.double(forKey: "Siphon.seedRatio")
            let time = UserDefaults.standard.integer(forKey: "Siphon.seedTime")
            Task { await self.aria2?.applySeedRatio(ratio); await self.aria2?.applySeedTime(time) }
        } catch {
            aria2Status = "aria2 不可用（应用未正确打包 aria2c，BT/Magnet/Metalink/SFTP 暂不可用）"
            aria2Ready = false
            startupError = error.localizedDescription
        }
    }

    public func stop() {
        Aria2Bootstrap.shared.stop()
        aria2?.suspendPolling()
        aria2Ready = false
        aria2Status = "已停止"
        didStart = false   // allow a clean re-start if the window reappears
    }

    // MARK: - CRUD
    public func add(urlString: String, name: String? = nil, queueName: String = "Default",
                    options: [String: String] = [:], checksum: String? = nil,
                    mirrors: [String] = []) {
        Task {
            await addNormalized(urlString: urlString, name: name,
                                queueName: queueName, options: options, checksum: checksum,
                                mirrors: mirrors)
        }
    }

    /// Resolve vendor links / gateways / playlists, then enqueue one task per URL.
    /// Kept `async` because a playlist or gateway may require a network read.
    public func addNormalized(urlString: String, name: String? = nil,
                              queueName: String = "Default",
                              options: [String: String] = [:],
                              checksum: String? = nil,
                              mirrors: [String] = []) async {
        let mirrorURLs = mirrors.compactMap { URL(string: $0) }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // JS plugin rewrite (PluginHost): a matching plugin may turn the URL
        // into a direct download URL and attach headers. Pure URL rewriting —
        // no network access inside the sandbox.
        if let resolved = PluginHost.shared.resolve(urlString: trimmed, headers: options) {
            var opts = options
            for (k, v) in resolved.headers { opts[k] = v }
            let fileName = resolved.name ?? name
                ?? URL(string: trimmed)?.lastPathComponent
            ?? "download"
            let destination = uniqueDestination(for: fileName, in: categorizedDirectory(for: fileName))
            add(DownloadTask(name: fileName, source: resolved.url,
                             destination: destination, queueName: queueName,
                             options: opts, origin: "plugin", checksum: checksum))
            lastError = nil
            return
        }
        // yt-dlp video-site resolution (opt-in; silent fallback when the binary
        // is absent or the site is unknown). Resolved streams go through the
        // native HTTP engine like any other URL.
        if UserDefaults.standard.bool(forKey: PrefKey.ytdlp),
           let u = URL(string: trimmed), YtDlpResolver.isSupported(u),
           YtDlpResolver.available() {
            do {
                let medias = try await YtDlpResolver.resolve(trimmed)
                enqueueMedias(medias, queueName: queueName, options: options,
                              checksum: checksum, customName: name)
                lastError = nil
                return
            } catch {
                // Resolution is best-effort: fall through to the normal path.
                lastError = error.localizedDescription
            }
        }
        do {
            let reqs = try await URINormalizer.normalize(trimmed, options: options)
            for req in reqs {
                // A custom name only makes sense for a single-file submission.
                let fileName: String
                if reqs.count == 1, let name, !name.isEmpty { fileName = name }
                else if let n = req.suggestedName, !n.isEmpty { fileName = n }
                else if req.proto == .data { fileName = "data.bin" }
                else {
                    let probe = DownloadTask(source: req.url,
                                             destination: downloadDirectory,
                                             protoOverride: req.proto)
                    fileName = probe.name
                }
                let destination = uniqueDestination(for: fileName,
                                                    in: categorizedDirectory(for: fileName))
                let task = DownloadTask(name: fileName, source: req.url,
                                        destination: destination,
                                        queueName: queueName, options: req.options,
                                        origin: req.origin,
                                        checksum: checksum ?? req.checksum,
                                        mirrors: req.mirrors.isEmpty
                                            ? (reqs.count == 1 ? mirrorURLs : [])
                                            : req.mirrors,
                                        pieceHashes: req.pieceHashes,
                                        pieceLength: req.pieceLength,
                                        protoOverride: req.proto)
                add(task)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Enqueue yt-dlp–resolved media entries. The title (sanitized) becomes the
    /// file name, with the container extension when known.
    private func enqueueMedias(_ medias: [YtDlpResolver.Media], queueName: String,
                               options: [String: String], checksum: String?,
                               customName: String?) {
        for (index, media) in medias.enumerated() {
            let sanitizedTitle = media.title
                .replacingOccurrences(of: "/", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var fileName = sanitizedTitle.isEmpty ? "video-\(index + 1)" : sanitizedTitle
            if let ext = media.ext, !ext.isEmpty, !fileName.hasSuffix(".\(ext)") {
                fileName += ".\(ext)"
            }
            if medias.count == 1, let customName, !customName.isEmpty {
                fileName = customName
            }
            let destination = uniqueDestination(for: fileName, in: categorizedDirectory(for: fileName))
            guard let src = URL(string: media.url) else { continue }
            let task = DownloadTask(name: fileName,
                                    source: src,
                                    destination: destination,
                                    queueName: queueName, options: options,
                                    origin: "yt-dlp", checksum: checksum,
                                    protoOverride: .https)
            add(task)
        }
    }

    public func add(_ task: DownloadTask) {
        tasks.append(task)
        save()
        resetCompletionLatch() // a fresh task re-arms the completion action
        Task { await schedule() }
    }

    /// Duplicate-name dedup (ABD's numberedIfExists): if the destination already
    /// exists — on disk or in the task list — append " (n)" until unique.
    private func uniqueDestination(for fileName: String, in dir: URL? = nil) -> URL {
        let base = dir ?? downloadDirectory
        let taken = Set(tasks.map { $0.destination.lastPathComponent })
        var candidate = fileName
        var n = 1
        while taken.contains(candidate)
                || FileManager.default.fileExists(atPath: base.appendingPathComponent(candidate).path) {
            let ext = (candidate as NSString).pathExtension
            let baseName = (candidate as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(baseName) (\(n))" : "\(baseName) (\(n)).\(ext)"
            n += 1
        }
        return base.appendingPathComponent(candidate)
    }

    public func pause(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].state = .paused
        save()
        Task { await engines[tasks[i].protocol]?.pause(id) }
    }

    public func resume(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].state = .pending
        save()
        Task { await schedule() }
    }

    public func remove(_ id: UUID) {
        if let t = tasks.first(where: { $0.id == id }) {
            Task { await engines[t.protocol]?.remove(id) }
        }
        submitted.remove(id)
        taskSpeedLimits.removeValue(forKey: id)
        tasks.removeAll { $0.id == id }
        save()
    }

    public func removeCompleted() {
        for t in tasks where t.state == .completed { remove(t.id) }
    }

    // MARK: - scheduling
    /// Start pending tasks up to available slots (queue-aware). A task that was already
    /// submitted is *resumed*, never re-submitted. Re-entrant calls (engine callbacks
    /// arrive while we are awaiting `submit`) are coalesced into one follow-up pass.
    private func schedule() async {
        if isScheduling { needsReschedule = true; return }
        isScheduling = true
        defer {
            isScheduling = false
            if needsReschedule {
                needsReschedule = false
                Task { await self.schedule() }
            }
        }

        let slots = max(0, queues.globalConcurrent - tasks.filter { $0.state == .active }.count)
        let ids = queues.nextToStart(from: tasks, slots: slots)
        for id in ids {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { continue }
            let task = tasks[i]
            guard let engine = engines[task.protocol] else {
                tasks[i].state = .error
                tasks[i].errorDescription = "没有可处理 \(task.protocol.displayName) 的引擎"
                continue
            }
            do {
                if submitted.contains(id) {
                    await engine.resume(id)
                } else {
                    try await engine.submit(task)
                    submitted.insert(id)
                }
                // Re-apply any saved per-task cap (survives pause/resume/relaunch).
                if let cap = taskSpeedLimits[id] {
                    await engine.setTaskSpeedLimit(id, bytesPerSec: cap)
                }
                tasks[i].state = .active
            } catch {
                tasks[i].state = .error
                tasks[i].errorDescription = error.localizedDescription
            }
        }
        save()
    }

    // MARK: - EngineDelegate
    public func engineDidUpdate(taskID: UUID, progress: DownloadProgress) {
        let i: Int?
        if let cached = indexByID[taskID], cached < tasks.count, tasks[cached].id == taskID {
            i = cached
        } else {
            i = tasks.firstIndex(where: { $0.id == taskID })
            indexByID = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($1.id, $0) })
        }
        guard let i else { return }
        tasks[i].progress = progress
    }

    public func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        // Aria2's poll() reports the current state every tick; skip the per-second
        // reschedule + full JSON re-encode when nothing actually changed.
        guard tasks[i].state != state else {
            if let error { tasks[i].errorDescription = error.localizedDescription }
            return
        }
        tasks[i].state = state
        if let error { tasks[i].errorDescription = error.localizedDescription }
        if state == .completed {
            // Flag the finished file as an internet download so Gatekeeper applies its
            // first-launch checks (FluxDown mark_of_the_web).
            markDownloadQuarantine(tasks[i].destination)
            // Auto-extract archives and run any post-processing command (HyperDM model).
            ArchiveManager.shared.handleCompletion(of: tasks[i].destination)
        }
        if state.isTerminal { save() }
        // Task-event webhook: fire on every terminal transition (FluxDown model).
        if state == .completed || state == .error || state == .removed {
            let t = tasks[i]
            WebhookManager.shared.deliver(task: .init(
                id: t.id, name: t.name, url: t.source.absoluteString,
                state: state.rawValue,
                downloadedBytes: t.progress.downloadedBytes,
                totalBytes: t.progress.totalBytes,
                error: t.errorDescription))
        }
        Task { await schedule() }
    }

    // MARK: - BT file selection
    /// Files of a multi-file torrent (empty when the task is not on aria2 or the
    /// magnet's metadata has not been resolved yet).
    public func btFiles(for id: UUID) async -> [Aria2Engine.BTFile] {
        await aria2?.listFiles(taskID: id) ?? []
    }

    /// Apply the checked file set via aria2's `select-file`. Returns false when
    /// the selection is empty or aria2 rejected it (metadata not loaded yet).
    public func applyBTFileSelection(_ id: UUID, indexes: [Int]) async -> Bool {
        guard let aria2 else { return false }
        return await aria2.selectFiles(taskID: id, indexes: indexes)
    }

    // MARK: - speed limit
    public func applySpeedLimit(_ text: String) {
        speedLimitText = text
        applyEffectiveGlobalLimit()
    }

    /// Persist and push BitTorrent seeding preferences (Gopeed SeedRatio/SeedTime).
    /// `ratio`/`time` of 0 mean unlimited.
    public func applySeedSettings(ratio: Double, time: Int) {
        UserDefaults.standard.set(ratio, forKey: "Siphon.seedRatio")
        UserDefaults.standard.set(time, forKey: "Siphon.seedTime")
        Task {
            await aria2?.applySeedRatio(ratio)
            await aria2?.applySeedTime(time)
        }
    }

    /// Recompute and push the effective global cap = min(manual, turtle).
    /// Called whenever the manual limit text or the turtle config changes.
    private func applyEffectiveGlobalLimit() {
        let trimmed = speedLimitText.trimmingCharacters(in: .whitespaces)
        let manual: Int64? = trimmed.isEmpty ? nil : Int64(trimmed)
        let turtle = turtleConfig.effectiveLimit()
        let effective: Int64?
        switch (manual, turtle) {
        case (.some(let a), .some(let b)): effective = min(a, b)
        case (.some(let a), .none): effective = a
        case (.none, .some(let b)): effective = b
        case (.none, .none): effective = nil
        }
        SpeedLimitController.shared.setLimit(effective)
        Task {
            var seen = Set<ObjectIdentifier>()
            for engine in engines.values {
                if seen.insert(ObjectIdentifier(engine)).inserted {
                    await engine.setGlobalSpeedLimit(effective)
                }
            }
        }
    }

    /// Hot-updatable per-task speed cap (bytes/s). Effective rate is folded under
    /// the global cap by the engines. Persisted so the cap survives relaunch.
    public func setTaskSpeedLimit(_ id: UUID, _ bytesPerSec: Int64?) {
        if let v = bytesPerSec { taskSpeedLimits[id] = v }
        else { taskSpeedLimits.removeValue(forKey: id) }
        save()
        Task {
            var seen = Set<ObjectIdentifier>()
            for engine in engines.values {
                if seen.insert(ObjectIdentifier(engine)).inserted {
                    await engine.setTaskSpeedLimit(id, bytesPerSec: bytesPerSec)
                }
            }
        }
    }

    // MARK: - integrations
    public func setClipboardEnabled(_ on: Bool) {
        clipboardEnabled = on
        UserDefaults.standard.set(on, forKey: PrefKey.clipboard)
        clipboard.setEnabled(on)
    }

    public func setBrowserCaptureEnabled(_ on: Bool) {
        browserCaptureEnabled = on
        UserDefaults.standard.set(on, forKey: PrefKey.browser)
        if on {
            let server = NativeMessagingServer()
            server.start(onURL: { [weak self] url, options, checksum, mirrors in
                Task { @MainActor in
                    self?.add(urlString: url, options: options, checksum: checksum,
                              mirrors: mirrors)
                }
            }, api: { [weak self] method, path, body in
                self?.handleRESTAPI(method: method, path: path, body: body) ?? Data(#"{"ok":false}"#.utf8)
            })
            nativeMessaging = server
        } else {
            nativeMessaging?.stop()
            nativeMessaging = nil
        }
    }

    /// MCP server (Model Context Protocol) — lets AI clients manage downloads.
    /// Runs on a separate loopback port (17802) so it can be toggled independently
    /// of the browser-capture REST surface.
    public func setMCPEnabled(_ on: Bool) {
        mcpEnabled = on
        UserDefaults.standard.set(on, forKey: PrefKey.mcp)
        if on {
            let server = MCPServer()
            server.configure(handlers: mcpHandlers())
            server.start()
            mcpServer = server
        } else {
            mcpServer?.stop()
            mcpServer = nil
        }
    }

    /// Tool handlers bound to the store (FluxDown 12-tool MCP model).
    private func mcpHandlers() -> [String: MCPServer.ToolHandler] {
        return [
            "add_download": { [weak self] args in
                guard let self, let url = args["url"] as? String, !url.isEmpty else {
                    return "error: missing url"
                }
                let name = args["name"] as? String
                let mirrors = args["mirrors"] as? [String] ?? []
                Task { @MainActor in
                    self.add(urlString: url, name: name, mirrors: mirrors)
                }
                return "ok: enqueued \(url)"
            },
            "list_tasks": { [weak self] _ in
                guard let self else { return "error: store unavailable" }
                let lines = self.tasks.map {
                    "\($0.id.uuidString) [\($0.state.rawValue)] \($0.name) " +
                    "(\($0.progress.downloadedBytes)/\($0.progress.totalBytes))"
                }
                return lines.isEmpty ? "no tasks" : lines.joined(separator: "\n")
            },
            "pause_task": { [weak self] args in
                guard let self, let id = Self.taskID(from: args) else { return "error: missing id" }
                self.pause(id)
                return "ok"
            },
            "resume_task": { [weak self] args in
                guard let self, let id = Self.taskID(from: args) else { return "error: missing id" }
                self.resume(id)
                return "ok"
            },
            "remove_task": { [weak self] args in
                guard let self, let id = Self.taskID(from: args) else { return "error: missing id" }
                self.remove(id)
                return "ok"
            },
        ]
    }

    private static func taskID(from args: [String: Any]) -> UUID? {
        guard let s = args["id"] as? String else { return nil }
        return UUID(uuidString: s)
    }

    // MARK: - REST API (localhost:17801, token-free: loopback only)
    /// GET  /tasks                 — task list snapshot
    /// POST /pause /resume /remove {"id":"uuid"}
    /// POST /add                   — handled above via onURL
    public func handleRESTAPI(method: String, path: String, body: Data) -> Data {
        func reply(_ dict: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: dict)) ?? Data(#"{"ok":false}"#.utf8)
        }
        switch (method, path) {
        case ("GET", "/tasks"):
            let list = tasks.map { t -> [String: Any] in
                ["id": t.id.uuidString, "name": t.name, "url": t.source.absoluteString,
                 "state": t.state.rawValue,
                 "downloaded": t.progress.downloadedBytes, "total": t.progress.totalBytes]
            }
            return reply(["ok": true, "tasks": list])
        case ("POST", "/pause"), ("POST", "/resume"), ("POST", "/remove"):
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let idString = json["id"] as? String, let id = UUID(uuidString: idString) else {
                return reply(["ok": false, "error": "missing id"])
            }
            switch path {
            case "/pause": pause(id)
            case "/resume": resume(id)
            case "/remove": remove(id)
            default: break
            }
            return reply(["ok": true])
        default:
            return reply(["ok": false, "error": "not found"])
        }
    }

    private func handleDetectedURL(_ url: URL) {
        // Offer rather than silently start: add as a paused task so the user confirms.
        let destination = downloadDirectory.appendingPathComponent(
            url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        var t = DownloadTask(source: url, destination: destination)
        t.state = .paused
        add(t)
    }

    // MARK: - derived
    public var filteredTasks: [DownloadTask] {
        switch filter {
        case .all: return tasks
        case .active: return tasks.filter { $0.state == .active || $0.state == .pending }
        case .completed: return tasks.filter { $0.state == .completed }
        case .paused: return tasks.filter { $0.state == .paused }
        }
    }

    public var aggregateSpeed: Int64 {
        tasks.filter { $0.state == .active }.reduce(0) { $0 + $1.progress.speedBytesPerSec }
    }

    // MARK: - persistence (metadata only; file data stays on disk)
    private var tasksFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Siphon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    private func save() {
        let codable = tasks.map { TaskRecord($0, limit: taskSpeedLimits[$0.id]) }
        guard let d = try? JSONEncoder().encode(codable) else { return }
        try? d.write(to: tasksFileURL, options: .atomic)
    }

    private func load() {
        let records: [TaskRecord]?
        if let d = try? Data(contentsOf: tasksFileURL) {
            records = try? JSONDecoder().decode([TaskRecord].self, from: d)
        } else if let d = UserDefaults.standard.data(forKey: defaultsKey) {
            // One-time migration from the old UserDefaults blob.
            records = try? JSONDecoder().decode([TaskRecord].self, from: d)
            save()
        } else {
            records = nil
        }
        guard let records else { return }
        tasks = records.map { $0.task }
        taskSpeedLimits = Dictionary(uniqueKeysWithValues: records.compactMap { r in
            r.speedLimit.map { (r.id, $0) }
        })
    }
}

private struct TaskRecord: Codable {
    var id: UUID, name: String, source: URL, destination: URL
    var proto: String, state: String, queueName: String
    var downloaded: Int64, total: Int64, error: String?
    var origin: String?
    var options: [String: String]?
    var checksum: String?
    var mirrors: [URL]?
    var pieceHashes: [String]?
    var pieceLength: Int64?
    var speedLimit: Int64?

    init(_ t: DownloadTask, limit: Int64? = nil) {
        id = t.id; name = t.name; source = t.source; destination = t.destination
        proto = t.protocol.rawValue; state = t.state.rawValue; queueName = t.queueName
        downloaded = t.progress.downloadedBytes; total = t.progress.totalBytes
        error = t.errorDescription; origin = t.origin
        options = t.options.isEmpty ? nil : t.options
        checksum = t.checksum
        mirrors = t.mirrors.isEmpty ? nil : t.mirrors
        pieceHashes = t.pieceHashes.isEmpty ? nil : t.pieceHashes
        pieceLength = t.pieceLength > 0 ? t.pieceLength : nil
        speedLimit = (limit ?? 0) > 0 ? limit : nil
    }

    var task: DownloadTask {
        var t = DownloadTask(id: id, name: name, source: source,
                             destination: destination, queueName: queueName,
                             options: options ?? [:], checksum: checksum,
                             mirrors: mirrors ?? [],
                             pieceHashes: pieceHashes ?? [],
                             pieceLength: pieceLength ?? 0)
        t.protocol = DownloadProtocol(rawValue: proto) ?? .https
        // Engine-side GIDs / segment state do not survive an app restart, so
        // restore non-terminal tasks as paused and let the user resume explicitly.
        let restored = DownloadState(rawValue: state) ?? .paused
        t.state = restored.isTerminal ? restored : .paused
        t.progress.downloadedBytes = downloaded
        t.progress.totalBytes = total
        t.errorDescription = error
        t.origin = origin
        return t
    }
}
