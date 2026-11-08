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
    @State private var pluginItems: [PluginHost.PluginInfo] = []

    // Remote pairing (MDXP)
    @State private var pairingCode = ""
    @State private var pairingActive = false
    @State private var pairingDeviceName = ""
    @State private var pairedDevices: [RemotePairing.PairedDevice] = []

    // Local API token
    @State private var apiToken = LocalAuthToken.current()
    @State private var postProcessStatus = ""
    @State private var archiveStatus = ""
    @State private var webhookAllowPrivate = UserDefaults.standard.bool(
        forKey: WebhookPolicy.allowPrivateKey)
    @State private var webhookStatus = ""
    @State private var webhookDeliveryStatus = ""

    // Browser extension v2 (native messaging)
    @State private var extensionID = NativeMessagingHostInstaller.extensionID
    @State private var gatewayStatus = ""

    // Site rules + cookie cache
    @State private var siteRules: [SiteRule] = []
    @State private var newSiteHost = ""
    @State private var cookieHostCount = 0

    // Proxy settings
    @State private var proxyManualEnabled = false
    @State private var proxyType: ManualProxy.ProxyType = .http
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var proxyUsername = ""
    @State private var proxyPassword = ""
    @State private var proxyPACEnabled = false

    // Notifications
    @State private var notificationsEnabled = true

    var body: some View {
        Form {
            Section("剪贴板监听") {
                Toggle("自动捕获复制的下载链接", isOn: Binding(
                    get: { store.clipboardEnabled },
                    set: { store.setClipboardEnabled($0) }))
                Toggle("智能识别（仅下载类链接）", isOn: Binding(
                    get: {
                        let key = "Siphon.clipboardSmartDetection"
                        return UserDefaults.standard.object(forKey: key) == nil
                            || UserDefaults.standard.bool(forKey: key)
                    },
                    set: { store.setClipboardSmartDetection($0) }))
                Picker("捕获后行为", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "Siphon.clipboardMode") ?? "notify" },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.clipboardMode") }
                )) {
                    Text("弹出通知，点击后下载").tag("notify")
                    Text("自动添加为暂停任务").tag("auto")
                }
                .pickerStyle(.menu)
                Text("智能识别会过滤网页等无关链接，仅匹配含下载扩展名或媒体流特征的 URL。")
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
                        LocalAuthToken.publishBootstrapFile()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("重新生成令牌（本机网关自动同步；HTTP 回退的扩展与 curl 调用需更新）")
                }
                Text("所有请求（除 /ping）需带 Authorization: Bearer <令牌>，防止任意网页跨站调用本机接口。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("令牌不会通过 /ping 下发。原生网关从本机受保护文件读取：\(LocalAuthToken.bootstrapFileURL.path)（目录 0700 / 文件 0600）。仅当扩展使用 HTTP 回退时，才需手动粘贴上方令牌。")
                    .font(.caption).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Section("浏览器扩展（Chrome / Edge / Brave / Firefox）") {
                TextField("扩展 ID（留空使用 Firefox 默认 ID）", text: $extensionID)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("安装原生网关") {
                        do {
                            let id = extensionID.trimmingCharacters(in: .whitespaces)
                            let written = try NativeMessagingHostInstaller.install(extensionID: id.isEmpty ? "siphon-connector@inkeju.com" : id)
                            gatewayStatus = "已写入 \(written.count) 份清单"
                                + "；网关：\(NativeMessagingHostInstaller.gatewayPath()?.lastPathComponent ?? "未找到")"
                        } catch {
                            gatewayStatus = error.localizedDescription
                        }
                    }
                    .disabled(false)
                    Button("卸载网关", role: .destructive) {
                        NativeMessagingHostInstaller.uninstall()
                        gatewayStatus = "已卸载"
                    }
                    if let folder = NativeMessagingHostInstaller.extensionFolderURL() {
                        Button("打开扩展目录") { NSWorkspace.shared.open(folder) }
                    }
                }
                if !gatewayStatus.isEmpty {
                    Text(gatewayStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Chrome / Edge / Brave：在 chrome://extensions 开启「开发者模式」，加载 App 内的 BrowserExtension 目录；在扩展弹窗「设置 → 连接诊断」复制扩展 ID，填入上方并点「安装原生网关」，然后完全退出并重启浏览器（浏览器只在启动时读取网关清单）。")
                Text("Firefox：在 about:debugging 加载前，先把扩展目录里的 manifest-firefox.json 复制为 manifest.json（Firefox 需要 background.scripts 而不是 service_worker），留空即使用默认 ID。")
                    .font(.caption).foregroundStyle(.tertiary)
                Text("出于安全考虑，/ping 不再自动绑定扩展 ID：清单里的白名单必须与扩展实际 ID 完全一致，否则浏览器会拒绝建立原生连接。")
                    .font(.caption).foregroundStyle(.tertiary)
                Text("当前已安装清单：\n" + NativeMessagingHostInstaller.installedManifestSummary())
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("网络代理") {
                Toggle("使用系统代理（PAC / 自动发现）", isOn: $proxyPACEnabled)
                    .onChange(of: proxyPACEnabled) { _, new in
                        ProxyRouter.shared.enabled = new
                    }
                Toggle("手动代理", isOn: $proxyManualEnabled)
                    .onChange(of: proxyManualEnabled) { _, new in
                        ProxyRouter.shared.manualEnabled = new
                    }
                if proxyManualEnabled {
                    Picker("类型", selection: $proxyType) {
                        Text("HTTP").tag(ManualProxy.ProxyType.http)
                        Text("SOCKS5").tag(ManualProxy.ProxyType.socks5)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("地址", text: $proxyHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("端口", text: $proxyPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    HStack {
                        TextField("用户名（可选）", text: $proxyUsername)
                            .textFieldStyle(.roundedBorder)
                        SecureField("密码（可选）", text: $proxyPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("保存") {
                        saveManualProxy()
                    }
                    .disabled(proxyHost.trimmingCharacters(in: .whitespaces).isEmpty
                              || Int(proxyPort) == nil)
                    Text("手动代理优先于系统 PAC；留空用户名即无认证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Circle()
                        .fill(ProxyRouter.shared.manualEnabled && ProxyRouter.shared.manualProxy.isValid
                              ? Color.green
                              : (ProxyRouter.shared.enabled ? Color.blue : Color.secondary))
                        .frame(width: 8, height: 8)
                    Text(proxyStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("通知") {
                Toggle("下载完成 / 失败时推送通知", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, new in
                        UserDefaults.standard.set(new, forKey: "Siphon.notificationsEnabled")
                    }
                Text("首次使用需授权；关闭后不再弹出系统通知。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("站点规则（Referer / 文件名 / 请求头）") {
                ForEach($siteRules) { $rule in
                    DisclosureGroup($rule.wrappedValue.host.isEmpty
                                    ? "未命名站点" : $rule.wrappedValue.host) {
                        TextField("主机（example.com 或 *.example.com）", text: $rule.host)
                            .textFieldStyle(.roundedBorder)
                        TextField("Referer（可选，防盗链）", text: $rule.referer)
                            .textFieldStyle(.roundedBorder)
                        TextField("User-Agent（可选）", text: $rule.userAgent)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("文件名前缀", text: $rule.filenamePrefix)
                                .textFieldStyle(.roundedBorder)
                            TextField("后缀（扩展名前）", text: $rule.filenameSuffix)
                                .textFieldStyle(.roundedBorder)
                        }
                        TextField("附加请求头（每行 Key: Value）", text: Binding(
                            get: { Self.headerText($rule.wrappedValue.extraHeaders) },
                            set: { $rule.wrappedValue.extraHeaders = Self.parseHeaders($0) }),
                                  axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                        HStack {
                            Button("保存并应用") {
                                SiteRuleStore.shared.replaceAll(siteRules)
                            }
                            Button("删除", role: .destructive) {
                                let id = $rule.wrappedValue.id
                                siteRules.removeAll { $0.id == id }
                                SiteRuleStore.shared.replaceAll(siteRules)
                            }
                        }
                    }
                }
                HStack {
                    TextField("新增站点规则（主机）", text: $newSiteHost)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        let host = newSiteHost.trimmingCharacters(in: .whitespaces)
                        guard !host.isEmpty else { return }
                        siteRules.append(SiteRule(host: host))
                        SiteRuleStore.shared.replaceAll(siteRules)
                        newSiteHost = ""
                    }
                    .disabled(newSiteHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Text("已缓存 Cookie 主机：\(cookieHostCount)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空 Cookie 缓存", role: .destructive) {
                        CookieJar.shared.clear()
                        cookieHostCount = 0
                    }
                    .controlSize(.small)
                }
                Text("规则只填补调用方未显式提供的请求头，不会覆盖扩展 / 表单传入的值；前缀与后缀作用于文件名（后缀插入扩展名前）。Cookie 由扩展随链接透传，并按主机缓存复用。")
                    .font(.caption).foregroundStyle(.tertiary)
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
            Section("MDXP 桥（远程设备）") {
                Toggle("启用 MDXP 桥", isOn: Binding(
                    get: { store.mdxpEnabled },
                    set: { store.setMDXPEnabled($0) }))
                HStack {
                    Text("POST http://127.0.0.1:\(NativeMessagingServer.port)/mdxp")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                }
                Text("JSON-RPC 2.0：mdxp.ping、tasks.list / get / add / pause / resume / remove / priority、config.get，事件流为 GET /mdxp/events。需在下方「远程设备配对」中完成配对，并在请求头携带 Authorization: Bearer <设备令牌>；与浏览器扩展共用同一回环端口。")
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
                        if WebhookPolicy.isAllowed(url,
                                allowPrivate: webhookAllowPrivate) != nil {
                            WebhookManager.shared.add(url: url)
                            webhookURLText = ""
                            webhookStatus = ""
                            reloadWebhooks()
                        } else {
                            webhookStatus = "地址被拒绝：仅接受 http/https；默认禁止本机与内网地址（可在下方显式开启）"
                        }
                    }
                    .disabled(!webhookURLText.contains("://"))
                }
                Toggle("允许本机 / 内网 Webhook 地址", isOn: Binding(
                    get: { webhookAllowPrivate },
                    set: {
                        webhookAllowPrivate = $0
                        UserDefaults.standard.set($0, forKey: WebhookPolicy.allowPrivateKey)
                    }))
                Text("任务进入完成 / 出错 / 移除终态时向每个地址 POST JSON；可选签名验证。仅允许 http/https，重定向逐跳复查，任务 URL 中的凭据与预签名参数会被脱敏后发送。失败不阻塞下载，最近一次错误显示在下方。")
                    .font(.caption).foregroundStyle(.tertiary)
                if !webhookStatus.isEmpty {
                    Text(webhookStatus).font(.caption).foregroundStyle(.orange)
                }
                if !webhookDeliveryStatus.isEmpty {
                    Text("最近一次投递：\(webhookDeliveryStatus)")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section("RSS 订阅下载") {
                ForEach(store.feedManager.feeds) { feed in
                    VStack(alignment: .leading, spacing: 6) {
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
                        DisclosureGroup("下载规则") {
                            TextField("包含正则（留空 = 全部）", text: Binding(
                                get: { feed.includePattern ?? "" },
                                set: { v in store.feedManager.update(id: feed.id) {
                                    $0.includePattern = v.isEmpty ? nil : v } }))
                                .textFieldStyle(.roundedBorder)
                            TextField("排除正则", text: Binding(
                                get: { feed.excludePattern ?? "" },
                                set: { v in store.feedManager.update(id: feed.id) {
                                    $0.excludePattern = v.isEmpty ? nil : v } }))
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Text("每次最多")
                                TextField("0 = 不限", value: Binding(
                                    get: { feed.maxItemsPerRefresh ?? 0 },
                                    set: { v in store.feedManager.update(id: feed.id) {
                                        $0.maxItemsPerRefresh = v > 0 ? v : nil } }),
                                    format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                                Text("条").foregroundStyle(.secondary)
                            }
                            TextField("下载队列（默认 Default）", text: Binding(
                                get: { feed.queueName ?? "" },
                                set: { v in store.feedManager.update(id: feed.id) {
                                    $0.queueName = v.isEmpty ? nil : v } }))
                                .textFieldStyle(.roundedBorder)
                            TextField("子目录（相对下载根目录，可留空）", text: Binding(
                                get: { feed.subdirectory ?? "" },
                                set: { v in store.feedManager.update(id: feed.id) {
                                    $0.subdirectory = v.isEmpty ? nil : v } }))
                                .textFieldStyle(.roundedBorder)
                            Text("规则只作用于新条目；被过滤的条目会标记为已读，不会在下次刷新时重试。")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
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
                    .onChange(of: postProcessCommand) { _, newValue in
                        UserDefaults.standard.set(newValue,
                            forKey: ArchiveManager.postProcessCommandKey)
                        postProcessStatus = "命令已修改，需重新确认后才会执行"
                    }
                HStack(spacing: 10) {
                    Button("确认并启用命令") {
                        UserDefaults.standard.set(postProcessCommand,
                            forKey: ArchiveManager.postProcessCommandKey)
                        ArchiveManager.shared.confirmPostProcessCommand(postProcessCommand)
                        postProcessStatus = "已确认：命令将在下载完成后执行"
                    }
                    .disabled(!postProcessEnabled
                              || postProcessCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                    Text(postProcessStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("可用环境变量：$SIPHON_FILE（文件路径）、$SIPHON_NAME（文件名）、$SIPHON_DIR（解压目录，未解压时为文件所在目录）。命令以当前用户权限执行，须在此处显式确认；超时 60 秒自动终止，退出码与错误会显示在下方。")
                    .font(.caption).foregroundStyle(.tertiary)
                if !archiveStatus.isEmpty {
                    Text(archiveStatus)
                        .font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text("归档解压前会校验条目路径（拒绝 ../ 与绝对路径）、符号链接及 2 GiB 展开上限，防止 Zip Slip 与解压炸弹。")
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
            Section("插件沙箱（JavaScript 解析器 · API v2）") {
                if pluginItems.isEmpty {
                    Text("未加载任何插件。插件目录：~/Library/Application Support/Siphon/plugins/")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(pluginItems) { info in
                        HStack(alignment: .top) {
                            Toggle("", isOn: Binding(
                                get: { info.enabled },
                                set: { on in
                                    PluginHost.shared.setEnabled(name: info.name, on: on)
                                    pluginItems = PluginHost.shared.pluginInfos
                                }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(info.name).font(.body)
                                    Text("v\(info.version)")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                    Text("API \(info.apiVersion)")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                    if info.priority != 0 {
                                        Text("优先级 \(info.priority)")
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                if let error = info.error {
                                    Text(error).font(.caption2).foregroundStyle(.red)
                                } else {
                                    Text(info.matches.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("重新加载") {
                        PluginHost.shared.reload()
                        pluginItems = PluginHost.shared.pluginInfos
                    }
                    Button("打开插件目录") {
                        NSWorkspace.shared.open(PluginHost.shared.ensurePluginsDirectory())
                    }
                    Button("创建示例插件") {
                        _ = PluginHost.shared.createExamplePlugin()
                        pluginItems = PluginHost.shared.pluginInfos
                    }
                }
                Text("插件在 JSContext 中运行，已移除常见触网/触盘 API，脚本路径被限制在插件目录内且不超过 1 MiB，声明额外权限的插件会被拒绝加载。注意：这不是进程级沙箱，JavaScriptCore 与 App 同进程、无执行超时，恶意脚本仍可能卡住线程或利用 JSC 漏洞——请只安装可信插件。API v2 支持 priority、mirrors、checksum 与 queue 字段，v1 插件保持兼容。")
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
                    Text("将配对码在远程设备 / MDXP 中继上验证即可完成握手；配对后设备令牌可直接作为 MDXP 桥的 Bearer 令牌。配对码 5 分钟内有效。")
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
            postProcessStatus = ArchiveManager.shared.isPostProcessConfirmed
                ? "已确认：命令将在下载完成后执行" : "尚未确认命令"
            archiveStatus = ArchiveManager.shared.lastError ?? ""
            webhookAllowPrivate = UserDefaults.standard.bool(forKey: WebhookPolicy.allowPrivateKey)
            webhookDeliveryStatus = WebhookManager.shared.lastError ?? ""
            ed2kServersText = ED2KServerList.shared.servers
                .map { "\($0.host):\($0.port)" }.joined(separator: "\n")
            ed2kKadText = ED2KServerList.shared.kadBootstrap.joined(separator: "\n")
            pluginItems = PluginHost.shared.pluginInfos
            pairedDevices = RemotePairing.shared.devices
            siteRules = SiteRuleStore.shared.rules
            cookieHostCount = CookieJar.shared.hostCount
            extensionID = NativeMessagingHostInstaller.extensionID
            // Proxy
            proxyPACEnabled = ProxyRouter.shared.enabled
            proxyManualEnabled = ProxyRouter.shared.manualEnabled
            let mp = ProxyRouter.shared.manualProxy
            proxyType = mp.type
            proxyHost = mp.host
            proxyPort = mp.port > 0 ? String(mp.port) : ""
            proxyUsername = mp.username
            proxyPassword = mp.password
            // Notifications (default on)
            notificationsEnabled = UserDefaults.standard.object(forKey: "Siphon.notificationsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "Siphon.notificationsEnabled")
        }
    }

    private static func headerText(_ headers: [String: String]) -> String {
        headers.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            out[key] = value
        }
        return out
    }

    private func reloadWebhooks() {
        webhooks = WebhookManager.shared.endpoints
    }

    private var proxyStatusText: String {
        if ProxyRouter.shared.manualEnabled, ProxyRouter.shared.manualProxy.isValid {
            let mp = ProxyRouter.shared.manualProxy
            return "手动 \(mp.type.rawValue.uppercased()) \(mp.host):\(mp.port)"
        }
        if ProxyRouter.shared.enabled {
            if let pac = ProxyRouter.shared.systemPACURL {
                return "系统 PAC：\(pac.host ?? pac.absoluteString)"
            }
            if let sp = ProxyRouter.shared.systemProxy {
                return "系统代理 \(sp.host):\(sp.port)"
            }
            return "系统代理（未配置）"
        }
        return "直连"
    }

    private func saveManualProxy() {
        var mp = ManualProxy()
        mp.type = proxyType
        mp.host = proxyHost.trimmingCharacters(in: .whitespaces)
        mp.port = Int(proxyPort) ?? 0
        mp.username = proxyUsername
        mp.password = proxyPassword
        ProxyRouter.shared.manualProxy = mp
    }
}
