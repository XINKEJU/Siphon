import SwiftUI

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
    @EnvironmentObject private var store: DownloadStore
    @Binding var selection: SidebarItem
    @State private var showingNewQueue = false
    @State private var newQueueName = ""

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
        .frame(minWidth: 190)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text(store.downloadDirectory.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
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
