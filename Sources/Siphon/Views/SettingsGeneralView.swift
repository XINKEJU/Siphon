import SwiftUI
import AppKit

/// 通用 tab（下载位置 / 并发 / 自动化）。
struct GeneralSettingsView: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        Form {
            Section("下载位置") {
                HStack {
                    Text(store.downloadDirectory.path)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("更改…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { store.downloadDirectory = u }
                    }
                }
            }
            Section("并发") {
                Stepper(value: Binding(
                    get: { store.queues.globalConcurrent },
                    set: { store.queues.globalConcurrent = $0 }), in: 1...20) {
                    Text("全局最大同时下载：\(store.queues.globalConcurrent)")
                }
                Text("每个队列还可单独设置并发数与下载时段。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("自动化") {
                Toggle("按类型自动归类子文件夹", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "Siphon.autoCategorize") },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.autoCategorize") }))
                Text("开启后新任务按视频 / 音频 / 文档 / 压缩包 / 镜像等自动放入子目录。")
                    .font(.caption).foregroundStyle(.tertiary)

                Toggle("下载文件标记隔离属性（macOS Gatekeeper）", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "Siphon.quarantineDownloads") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.quarantineDownloads") }))
                Text("开启后，下载完成的文件会写入 com.apple.quarantine 扩展属性，首次打开时被系统提示安全警告（与 Safari / Chrome 一致）。")
                    .font(.caption).foregroundStyle(.tertiary)

                Toggle("多网卡聚合下载", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "Siphon.multiNic") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.multiNic") }))
                Text("检测到 ≥2 个可用网络接口时，≥256 MB 的 HTTP 下载由第二接口（curl 绑定）并行拉取文件后半段，失败自动回退单路。实际分流取决于系统路由表（如有线 + Wi-Fi 双默认路由）。")
                    .font(.caption).foregroundStyle(.tertiary)

                Toggle("定时下载时段", isOn: Binding(
                    get: { store.scheduleWindow.enabled },
                    set: { store.scheduleWindow.enabled = $0 }))
                if store.scheduleWindow.enabled {
                    HStack {
                        TextField("开始 HH:mm", text: Binding(
                            get: { store.scheduleWindow.start },
                            set: { store.scheduleWindow.start = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Text("至").foregroundStyle(.secondary)
                        TextField("结束 HH:mm", text: Binding(
                            get: { store.scheduleWindow.end },
                            set: { store.scheduleWindow.end = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("时段外自动暂停（支持跨零点，如 22:00–07:00），时段内自动恢复。每 15 秒检查一次。")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                Picker("全部完成后", selection: Binding(
                    get: { store.completionAction },
                    set: { store.completionAction = $0 })) {
                    ForEach(CompletionAction.allCases) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
                Text("任务全部进入终态时执行一次；仅当选「无」以外选项时生效。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section {
                Button("清除已完成任务", role: .destructive) { store.removeCompleted() }
            }
        }
        .formStyle(.grouped)
    }
}
