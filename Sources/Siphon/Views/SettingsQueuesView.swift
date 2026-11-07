import SwiftUI

/// 队列 tab：并发、顺序、优先级、队列总限速与时段。
/// 编辑先落在本地草稿，变更后整体提交，避免每个按键都触发磁盘写入。
struct SettingsQueuesView: View {
    @Environment(DownloadStore.self) private var store
    @State private var draft: [DownloadQueue] = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section("全局") {
                Stepper(value: Binding(
                    get: { store.queues.globalConcurrent },
                    set: {
                        store.queues.setGlobalConcurrent($0)
                        store.refreshQueueLimits()
                    }), in: 1...20) {
                    Text("全局最大同时下载：\(store.queues.globalConcurrent)")
                }
                Text("所有队列共享这一上限；每个队列另有自己的并发数与时段。")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section("队列") {
                ForEach(draft) { queue in
                    QueueEditorRow(queue: Binding(
                        get: { draft.first(where: { $0.id == queue.id }) ?? queue },
                        set: { updated in
                            if let i = draft.firstIndex(where: { $0.id == updated.id }) {
                                draft[i] = updated
                            }
                        }), onDelete: {
                            guard draft.count > 1 else { return }
                            // Route through the store: tasks in the queue must be
                            // moved back to Default before the definition vanishes.
                            store.deleteQueue(id: queue.id)
                            draft.removeAll { $0.id == queue.id }
                        }, canDelete: queue.name != "Default")
                }
                if draft.isEmpty {
                    Text("尚无队列，点击下方按钮创建。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("新增队列") {
                    draft.append(DownloadQueue(name: "新队列", maxConcurrent: 3,
                                               priority: 0, speedLimit: 0))
                }
            }

            Section {
                Text("调度顺序：任务优先级（高→低）→ 队列优先级（高→低）→ 创建时间。队列总限速会平均分配给该队列内所有活动任务；单任务限速仍可再压低。时段支持跨零点，例如 23 点至 7 点。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            draft = store.queues.queues
            loaded = true
        }
        .onChange(of: draft) { _, newValue in
            guard loaded else { return }
            store.queues.replaceAll(newValue)
            store.refreshQueueLimits()
        }
    }
}

private struct QueueEditorRow: View {
    @Binding var queue: DownloadQueue
    let onDelete: () -> Void
    var canDelete: Bool = true

    var body: some View {
        DisclosureGroup {
            TextField("队列名称", text: $queue.name)
                .textFieldStyle(.roundedBorder)
            Stepper(value: $queue.maxConcurrent, in: 1...20) {
                Text("并发数：\(queue.maxConcurrent)")
            }
            Toggle("顺序下载（同一时间只跑一个）", isOn: $queue.isSequential)
            Picker("队列优先级", selection: $queue.priority) {
                Text("低").tag(-1)
                Text("普通").tag(0)
                Text("高").tag(1)
            }
            Stepper(value: $queue.speedLimit,
                    in: 0...(100 * 1024 * 1024),
                    step: 1024) {
                Text(queue.speedLimit > 0
                     ? "队列总限速：\(queue.speedLimit / 1024) KB/s"
                     : "队列总限速：不限")
            }
            HStack {
                TextField("开始小时（0–23，留空不限）", text: hourBinding(\.startHour))
                    .textFieldStyle(.roundedBorder)
                TextField("结束小时（0–23）", text: hourBinding(\.endHour))
                    .textFieldStyle(.roundedBorder)
            }
            Text("时段外队列内的待下载任务不会启动；支持跨零点（如 23–7）。")
                .font(.caption2).foregroundStyle(.tertiary)
        } label: {
            HStack {
                Text(queue.name.isEmpty ? "未命名队列" : queue.name)
                Spacer()
                Text("并发 \(queue.maxConcurrent)")
                    .font(.caption).foregroundStyle(.secondary)
                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func hourBinding(_ keyPath: WritableKeyPath<DownloadQueue, Int?>) -> Binding<String> {
        Binding(get: { queue[keyPath: keyPath].map(String.init) ?? "" },
                set: { queue[keyPath: keyPath] = $0.isEmpty ? nil : Int($0) })
    }
}
