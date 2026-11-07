import SwiftUI
import AppKit

/// 通用 tab（下载位置 / 并发 / 自动化）。
struct GeneralSettingsView: View {
    @Environment(DownloadStore.self) private var store
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var stats = TransferStats.shared

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
            Section("后台运行") {
                Toggle("关闭窗口后继续运行", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "Siphon.backgroundRun") },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.backgroundRun") }))
                Text("开启后关闭主窗口不会退出下载，可从菜单栏图标重新打开。")
                    .font(.caption).foregroundStyle(.tertiary)

                Toggle("仅显示菜单栏（隐藏 Dock 图标）", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "Siphon.menuBarOnly") },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: "Siphon.menuBarOnly")
                        if on {
                            UserDefaults.standard.set(true, forKey: "Siphon.backgroundRun")
                        }
                        NSApp.setActivationPolicy(on ? .accessory : .regular)
                    }))
                Text("菜单栏图标始终可用：显示主窗口、全部暂停/恢复、打开下载目录、偏好设置与退出。")
                    .font(.caption).foregroundStyle(.tertiary)

                Toggle("开机自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            try LaunchAtLogin.setEnabled(on)
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchError = nil
                        } catch {
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchError = error.localizedDescription
                        }
                    }))
                Text(LaunchAtLogin.statusText)
                    .font(.caption).foregroundStyle(.tertiary)
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("文件处理") {
                Picker("同名文件", selection: Binding(
                    get: { ConflictPolicy.current },
                    set: { UserDefaults.standard.set($0.rawValue, forKey: ConflictPolicy.defaultsKey) })) {
                    ForEach(ConflictPolicy.allCases) { Text($0.label).tag($0) }
                }
                Text("自动重命名：保留两份文件；跳过：不新建任务；覆盖：先删除同名文件再下载。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("并发") {
                Stepper(value: Binding(
                    get: { store.queues.globalConcurrent },
                    set: {
                        store.queues.setGlobalConcurrent($0)
                        store.refreshQueueLimits()
                    }), in: 1...20) {
                    Text("全局最大同时下载：\(store.queues.globalConcurrent)")
                }
                Text("每个队列还可单独设置并发数与下载时段（见「队列」标签页）。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("传输统计") {
                LabeledContent("今日", value: "\(Formatting.bytes(stats.todayBytes)) · \(stats.todayCompleted) 个完成")
                LabeledContent("近 7 天", value: Formatting.bytes(stats.last7DaysBytes))
                LabeledContent("累计", value: "\(Formatting.bytes(stats.totalBytes)) · \(stats.totalCompleted) 个完成")
                Text("按天累计并持久化在本地，保留最近 90 天。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("自动化") {
                Toggle("启动时自动恢复未完成任务", isOn: Binding(
                    get: {
                        let d = UserDefaults.standard
                        return d.object(forKey: "Siphon.autoResumeInterrupted") == nil
                            || d.bool(forKey: "Siphon.autoResumeInterrupted")
                    },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.autoResumeInterrupted") }))
                Text("退出时正在下载的任务会在下次启动后自动继续，并从已完成的进度续传（aria2 会话 / HTTP 断点 / HLS·DASH 分段）。")
                    .font(.caption).foregroundStyle(.tertiary)

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
                Button("从列表清除已完成任务") { store.removeCompleted() }
            }
        }
        .formStyle(.grouped)
    }
}
