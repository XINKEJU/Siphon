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
        let scale = CGFloat(theme.scale)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520 * scale, height: 460 * scale),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        if let taskName = store.tasks.first(where: { $0.id == taskID })?.name, !taskName.isEmpty {
            panel.title = "\(taskName) — Download progress"
        } else {
            panel.title = "Download progress"
        }
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420 * scale, height: 360 * scale)
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

    private enum Tab: String, CaseIterable, Identifiable {
        case status, limiter, completion
        var id: String { rawValue }
        var title: String {
            switch self {
            case .status: return MDMI18n.t("progress.status")
            case .limiter: return MDMI18n.t("progress.limiter")
            case .completion: return MDMI18n.t("progress.completion")
            }
        }
    }

    private var task: DownloadTask? { store.tasks.first { $0.id == taskID } }
    private var colorScheme: ColorScheme? {
        switch theme.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = CGFloat(theme.scale)
            panelContent
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(theme.color(.surface))
        .preferredColorScheme(colorScheme)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { item in
                    Button(item.title) { tab = item }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
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
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("任务已移除", systemImage: "tray")
            }
        }
        .padding(.bottom, 10)
        .onAppear { limitText = store.speedLimitText }
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
