import SwiftUI
import AppKit

/// 集成 tab（剪贴板 / yt-dlp / 本地接口 / MCP / Webhook / RSS / BT 增强 /
/// 每主机规则 / 归档后处理 / UPnP / eD2K 服务器 / 插件 / 远程配对 / aria2 引擎）。
struct IntegrationSettingsView: View {
    @Environment(DownloadStore.self) private var store

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

    var body: some View {
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
        .onAppear {
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
        }
    }

    private func reloadWebhooks() {
        webhooks = WebhookManager.shared.endpoints
    }
}
