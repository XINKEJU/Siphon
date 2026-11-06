import Foundation
import SwiftUI
import Combine

/// Central, main-actor store. Owns the task list, routes each task to the right engine,
/// and funnels engine callbacks into SwiftUI state.
@MainActor
public final class DownloadStore: ObservableObject, EngineDelegate {
    @Published public var tasks: [DownloadTask] = []
    @Published public var selectedTaskID: UUID?
    @Published public var filter: TaskFilter = .all
    @Published public var aria2Status: String = "未启动"
    /// Prefer this over string-matching `aria2Status`: the human-readable status
    /// text changes, but the readiness flag stays a reliable source of truth.
    @Published public var aria2Ready: Bool = false
    @Published public var startupError: String?
    /// Last link-normalization failure (bad vendor link, missing S3 credentials, …).
    @Published public var lastError: String?
    @Published public var speedLimitText: String = ""
    @Published public var clipboardEnabled = false
    @Published public var browserCaptureEnabled = false
    @Published public var downloadDirectory: URL = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }()

    public let queues = QueueManager()
    public let clipboard = ClipboardMonitor()

    private var engines: [DownloadProtocol: DownloadEngine] = [:]
    private var aria2: Aria2Engine?
    private var nativeMessaging: NativeMessagingServer?
    private let defaultsKey = "Siphon.tasks"
    private enum PrefKey {
        static let clipboard = "Siphon.clipboardEnabled"
        static let browser = "Siphon.browserCaptureEnabled"
    }
    /// Tasks already handed to an engine. Resuming these must call `resume(id)`,
    /// never `submit(task)` again (that would create a duplicate aria2 GID).
    private var submitted: Set<UUID> = []
    private var didStart = false
    private var isScheduling = false
    private var needsReschedule = false

    public enum TaskFilter: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", completed = "已完成", paused = "已暂停"
        public var id: String { rawValue }
    }

    private var cancellables: [AnyCancellable] = []

    public init() {
        load()
        clipboard.onURLDetected = { [weak self] url in
            Task { @MainActor in self?.handleDetectedURL(url) }
        }
        // Forward nested ObservableObject changes so views observing the store refresh.
        cancellables.append(queues.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
        cancellables.append(clipboard.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
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
    }

    /// Integration switches are user preferences, so they must survive relaunch.
    /// Restore through the same setters used by Settings to avoid a second
    /// listener/server instance getting out of sync with the published state.
    private func restoreIntegrations() {
        let d = UserDefaults.standard
        if d.bool(forKey: PrefKey.browser) { setBrowserCaptureEnabled(true) }
        if d.bool(forKey: PrefKey.clipboard) { setClipboardEnabled(true) }
    }

    public func restartAria2() async {
        Aria2Bootstrap.shared.stop()
        await startAria2()
    }

    private func startAria2() async {
        aria2Ready = false
        do {
            try await Aria2Bootstrap.shared.start()
            let engine = Aria2Engine(endpoint: Aria2Bootstrap.shared.rpcURL)
            engine.delegate = self
            engine.startPolling()
            aria2 = engine
            // aria2 handles only the P2P family (BT / Magnet / Metalink / SFTP);
            // every other protocol is owned by the native / curl / system engines.
            for p in engine.supportedProtocols { engines[p] = engine }
            aria2Status = "已连接 aria2（用于 BT/Magnet/Metalink/SFTP）"
            aria2Ready = true
            startupError = nil
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
                    options: [String: String] = [:]) {
        Task {
            await addNormalized(urlString: urlString, name: name,
                                queueName: queueName, options: options)
        }
    }

    /// Resolve vendor links / gateways / playlists, then enqueue one task per URL.
    /// Kept `async` because a playlist or gateway may require a network read.
    public func addNormalized(urlString: String, name: String? = nil,
                              queueName: String = "Default",
                              options: [String: String] = [:]) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
                let destination = downloadDirectory.appendingPathComponent(fileName)
                let task = DownloadTask(name: fileName, source: req.url,
                                        destination: destination,
                                        queueName: queueName, options: req.options,
                                        origin: req.origin, protoOverride: req.proto)
                add(task)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func add(_ task: DownloadTask) {
        tasks.append(task)
        save()
        Task { await schedule() }
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
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
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
        if state.isTerminal { save() }
        Task { await schedule() }
    }

    // MARK: - speed limit
    public func applySpeedLimit(_ text: String) {
        speedLimitText = text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let bytesPerSec: Int64? = trimmed.isEmpty ? nil : Int64(trimmed)
        SpeedLimitController.shared.setLimit(bytesPerSec)
        Task {
            // One engine instance is registered under many protocols; dedupe so
            // we don't send the same RPC 20 times.
            var seen = Set<ObjectIdentifier>()
            for engine in engines.values {
                if seen.insert(ObjectIdentifier(engine)).inserted {
                    await engine.setGlobalSpeedLimit(bytesPerSec)
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
            server.start { [weak self] url in
                Task { @MainActor in self?.add(urlString: url) }
            }
            nativeMessaging = server
        } else {
            nativeMessaging?.stop()
            nativeMessaging = nil
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
    private func save() {
        let codable = tasks.map { TaskRecord($0) }
        guard let d = try? JSONEncoder().encode(codable) else { return }
        UserDefaults.standard.set(d, forKey: defaultsKey)
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([TaskRecord].self, from: d) else { return }
        tasks = records.map { $0.task }
    }
}

private struct TaskRecord: Codable {
    var id: UUID, name: String, source: URL, destination: URL
    var proto: String, state: String, queueName: String
    var downloaded: Int64, total: Int64, error: String?
    var origin: String?

    init(_ t: DownloadTask) {
        id = t.id; name = t.name; source = t.source; destination = t.destination
        proto = t.protocol.rawValue; state = t.state.rawValue; queueName = t.queueName
        downloaded = t.progress.downloadedBytes; total = t.progress.totalBytes
        error = t.errorDescription; origin = t.origin
    }

    var task: DownloadTask {
        var t = DownloadTask(id: id, name: name, source: source,
                             destination: destination, queueName: queueName)
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
