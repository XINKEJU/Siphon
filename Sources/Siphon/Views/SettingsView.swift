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

    // RSS subscriptions
    @State private var feedURLText = ""

    // Webhooks
    @State private var webhooks: [WebhookManager.Endpoint] = []
    @State private var webhookURLText = ""

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
            reloadWebhooks()
        }
    }

    private func reloadWebhooks() {
        webhooks = WebhookManager.shared.endpoints
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
            Section("自动化") {
                Toggle("按类型自动归类子文件夹", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "Siphon.autoCategorize") },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.autoCategorize") }))
                Text("开启后新任务按视频 / 音频 / 文档 / 压缩包 / 镜像等自动放入子目录。")
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

                Picker("全部完成后", selection: $store.completionAction) {
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

    // MARK: - Speed
    private var speedTab: some View {
        Form {
            Section("乌龟模式（三档限速）") {
                Picker("模式", selection: Binding(
                    get: { store.turtleConfig.mode },
                    set: { store.turtleConfig.mode = $0 })) {
                    ForEach(TurtleMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if store.turtleConfig.mode != .off {
                    HStack {
                        Text("限速")
                        TextField("字节/秒", value: Binding(
                            get: { store.turtleConfig.limitBytesPerSec },
                            set: { store.turtleConfig.limitBytesPerSec = $0 }),
                            format: .number)
                            .textFieldStyle(.roundedBorder)
                        Text("B/s").foregroundStyle(.secondary)
                    }
                }
                if store.turtleConfig.mode == .auto {
                    HStack {
                        Text("时段")
                        TextField("开始(分)", value: Binding(
                            get: { store.turtleConfig.autoStartMinutes },
                            set: { store.turtleConfig.autoStartMinutes = $0 }),
                            format: .number)
                            .textFieldStyle(.roundedBorder)
                        Text("–").foregroundStyle(.secondary)
                        TextField("结束(分)", value: Binding(
                            get: { store.turtleConfig.autoEndMinutes },
                            set: { store.turtleConfig.autoEndMinutes = $0 }),
                            format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("开始/结束为当日分钟数（如 1320=22:00，420=07:00），支持跨零点。仅此时段内限速。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("乌龟模式与全局限速叠加，取二者较小值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            Section("视频站解析（yt-dlp）") {
                Toggle("解析视频站链接为直链", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "Siphon.ytdlp") },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.ytdlp") }))
                HStack(spacing: 8) {
                    Circle()
                        .fill(YtDlpResolver.available() ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(YtDlpResolver.available()
                         ? "已检测到 yt-dlp"
                         : "未安装 yt-dlp（brew install yt-dlp）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("开启后 YouTube / B 站 / Twitter 等链接经 yt-dlp 解析为最高画质直链（音视频合一），交由原生 HTTP 引擎下载。未安装或解析失败时按普通链接处理。")
                    .font(.caption).foregroundStyle(.tertiary)
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
            Section("AI 客户端（MCP）") {
                Toggle("启用 MCP 服务", isOn: Binding(
                    get: { store.mcpEnabled },
                    set: { store.setMCPEnabled($0) }))
                HStack {
                    Text("http://127.0.0.1:\(MCPServer.port)/mcp")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                }
                Text("让 Claude / Cursor 等 AI 客户端管理下载：add_download、list_tasks、pause_task、resume_task、remove_task。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("任务事件 Webhook") {
                ForEach(webhooks) { ep in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.url).font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                            if !ep.secret.isEmpty {
                                Text("已启用签名验证").font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            WebhookManager.shared.remove(id: ep.id)
                            reloadWebhooks()
                        } label: { Image(systemName: "trash") }
                        .controlSize(.small)
                    }
                }
                HStack {
                    TextField("Webhook URL（任务完成/失败时 POST）", text: $webhookURLText)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        let url = webhookURLText.trimmingCharacters(in: .whitespaces)
                        if URL(string: url)?.scheme != nil {
                            WebhookManager.shared.add(url: url)
                            webhookURLText = ""
                            reloadWebhooks()
                        }
                    }
                    .disabled(!webhookURLText.contains("://"))
                }
                Text("任务进入完成 / 出错 / 移除终态时向每个地址 POST JSON；可选签名验证。失败不阻塞下载。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("RSS 订阅下载") {
                ForEach(store.feedManager.feeds) { feed in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(feed.lastError == nil ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feed.title).font(.body)
                            Text(feed.lastError ?? feed.url.absoluteString)
                                .font(.caption2.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { feed.enabled },
                            set: { store.feedManager.setEnabled(id: feed.id, $0) }))
                            .labelsHidden()
                        Button(role: .destructive) {
                            store.feedManager.remove(id: feed.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    TextField("RSS / Atom 订阅地址", text: $feedURLText)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        if let u = URL(string: feedURLText.trimmingCharacters(
                            in: .whitespacesAndNewlines)), u.scheme != nil {
                            store.feedManager.add(url: u)
                            feedURLText = ""
                            Task { await store.feedManager.refreshAll() }
                        }
                    }
                    .disabled(!feedURLText.contains("://"))
                    Button("立即刷新") { Task { await store.feedManager.refreshAll() } }
                }
                Text("每次刷新按 guid 去重，只下载新条目；首次添加不下载历史内容。应用运行期间每 30 分钟自动检查一次（有活动下载时顺延）。")
                    .font(.caption).foregroundStyle(.tertiary)
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
            Section("系统代理（PAC）") {
                Toggle("自动使用系统代理 / PAC 脚本", isOn: Binding(
                    get: { ProxyRouter.shared.enabled },
                    set: { ProxyRouter.shared.enabled = $0 }))
                Text("开启后，下载按系统代理设置（含 PAC 自动配置）走代理；本地回环地址始终直连。默认关闭以避免阻塞。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
