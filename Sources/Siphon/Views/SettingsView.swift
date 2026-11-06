import SwiftUI
import AppKit

/// Settings scene (⌘,). macOS convention: tabs/panes, no "Save" button — changes
/// apply immediately, destructive actions are clearly separated. Glass is used
/// for the small status/identity cards and grouped quick-action buttons only.
struct SettingsView: View {
    @EnvironmentObject private var store: DownloadStore
    @State private var limitText = ""
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("通用", systemImage: "gear") }.tag(0)
            speedTab.tabItem { Label("速度", systemImage: "speedometer") }.tag(1)
            integrationTab.tabItem { Label("集成", systemImage: "link") }.tag(2)
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }.tag(3)
        }
        .frame(width: 540, height: 380)
        .padding()
        .onAppear { limitText = store.speedLimitText }
    }

    // MARK: - General
    private var generalTab: some View {
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
            Section {
                Button("清除已完成任务", role: .destructive) { store.removeCompleted() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Speed
    private var speedTab: some View {
        Form {
            Section("全局限速") {
                HStack {
                    TextField("字节/秒", text: $limitText, prompt: Text("留空为不限速"))
                        .textFieldStyle(.roundedBorder)
                    Button("应用") { store.applySpeedLimit(limitText) }
                }
                Text("同时作用于 aria2（--max-overall-download-limit）与原生 HLS/DASH 引擎（令牌桶）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("快速设置") {
                GlassGroup(spacing: 8) {
                    ForEach(["", "524288", "1048576", "5242880"], id: \.self) { v in
                        Button(v.isEmpty ? "不限速" : Formatting.speed(Int64(v) ?? 0)) {
                            limitText = v
                            store.applySpeedLimit(v)
                        }
                        .controlSize(.small)
                        .glassButton()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Integrations
    private var integrationTab: some View {
        Form {
            Section("剪贴板监听") {
                Toggle("自动捕获复制的下载链接", isOn: Binding(
                    get: { store.clipboardEnabled },
                    set: { store.setClipboardEnabled($0) }))
                Text("捕获后以「已暂停」状态添加，需手动确认开始。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("浏览器与脚本") {
                Toggle("启用本地控制接口", isOn: Binding(
                    get: { store.browserCaptureEnabled },
                    set: { store.setBrowserCaptureEnabled($0) }))
                HStack {
                    Text("http://127.0.0.1:\(NativeMessagingServer.port)/add")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                }
                Text("POST {\"url\": \"…\"} 即可添加任务；浏览器扩展可通过 host_permissions 调用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("aria2 引擎") {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.aria2Status == "已停止" || store.aria2Status == "aria2 不可用"
                              ? Color.red : Color.green)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("引擎状态")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(store.aria2Status).font(.body)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .glassCard(cornerRadius: 12)

                Text("应用需捆绑 aria2c 二进制（放到 App Bundle 的 Resources 或 ~/Library/Application Support/Siphon/）。")
                    .font(.caption).foregroundStyle(.secondary)
                GlassGroup(spacing: 8) {
                    Button("重新启动引擎") { store.restartAria2() }
                        .controlSize(.small)
                        .glassButton()
                    Button("停止引擎", role: .destructive) { store.stop() }
                        .controlSize(.small)
                        .glassButton()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About
    private var aboutTab: some View {
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                // The real bundled app icon, not a placeholder SF Symbol.
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Siphon").font(.title2.weight(.semibold))
                Text("原生 macOS 全协议下载管理器")
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider().frame(width: 260)
                VStack(alignment: .leading, spacing: 6) {
                    Text("下载内核：aria2（独立进程，JSON-RPC）")
                    Text("原生补充：HLS · DASH · eD2K 哈希与链接解析")
                    Text("界面：SwiftUI · Liquid Glass（macOS 26+）")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .glassCard(cornerRadius: 20)

            Spacer()
            Text("aria2 采用 GPLv2；以独立进程调用，不链接其库。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
    }
}
