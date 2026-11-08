import Foundation
import SwiftUI
import Combine
import AppKit
import OSLog

private let storeLog = Logger(subsystem: "com.xinkeju.siphon.macos", category: "store")

/// Central, main-actor store. Owns the task list, routes each task to the right engine,
/// and funnels engine callbacks into SwiftUI state.
@MainActor
@Observable
public final class DownloadStore: EngineDelegate {
    public var tasks: [DownloadTask] = []
    /// 列表选中项。批量暂停 / 继续 / 删除 / 拷贝链接都以这组 id 为准；
    /// 单选只是它的退化情形，所以选择状态只存这一份，避免两套状态漂移。
    public var selectedTaskIDs: Set<UUID> = []
    /// 「恰好选中一个」时的便捷视图：详情列、弹窗、通知都按它取任务。
    /// 多选时返回 nil —— 与其随便挑其中一个假装是「当前任务」，不如明确没有。
    public var selectedTaskID: UUID? {
        get { selectedTaskIDs.count == 1 ? selectedTaskIDs.first : nil }
        set {
            if let newValue { selectedTaskIDs = [newValue] }
            else if !selectedTaskIDs.isEmpty { selectedTaskIDs = [] }
        }
    }
    /// 等待二次确认的批量删除目标（菜单和列表都能触发同一个确认框）。
    public var pendingDeleteIDs: Set<UUID> = []
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
    /// MDXP bridge (paired remote devices) shares the loopback control port.
    public var mdxpEnabled = false
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
    /// 下载根目录。持久化到 UserDefaults：重启后仍沿用用户上次选择的目录，
    /// 而不是悄悄回落到 ~/Downloads。
    public var downloadDirectory: URL = {
        if let raw = UserDefaults.standard.string(forKey: PrefKey.downloadDirectory),
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }() {
        didSet {
            guard downloadDirectory != oldValue else { return }
            UserDefaults.standard.set(downloadDirectory.path, forKey: PrefKey.downloadDirectory)
        }
    }

    public let queues = QueueManager()
    public let clipboard = ClipboardMonitor()

    private var engines: [DownloadProtocol: DownloadEngine] = [:]
    /// yt-dlp 专用引擎：不按协议注册，由 `task.ytdlp` 标记显式路由。
    private let ytdlpEngine = YtDlpEngine()
    private var aria2: Aria2Engine?
    private var nativeMessaging: NativeMessagingServer?
    private var mcpServer: MCPServer?
    private var previewServer: PreviewServer?
    /// Strong reference to the MDXP adapter; it holds the store weakly.
    private var storeMDXPBackend: StoreMDXPBackend?
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
        static let mdxp = "Siphon.mdxpEnabled"
        static let schedule = "Siphon.scheduleWindow"
        static let actionFired = "Siphon.completionActionFired"
        static let autoCategorize = "Siphon.autoCategorize"
        static let ytdlp = "Siphon.ytdlp"
        static let turtle = "Siphon.turtleConfig"
        static let autoResumeInterrupted = "Siphon.autoResumeInterrupted"
        static let downloadDirectory = "Siphon.downloadDirectory"
    }
    /// Tasks already handed to an engine. Resuming these must call `resume(id)`,
    /// never `submit(task)` again (that would create a duplicate aria2 GID).
    private var submitted: Set<UUID> = []
    /// Tasks that were running (active/pending) when the previous session ended.
    /// They are restored as paused — engines cannot keep handles across a relaunch
    /// — and handed back to the scheduler once engines are up, if the preference
    /// 「启动时自动恢复」is enabled.
    private var interruptedIDs: Set<UUID> = []

    /// Tasks whose finished bytes are being hashed off the main actor, tasks
    /// that already failed that check, and tasks marked completed without a
    /// verifiable single file (e.g. multi-file torrents). Only the native
    /// URLSession engine verifies inline; every other engine is checked here.
    private var checksumVerifying: Set<UUID> = []
    private var checksumFailed: Set<UUID> = []
    public private(set) var checksumUnverified: Set<UUID> = []
    /// Throttles SSE progress frames to ~1 Hz per task instead of每次轮询.
    private var lastProgressPush: [UUID: Date] = [:]
    private var didStart = false
    private var isScheduling = false
    private var needsReschedule = false
    private var lastTurtleEffective: Int64?
    /// 因 Boost 独占而让位的任务；Boost 结束后按此集合恢复。
    private var boostPausedIDs: Set<UUID> = []
    /// 每个任务上次记账的已下载字节数，用于持久化传输统计的增量。
    private var statsLastBytes: [UUID: Int64] = [:]

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
        clipboard.onURLDetected = { [weak self] url, isDefinite in
            Task { @MainActor in self?.handleDetectedURL(url, isDefinite: isDefinite) }
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
        ytdlpEngine.delegate = self
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
        autoResumeInterrupted()
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
            let dir: URL
            if let raw = feed.subdirectory?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                // Keep it inside the download root: no absolute paths, no "..".
                let safe = raw.split(separator: "/")
                    .filter { $0 != ".." && !$0.isEmpty }
                    .joined(separator: "/")
                let target = downloadDirectory.appendingPathComponent(safe, isDirectory: true)
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                dir = target
            } else {
                dir = categorizedDirectory(for: fileName)
            }
            guard let destination = uniqueDestination(for: fileName, in: dir) else { continue }
            add(DownloadTask(name: destination.lastPathComponent, source: url, destination: destination,
                             queueName: feed.effectiveQueueName, options: [:],
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
    /// 被网络事件（断网 / 计费网络）自动暂停的任务。只恢复这一组：
    /// 用户自己按暂停的任务不该被“网络恢复”偷偷继续。
    private var autoPausedByNetwork: Set<UUID> = []
    /// 当前生效的网络暂停原因，状态栏据此显示提示。
    public private(set) var networkPauseReason: NetworkPauseReason?
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
        // A queue's time window may have just opened; give pending tasks slots.
        if tasks.contains(where: { $0.state == .pending }) {
            Task { await schedule() }
        }
        enforceBoost()
    }

    /// Boost 独占：被标记的任务处于活动/待启动时，其余活动任务让位暂停；
    /// 独占任务完成、暂停或被移除后，把让位的任务恢复为待启动。
    private func enforceBoost() {
        guard let boosted = tasks.first(where: { $0.boost }) else {
            restoreBoostPaused()
            return
        }
        guard boosted.state == .active else {
            restoreBoostPaused()
            return
        }
        for t in tasks where t.id != boosted.id && t.state == .active {
            boostPausedIDs.insert(t.id)
            pause(t.id)
        }
    }

    private func restoreBoostPaused() {
        guard !boostPausedIDs.isEmpty else { return }
        let ids = boostPausedIDs
        boostPausedIDs.removeAll()
        for id in ids where tasks.first(where: { $0.id == id })?.state == .paused {
            resume(id)
        }
    }

    public func resetCompletionLatch() {
        UserDefaults.standard.removeObject(forKey: PrefKey.actionFired)
    }

    // MARK: - 网络变化（断网 / 计费网络）

    /// 断网瞬间让几十条连接各自超时，比主动暂停糟糕得多：进度会留下大量
    /// 半截分片、失败计数还会污染重试策略。这里统一「先停后起」。
    public func handleNetworkChange(_ status: NetworkStatus) {
        let settings = NetworkPolicy.Settings.current
        if let reason = NetworkPolicy.pauseReason(for: status, settings: settings) {
            guard networkPauseReason != reason else { return }
            networkPauseReason = reason
            var paused = 0
            for t in tasks where t.state == .active || t.state == .pending {
                autoPausedByNetwork.insert(t.id)
                pause(t.id)
                paused += 1
            }
            if paused > 0 {
                SystemPresence.shared.showNotice(title: "下载已暂停", body: reason.displayText)
            }
        } else {
            guard networkPauseReason != nil || !autoPausedByNetwork.isEmpty else { return }
            networkPauseReason = nil
            let ids = autoPausedByNetwork
            autoPausedByNetwork.removeAll()
            for id in ids where tasks.first(where: { $0.id == id })?.state == .paused {
                resume(id)
            }
        }
    }

    /// Integration switches are user preferences, so they must survive relaunch.
    /// Restore through the same setters used by Settings to avoid a second
    /// listener/server instance getting out of sync with the published state.
    private func restoreIntegrations() {
        let d = UserDefaults.standard
        if d.bool(forKey: PrefKey.browser) { setBrowserCaptureEnabled(true) }
        if d.bool(forKey: PrefKey.clipboard) { setClipboardEnabled(true) }
        if d.bool(forKey: PrefKey.mcp) { setMCPEnabled(true) }
        if d.bool(forKey: PrefKey.mdxp) { setMDXPEnabled(true) }
        // Smart detection defaults to on; only turn off if explicitly disabled.
        let smartKey = "Siphon.clipboardSmartDetection"
        let smart = d.object(forKey: smartKey) == nil || d.bool(forKey: smartKey)
        clipboard.smartDetection = smart
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

    /// Hand tasks that were running at the last shutdown back to the scheduler.
    /// Called after every engine is registered (aria2 has also re-bound its
    /// persisted GIDs by then), so a resumed task continues from the engine's own
    /// resume state: aria2 session GID, `.part` sidecar, or segment sidecar.
    private func autoResumeInterrupted() {
        let ids = interruptedIDs
        interruptedIDs.removeAll()
        let d = UserDefaults.standard
        // Absent means "on" (the feature is opt-out). `bool(forKey:)` alone would
        // read an absent key as false, and `object(forKey:) as? Bool` ignores the
        // NSArgumentDomain form (`-Siphon.autoResumeInterrupted NO`) used by the
        // GUI restart verification script.
        let enabled = d.object(forKey: PrefKey.autoResumeInterrupted) == nil
            || d.bool(forKey: PrefKey.autoResumeInterrupted)
        guard enabled, !ids.isEmpty else { return }
        for id in ids where tasks.first(where: { $0.id == id })?.state == .paused {
            resume(id)
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
    /// 拖入窗口的条目：远程链接直接入队；本地文件只接受种子 / Metalink / 播放列表。
    public func addDropped(_ urls: [URL]) {
        let allowed: Set<String> = ["torrent", "metalink", "meta4",
                                    "m3u", "m3u8", "pls", "asx", "wpl"]
        for url in urls {
            if url.isFileURL, !allowed.contains(url.pathExtension.lowercased()) {
                lastError = "不支持拖入的文件类型：\(url.lastPathComponent)"
                continue
            }
            add(urlString: url.absoluteString)
        }
    }

    /// 拖入纯文本（可能包含多行链接，交给 `URINormalizer` 展开）。
    public func addDroppedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        add(urlString: trimmed)
    }

    public func add(urlString: String, name: String? = nil, queueName: String = "Default",
                    options: [String: String] = [:], checksum: String? = nil,
                    mirrors: [String] = [], priority: Int = 0,
                    ytdlpQuality: YtDlpResolver.Quality = .auto) {
        Task {
            await addNormalized(urlString: urlString, name: name,
                                queueName: queueName, options: options, checksum: checksum,
                                mirrors: mirrors, priority: priority,
                                ytdlpQuality: ytdlpQuality)
        }
    }

    /// Resolve vendor links / gateways / playlists, then enqueue one task per URL.
    /// Kept `async` because a playlist or gateway may require a network read.
    public func addNormalized(urlString: String, name: String? = nil,
                              queueName: String = "Default",
                              options: [String: String] = [:],
                              checksum: String? = nil,
                              mirrors: [String] = [],
                              priority: Int = 0,
                              ytdlpQuality: YtDlpResolver.Quality = .auto) async {
        let mirrorURLs = mirrors.compactMap { URL(string: $0) }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Cache the browser-supplied cookie for the submitted host so playlist
        // segments / mirrors / redirect targets can reuse it later.
        if let cookie = options.first(where: { $0.key.lowercased() == "cookie" })?.value,
           let host = URL(string: trimmed)?.host {
            CookieJar.shared.ingest(cookieHeader: cookie, forHost: host)
        }
        // JS plugin rewrite (PluginHost): a matching plugin may turn the URL
        // into a direct download URL and attach headers. Pure URL rewriting —
        // no network access inside the sandbox.
        if let resolved = PluginHost.shared.resolve(urlString: trimmed, headers: options) {
            var opts = options
            for (k, v) in resolved.headers { opts[k] = v }
            opts = SiteRuleStore.shared.enrichedOptions(opts, for: resolved.url)
            if !Self.hasHeader(opts, "cookie"),
               let cookie = CookieJar.shared.cookieHeader(for: resolved.url) {
                opts["Cookie"] = cookie
            }
            let baseName = resolved.name ?? name
                ?? URL(string: trimmed)?.lastPathComponent
            ?? "download"
            let fileName = SiteRuleStore.shared.adjustedFileName(baseName, for: resolved.url)
            guard let destination = uniqueDestination(for: fileName,
                                                      in: categorizedDirectory(for: fileName)) else {
                lastError = "文件已存在，已按冲突策略跳过：\(fileName)"
                return
            }
            // A plugin may name a queue that does not exist; fall back instead of
            // stranding the task in a queue the scheduler never visits.
            let targetQueue = resolved.queueName.flatMap {
                queues.queue(named: $0) != nil ? $0 : nil
            } ?? queueName
            add(DownloadTask(name: destination.lastPathComponent, source: resolved.url,
                             destination: destination,
                             queueName: targetQueue,
                             options: opts, origin: "plugin",
                             checksum: resolved.checksum ?? checksum,
                             mirrors: resolved.mirrors.isEmpty ? mirrorURLs : resolved.mirrors,
                             priority: priority))
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
                let medias = try await YtDlpResolver.resolveForDownload(
                    trimmed, quality: ytdlpQuality)
                enqueueMedias(medias, queueName: queueName, options: options,
                              checksum: checksum, customName: name,
                              priority: priority, quality: ytdlpQuality)
                lastError = nil
                return
            } catch {
                // Resolution is best-effort: fall through to the normal path.
                lastError = error.localizedDescription
            }
        }
        do {
            let reqs = try await URINormalizer.normalize(trimmed, options: options)
            var skipped: String?
            for req in reqs {
                // A custom name only makes sense for a single-file submission.
                let baseName: String
                if reqs.count == 1, let name, !name.isEmpty { baseName = name }
                else if let n = req.suggestedName, !n.isEmpty { baseName = n }
                else if req.proto == .data { baseName = "data.bin" }
                else if reqs.count == 1,
                        let remote = await serverFileName(for: req.url, options: req.options) {
                    // RFC 6266 `Content-Disposition` beats an opaque URL id.
                    baseName = remote
                } else {
                    let probe = DownloadTask(source: req.url,
                                             destination: downloadDirectory,
                                             protoOverride: req.proto)
                    baseName = probe.name
                }
                // Site rules fill missing headers and decorate the file name.
                var reqOptions = SiteRuleStore.shared.enrichedOptions(req.options, for: req.url)
                if !Self.hasHeader(reqOptions, "cookie"),
                   let cookie = CookieJar.shared.cookieHeader(for: req.url) {
                    reqOptions["Cookie"] = cookie
                }
                let fileName = SiteRuleStore.shared.adjustedFileName(baseName, for: req.url)
                guard let destination = uniqueDestination(for: fileName,
                                                          in: categorizedDirectory(for: fileName)) else {
                    skipped = fileName
                    continue
                }
                let task = DownloadTask(name: destination.lastPathComponent, source: req.url,
                                        destination: destination,
                                        queueName: queueName, options: reqOptions,
                                        origin: req.origin,
                                        checksum: checksum ?? req.checksum,
                                        mirrors: req.mirrors.isEmpty
                                            ? (reqs.count == 1 ? mirrorURLs : [])
                                            : req.mirrors,
                                        pieceHashes: req.pieceHashes,
                                        pieceLength: req.pieceLength,
                                        priority: priority,
                                        protoOverride: req.proto)
                add(task)
            }
            lastError = skipped.map { "文件已存在，已按冲突策略跳过：\($0)" }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Enqueue yt-dlp–resolved media entries. The title (sanitized) becomes the
    /// file name, with the container extension when known.
    private func enqueueMedias(_ medias: [YtDlpResolver.Media], queueName: String,
                               options: [String: String], checksum: String?,
                               customName: String?, priority: Int = 0,
                               quality: YtDlpResolver.Quality = .auto) {
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
                // 固定输出名必须带扩展名：yt-dlp 合并时依赖它选择容器。
                if let ext = media.ext, !ext.isEmpty,
                   (fileName as NSString).pathExtension.isEmpty {
                    fileName += ".\(ext)"
                }
            }
            // yt-dlp 必须拿到页面地址，而不是解析出来的直链。
            guard let src = URL(string: media.pageURL ?? media.url) else { continue }
            var opts = SiteRuleStore.shared.enrichedOptions(options, for: src)
            if !Self.hasHeader(opts, "cookie"),
               let cookie = CookieJar.shared.cookieHeader(for: src) {
                opts["Cookie"] = cookie
            }
            fileName = SiteRuleStore.shared.adjustedFileName(fileName, for: src)
            guard let destination = uniqueDestination(for: fileName,
                                                      in: categorizedDirectory(for: fileName)) else { continue }
            let task = DownloadTask(name: destination.lastPathComponent,
                                    source: src,
                                    destination: destination,
                                    queueName: queueName, options: opts,
                                    origin: "yt-dlp", checksum: checksum,
                                    priority: priority,
                                    ytdlp: true,
                                    ytdlpFormat: media.selector ?? quality.selector,
                                    protoOverride: .https)
            add(task)
        }
    }

    public func add(_ task: DownloadTask) {
        // The same URL already in flight (pending/active/paused) in the same
        // folder: focus it instead of starting a duplicate connection set.
        let inFlight: Set<DownloadState> = [.pending, .active, .paused]
        if let existing = tasks.first(where: {
            inFlight.contains($0.state)
                && $0.source.absoluteString == task.source.absoluteString
                && $0.destination.deletingLastPathComponent().path
                    == task.destination.deletingLastPathComponent().path
        }) {
            selectedTaskID = existing.id
            // 重复提交也把弹窗叫出来，指向已有任务：用户刚点了一个链接，
            // 需要看到「已经在下了」，否则会以为没生效。
            DownloadPopupController.shared.present(taskID: existing.id, store: self)
            return
        }
        // 同一链接已完成（同目录）：按重复策略跳过或重新下载。
        // 跳过时聚焦已有任务；重新下载仍走冲突策略生成新的目标文件名。
        if let completed = tasks.first(where: {
            $0.state == .completed
                && $0.source.absoluteString == task.source.absoluteString
                && $0.destination.deletingLastPathComponent().path
                    == task.destination.deletingLastPathComponent().path
        }) {
            switch DuplicatePolicy.current {
            case .skip:
                selectedTaskID = completed.id
                return
            case .redownload:
                break
            case .ask:
                // 后台/接口调用（MCP、浏览器扩展）不弹模态框，按“跳过”处理，
                // 避免主线程被对话框阻塞。
                if !NSApp.isActive || !askRedownload(duplicate: completed) {
                    selectedTaskID = completed.id
                    return
                }
            }
        }
        // Overwrite policy: drop the stale file first so the native engine does
        // not mistake it for an already-finished download. Directories
        // (multi-file torrents) are never touched.
        if ConflictPolicy.current == .overwrite {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: task.destination.path,
                                              isDirectory: &isDirectory),
               !isDirectory.boolValue {
                try? FileManager.default.removeItem(at: task.destination)
            }
        }
        tasks.append(task)
        save()
        resetCompletionLatch() // a fresh task re-arms the completion action
        broadcastTask(task)
        SystemPresence.shared.refresh(tasks: tasks)
        Task { await schedule() }
        // NDM 式反馈：新任务先弹紧凑浮窗（速度 / 总进度 / 分段），
        // 而不是把整个主窗口翻到最前。
        DownloadPopupController.shared.present(taskID: task.id, store: self)
    }

    /// Ask the server for `Content-Disposition` only when the URL path cannot
    /// name the file (`/download?id=123`, `/file/`, `/stream`). Normal URLs are
    /// left untouched, so adding a task does not pay an extra network round-trip.
    private func serverFileName(for url: URL, options: [String: String]) async -> String? {
        guard needsServerFilename(url) else { return nil }
        return await RemoteFilenameResolver.suggestedName(for: url, options: options)
    }

    private func needsServerFilename(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return true }
        let lower = last.lowercased()
        if !lower.contains(".") { return true }
        let generic: Set<String> = [
            "download", "downloads", "file", "files", "get", "index",
            "redirect", "attachment", "data", "binary", "stream",
            "file.php", "download.php", "downloadfile", "getfile"
        ]
        return generic.contains(lower)
    }

    /// Case-insensitive header presence check (browser/plugin payloads mix
    /// `Cookie` and `cookie` spellings).
    private static func hasHeader(_ options: [String: String], _ name: String) -> Bool {
        options.keys.contains { $0.lowercased() == name.lowercased() }
    }

    /// Resolve the destination according to the user's conflict policy.
    /// `.rename` keeps ABD's numberedIfExists behaviour, `.skip` returns nil so
    /// the caller drops the task, and `.overwrite` reuses the name when no other
    /// task owns it (the existing file is removed when the task is enqueued).
    private func uniqueDestination(for fileName: String, in dir: URL? = nil) -> URL? {
        // `name` reaches us from REST `/add`, MCP `add_download`, MDXP, plugins,
        // yt-dlp titles and RSS entries. None of them is a trusted path. Without
        // this, `../../…/authorized_keys` plus a `data:` source writes anywhere
        // the app can reach. Reuse the same sanitizer as Content-Disposition.
        guard let fileName = ContentDisposition.safeName(fileName) else { return nil }
        let base = (dir ?? downloadDirectory).standardizedFileURL
        let path = base.appendingPathComponent(fileName).standardizedFileURL
        // Belt and braces: even if the sanitizer changes, the final destination
        // must remain a direct child of the chosen download directory.
        guard path.deletingLastPathComponent().path == base.path else { return nil }
        let taken = Set(tasks.map { $0.destination.lastPathComponent })
        let existsOnDisk = FileManager.default.fileExists(atPath: path.path)
        if !taken.contains(fileName) {
            switch ConflictPolicy.current {
            case .overwrite:
                return path
            case .skip:
                return existsOnDisk ? nil : path
            case .rename:
                if !existsOnDisk { return path }
            case .ask:
                if !existsOnDisk { return path }
                return askConflict(fileName: fileName, path: path,
                                   base: base, taken: taken)
            }
        }
        switch ConflictPolicy.current {
        case .skip:
            return nil
        case .ask:
            return askConflict(fileName: fileName, path: path,
                               base: base, taken: taken)
        case .rename, .overwrite:
            break
        }
        return numberedDestination(fileName, base: base, taken: taken)
    }

    /// 逐次询问（FluxDown 三态冲突对话框）：覆盖 / 重命名 / 跳过，可选“应用到全部”。
    private func askConflict(fileName: String, path: URL, base: URL,
                             taken: Set<String>) -> URL? {
        let alert = NSAlert()
        alert.messageText = "文件已存在"
        alert.informativeText = "“\(fileName)”已存在于目标文件夹，请选择处理方式。"
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "跳过")
        let remember = NSButton(checkboxWithTitle: "记住选择，应用到全部",
                                target: nil, action: nil)
        alert.accessoryView = remember

        let policy: ConflictPolicy
        switch alert.runModal() {
        case .alertFirstButtonReturn: policy = .overwrite
        case .alertSecondButtonReturn: policy = .rename
        default: policy = .skip
        }
        if remember.state == .on {
            UserDefaults.standard.set(policy.rawValue, forKey: ConflictPolicy.defaultsKey)
        }
        switch policy {
        case .overwrite:
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path,
                                              isDirectory: &isDirectory),
               !isDirectory.boolValue {
                try? FileManager.default.removeItem(at: path)
            }
            return path
        case .rename:
            return numberedDestination(fileName, base: base, taken: taken)
        case .skip, .ask:
            return nil
        }
    }

    /// 逐次询问：同一链接已完成时是否重新下载。返回 true 表示继续新建任务。
    private func askRedownload(duplicate: DownloadTask) -> Bool {
        let alert = NSAlert()
        alert.messageText = "该链接已下载完成"
        alert.informativeText = "「\(duplicate.name)」已在任务列表中完成。是否重新下载？"
        alert.addButton(withTitle: "重新下载")
        alert.addButton(withTitle: "跳过")
        let remember = NSButton(checkboxWithTitle: "记住选择", target: nil, action: nil)
        alert.accessoryView = remember

        let proceed = alert.runModal() == .alertFirstButtonReturn
        if remember.state == .on {
            UserDefaults.standard.set(
                (proceed ? DuplicatePolicy.redownload : DuplicatePolicy.skip).rawValue,
                forKey: DuplicatePolicy.defaultsKey)
        }
        return proceed
    }

    /// 在文件名后追加 `(n)` 直到磁盘与任务列表都不冲突。
    private func numberedDestination(_ fileName: String, base: URL,
                                     taken: Set<String>) -> URL {
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
        broadcastTask(tasks[i])
        SystemPresence.shared.refresh(tasks: tasks)
        Task { await engine(for: tasks[i])?.pause(id) }
        // The queue's cap now has one fewer consumer; redistribute it.
        Task { await reapplyTaskCaps() }
    }

    public func resume(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        // Manual resume re-arms a deferred integrity check (and lets the engine
        // report "completed" again instead of being pinned to the old failure).
        checksumFailed.remove(id)
        checksumUnverified.remove(id)
        checksumVerifying.remove(id)
        tasks[i].state = .pending
        save()
        broadcastTask(tasks[i])
        SystemPresence.shared.refresh(tasks: tasks)
        Task { await schedule() }
    }

    public func pauseAll() {
        for t in tasks where t.state == .active || t.state == .pending {
            pause(t.id)
        }
    }

    public func resumeAll() {
        for t in tasks where t.state == .paused || t.state == .error {
            resume(t.id)
        }
    }

    public func remove(_ id: UUID) {
        if let t = tasks.first(where: { $0.id == id }) {
            broadcastTask(t, stateOverride: "removed")
            Task { await engine(for: t)?.remove(id) }
        }
        submitted.remove(id)
        taskSpeedLimits.removeValue(forKey: id)
        checksumVerifying.remove(id)
        checksumFailed.remove(id)
        checksumUnverified.remove(id)
        PreviewRegistry.shared.unregister(taskID: id)
        boostPausedIDs.remove(id)
        statsLastBytes.removeValue(forKey: id)
        tasks.removeAll { $0.id == id }
        // 选中的任务被删掉后必须从选择集合里剔除，否则批量操作会拿着幽灵 id
        // 到处跑（数量对不上、按钮状态也不对）。
        selectedTaskIDs.remove(id)
        pendingDeleteIDs.remove(id)
        save()
        SystemPresence.shared.refresh(tasks: tasks)
        enforceBoost()
    }

    /// 移除任务并删除磁盘上的文件（成品、未完成的 .part、续传 sidecar）。
    /// 普通 `remove` 只把任务移出列表，绝不删除已完成的成品文件。
    public func removeAndDelete(_ id: UUID) {
        guard let t = tasks.first(where: { $0.id == id }) else { return }
        let destination = t.destination
        let part = destination.appendingPathExtension("part")
        let controlFiles = [
            destination.appendingPathExtension("aria2"),
            URL(fileURLWithPath: destination.path + ".siphon-resume.json")
        ]
        remove(id)
        // macOS 的删除约定是「进废纸篓」：用户误删一个 20 GB 的镜像时，
        // 直接 unlink 没有第二次机会，废纸篓有。
        for url in [destination, part] {
            Self.moveToTrash(url)
        }
        // 引擎的断点控制文件不是用户数据，直接删掉。
        for url in controlFiles {
            try? FileManager.default.removeItem(at: url)
        }
        Sidecar.clear(for: destination)
        Sidecar.clear(for: part)
    }

    /// 能进废纸篓就进；跨卷/无权限等情况下才退回直接删除（否则删除按钮会静默失效）。
    private static func moveToTrash(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func removeCompleted() {
        for t in tasks where t.state == .completed { remove(t.id) }
    }

    // MARK: - 批量操作（列表多选 / 右键菜单 / 「任务」菜单共用）

    /// 当前选中的任务，按列表顺序返回（顺序稳定，批量结果才可预期）。
    public var selectedTasks: [DownloadTask] {
        guard !selectedTaskIDs.isEmpty else { return [] }
        return tasks.filter { selectedTaskIDs.contains($0.id) }
    }

    public func clearSelection() {
        guard !selectedTaskIDs.isEmpty else { return }
        selectedTaskIDs = []
        pendingDeleteIDs = []
    }

    public func selectAll(_ ids: [UUID]) {
        selectedTaskIDs = Set(ids)
    }

    public func pauseTasks(_ ids: Set<UUID>) {
        for t in tasks where ids.contains(t.id) && (t.state == .active || t.state == .pending) {
            pause(t.id)
        }
    }

    public func resumeTasks(_ ids: Set<UUID>) {
        for t in tasks where ids.contains(t.id) && (t.state == .paused || t.state == .error) {
            resume(t.id)
        }
    }

    /// 只移出列表，保留磁盘文件。
    public func removeTasks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in tasks.map(\.id) where ids.contains(id) { remove(id) }
    }

    /// 移出列表并删除磁盘文件（成品 / .part / 续传 sidecar）。
    public func deleteTasks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in tasks.map(\.id) where ids.contains(id) { removeAndDelete(id) }
        pendingDeleteIDs = []
    }

    public func setSpeedLimit(_ ids: Set<UUID>, bytesPerSec: Int64?) {
        guard !ids.isEmpty else { return }
        for id in tasks.map(\.id) where ids.contains(id) {
            setTaskSpeedLimit(id, bytesPerSec)
        }
    }

    public func setPriority(_ ids: Set<UUID>, _ priority: Int) {
        guard !ids.isEmpty else { return }
        for id in tasks.map(\.id) where ids.contains(id) {
            setTaskPriority(id, priority)
        }
    }

    /// 多选时拷出的链接按列表顺序每行一条，粘回「新建下载」可直接批量添加。
    @discardableResult
    public func copyLinks(_ ids: Set<UUID>) -> Int {
        let links = tasks.filter { ids.contains($0.id) }.map(\.source.absoluteString)
        guard !links.isEmpty else { return 0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        return links.count
    }

    // MARK: - 边下边播
    /// Container formats a browser / AVPlayer can start playing before EOF.
    private static let previewableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "ts", "mkv", "webm",
        "mp3", "m4a", "aac", "flac", "ogg", "wav"
    ]

    public func isPreviewable(_ task: DownloadTask) -> Bool {
        let ext = task.destination.pathExtension.lowercased()
        return Self.previewableExtensions.contains(ext)
    }

    /// Local loopback URL for `AVPlayer`. Starts the preview server lazily and
    /// registers the task's current bytes with the registry.
    public func previewURL(for task: DownloadTask) -> URL? {
        guard isPreviewable(task) else {
            lastError = "该文件类型不支持边下边播"
            return nil
        }
        guard let server = ensurePreviewServer() else { return nil }
        let fileURL = previewFileURL(for: task)
        let diskSize = Self.fileSize(fileURL)
        PreviewRegistry.shared.register(
            taskID: task.id,
            fileURL: fileURL,
            totalBytes: max(task.progress.totalBytes, diskSize),
            downloadedBytes: task.state == .completed ? diskSize : task.progress.downloadedBytes)
        return server.url(for: task.id)
    }

    /// Finished files are handed to the system default app (QuickTime / IINA…),
    /// which is both simpler and faster than proxying them through the server.
    public func openWithDefaultApp(_ task: DownloadTask) {
        NSWorkspace.shared.open(task.destination)
    }

    private func ensurePreviewServer() -> PreviewServer? {
        if let previewServer { return previewServer }
        let server = PreviewServer()
        guard server.start() else {
            lastError = server.lastError ?? "边下边播服务启动失败"
            return nil
        }
        previewServer = server
        return server
    }

    /// Unfinished native-HTTP transfers live at `<dest>.part`; aria2 writes straight
    /// to the destination. Prefer the partial file when it exists.
    private func previewFileURL(for task: DownloadTask) -> URL {
        let dir = task.destination.deletingLastPathComponent()
        let part = dir.appendingPathComponent(task.destination.lastPathComponent + ".part")
        if FileManager.default.fileExists(atPath: part.path) { return part }
        return task.destination
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - scheduling
    /// 任务 → 引擎：yt-dlp 任务走专用引擎，其余按协议路由。
    private func engine(for task: DownloadTask) -> (any DownloadEngine)? {
        task.ytdlp ? ytdlpEngine : engines[task.protocol]
    }

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
        let activeByQueue = Dictionary(grouping: tasks.filter { $0.state == .active }) {
            $0.queueName
        }.mapValues(\.count)
        var startingByQueue: [String: Int] = [:]
        // 独占带宽生效时只允许 Boost 任务占用新槽位。
        let boostID = tasks.first(where: { $0.boost && $0.state == .active })?.id
        for id in ids {
            if let boostID, boostID != id { continue }
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { continue }
            let task = tasks[i]
            guard let eng = engine(for: task) else {
                tasks[i].state = .error
                tasks[i].errorDescription = "没有可处理 \(task.protocol.displayName) 的引擎"
                continue
            }
            do {
                if submitted.contains(id) {
                    await eng.resume(id)
                } else {
                    try await eng.submit(task)
                    submitted.insert(id)
                }
                // Re-apply the saved per-task cap, folded under the queue's
                // aggregate cap (shared evenly among its running tasks).
                let cap = effectiveCap(for: task,
                                       activeInQueue: activeByQueue[task.queueName] ?? 0,
                                       starting: startingByQueue[task.queueName] ?? 0)
                if let cap {
                    await eng.setTaskSpeedLimit(id, bytesPerSec: cap)
                }
                startingByQueue[task.queueName, default: 0] += 1
                tasks[i].state = .active
            } catch {
                tasks[i].state = .error
                tasks[i].errorDescription = error.localizedDescription
            }
        }
        save()
    }

    /// Effective per-task cap = min(saved per-task cap, queue share). The queue
    /// limit is divided by the number of tasks that will be active in it once
    /// this task starts; `0` means the queue is unlimited.
    private func effectiveCap(for task: DownloadTask, activeInQueue: Int,
                              starting: Int) -> Int64? {
        let saved = taskSpeedLimits[task.id]
        guard let queue = queues.queue(named: task.queueName), queue.speedLimit > 0 else {
            return saved
        }
        let share = max(1, queue.speedLimit / Int64(max(1, activeInQueue + starting + 1)))
        return saved.map { min($0, share) } ?? share
    }

    /// Recompute caps for every active task after a task pause/completion or
    /// a queue-definition change, so a freed share goes to the remaining tasks.
    private func reapplyTaskCaps() async {
        let activeByQueue = Dictionary(grouping: tasks.filter { $0.state == .active }) {
            $0.queueName
        }.mapValues(\.count)
        for task in tasks where task.state == .active {
            guard let eng = engine(for: task) else { continue }
            let cap = effectiveCap(for: task,
                                   activeInQueue: max(0, (activeByQueue[task.queueName] ?? 1) - 1),
                                   starting: 0)
            await eng.setTaskSpeedLimit(task.id, bytesPerSec: cap)
        }
    }

    /// Queue definitions are edited in Settings; re-arm scheduling and caps.
    public func refreshQueueLimits() {
        Task { await reapplyTaskCaps() }
        Task { await schedule() }
    }

    /// Delete a queue. Tasks reference queues by name, so they must be moved
    /// back to Default first — otherwise `nextToStart` would skip them forever.
    /// The Default queue itself cannot be deleted.
    public func deleteQueue(id: UUID) {
        guard let q = queues.queues.first(where: { $0.id == id }), q.name != "Default" else { return }
        for i in tasks.indices where tasks[i].queueName == q.name {
            tasks[i].queueName = "Default"
        }
        save()
        queues.remove(id)
        refreshQueueLimits()
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
        // 持久化传输统计：只累计本次会话新增的字节（首次见到该任务时以当前值为基线）。
        let previous = statsLastBytes[taskID] ?? progress.downloadedBytes
        if progress.downloadedBytes > previous {
            TransferStats.shared.addDownloaded(progress.downloadedBytes - previous)
        }
        statsLastBytes[taskID] = progress.downloadedBytes
        tasks[i].progress = progress
        // Feed the streaming server: it may only serve up to the bytes the engine
        // reports as downloaded (preallocated `.part` files are full-size from byte 0).
        PreviewRegistry.shared.update(taskID: taskID,
                                      downloaded: progress.downloadedBytes,
                                      total: progress.totalBytes)
        guard tasks[i].state == .active else { return }
        let now = Date()
        if now.timeIntervalSince(lastProgressPush[taskID] ?? .distantPast) >= 1 {
            lastProgressPush[taskID] = now
            broadcastTask(tasks[i])
            SystemPresence.shared.refresh(tasks: tasks)
        }
    }

    public func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        // A checksum failure was already surfaced; keep polling reports of "complete"
        // from silently clearing it again.
        if checksumFailed.contains(taskID), state != .error, state != .removed { return }
        // Aria2's poll() reports the current state every tick; skip the per-second
        // reschedule + full JSON re-encode when nothing actually changed.
        guard tasks[i].state != state else {
            if let error { tasks[i].errorDescription = error.localizedDescription }
            return
        }
        // Engines that move bytes through an external process cannot verify inline.
        // Hold the completion transition until the store's own hash check finishes.
        if state == .completed,
           needsPostCompletionChecksum(tasks[i]),
           !checksumVerifying.contains(taskID) {
            checksumVerifying.insert(taskID)
            let spec = tasks[i].checksum ?? ""
            let destination = tasks[i].destination
            Task {
                let outcome: ChecksumPolicy.Outcome = await Task.detached(priority: .utility) {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: destination.path,
                                                         isDirectory: &isDirectory),
                          !isDirectory.boolValue else {
                        // Multi-file torrents / missing files have no single hash.
                        // Report "unverifiable" instead of claiming success.
                        return .unverifiable
                    }
                    do {
                        return try ChecksumVerifier.verify(fileAt: destination, spec: spec)
                            ? .verified : .mismatched
                    } catch {
                        // An unreadable file or an unsupported spec is a failure,
                        // never a silent pass.
                        return .mismatched
                    }
                }.value
                checksumVerifying.remove(taskID)
                // The list may have shifted (insert/remove) while hashing.
                guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
                switch outcome {
                case .verified:
                    checksumUnverified.remove(taskID)
                    applyState(index: index, state: .completed, error: nil)
                case .mismatched:
                    checksumFailed.insert(taskID)
                    applyState(index: index, state: .error,
                               error: NetFailure.checksumMismatch)
                case .unverifiable:
                    checksumUnverified.insert(taskID)
                    tasks[index].errorDescription = "校验和未验证"
                    applyState(index: index, state: .completed, error: nil)
                }
            }
            return
        }
        applyState(index: i, state: state, error: error)
    }

    /// Delegates to the pure `ChecksumPolicy` so the coverage rule is unit-tested.
    private func needsPostCompletionChecksum(_ task: DownloadTask) -> Bool {
        ChecksumPolicy.needsPostCompletionChecksum(
            isNative: task.protocol.transport == .native,
            ytdlp: task.ytdlp,
            checksum: task.checksum)
    }

    private func applyState(index i: Int, state: DownloadState, error: Error?) {
        tasks[i].state = state
        if let error { tasks[i].errorDescription = error.localizedDescription }
        if state == .completed {
            // Flag the finished file as an internet download so Gatekeeper applies its
            // first-launch checks (FluxDown mark_of_the_web).
            markDownloadQuarantine(tasks[i].destination)
            // Finder 的「简介 → 更多信息 → 来自何处」由这个 xattr 提供。
            // 下载器不写它，用户事后就再也说不清文件是从哪个地址来的。
            if PresenceDefaults.bool(PresenceDefaults.recordWhereFromsKey, default: true) {
                DownloadOriginMetadata.write(source: tasks[i].source.absoluteString,
                                             referrer: tasks[i].origin,
                                             to: tasks[i].destination)
            }
            // The `.part` file was atomically renamed; an open preview must follow.
            PreviewRegistry.shared.retarget(taskID: tasks[i].id,
                                            fileURL: tasks[i].destination,
                                            totalBytes: tasks[i].progress.totalBytes,
                                            downloadedBytes: tasks[i].progress.downloadedBytes)
            // Auto-extract archives and run any post-processing command (HyperDM model).
            ArchiveManager.shared.handleCompletion(of: tasks[i].destination)
        }
        // Persist `.error` too: otherwise the last saved record still says
        // "active", and the auto-resume-on-launch feature would retry a task
        // that had already failed.
        if state == .completed { TransferStats.shared.recordCompletion(success: true) }
        else if state == .error { TransferStats.shared.recordCompletion(success: false) }
        if state.isTerminal || state == .error { save() }
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
        broadcastTask(tasks[i])
        SystemPresence.shared.taskStateChanged(tasks[i])
        SystemPresence.shared.refresh(tasks: tasks)
        enforceBoost()
        if state.isTerminal {
            // A finished/paused task frees its share of the queue cap.
            Task { await reapplyTaskCaps() }
        }
        Task { await schedule() }
    }

    /// One SSE frame describing a task. JSON stays single-line so the
    /// `data:` framing in `NativeMessagingServer` cannot be split.
    private func broadcastTask(_ task: DownloadTask, stateOverride: String? = nil) {
        guard let server = nativeMessaging else { return }
        let payload: [String: Any] = [
            "id": task.id.uuidString,
            "name": task.name,
            "url": task.source.absoluteString,
            "state": stateOverride ?? task.state.rawValue,
            "downloaded": task.progress.downloadedBytes,
            "total": task.progress.totalBytes,
            "speed": task.progress.speedBytesPerSec,
            "peers": task.progress.connectedPeers,
            "priority": task.priority
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        server.broadcast(json)
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
            for engine in Array(engines.values) + [ytdlpEngine] {
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
        // The saved cap folds under the queue's aggregate share. The share is
        // divided among active tasks in THIS task's queue only (same accounting
        // as reapplyTaskCaps), not across every active task in the store.
        let effective = tasks.first(where: { $0.id == id }).flatMap { task in
            let activeInQueue = tasks.filter {
                $0.state == .active && $0.queueName == task.queueName
            }.count
            return effectiveCap(for: task,
                                activeInQueue: max(0, activeInQueue - 1),
                                starting: 0)
        }
        Task {
            for engine in Array(engines.values) + [ytdlpEngine] {
                await engine.setTaskSpeedLimit(id, bytesPerSec: effective)
            }
        }
    }

    /// Change a task's scheduling priority (higher = starts sooner).
    public func setTaskPriority(_ id: UUID, _ priority: Int) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].priority = priority
        save()
        broadcastTask(tasks[i])
        Task { await schedule() }
    }

    /// 切换独占带宽。整个任务列表里同时最多只有一个 Boost 任务。
    public func setBoost(_ id: UUID, _ on: Bool) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        for i in tasks.indices {
            tasks[i].boost = on && tasks[i].id == id
        }
        if !on { restoreBoostPaused() }
        save()
        if let i = tasks.firstIndex(where: { $0.id == id }) { broadcastTask(tasks[i]) }
        enforceBoost()
        Task { await schedule() }
    }

    /// 每任务并发连接数（1...32）。运行中的任务会在下一次续传/重试时采用新值。
    public func setTaskConnections(_ id: UUID, _ connections: Int) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].connections = min(32, max(1, connections))
        save()
        broadcastTask(tasks[i])
    }

    /// HLS 画质：按 BANDWIDTH 选择；`nil` 为最高画质。下次开始/续传生效。
    public func setHLSBandwidth(_ id: UUID, _ bandwidth: Int?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].hlsBandwidth = bandwidth
        save()
        broadcastTask(tasks[i])
    }

    /// 读取 HLS 主播放列表里的画质档位（检查器按需调用）。
    public func hlsVariants(for task: DownloadTask)
        async -> [(url: URL, bandwidth: Int)] {
        (try? await HLSEngine.variants(for: task.source, options: task.options)) ?? []
    }

    /// 活跃任务的分段快照（仅原生 HTTP 引擎提供；其他引擎返回空）。
    public func segmentSnapshot(for id: UUID) -> [SegmentSnapshot] {
        guard let task = tasks.first(where: { $0.id == id }),
              let eng = engine(for: task) else { return [] }
        return eng.segmentSnapshot(for: id)
    }

    // MARK: - integrations
    public func setClipboardEnabled(_ on: Bool) {
        clipboardEnabled = on
        UserDefaults.standard.set(on, forKey: PrefKey.clipboard)
        clipboard.setEnabled(on)
    }

    public func setClipboardSmartDetection(_ on: Bool) {
        clipboard.smartDetection = on
        UserDefaults.standard.set(on, forKey: "Siphon.clipboardSmartDetection")
    }

    public func setBrowserCaptureEnabled(_ on: Bool) {
        browserCaptureEnabled = on
        UserDefaults.standard.set(on, forKey: PrefKey.browser)
        refreshControlServer()
    }

    /// MDXP bridge toggle. It shares the loopback control port with browser
    /// capture, so either feature being on keeps one server alive.
    public func setMDXPEnabled(_ on: Bool) {
        mdxpEnabled = on
        UserDefaults.standard.set(on, forKey: PrefKey.mdxp)
        refreshControlServer()
    }

    private func refreshControlServer() {
        guard browserCaptureEnabled || mdxpEnabled else {
            nativeMessaging?.stop()
            nativeMessaging = nil
            storeMDXPBackend = nil
            // No listener means no reason to leave a token file behind.
            LocalAuthToken.unpublishBootstrapFile()
            return
        }
        // The NM gateway is launched by the browser as a separate process and
        // cannot inherit in-memory state, so publish the token out of band.
        LocalAuthToken.publishBootstrapFile()
        // The loopback server is shared by browser capture and MDXP, so it is
        // created once when either feature turns on and kept alive while either
        // remains enabled.
        if nativeMessaging == nil {
            let server = NativeMessagingServer()
            server.start(onURL: { [weak self] url, options, checksum, mirrors in
                Task { @MainActor in
                    // Browser-intercepted downloads get a priority boost.
                    self?.add(urlString: url, options: options, checksum: checksum,
                              mirrors: mirrors, priority: 1)
                }
            }, api: { [weak self] method, path, body in
                // This closure runs on the server's private queue. The store is
                // @MainActor @Observable, so hop before touching any task state.
                guard let self else { return Data(#"{"ok":false}"#.utf8) }
                return runOnMainActor {
                    self.handleRESTAPI(method: method, path: path, body: body)
                } ?? Data(#"{"ok":false,"error":"main actor timeout"}"#.utf8)
            })
            nativeMessaging = server
        }
        guard let server = nativeMessaging else { return }
        // Attach or detach the MDXP handler + device-token verifier on every
        // refresh, so toggling MDXP off (while browser capture keeps the shared
        // server alive) actually closes the /mdxp surface.
        if mdxpEnabled {
            let backend = storeMDXPBackend ?? StoreMDXPBackend(store: self)
            storeMDXPBackend = backend
            let bridge = MDXPBridge(backend: backend)
            server.setMDXPHandler { body in bridge.handle(body) }
            // Paired remote devices authenticate with their device token.
            server.setAdditionalTokenVerifier { presented in
                RemotePairing.shared.verify(presented: presented)
            }
        } else {
            server.setMDXPHandler(nil)
            server.setAdditionalTokenVerifier(nil)
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
    /// Tool handlers bound to the store. Every store access hops to the main
    /// actor: `MCPServer.process` runs on its own `DispatchQueue`, and reading
    /// `tasks` / calling `pause` there used to race with UI mutations.
    private func mcpHandlers() -> [String: MCPServer.ToolHandler] {
        let timeoutMessage = "error: main actor timeout"
        return [
            "add_download": { [weak self] args in
                guard let self, let url = args["url"] as? String, !url.isEmpty else {
                    return "error: missing url"
                }
                let name = args["name"] as? String
                let mirrors = args["mirrors"] as? [String] ?? []
                return runOnMainActor {
                    self.add(urlString: url, name: name, mirrors: mirrors)
                    return "ok: enqueued \(url)"
                } ?? timeoutMessage
            },
            "list_tasks": { [weak self] _ in
                guard let self else { return "error: store unavailable" }
                return runOnMainActor {
                    let lines = self.tasks.map {
                        "\($0.id.uuidString) [\($0.state.rawValue)] \($0.name) " +
                        "(\($0.progress.downloadedBytes)/\($0.progress.totalBytes))"
                    }
                    return lines.isEmpty ? "no tasks" : lines.joined(separator: "\n")
                } ?? timeoutMessage
            },
            "pause_task": { [weak self] args in
                guard let self, let id = Self.taskID(from: args) else { return "error: missing id" }
                return runOnMainActor { self.pause(id); return "ok" } ?? timeoutMessage
            },
            "resume_task": { [weak self] args in
                guard let self, let id = Self.taskID(from: args) else { return "error: missing id" }
                return runOnMainActor { self.resume(id); return "ok" } ?? timeoutMessage
            },
            "remove_task": { [weak self] args in
                guard let self, let id = Self.taskID(from: args) else { return "error: missing id" }
                return runOnMainActor { self.remove(id); return "ok" } ?? timeoutMessage
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
                 "state": t.state.rawValue, "priority": t.priority,
                 "downloaded": t.progress.downloadedBytes, "total": t.progress.totalBytes]
            }
            return reply(["ok": true, "tasks": list])
        case ("GET", let p) where p.hasPrefix("/tasks/"):
            guard let id = UUID(uuidString: String(p.dropFirst("/tasks/".count))),
                  let t = tasks.first(where: { $0.id == id }) else {
                return reply(["ok": false, "error": "not found"])
            }
            return reply(["ok": true, "task": [
                "id": t.id.uuidString, "name": t.name, "url": t.source.absoluteString,
                "state": t.state.rawValue, "queue": t.queueName,
                "priority": t.priority,
                "destination": t.destination.path,
                "downloaded": t.progress.downloadedBytes, "total": t.progress.totalBytes,
                "speed": t.progress.speedBytesPerSec, "peers": t.progress.connectedPeers,
                "error": t.errorDescription ?? ""
            ]])
        case ("POST", "/pause-all"):
            for t in tasks where t.state == .active || t.state == .pending { pause(t.id) }
            return reply(["ok": true])
        case ("POST", "/resume-all"):
            for t in tasks where t.state == .paused { resume(t.id) }
            return reply(["ok": true])
        case ("POST", "/remove-completed"):
            removeCompleted()
            return reply(["ok": true])
        case ("GET", "/queues"):
            return reply(["ok": true, "globalConcurrent": queues.globalConcurrent,
                          "queues": queues.queues.map { q -> [String: Any] in
                              ["name": q.name, "maxConcurrent": q.maxConcurrent,
                               "sequential": q.isSequential,
                               "priority": q.priority, "speedLimit": q.speedLimit,
                               "startHour": q.startHour ?? -1, "endHour": q.endHour ?? -1]
                          }])
        case ("GET", "/config"):
            return reply(configPayload())
        case ("POST", "/config"):
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return reply(["ok": false, "error": "malformed json"])
            }
            if let n = json["globalConcurrent"] as? Int { queues.setGlobalConcurrent(n) }
            if let limit = json["speedLimit"] as? String { applySpeedLimit(limit) }
            if let raw = json["conflictPolicy"] as? String,
               let policy = ConflictPolicy(rawValue: raw) {
                UserDefaults.standard.set(policy.rawValue, forKey: ConflictPolicy.defaultsKey)
            }
            if let dir = json["downloadDirectory"] as? String, !dir.isEmpty {
                downloadDirectory = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath,
                                        isDirectory: true)
            }
            return reply(configPayload())
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
        case ("POST", "/priority"):
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let idString = json["id"] as? String, let id = UUID(uuidString: idString),
                  let priority = json["priority"] as? Int,
                  tasks.contains(where: { $0.id == id }) else {
                return reply(["ok": false, "error": "missing id or priority"])
            }
            setTaskPriority(id, priority)
            return reply(["ok": true])
        default:
            return reply(["ok": false, "error": "not found"])
        }
    }

    private func configPayload() -> [String: Any] {
        ["ok": true, "config": [
            "downloadDirectory": downloadDirectory.path,
            "globalConcurrent": queues.globalConcurrent,
            "speedLimit": speedLimitText,
            "conflictPolicy": ConflictPolicy.current.rawValue
        ]]
    }

    private func handleDetectedURL(_ url: URL, isDefinite: Bool) {
        let notifyMode = UserDefaults.standard.string(forKey: "Siphon.clipboardMode") ?? "notify"
        let filename = url.lastPathComponent.isEmpty ? nil : url.lastPathComponent

        if notifyMode == "auto" {
            // Legacy: auto-create paused task with priority boost for clipboard captures.
            let destination = downloadDirectory.appendingPathComponent(
                url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
            var t = DownloadTask(source: url, destination: destination)
            t.state = .paused
            t.priority = 1
            add(t)
        } else {
            // Default: show notification with download action
            SystemPresence.shared.showClipboardNotification(url: url, filename: filename)
        }
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

    private var tasksBackupURL: URL {
        tasksFileURL.deletingLastPathComponent().appendingPathComponent("tasks.json.bak")
    }

    private func save() {
        let codable = tasks.map { TaskRecord($0, limit: taskSpeedLimits[$0.id]) }
        let d: Data
        do {
            d = try JSONEncoder().encode(codable)
        } catch {
            storeLog.error("task list encoding failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // 覆盖前先把上一份留作备份：写失败或文件损坏时还能回滚。
        if let old = try? Data(contentsOf: tasksFileURL) {
            do {
                try old.write(to: tasksBackupURL, options: .atomic)
            } catch {
                storeLog.error("task list backup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try d.write(to: tasksFileURL, options: .atomic)
        } catch {
            startupError = "任务列表保存失败：\(error.localizedDescription)"
        }
    }

    private func load() {
        var records: [TaskRecord]?
        if let d = try? Data(contentsOf: tasksFileURL),
           let decoded = try? JSONDecoder().decode([TaskRecord].self, from: d) {
            records = decoded
        } else if let d = try? Data(contentsOf: tasksBackupURL),
                  let decoded = try? JSONDecoder().decode([TaskRecord].self, from: d) {
            // 主文件损坏时用备份恢复，并立刻覆盖主文件，避免下次保存把坏文件再备份一次。
            records = decoded
            do {
                try d.write(to: tasksFileURL, options: .atomic)
            } catch {
                storeLog.error("restoring tasks.json from backup failed: \(error.localizedDescription, privacy: .public)")
            }
        } else if let d = UserDefaults.standard.data(forKey: defaultsKey),
                  let decoded = try? JSONDecoder().decode([TaskRecord].self, from: d) {
            // One-time migration from the old UserDefaults blob.
            records = decoded
            save()
        }
        guard let records else {
            // 读不出来时保留现场：不要静默清空列表，并提示用户。
            if FileManager.default.fileExists(atPath: tasksFileURL.path) {
                startupError = "任务列表读取失败，原文件已保留以便排查"
            }
            return
        }
        tasks = records.map { $0.task }
        // Selection is per-session view state; a restored list must not inherit
        // ids the user picked before quitting.
        selectedTaskIDs = []
        // Remember which tasks were mid-flight; `start()` resumes them once
        // engines are ready. Records without the marker (older files) stay paused.
        interruptedIDs = Set(records.filter { $0.wasInterrupted }.map { $0.id })
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
    var priority: Int?
    var boost: Bool?
    var connections: Int?
    var ytdlp: Bool?
    var ytdlpFormat: String?
    var hlsBandwidth: Int?
    /// True when the task was active/pending at save time, i.e. it was interrupted
    /// by an app quit rather than paused by the user.
    var wasActive: Bool?

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
        priority = t.priority != 0 ? t.priority : nil
        boost = t.boost ? true : nil
        connections = t.connections != 8 ? t.connections : nil
        ytdlp = t.ytdlp ? true : nil
        ytdlpFormat = t.ytdlpFormat
        hlsBandwidth = t.hlsBandwidth
        // Only an in-flight task counts as interrupted; an explicit pause or a
        // terminal task must not be auto-restarted on the next launch.
        let inFlight = t.state == .active || t.state == .pending
        wasActive = inFlight ? true : nil
    }

    /// A task that was mid-flight when the app quit. Terminal and user-paused
    /// tasks are excluded even if an old file still carries the marker.
    var wasInterrupted: Bool {
        guard wasActive == true else { return false }
        let savedState = DownloadState(rawValue: state) ?? .paused
        return (savedState == .active || savedState == .pending)
    }

    var task: DownloadTask {
        var t = DownloadTask(id: id, name: name, source: source,
                             destination: destination, queueName: queueName,
                             options: options ?? [:], checksum: checksum,
                             mirrors: mirrors ?? [],
                             pieceHashes: pieceHashes ?? [],
                             pieceLength: pieceLength ?? 0,
                             priority: priority ?? 0,
                             boost: boost ?? false,
                             connections: connections ?? 8,
                             ytdlp: ytdlp ?? false,
                             ytdlpFormat: ytdlpFormat,
                             hlsBandwidth: hlsBandwidth)
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

/// Bridges MDXP JSON-RPC calls back to the main-actor store. The server handler
/// runs on its own queue, so every access hops to the main thread. Use the
/// bounded `runOnMainActor` bridge rather than `DispatchQueue.main.sync`, which
/// can deadlock when the main thread is already waiting on the server queue.
private final class StoreMDXPBackend: MDXPBackend {
    private weak var store: DownloadStore?

    init(store: DownloadStore) {
        self.store = store
    }

    private func onMain<T>(_ body: @escaping @Sendable @MainActor (DownloadStore) -> T) -> T? {
        guard let store else { return nil }
        return runOnMainActor { body(store) }
    }

    private static func payload(_ t: DownloadTask) -> [String: Any] {
        ["id": t.id.uuidString, "name": t.name, "url": t.source.absoluteString,
         "state": t.state.rawValue, "queue": t.queueName,
         "priority": t.priority, "destination": t.destination.path,
         "downloaded": t.progress.downloadedBytes, "total": t.progress.totalBytes,
         "speed": t.progress.speedBytesPerSec, "peers": t.progress.connectedPeers,
         "error": t.errorDescription ?? ""]
    }

    func mdxpTasks() -> [[String: Any]] {
        onMain { store in store.tasks.map(Self.payload) } ?? []
    }

    func mdxpTask(id: String) -> [String: Any]? {
        onMain { store in
            guard let uuid = UUID(uuidString: id),
                  let task = store.tasks.first(where: { $0.id == uuid }) else { return nil }
            return Self.payload(task)
        } ?? nil
    }

    func mdxpAdd(url: String, name: String?, queue: String?, priority: Int?,
                 headers: [String: String]?) -> Bool {
        onMain { store in
            let targetQueue = queue.flatMap {
                store.queues.queue(named: $0) != nil ? $0 : nil
            } ?? "Default"
            store.add(urlString: url, name: name, queueName: targetQueue,
                      options: headers ?? [:], priority: priority ?? 0)
            return true
        } ?? false
    }

    func mdxpPause(id: String) -> Bool {
        onMain { store in
            guard let uuid = UUID(uuidString: id),
                  store.tasks.contains(where: { $0.id == uuid }) else { return false }
            store.pause(uuid)
            return true
        } ?? false
    }

    func mdxpResume(id: String) -> Bool {
        onMain { store in
            guard let uuid = UUID(uuidString: id),
                  store.tasks.contains(where: { $0.id == uuid }) else { return false }
            store.resume(uuid)
            return true
        } ?? false
    }

    func mdxpRemove(id: String) -> Bool {
        onMain { store in
            guard let uuid = UUID(uuidString: id),
                  store.tasks.contains(where: { $0.id == uuid }) else { return false }
            store.remove(uuid)
            return true
        } ?? false
    }

    func mdxpSetPriority(id: String, priority: Int) -> Bool {
        onMain { store in
            guard let uuid = UUID(uuidString: id),
                  store.tasks.contains(where: { $0.id == uuid }) else { return false }
            store.setTaskPriority(uuid, priority)
            return true
        } ?? false
    }

    func mdxpConfig() -> [String: Any] {
        onMain { store in
            ["downloadDirectory": store.downloadDirectory.path,
             "globalConcurrent": store.queues.globalConcurrent,
             "speedLimit": store.speedLimitText,
             "conflictPolicy": ConflictPolicy.current.rawValue,
             "mdxpEnabled": store.mdxpEnabled]
        } ?? [:]
    }
}
