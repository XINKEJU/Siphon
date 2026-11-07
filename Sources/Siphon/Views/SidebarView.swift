import SwiftUI
import AppKit

/// Sidebar entries: built-in smart folders plus user-defined queues.
enum SidebarItem: Hashable {
    case all, downloading, completed, paused
    case queue(String)

    var title: String {
        switch self {
        case .all: return "全部任务"
        case .downloading: return "进行中"
        case .completed: return "已完成"
        case .paused: return "已暂停"
        case .queue(let name): return name
        }
    }
}

struct SidebarView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var selection: SidebarItem
    @State private var showingNewQueue = false
    @State private var newQueueName = ""
    @State private var queueToDelete: DownloadQueue?

    var body: some View {
        List(selection: $selection) {
            Section("资料库") {
                row("全部任务", "tray.full", .all, count: store.tasks.count)
                row("进行中", "arrow.down.circle", .downloading,
                    count: store.tasks.filter { $0.state == .active || $0.state == .pending }.count)
                row("已完成", "checkmark.circle", .completed,
                    count: store.tasks.filter { $0.state == .completed }.count)
                row("已暂停", "pause.circle", .paused,
                    count: store.tasks.filter { $0.state == .paused }.count)
            }

            Section("队列") {
                ForEach(store.queues.queues) { q in
                    row(q.name, q.isSequential ? "list.number" : "square.stack.3d.up",
                        .queue(q.name),
                        count: store.tasks.filter { $0.queueName == q.name }.count)
                        .contextMenu {
                            // The Default queue anchors task reassignment and cannot go away.
                            if q.name != "Default" {
                                Button("删除队列…", role: .destructive) { queueToDelete = q }
                            }
                        }
                }
                Button {
                    showingNewQueue = true
                } label: {
                    Label("新建队列", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .softScrollTopEdge()
        .frame(minWidth: 190)
        .safeAreaInset(edge: .bottom) {
            // The sidebar itself IS the system glass panel on macOS 26+.
            // Painting another glass card on top of it double-composites, so
            // this footer is plain content: destination + engine status.
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    NSWorkspace.shared.open(store.downloadDirectory)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("下载位置")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(store.downloadDirectory.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("在访达中打开下载目录")

                Divider()

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 6, height: 6)
                    Text(shortStatus)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Formatting.speed(store.aggregateSpeed))
                        .font(.caption2.monospacedDigit())
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .foregroundStyle(.secondary)
                .help("\(store.aria2Status) · 总速度 \(Formatting.speed(store.aggregateSpeed))")

                if let e = store.startupError {
                    Button { Task { await store.restartAria2() } } label: {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("点击重试启动 aria2")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .alert("新建队列", isPresented: $showingNewQueue) {
            TextField("队列名称", text: $newQueueName)
            Button("取消", role: .cancel) { newQueueName = "" }
            Button("创建") {
                let n = newQueueName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { store.queues.add(name: n) }
                newQueueName = ""
            }
        } message: {
            Text("队列可设置并发数、顺序模式和下载时段。")
        }
        .alert("删除队列“\(queueToDelete?.name ?? "")”？", isPresented: Binding(
            get: { queueToDelete != nil },
            set: { if !$0 { queueToDelete = nil } })) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let q = queueToDelete {
                    if case .queue(let n) = selection, n == q.name { selection = .all }
                    store.deleteQueue(id: q.id)
                }
                queueToDelete = nil
            }
        } message: {
            Text("队列内的任务将移回 Default 队列，任务本身不受影响。")
        }
    }

    private var statusTint: Color {
        store.aria2Status == "已停止" || store.aria2Status == "aria2 不可用"
            ? .red : .green
    }

    /// The store appends the RPC endpoint ("已连接 (127.0.0.1:6800)");
    /// the footer only has room for the short state, full text is the tooltip.
    private var shortStatus: String {
        guard let r = store.aria2Status.range(of: " (") else { return store.aria2Status }
        return String(store.aria2Status[..<r.lowerBound])
    }

    @ViewBuilder
    private func row(_ title: String, _ icon: String, _ item: SidebarItem,
                     count: Int) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .tag(item)
    }
}
