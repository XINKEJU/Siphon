import SwiftUI
import AppKit

/// Inspector column: an opaque grouped form. The inspector sits beside the
/// system's glass sidebar, so adding another custom glass surface here would
/// double-composite; header, rows and numbers stay plain and crisp.
struct TaskDetailView: View {
    @Environment(DownloadStore.self) private var store
    let task: DownloadTask
    @State private var previewTask: DownloadTask?

    var body: some View {
        VStack(spacing: 0) {
            identityCard
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            Form {
                Section("进度") {
                    LabeledContent("状态", value: task.state.displayName)
                    ProgressView(value: task.progress.percent)
                    LabeledContent("已完成", value: Formatting.percent(task.progress.percent))
                    LabeledContent("大小", value: "\(Formatting.bytes(task.progress.downloadedBytes)) / \(Formatting.bytes(task.progress.totalBytes))")
                    LabeledContent("速度", value: Formatting.speed(task.progress.speedBytesPerSec))
                    LabeledContent("剩余时间", value: Formatting.eta(downloaded: task.progress.downloadedBytes,
                                                                 total: task.progress.totalBytes,
                                                                 speed: task.progress.speedBytesPerSec))
                    if task.progress.connectedPeers > 0 {
                        LabeledContent("连接数", value: "\(task.progress.connectedPeers)")
                    }
                    if task.state == .completed {
                        Button {
                            store.openWithDefaultApp(task)
                        } label: {
                            Label("用默认应用打开", systemImage: "arrow.up.forward.app")
                        }
                    } else if store.isPreviewable(task) {
                        Button {
                            previewTask = task
                        } label: {
                            Label("边下边播", systemImage: "play.rectangle.fill")
                        }
                    }
                }

                if task.protocol == .bittorrent || task.protocol == .magnet {
                    BTFilesSection(task: task)
                }

                if task.state == .active,
                   task.protocol.transport == .native,
                   task.protocol != .hls, task.protocol != .dash, task.protocol != .ed2k {
                    Section("分段") {
                        SegmentBars(taskID: task.id)
                        Text("每段颜色越满表示越接近完成；慢速段的尾部会被其他连接“偷取”并重新划分。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Section("引擎选项") {
                    Toggle("独占带宽（Boost）", isOn: Binding(
                        get: { task.boost },
                        set: { store.setBoost(task.id, $0) }))
                    Text("开启后其他活动任务会暂时让位暂停，本任务结束后自动恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper(value: Binding(
                        get: { task.connections },
                        set: { store.setTaskConnections(task.id, $0) }), in: 1...32) {
                        Text("并发连接：\(task.connections)")
                    }
                    if task.connections > 16 {
                        Text("并发超过 16 可能被服务器限流或拒绝（403 / 429），建议保持在 8 左右。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("连接数与画质修改会在下一次开始或续传时生效。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                if task.protocol == .hls {
                    HLSQualitySection(task: task)
                }

                Section("任务信息") {
                    LabeledContent("队列", value: task.queueName)
                    Picker("优先级", selection: Binding(
                        get: { task.priority },
                        set: { store.setTaskPriority(task.id, $0) })) {
                        Text("低").tag(-1)
                        Text("普通").tag(0)
                        Text("高").tag(1)
                    }
                    LabeledContent("引擎", value: task.ytdlp ? "yt-dlp" : task.protocol.transport.displayName)
                    if task.ytdlp {
                        LabeledContent("下载画质", value: task.ytdlpFormat ?? "自动")
                    }
                    LabeledContent("创建时间", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("来源（规范化后）").font(.caption).foregroundStyle(.secondary)
                        Text(task.source.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    if let origin = task.origin, origin != task.source.absoluteString {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("原始链接").font(.caption).foregroundStyle(.secondary)
                            Text(origin)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.middle)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标").font(.caption).foregroundStyle(.secondary)
                        Text(task.destination.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if store.checksumUnverified.contains(task.id) {
                        Text("校验和未验证：目标为目录、多文件产物或文件缺失，没有单一文件可校验。")
                            .font(.caption).foregroundStyle(.orange)
                    } else if let e = task.errorDescription {
                        Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 280)
        .sheet(item: $previewTask) { task in
            StreamingPreviewView(task: task)
        }
        // No nested toolbar: a second .toolbar here injects an ungrouped item
        // into the window's unified toolbar. "在访达中显示所选文件" lives in
        // ContentView's More menu instead.
    }

    private var identityCard: some View {        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        ProtocolBadge(proto: task.protocol)
                        Text(task.state.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

/// Multi-file torrent selection (aria2 `getFiles` + `select-file`). Files exist
/// only after BT metadata resolution — for magnets that means the task must
/// have started once. The selection applies live on a running download.
private struct BTFilesSection: View {
    @Environment(DownloadStore.self) private var store
    let task: DownloadTask

    @State private var files: [Aria2Engine.BTFile] = []
    @State private var checked: Set<Int> = []
    @State private var loaded = false
    @State private var status: String?
    @State private var loading = false

    var body: some View {
        Section("BT 文件选择") {
            if loading {
                ProgressView().controlSize(.small)
            } else if files.isEmpty {
                Text(loaded ? "暂无文件列表（磁力任务需先启动一次以获取元数据）"
                            : "尚未加载，任务启动后可获取文件列表")
                    .font(.caption).foregroundStyle(.secondary)
                Button("加载文件列表") { Task { await load() } }
            } else {
                ForEach(files) { f in
                    Toggle(isOn: binding(for: f.index)) {
                        HStack {
                            Text(f.displayName).lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Formatting.bytes(f.length))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("全选") { checked = Set(files.map(\.index)) }
                        .disabled(checked.count == files.count)
                    Button("应用选择") { Task { await apply() } }
                        .disabled(checked.isEmpty)
                    if let s = status, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
                Text("取消勾选的文件不会下载；对已完成的文件无效。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(get: { checked.contains(index) },
                set: { if $0 { checked.insert(index) } else { checked.remove(index) } })
    }

    private func load() async {
        loading = true
        let list = await store.btFiles(for: task.id)
        files = list
        checked = Set(list.filter(\.selected).map(\.index))
        loaded = true
        loading = false
    }

    private func apply() async {
        let ok = await store.applyBTFileSelection(task.id, indexes: checked.sorted())
        status = ok ? "已应用" : "应用失败（需至少选择一个文件，且元数据已加载）"
        if ok { await load() }
    }
}

/// HLS 主播放列表的画质档位（借鉴 FluxDown `select_hls_quality`）：
/// 读取所有 `EXT-X-STREAM-INF` 变体，按 BANDWIDTH 让用户选择；改动在下次续传生效。
private struct HLSQualitySection: View {
    @Environment(DownloadStore.self) private var store
    let task: DownloadTask
    @State private var variants: [(url: URL, bandwidth: Int)] = []
    @State private var loading = false

    var body: some View {
        Section("HLS 画质") {
            if loading {
                ProgressView().controlSize(.small)
            } else if variants.isEmpty {
                Text(task.hlsBandwidth == nil
                     ? "最高画质（未发现多档变体）"
                     : "已选 \(Self.label(task.hlsBandwidth ?? 0))，但播放列表当前未提供多档变体")
                    .font(.caption).foregroundStyle(.secondary)
                Button("读取画质列表") { Task { await load() } }
            } else {
                Picker("画质", selection: Binding(
                    get: { task.hlsBandwidth },
                    set: { store.setHLSBandwidth(task.id, $0) })) {
                    Text("最高（自动）").tag(Int?.none)
                    ForEach(Array(variants.enumerated()), id: \.offset) { _, v in
                        Text(Self.label(v.bandwidth)).tag(Int?.some(v.bandwidth))
                    }
                }
                Text("切换后在下一次开始或续传时生效。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .task(id: task.id) { await load() }
    }

    private func load() async {
        loading = true
        variants = await store.hlsVariants(for: task)
        loading = false
    }

    private static func label(_ bandwidth: Int) -> String {
        bandwidth > 0 ? String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000)
                      : "未知码率"
    }
}

/// 分段条形图：每 0.5 秒从引擎拉一次快照（引擎不推送分段事件）。
private struct SegmentBars: View {
    @Environment(DownloadStore.self) private var store
    let taskID: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let segments = store.segmentSnapshot(for: taskID).filter(\.knownEnd)
            if segments.isEmpty {
                Text("等待分段数据…").font(.caption).foregroundStyle(.secondary)
            } else {
                let total = max(1, segments.reduce(0) { $0 + Double($1.span) })
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(segments) { s in
                            let width = max(2, geo.size.width * Double(s.span) / total)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.15))
                                Capsule().fill(Color.accentColor)
                                    .frame(width: width * s.fraction)
                            }
                            .frame(width: width)
                        }
                    }
                }
                .frame(height: 10)
                LabeledContent("活动分段", value: "\(segments.count)")
            }
        }
    }
}
