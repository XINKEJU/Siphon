import SwiftUI
import AppKit

/// Settings scene (⌘,). macOS convention: tabs/panes, no "Save" button — changes
/// apply immediately, destructive actions are clearly separated. Glass is used
/// for the small status/identity cards and grouped quick-action buttons only.
struct SettingsView: View {
    @EnvironmentObject private var store: DownloadStore
    @State private var limitText = ""
    @State private var selectedTab = 0

    // Protocol gateways
    @State private var ipfsGateway = ""
    @State private var s3Endpoint = ""
    @State private var s3Region = ""
    @State private var s3AccessKey = ""
    @State private var s3SecretKey = ""
    @State private var s3UseHTTPS = true
    @State private var curlPath = ""
    @State private var settingsSaved = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("通用", systemImage: "gear") }.tag(0)
            speedTab.tabItem { Label("速度", systemImage: "speedometer") }.tag(1)
            integrationTab.tabItem { Label("集成", systemImage: "link") }.tag(2)
            gatewayTab.tabItem { Label("协议网关", systemImage: "network") }.tag(3)
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }.tag(4)
        }
        .frame(width: 560, height: 440)
        .padding()
        .onAppear {
            limitText = store.speedLimitText
            loadGatewaySettings()
        }
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
            Section("P2P 引擎（aria2，随应用打包）") {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.aria2Ready ? Color.green : Color.red)
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

                Text("aria2c 随应用打包（GPLv2，独立进程），仅用于 BitTorrent / Magnet / Metalink / SFTP。HTTP/HTTPS/FTP、eD2K 等由原生 Swift 引擎处理，无需任何外部依赖。")
                    .font(.caption).foregroundStyle(.secondary)
                GlassGroup(spacing: 8) {
                    Button("重新启动引擎") { Task { await store.restartAria2() } }
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

    // MARK: - Protocol gateways
    private var gatewayTab: some View {
        Form {
            Section("IPFS / IPNS 网关") {
                TextField("网关地址", text: $ipfsGateway,
                          prompt: Text("https://ipfs.io 或 http://127.0.0.1:8080"))
                    .textFieldStyle(.roundedBorder)
                Text("ipfs:// 与 ipns:// 会重写为 <网关>/ipfs/<CID> 后交给原生 HTTP 引擎拉取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("S3 兼容对象存储") {
                TextField("Endpoint（仅主机名）", text: $s3Endpoint,
                          prompt: Text("s3.amazonaws.com / localhost:9000"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Region", text: $s3Region, prompt: Text("us-east-1"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Access Key", text: $s3AccessKey)
                        .textFieldStyle(.roundedBorder)
                }
                SecureField("Secret Key（存入钥匙串）", text: $s3SecretKey)
                    .textFieldStyle(.roundedBorder)
                Toggle("使用 HTTPS", isOn: $s3UseHTTPS)
                Text("s3://bucket/key 会生成 AWS SigV4 预签名 URL。兼容 AWS S3、MinIO、Cloudflare R2、Wasabi、Backblaze B2。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("libcurl") {
                TextField("curl 可执行文件", text: $curlPath)
                    .textFieldStyle(.roundedBorder)
                Text("用于 FTPS / SMB / TFTP / Gopher / RTSP 等协议。留空则使用 /usr/bin/curl。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(settingsSaved ? "已保存" : "保存设置") { saveGatewaySettings() }
                        .glassButton(prominent: true)
                    if settingsSaved {
                        Text("已生效").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func loadGatewaySettings() {
        let s = ProtocolSettings.load()
        ipfsGateway = s.ipfsGateway
        s3Endpoint = s.s3.endpoint
        s3Region = s.s3.region
        s3AccessKey = s.s3.accessKey
        s3SecretKey = s.s3.secretKey
        s3UseHTTPS = s.s3.useHTTPS
        curlPath = s.curlPath
    }

    private func saveGatewaySettings() {
        var cfg = S3Signer.Config()
        cfg.endpoint = s3Endpoint.trimmingCharacters(in: .whitespaces)
        cfg.region = s3Region.trimmingCharacters(in: .whitespaces)
        cfg.accessKey = s3AccessKey.trimmingCharacters(in: .whitespaces)
        cfg.secretKey = s3SecretKey
        cfg.useHTTPS = s3UseHTTPS
        if cfg.endpoint.isEmpty { cfg.endpoint = "s3.amazonaws.com" }
        if cfg.region.isEmpty { cfg.region = "us-east-1" }
        let gateway = ipfsGateway.trimmingCharacters(in: .whitespaces)
        ProtocolSettings(
            ipfsGateway: gateway.isEmpty ? "https://ipfs.io" : gateway,
            s3: cfg,
            curlPath: curlPath.trimmingCharacters(in: .whitespaces).isEmpty
                ? "/usr/bin/curl" : curlPath.trimmingCharacters(in: .whitespaces)
        ).save()
        settingsSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settingsSaved = false }
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
                Text("原生 macOS 多协议下载管理器")
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider().frame(width: 260)
                VStack(alignment: .leading, spacing: 6) {
                    Text("下载内核：Swift 原生 HTTP/HTTPS/FTP（URLSession 分段）")
                    Text("P2P：aria2 独立进程，随应用打包（BT / Magnet / Metalink / SFTP）")
                    Text("原生协议：HTTP/HTTPS/FTP · HLS · DASH · eD2K 传输 · 专用链 · 网关 · libcurl")
                    Text("界面：SwiftUI · Liquid Glass（macOS 26+）")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .glassCard(cornerRadius: 20)

            Spacer()
            Text("HTTP/HTTPS/FTP、DASH 扁平化与 eD2K 传输均为原生 Swift 实现；aria2 以独立进程调用（GPLv2），不链接其库。AFP 链接自动迁移为 SMB。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
    }
}
