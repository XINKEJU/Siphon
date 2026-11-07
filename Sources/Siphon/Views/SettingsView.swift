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

    // BitTorrent enhancement + per-host
    @State private var trackerBlacklistText = ""
    @State private var seedRatio: Double = 0
    @State private var seedTime: Int = 0
    @State private var perHostRules: [PerHostRule] = []
    @State private var newHostText = ""

    // Archive auto-extract + post-process
    @State private var autoExtract = false
    @State private var postProcessEnabled = false
    @State private var postProcessCommand = ""

    // eD2K servers / Kad bootstrap
    @State private var ed2kServersText = ""
    @State private var ed2kKadText = ""

    // UPnP / NAT-PMP
    @State private var btPortText = "6881"
    @State private var natResult = ""

    // Plugin sandbox
    @State private var pluginList: [String] = []

    // Remote pairing (MDXP)
    @State private var pairingCode = ""
    @State private var pairingActive = false
    @State private var pairingDeviceName = ""
    @State private var pairedDevices: [RemotePairing.PairedDevice] = []

    // Local API token
    @State private var apiToken = LocalAuthToken.current()

    // Self-update
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var updateFeedText = ""

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
            trackerBlacklistText = TrackerManager.shared.blacklist.joined(separator: "\n")
            seedRatio = UserDefaults.standard.double(forKey: "Siphon.seedRatio")
            seedTime = UserDefaults.standard.integer(forKey: "Siphon.seedTime")
            perHostRules = PerHostSettings.shared.rules
            autoExtract = UserDefaults.standard.bool(forKey: ArchiveManager.autoExtractKey)
            postProcessEnabled = UserDefaults.standard.bool(forKey: ArchiveManager.postProcessKey)
            postProcessCommand = UserDefaults.standard.string(forKey: ArchiveManager.postProcessCommandKey) ?? ""
            ed2kServersText = ED2KServerList.shared.servers
                .map { "\($0.host):\($0.port)" }.joined(separator: "\n")
            ed2kKadText = ED2KServerList.shared.kadBootstrap.joined(separator: "\n")
            pluginList = PluginHost.shared.pluginNames
            pairedDevices = RemotePairing.shared.devices
            updateFeedText = updater.feedURL
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
                HStack(spacing: 8) {
                    Text(apiToken)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(apiToken)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(apiToken, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }.help("复制令牌")
                    Button {
                        apiToken = LocalAuthToken.rotate()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("重新生成令牌（已配置的扩展会通过 /ping 自动获取新令牌，curl 调用需更新）")
                }
                Text("所有请求（除 /ping）需带 Authorization: Bearer <令牌>，防止任意网页跨站调用本机接口。")
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
                Text("让 Claude / Cursor 等 AI 客户端管理下载：add_download、list_tasks、pause_task、resume_task、remove_task。客户端需在请求头配置上面的本地接口令牌。")
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
            Section("BitTorrent 增强（Tracker / 做种）") {
                Toggle("自动订阅公共 Tracker 列表", isOn: Binding(
                    get: { TrackerManager.shared.autoUpdateEnabled },
                    set: { TrackerManager.shared.setAutoUpdate($0) }))
                HStack {
                    Text("当前可用 Tracker")
                    Spacer()
                    Text("\(TrackerManager.shared.lastTrackers.count) 个").foregroundStyle(.secondary)
                }
                if let err = TrackerManager.shared.lastError {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Tracker 黑名单（每行一个，自动过滤）", text: $trackerBlacklistText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Button("应用") { TrackerManager.shared.setBlacklist(trackerBlacklistText) }
                }
                Button("立即刷新 Tracker") { Task { await TrackerManager.shared.refresh() } }
                Divider()
                HStack(spacing: 8) {
                    Text("做种比"); TextField("0 = 不限", value: $seedRatio, format: .number)
                        .textFieldStyle(.roundedBorder)
                    Text("做种时长（分）"); TextField("0 = 不限", value: $seedTime, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                Button("应用做种设置") { store.applySeedSettings(ratio: seedRatio, time: seedTime) }
                Text("Tracker 列表定时从公开源拉取、去重后注入 aria2；做种比/时长作用于全部 BT 任务，达到后自动停止做种。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("每主机连接 / 限速 / User-Agent") {
                ForEach($perHostRules) { $rule in
                    DisclosureGroup(rule.host.isEmpty ? "未命名主机" : rule.host) {
                        HStack {
                            Text("主机"); TextField("example.com 或 *.example.com", text: $rule.host)
                                .textFieldStyle(.roundedBorder)
                        }
                        Stepper("最大连接数：\(rule.maxConnections)", value: $rule.maxConnections, in: 1...32)
                        HStack {
                            Text("限速 B/s"); TextField("0 = 不限", value: $rule.speedLimitBytesPerSec, format: .number)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("User-Agent"); TextField("可选", text: $rule.userAgent)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button("保存并应用") {
                            PerHostSettings.shared.upsert(rule)
                            perHostRules = PerHostSettings.shared.rules
                        }
                        Button("删除", role: .destructive) {
                            PerHostSettings.shared.remove(rule.id)
                            perHostRules = PerHostSettings.shared.rules
                        }
                    }
                }
                HStack {
                    TextField("新主机（如 cdn.example.com）", text: $newHostText)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        let r = PerHostRule(host: newHostText.trimmingCharacters(in: .whitespaces))
                        PerHostSettings.shared.upsert(r)
                        perHostRules = PerHostSettings.shared.rules
                        newHostText = ""
                    }
                    .disabled(newHostText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("按域名覆盖连接数、限速与 User-Agent，不影响全局设置。匹配顺序：精确主机名 → *.域名 通配。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("归档自动解压与后处理（HyperDM 模型）") {
                Toggle("下载完成后自动解压归档文件", isOn: Binding(
                    get: { autoExtract },
                    set: {
                        autoExtract = $0
                        UserDefaults.standard.set($0, forKey: ArchiveManager.autoExtractKey)
                    }))
                Text("支持 zip / tar(.gz/.bz2/.xz/.tgz) / .gz / 7z（需安装 p7zip）。解压到同名文件夹，原文件保留。rar 暂不支持。")
                    .font(.caption).foregroundStyle(.tertiary)
                Divider()
                Toggle("完成后执行后处理命令", isOn: Binding(
                    get: { postProcessEnabled },
                    set: {
                        postProcessEnabled = $0
                        UserDefaults.standard.set($0, forKey: ArchiveManager.postProcessKey)
                    }))
                TextField("Shell 命令（/bin/sh -c 执行）", text: $postProcessCommand,
                          prompt: Text("例如：mv \"$SIPHON_DIR\"/* ~/Movies/"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!postProcessEnabled)
                Text("可用环境变量：$SIPHON_FILE（文件路径）、$SIPHON_NAME（文件名）、$SIPHON_DIR（解压目录，未解压时为文件所在目录）。失败不阻塞下载。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("UPnP / NAT-PMP 端口映射（BT 入站）") {
                HStack {
                    Text("BT 监听端口"); TextField("6881", text: $btPortText)
                        .textFieldStyle(.roundedBorder)
                    Button("检测 NAT 类型") {
                        let t = PortMapper.shared.detect()
                        natResult = "NAT：\(t.rawValue)  外网 IP：\(PortMapper.shared.externalIP ?? "—")"
                    }
                    Button("映射端口") {
                        let port = UInt16(btPortText) ?? 6881
                        Task {
                            let ok = await PortMapper.shared.mapPortAsync(internalPort: port, description: "Siphon")
                            natResult = ok
                                ? "已映射 TCP \(port) via \(PortMapper.shared.natType.rawValue)  外网 IP：\(PortMapper.shared.externalIP ?? "—")"
                                : "映射失败：\(PortMapper.shared.lastError ?? "未知原因")"
                        }
                    }
                }
                if !natResult.isEmpty {
                    Text(natResult).font(.caption).foregroundStyle(.secondary)
                }
                Text("为 BitTorrent 入站连接做 UPnP / NAT-PMP 端口映射，提升做种与连接数。无可用网关或沙盒阻止组播时自动跳过并报告原因，不影响下载。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("eD2K 服务器与 Kad 引导（原生 P2P 后端）") {
                HStack {
                    TextField("eD2K 服务器（每行 host:port，默认端口 4661）",
                              text: $ed2kServersText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Button("应用") {
                        ED2KServerList.shared.setServers(
                            ed2kServersText.components(separatedBy: .newlines))
                    }
                }
                HStack {
                    TextField("Kad 引导节点（每行 host:port，可选）",
                              text: $ed2kKadText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Button("应用") {
                        ED2KServerList.shared.setKadBootstrap(
                            ed2kKadText.components(separatedBy: .newlines))
                    }
                }
                Text("链接未内嵌 |sources,host:port| 时，原生 eD2K 后端会用这些服务器做 OP_GETSOURCES 寻源；Kad DHT 引导暂未实现，因此无内嵌源且无服务器的链接仍会报 noSources。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("插件沙箱（JavaScript 解析器）") {
                if pluginList.isEmpty {
                    Text("未加载任何插件。插件目录：~/Library/Application Support/Siphon/plugins/")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(pluginList, id: \.self) { name in
                        HStack {
                            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                            Text(name)
                        }
                    }
                }
                Text("插件在隔离的 JSContext 中运行，已移除 XMLHttpRequest / fetch / WebSocket / import / require / process 等可触网或触盘 API，且仅允许纯 URL 改写；声明额外权限的插件会被拒绝加载。恶意插件最多只能误改一个下载链接。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("远程设备配对（MDXP 设备码）") {
                if !pairingActive {
                    Button("生成配对码") {
                        pairingCode = RemotePairing.shared.beginPairing()
                        pairingActive = true
                    }
                } else {
                    HStack {
                        Text("配对码").foregroundStyle(.secondary)
                        Text(pairingCode).font(.title3.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button("取消", role: .destructive) {
                            RemotePairing.shared.cancelPairing()
                            pairingActive = false
                        }
                    }
                    HStack {
                        TextField("远程设备名（可选）", text: $pairingDeviceName)
                            .textFieldStyle(.roundedBorder)
                        Button("确认配对") {
                            if RemotePairing.shared.confirmPairing(deviceName: pairingDeviceName) != nil {
                                pairedDevices = RemotePairing.shared.devices
                                pairingDeviceName = ""
                                pairingActive = false
                            }
                        }
                    }
                    Text("将配对码在远程设备 / MDXP 中继上验证即可完成握手；此处为客户端状态机与持久化，传输层可后续接入真实中继。配对码 5 分钟内有效。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if !pairedDevices.isEmpty {
                    Divider()
                    ForEach(pairedDevices) { d in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name)
                                Text(d.token.prefix(12) + "…  ·  "
                                      + d.pairedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                RemotePairing.shared.remove(deviceID: d.id)
                                pairedDevices = RemotePairing.shared.devices
                            } label: { Image(systemName: "trash") }
                                .controlSize(.small)
                        }
                    }
                }
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

            VStack(alignment: .leading, spacing: 8) {
                Text("软件更新").font(.headline)
                HStack {
                    TextField("更新源 JSON（如 GitHub Releases latest.json）", text: $updateFeedText)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") { updater.feedURL = updateFeedText }
                }
                HStack {
                    Button(updater.checking ? "检查中…" : "检查更新") {
                        Task { await updater.check() }
                    }
                    .disabled(updater.checking)
                    if let info = updater.available {
                        Text("新版本 \(info.version)").foregroundStyle(.green)
                        Button(updater.installing ? "安装中…" : "下载并安装") {
                            Task { await updater.downloadAndInstall() }
                        }
                        .disabled(updater.installing)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                if !updater.status.isEmpty {
                    Text(updater.status).font(.caption).foregroundStyle(.secondary)
                }
                Text("默认无更新源，保持静默。配置后：下载更新包 → SHA-256 校验 → 解压替换 .app（失败自动还原）→ 重启。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)

            Spacer()
            Text("HTTP/HTTPS/FTP、DASH 扁平化与 eD2K 传输均为原生 Swift 实现；aria2 以独立进程调用（GPLv2），不链接其库。AFP 链接自动迁移为 SMB。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
    }
}
