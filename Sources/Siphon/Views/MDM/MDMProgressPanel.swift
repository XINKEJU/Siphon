import SwiftUI
import AppKit

/// MDM shows a separate progress window per active download with three tabs:
/// Status (segment bitmap + connection table), Limiter and Completion.
/// Siphon already exposes segment snapshots and per-task limits; this window
/// is the presentation layer on top of them.
@MainActor
public final class MDMProgressPanelController: NSObject, NSWindowDelegate {
    public static let shared = MDMProgressPanelController()

    private var windows: [UUID: NSWindow] = [:]

    private override init() { super.init() }

    public func show(taskID: UUID, store: DownloadStore) {
        if let panel = windows[taskID] {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let theme = MDMThemeStore.shared
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        if let taskName = store.tasks.first(where: { $0.id == taskID })?.name, !taskName.isEmpty {
            panel.title = "\(taskName) — " + MDMI18n.t("progress.window")
        } else {
            panel.title = MDMI18n.t("progress.window")
        }
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 360)
        panel.delegate = self

        let root = MDMProgressView(taskID: taskID, onClose: { [weak self] in
            self?.hide(taskID: taskID)
        })
        .environment(store)
        .environmentObject(theme)
        let host = NSHostingView(rootView: root)
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        windows[taskID] = panel

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hide(taskID: UUID) {
        guard let panel = windows.removeValue(forKey: taskID) else { return }
        panel.close()
        panel.delegate = nil
    }

    public func hide() {
        let panels = Array(windows.values)
        windows.removeAll()
        for panel in panels {
            panel.close()
            panel.delegate = nil
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow,
              let taskID = windows.first(where: { $0.value === panel })?.key else { return }
        windows.removeValue(forKey: taskID)
        panel.delegate = nil
    }
}

struct MDMProgressView: View {
    @Environment(DownloadStore.self) private var store
    @EnvironmentObject private var theme: MDMThemeStore
    let taskID: UUID
    let onClose: () -> Void
    @State private var tab: Tab = .status
    @State private var limitText = ""
    @State private var torrentSnapshot = TorrentSnapshot()
    @State private var torrentRefreshTask: Task<Void, Never>?

    private enum Tab: String, CaseIterable, Identifiable {
        case status, limiter, completion
        case files, peers, trackers, pieces, general

        var id: String { rawValue }
        var title: String {
            switch self {
            case .status: return MDMI18n.t("progress.status")
            case .limiter: return MDMI18n.t("progress.limiter")
            case .completion: return MDMI18n.t("progress.completion")
            case .files: return MDMI18n.t("torrent.files")
            case .peers: return MDMI18n.t("torrent.peers")
            case .trackers: return MDMI18n.t("torrent.trackers")
            case .pieces: return MDMI18n.t("torrent.pieces")
            case .general: return MDMI18n.t("torrent.general")
            }
        }

        static var torrentTabs: [Tab] { [.files, .peers, .trackers, .pieces, .general] }
        static var normalTabs: [Tab] { [.status, .limiter, .completion] }
    }

    private var task: DownloadTask? { store.tasks.first { $0.id == taskID } }
    private var isTorrent: Bool {
        guard let p = task?.protocol else { return false }
        return p == .bittorrent || p == .magnet || p == .metalink
    }
    private var colorScheme: ColorScheme? {
        switch theme.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        panelContent
            .background(theme.color(.surface))
            .preferredColorScheme(colorScheme)
            .environment(\.layoutDirection, MDMI18n.shared.isRTL ? .rightToLeft : .leftToRight)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(isTorrent ? Tab.torrentTabs : Tab.normalTabs) { item in
                    Button(item.title) { tab = item }
                        .buttonStyle(.plain)
                        .font(theme.font(size: 12, weight: tab == item ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(tab == item ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Button(MDMI18n.t("action.close")) { onClose() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Divider()

            if let task {
                ScrollView {
                    switch tab {
                    case .status: statusTab(task)
                    case .limiter: limiterTab(task)
                    case .completion: completionTab(task)
                    case .files: torrentFilesTab(task)
                    case .peers: torrentPeersTab(task)
                    case .trackers: torrentTrackersTab(task)
                    case .pieces: torrentPiecesTab(task)
                    case .general: torrentGeneralTab(task)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("任务已移除", systemImage: "tray")
            }
        }
        .padding(.bottom, 10)
        .onAppear {
            limitText = store.speedLimitText
            if isTorrent {
                if tab == .status || tab == .limiter || tab == .completion { tab = .files }
                startTorrentRefresh()
            }
        }
        .onDisappear { torrentRefreshTask?.cancel() }
        .onChange(of: isTorrent) { _, newValue in
            if newValue {
                tab = .files
                startTorrentRefresh()
            } else {
                torrentRefreshTask?.cancel()
                if Tab.torrentTabs.contains(tab) { tab = .status }
            }
        }
    }

    private func startTorrentRefresh() {
        torrentRefreshTask?.cancel()
        torrentRefreshTask = Task {
            while !Task.isCancelled {
                let snap = await store.torrentSnapshot(for: taskID)
                if !Task.isCancelled { torrentSnapshot = snap }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func statusTab(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(task.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(MDMStatus(task.state).displayName).font(.caption).foregroundStyle(.secondary)
            }

            ProgressView(value: task.progress.percent)
                .progressViewStyle(.linear)

            HStack(spacing: 18) {
                stat(MDMI18n.t("column.rate"), Formatting.speed(task.progress.speedBytesPerSec))
                stat(MDMI18n.t("column.size"),
                     "\(Formatting.bytes(task.progress.downloadedBytes)) / \(Formatting.bytes(task.progress.totalBytes))")
                stat(MDMI18n.t("column.timeLeft"),
                     Formatting.eta(downloaded: task.progress.downloadedBytes,
                                    total: task.progress.totalBytes,
                                    speed: task.progress.speedBytesPerSec))
            }

            GroupBox(MDMI18n.t("progress.segments")) {
                segmentGrid(task)
            }

            GroupBox(MDMI18n.t("progress.connections")) {
                let snapshot = MDMEngineSnapshot(task: task,
                                                 segments: store.segmentSnapshot(for: task.id))
                if snapshot.connections.isEmpty {
                    Text("该引擎不提供逐连接视图。").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(snapshot.connections) { conn in
                        HStack {
                            Text("#\(conn.index + 1)").font(.caption.monospacedDigit())
                            Text("\(Formatting.bytes(conn.cursor - conn.start)) / \(Formatting.bytes(max(0, conn.end - conn.start)))")
                                .font(.caption.monospacedDigit())
                            Spacer()
                        }
                    }
                }
            }

            HStack {
                Label(MDMI18n.t("progress.resumeCapability"),
                      systemImage: task.state == .completed ? "checkmark.circle" : "arrow.triangle.branch")
                    .font(.caption)
                Spacer()
                if task.state == .active || task.state == .pending {
                    Button(MDMI18n.t("progress.stopAndKeep")) { store.pause(task.id) }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func limiterTab(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("全局限速（字节/秒，留空为不限速）").font(.subheadline.weight(.semibold))
            HStack {
                TextField("例如 1048576", text: $limitText).textFieldStyle(.roundedBorder)
                Button("应用") { store.applySpeedLimit(limitText) }
            }
            Divider()
            Text("此任务").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Button("不限速") { store.setTaskSpeedLimit(task.id, nil) }
                Button("512 KB/s") { store.setTaskSpeedLimit(task.id, 524288) }
                Button("1 MB/s") { store.setTaskSpeedLimit(task.id, 1048576) }
                Button("5 MB/s") { store.setTaskSpeedLimit(task.id, 5242880) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer(minLength: 20)
        }
        .padding(14)
    }

    @ViewBuilder
    private func completionTab(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("全部完成后").font(.subheadline.weight(.semibold))
            Picker("", selection: Binding(
                get: { store.completionAction },
                set: { store.completionAction = $0 }
            )) {
                ForEach(CompletionAction.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Divider()
            HStack {
                Text("连接数").frame(width: 70, alignment: .leading)
                Stepper("\(task.connections)", value: Binding(
                    get: { task.connections },
                    set: { store.setTaskConnections(task.id, $0) }
                ), in: 1...32)
            }
            HStack {
                Text("优先级").frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(
                    get: { task.priority },
                    set: { store.setTaskPriority(task.id, $0) }
                )) {
                    Text("高").tag(1); Text("普通").tag(0); Text("低").tag(-1)
                }
                .pickerStyle(.segmented)
            }
            Spacer(minLength: 20)
        }
        .padding(14)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    // MARK: - Torrent five tabs

    @ViewBuilder
    private func torrentFilesTab(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(MDMI18n.t("torrent.files")).font(.headline)
                Spacer()
                Text(MDMI18n.t("torrent.selectedCount",
                               "\(torrentSnapshot.files.filter(\.selected).count)",
                               "\(torrentSnapshot.files.count)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if torrentSnapshot.files.isEmpty {
                Text(MDMI18n.t("torrent.metadataPending")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(torrentSnapshot.files) { file in
                    HStack {
                        Image(systemName: file.selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(file.selected ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(file.displayName).font(.caption).lineLimit(1)
                            Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(Formatting.bytes(file.length)).font(.caption.monospacedDigit())
                        Text("\(Int(file.progress * 100))%").font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func torrentPeersTab(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(MDMI18n.t("torrent.peers")).font(.headline)
                Spacer()
                Text(MDMI18n.t("torrent.connected", "\(torrentSnapshot.peers.count)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if torrentSnapshot.peers.isEmpty {
                Text(MDMI18n.t("torrent.noPeers")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(torrentSnapshot.peers) { peer in
                    HStack {
                        Text(peer.address).font(.caption.monospaced())
                        Spacer()
                        Text("↓\(Formatting.speed(peer.downloadSpeed)) ↑\(Formatting.speed(peer.uploadSpeed))")
                            .font(.caption.monospacedDigit())
                        Text("\(Int(peer.progress * 100))%").font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func torrentTrackersTab(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MDMI18n.t("torrent.trackers")).font(.headline)
            if torrentSnapshot.trackers.isEmpty {
                Text(MDMI18n.t("torrent.noTrackers")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(torrentSnapshot.trackers) { tracker in
                    HStack {
                        Image(systemName: tracker.status == "working" ? "checkmark.circle" : "circle")
                            .foregroundStyle(tracker.status == "working" ? .green : .secondary)
                        Text(tracker.url).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(tracker.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func torrentPiecesTab(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(MDMI18n.t("torrent.pieces")).font(.headline)
                Spacer()
                Text("\(torrentSnapshot.pieces.filter { $0.state == .complete }.count)/\(torrentSnapshot.numPieces)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if torrentSnapshot.pieces.isEmpty {
                Text(MDMI18n.t("torrent.noPieces")).font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 32), spacing: 1) {
                    ForEach(torrentSnapshot.pieces) { piece in
                        Rectangle()
                            .fill(piece.state == .complete ? Color.green : Color.secondary.opacity(0.2))
                            .frame(height: 8)
                    }
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func torrentGeneralTab(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(MDMI18n.t("torrent.transfer")) {
                VStack(alignment: .leading, spacing: 8) {
                    statRow(MDMI18n.t("torrent.name"), torrentSnapshot.name.isEmpty ? task.name : torrentSnapshot.name)
                    statRow(MDMI18n.t("torrent.infoHash"), torrentSnapshot.infoHash ?? "—")
                    statRow(MDMI18n.t("torrent.size"), Formatting.bytes(torrentSnapshot.totalSize))
                    statRow(MDMI18n.t("torrent.downloaded"), Formatting.bytes(torrentSnapshot.downloaded))
                    statRow(MDMI18n.t("torrent.uploaded"), Formatting.bytes(torrentSnapshot.uploaded))
                    statRow(MDMI18n.t("torrent.shareRatio"), String(format: "%.2f", torrentSnapshot.shareRatio))
                    statRow(MDMI18n.t("torrent.downSpeed"), Formatting.speed(torrentSnapshot.downloadSpeed))
                    statRow(MDMI18n.t("torrent.upSpeed"), Formatting.speed(torrentSnapshot.uploadSpeed))
                    statRow(MDMI18n.t("torrent.seeders"), "\(torrentSnapshot.seeders) / \(torrentSnapshot.leechers)")
                }
            }

            GroupBox(MDMI18n.t("torrent.options")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(MDMI18n.t("torrent.sequential"), isOn: Binding(
                        get: { torrentSnapshot.isSequential },
                        set: { newValue in
                            Task { try? await store.setTorrentSequential(taskID, enabled: newValue) }
                        }
                    ))
                    HStack {
                        Button(MDMI18n.t("torrent.recheck")) {
                            Task { try? await store.recheckTorrent(taskID) }
                        }
                        Spacer()
                        if !(store.torrentBackend?.supportsPerTaskUploadLimit ?? false) {
                            Text(MDMI18n.t("torrent.perTaskUploadNote"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).lineLimit(1).truncationMode(.middle)
        }
    }

    /// Segment bitmap: one cell per 1/64 of the file, filled according to the
    /// engine's real segment cursors. MDM uses the same visualisation.
    private func segmentGrid(_ task: DownloadTask) -> some View {
        let cells = 64
        let segments = store.segmentSnapshot(for: task.id)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 16),
                         spacing: 2) {
            ForEach(0..<cells, id: \.self) { index in
                let fraction = Self.cellFraction(index: index, cells: cells,
                                                 task: task, segments: segments)
                Rectangle()
                    .fill(fraction >= 1 ? Color(nsColor: .systemGreen)
                          : fraction > 0 ? Color(nsColor: .systemOrange)
                          : Color.secondary.opacity(0.18))
                    .frame(height: 10)
                    .cornerRadius(1)
            }
        }
    }

    private static func cellFraction(index: Int, cells: Int,
                                     task: DownloadTask,
                                     segments: [SegmentSnapshot]) -> Double {
        guard task.progress.totalBytes > 0 else { return 0 }
        let lo = Double(index) / Double(cells)
        let hi = Double(index + 1) / Double(cells)
        if segments.isEmpty {
            return Double(index) / Double(cells) < task.progress.percent ? 1 : 0
        }
        let total = Double(max(1, task.progress.totalBytes))
        var covered = 0.0
        for seg in segments where seg.knownEnd {
            let s = Double(seg.start) / total
            let e = Double(seg.end + 1) / total
            covered += max(0, min(hi, e) - max(lo, s)) * seg.fraction
        }
        return min(1, covered)
    }
}
