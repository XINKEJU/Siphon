import SwiftUI
import AppKit

/// MDM's Options window: twelve pages in two rows of six tabs, with fixed
/// geometry rather than a macOS TabView. The content views are Siphon's real
/// settings panes, so every control here changes live behaviour.
enum MDMOptionsPage: Int, CaseIterable, Identifiable {
    case general, fileTypes, saveTo, downloads, connection, remote
    case proxySocks, sitesLogins, accounts, sounds, regional, archives

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: return MDMI18n.t("options.general")
        case .fileTypes: return MDMI18n.t("options.fileTypes")
        case .saveTo: return MDMI18n.t("options.saveTo")
        case .downloads: return MDMI18n.t("options.downloads")
        case .connection: return MDMI18n.t("options.connection")
        case .remote: return MDMI18n.t("options.remote")
        case .proxySocks: return "\(MDMI18n.t("options.proxy")) / \(MDMI18n.t("options.socks"))"
        case .sitesLogins: return MDMI18n.t("options.sitesLogins")
        case .accounts: return MDMI18n.t("options.accounts")
        case .sounds: return MDMI18n.t("options.sounds")
        case .regional: return MDMI18n.t("options.regional")
        case .archives: return MDMI18n.t("options.archives")
        }
    }
}

struct MDMOptionsView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var isPresented: Bool
    @State private var page: MDMOptionsPage = .general
    @ObservedObject private var theme = MDMThemeStore.shared

    private let columns = Array(repeating: GridItem(.fixed(78), spacing: 2), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            tabGrid
            Divider()
            ScrollView {
                pageContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Text("Siphon \(MDMProduct.version) · \(MDMI18n.t("app.name"))")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(MDMI18n.t("action.close")) { isPresented = false }
                    .keyboardShortcut(.escape)
            }
            .padding(10)
        }
        .frame(width: 620, height: 560)
        .background(theme.color(.surface))
    }

    private var tabGrid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(MDMOptionsPage.allCases) { item in
                Button {
                    page = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(page == item ? .primary : .secondary)
                        .background(page == item ? theme.color(.selection) : theme.color(.surfaceRaised),
                                    in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(theme.color(.tabPage))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general: GeneralSettingsView()
        case .downloads: SpeedSettingsView()
        case .connection: GatewaySettingsView()
        case .sitesLogins: MDMSitesLoginsPage()
        case .archives: MDMArchivesPage()
        case .fileTypes: MDMFileTypesPage()
        case .saveTo: MDMSaveToPage()
        case .remote: MDMRemotePage()
        case .proxySocks: MDMProxySocksPage()
        case .accounts: MDMAccountsPage()
        case .sounds: MDMSoundsPage()
        case .regional: MDMRegionalPage()
        }
    }
}

private struct MDMFileTypesPage: View {
    @State private var newName = ""
    @State private var newSymbol = "folder"
    @State private var newFolder = ""
    @State private var newExts = ""

    private let symbols = ["folder", "doc", "archivebox", "music.note", "film",
                           "app.dashed", "arrow.down.circle", "star", "book",
                           "photo", "paintpalette", "tag"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按扩展名归类下载；分类树、列表列与保存目录共用同一套规则，编辑立即生效。")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(CategoryStore.shared.categories) { cat in
                CategoryExtensionsRow(category: cat)
                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("新增分类").font(.subheadline.weight(.semibold))
                HStack {
                    TextField("分类名", text: $newName).textFieldStyle(.roundedBorder)
                    Picker("", selection: $newSymbol) {
                        ForEach(symbols, id: \.self) { Image(systemName: $0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 44)
                }
                TextField("子目录名（留空则存到根目录）", text: $newFolder)
                    .textFieldStyle(.roundedBorder)
                TextField("扩展名，逗号分隔（如 zip, rar）", text: $newExts)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                Button {
                    let exts = newExts.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline })
                        .map(String.init)
                    CategoryStore.shared.add(name: newName, symbolName: newSymbol,
                                             folderName: newFolder, extensions: exts,
                                             autoStart: true)
                    newName = ""; newFolder = ""; newExts = ""
                } label: {
                    Label("添加分类", systemImage: "plus.circle")
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// One editable category row: extension mapping (all categories) and a delete
/// affordance (custom only). Edits write through to `CategoryStore` so new
/// downloads route immediately; already-downloaded files are never moved.
private struct CategoryExtensionsRow: View {
    @Environment(DownloadStore.self) private var store
    let category: UserCategory
    @State private var text: String

    init(category: UserCategory) {
        self.category = category
        _text = State(initialValue: category.extensions.joined(separator: ", "))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.symbolName).frame(width: 18)
            Text(category.name)
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(category.isBuiltin ? .primary : .secondary)
            TextField("扩展名，逗号分隔", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
            if !category.isBuiltin {
                Button(role: .destructive) {
                    CategoryStore.shared.remove(key: category.key, store: store)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除分类：任务移回通用，磁盘文件不动")
            }
        }
        .onChange(of: text) { _, new in commit(new) }
    }

    private func commit(_ new: String) {
        let parsed = new.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline })
            .map(String.init)
        guard parsed != category.extensions else { return }
        var updated = category
        updated.extensions = parsed
        CategoryStore.shared.update(updated)
    }
}

private struct MDMSaveToPage: View {
    @Environment(DownloadStore.self) private var store
    @State private var path = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MDMI18n.t("dialog.saveTo")).font(.subheadline.weight(.semibold))
            HStack {
                TextField("", text: $path).textFieldStyle(.roundedBorder)
                Button("选择…") { choose() }
            }
            Text("根目录写回 DownloadStore.downloadDirectory；每分类子目录由下方列表管理，新任务立即生效，已有任务保持原目标。")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("分类子目录").font(.subheadline.weight(.semibold))
            ForEach(CategoryStore.shared.categories) { cat in
                CategoryFolderRow(category: cat)
            }
            Spacer(minLength: 20)
        }
        .onAppear { path = store.downloadDirectory.path }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { reply in
            guard reply == .OK, let url = panel.url else { return }
            Task { @MainActor in
                store.downloadDirectory = url
                path = url.path
            }
        }
    }
}

/// Editable subfolder for one category. An empty folder means the category
/// lands directly under the download root (General's behaviour).
private struct CategoryFolderRow: View {
    let category: UserCategory
    @State private var folder: String

    init(category: UserCategory) {
        self.category = category
        _folder = State(initialValue: category.folderName)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.symbolName).frame(width: 18)
            Text(category.name)
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(category.isBuiltin ? .primary : .secondary)
            TextField("（根目录）", text: $folder)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
        .onChange(of: folder) { _, new in
            guard new != category.folderName else { return }
            var updated = category
            updated.folderName = new
            CategoryStore.shared.update(updated)
        }
    }
}

private struct MDMRemotePage: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("本机接口 127.0.0.1:17801 使用 0600 令牌文件；远程配对使用设备码。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("浏览器接管（原生消息）", isOn: Binding(
                get: { store.browserCaptureEnabled },
                set: { store.setBrowserCaptureEnabled($0) }
            ))
            Toggle("自动化 API / MCP", isOn: Binding(
                get: { store.mcpEnabled },
                set: { store.setMCPEnabled($0) }
            ))
            Toggle("远程设备配对（MDXP）", isOn: Binding(
                get: { store.mdxpEnabled },
                set: { store.setMDXPEnabled($0) }
            ))
            Spacer(minLength: 20)
        }
    }
}

private struct MDMAccountsPage: View {
    @State private var debrid = DebridService.shared
    @State private var cnl = CnLService.shared
    @State private var tokens: [String: String] = [:]
    @State private var messages: [String: String] = [:]
    @State private var testing: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("凭据只存系统钥匙串；列表、API 与日志都不会回显令牌。")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("启用网盘加速解析", isOn: Binding(
                    get: { debrid.enabled },
                    set: { debrid.enabled = $0 }
                ))

                ForEach(debrid.providers, id: \.id) { provider in
                    providerRow(provider)
                }

                Divider()

                Text("Click'n'Load 2").font(.headline)
                Toggle("启用本地接收（127.0.0.1:\(String(cnl.port)))", isOn: Binding(
                    get: { cnl.enabled },
                    set: { cnl.enabled = $0 }
                ))
                Toggle("收到链接后自动加入队列", isOn: Binding(
                    get: { cnl.autoAdd },
                    set: { cnl.autoAdd = $0 }
                ))
                .disabled(!cnl.enabled)
                if let error = cnl.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if !cnl.pending.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("待确认的链接（\(cnl.pending.count)）").font(.subheadline)
                            Spacer()
                            Button("全部加入") { cnl.confirmAll() }.controlSize(.small)
                            Button("全部忽略") { cnl.rejectAll() }.controlSize(.small)
                        }
                        ForEach(cnl.pending) { request in
                            VStack(alignment: .leading, spacing: 2) {
                                if let comment = request.comment {
                                    Text(comment).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(request.sources.map(\.absoluteString).joined(separator: "\n"))
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                                HStack {
                                    Button("加入") { cnl.confirm(request.id) }.controlSize(.mini)
                                    Button("忽略") { cnl.reject(request.id) }.controlSize(.mini)
                                }
                            }
                            .padding(6)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .onAppear(perform: loadTokens)
    }

    private func providerRow(_ provider: any DebridProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.displayName).font(.subheadline.weight(.semibold))
                Link("注册", destination: provider.signupURL)
                    .font(.caption)
                Spacer()
                if testing == provider.id {
                    ProgressView().controlSize(.small)
                }
                Button("测试") { test(provider) }
                    .controlSize(.small)
                    .disabled(tokens[provider.id, default: ""].isEmpty)
            }
            HStack {
                SecureField("API Token", text: Binding(
                    get: { tokens[provider.id] ?? "" },
                    set: { tokens[provider.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Button("保存") {
                    let ok = debrid.setToken(tokens[provider.id] ?? "", for: provider.id)
                    messages[provider.id] = ok ? "已保存到钥匙串" : "保存失败"
                }
                .controlSize(.small)
            }
            if let message = messages[provider.id] {
                Text(message).font(.caption)
                    .foregroundStyle(message.contains("失败") ? .red : .secondary)
            }
        }
    }

    private func loadTokens() {
        for provider in debrid.providers {
            tokens[provider.id] = debrid.token(for: provider.id)
        }
    }

    private func test(_ provider: any DebridProvider) {
        testing = provider.id
        messages[provider.id] = nil
        Task {
            defer { testing = nil }
            do {
                let account = try await debrid.testAccount(providerID: provider.id)
                messages[provider.id] = "\(account.username) · \(account.isPremium ? "高级" : "免费")"
            } catch {
                messages[provider.id] = "失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct MDMSoundsPage: View {
    @AppStorage("Siphon.soundsEnabled") private var soundEnabled = false
    @State private var notifyEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("下载完成 / 失败时推送系统通知", isOn: $notifyEnabled)
                .onChange(of: notifyEnabled) { _, new in
                    UserDefaults.standard.set(new, forKey: "Siphon.notificationsEnabled")
                }
            Text("首次使用需授权；关闭后不再弹出横幅。通知偏好由 SystemPresence 读取，与提示音相互独立。")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Toggle("下载完成提示音", isOn: $soundEnabled)
            HStack {
                Button("试听") { NSSound(named: NSSound.Name("Glass"))?.play() }
                    .disabled(!soundEnabled)
                Spacer()
            }
            Text("显式开启后，任务完成时播放 Glass 提示音（不依赖通知权限）。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear {
            notifyEnabled = UserDefaults.standard.object(forKey: "Siphon.notificationsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "Siphon.notificationsEnabled")
        }
    }
}

private struct MDMRegionalPage: View {
    private struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private var languages: [Language] {
        MDMI18n.availableLanguages.map { Language(code: $0.code, name: $0.name) }
    }

    @State private var selected = MDMI18n.shared.language
    @ObservedObject private var theme = MDMThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("界面语言", selection: $selected) {
                ForEach(languages) { Text($0.name).tag($0.code) }
            }
            .onChange(of: selected) { _, newValue in MDMI18n.shared.language = newValue }

            if MDMI18n.rtlLanguages.contains(selected) {
                Label("该语言使用从右到左布局（RTL），界面将自动镜像。", systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Picker("主题", selection: $theme.theme) {
                ForEach(MDMTheme.allCases) { Text($0.displayName).tag($0) }
            }

            Picker("外观", selection: $theme.appearance) {
                Text("跟随系统").tag(MDMAppearance.system)
                Text("浅色").tag(MDMAppearance.light)
                Text("深色").tag(MDMAppearance.dark)
            }

            VStack(alignment: .leading) {
                Text("界面缩放：\(Int(theme.scale * 100))%")
                Slider(value: $theme.scale, in: 1.0...2.0, step: 0.05)
            }

            Text("共 \(MDMI18n.availableLanguages.count) 种语言，核心 12 种已人工校对，其余为机器初译并标记状态。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Proxy / SOCKS page (independent of the protocol-gateway page)

private struct MDMProxySocksPage: View {
    @State private var proxyType: ManualProxy.ProxyType = .http
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("系统代理 / PAC") {
                Toggle("自动使用系统代理 / PAC 脚本", isOn: Binding(
                    get: { ProxyRouter.shared.enabled },
                    set: { ProxyRouter.shared.enabled = $0 }))
                Text("开启后下载按系统代理设置（含 PAC 自动配置）走代理；本地回环地址始终直连。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("手动代理") {
                Toggle("启用手动代理", isOn: Binding(
                    get: { ProxyRouter.shared.manualEnabled },
                    set: { ProxyRouter.shared.manualEnabled = $0 }))
                if ProxyRouter.shared.manualEnabled {
                    Picker("类型", selection: $proxyType) {
                        Text("HTTP").tag(ManualProxy.ProxyType.http)
                        Text("SOCKS5").tag(ManualProxy.ProxyType.socks5)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("地址", text: $host).textFieldStyle(.roundedBorder)
                        TextField("端口", text: $port).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    HStack {
                        TextField("用户名（可选）", text: $username).textFieldStyle(.roundedBorder)
                        SecureField("密码（可选）", text: $password).textFieldStyle(.roundedBorder)
                    }
                    Button("保存") { save() }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                                  || Int(port) == nil)
                    Text("手动代理优先于系统 PAC；留空用户名即无认证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    private var statusColor: Color {
        if ProxyRouter.shared.manualEnabled, ProxyRouter.shared.manualProxy.isValid { return .green }
        if ProxyRouter.shared.enabled { return .blue }
        return .secondary
    }
    private var statusText: String {
        if ProxyRouter.shared.manualEnabled, ProxyRouter.shared.manualProxy.isValid {
            let m = ProxyRouter.shared.manualProxy
            return "手动 \(m.type.rawValue.uppercased()) \(m.host):\(m.port)"
        }
        if ProxyRouter.shared.enabled {
            if let pac = ProxyRouter.shared.systemPACURL { return "系统 PAC：\(pac.host ?? pac.absoluteString)" }
            if let sp = ProxyRouter.shared.systemProxy { return "系统代理 \(sp.host):\(sp.port)" }
            return "系统代理（未配置）"
        }
        return "直连"
    }
    private func load() {
        let m = ProxyRouter.shared.manualProxy
        proxyType = m.type
        host = m.host
        port = m.port > 0 ? String(m.port) : ""
        username = m.username
        password = m.password
    }
    private func save() {
        var m = ManualProxy()
        m.type = proxyType
        m.host = host.trimmingCharacters(in: .whitespaces)
        m.port = Int(port) ?? 0
        m.username = username
        m.password = password
        ProxyRouter.shared.manualProxy = m
    }
}

// MARK: - Archives page (auto-extract + post-process, independent slice)

private struct MDMArchivesPage: View {
    @State private var autoExtract = false
    @State private var postProcessEnabled = false
    @State private var postProcessCommand = ""
    @State private var postProcessStatus = ""
    @State private var archiveStatus = ""

    var body: some View {
        Form {
            Section("归档自动解压") {
                Toggle("下载完成后自动解压归档文件", isOn: Binding(
                    get: { autoExtract },
                    set: { autoExtract = $0
                          UserDefaults.standard.set($0, forKey: ArchiveManager.autoExtractKey) }))
                Text("支持 zip / tar(.gz/.bz2/.xz/.tgz) / .gz / 7z（需安装 p7zip）。解压到同名文件夹，原文件保留；rar 暂不支持。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("完成后处理命令") {
                Toggle("启用后处理命令", isOn: Binding(
                    get: { postProcessEnabled },
                    set: { postProcessEnabled = $0
                          UserDefaults.standard.set($0, forKey: ArchiveManager.postProcessKey) }))
                TextField("Shell 命令（/bin/sh -c 执行）", text: $postProcessCommand,
                          prompt: Text("例如：mv \"$SIPHON_DIR\"/* ~/Movies/"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!postProcessEnabled)
                    .onChange(of: postProcessCommand) { _, v in
                        UserDefaults.standard.set(v, forKey: ArchiveManager.postProcessCommandKey)
                        postProcessStatus = "命令已修改，需重新确认后才会执行"
                    }
                Button("确认并启用命令") {
                    UserDefaults.standard.set(postProcessCommand,
                                              forKey: ArchiveManager.postProcessCommandKey)
                    ArchiveManager.shared.confirmPostProcessCommand(postProcessCommand)
                    postProcessStatus = "已确认：命令将在下载完成后执行"
                }
                .disabled(!postProcessEnabled
                          || postProcessCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(postProcessStatus).font(.caption).foregroundStyle(.secondary)
                Text("可用环境变量：$SIPHON_FILE / $SIPHON_NAME / $SIPHON_DIR。解压前校验条目路径（拒绝 ../ 与绝对路径）、符号链接及 2 GiB 展开上限，防止 Zip Slip 与解压炸弹。")
                    .font(.caption).foregroundStyle(.tertiary)
                if !archiveStatus.isEmpty {
                    Text(archiveStatus).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            autoExtract = UserDefaults.standard.bool(forKey: ArchiveManager.autoExtractKey)
            postProcessEnabled = UserDefaults.standard.bool(forKey: ArchiveManager.postProcessKey)
            postProcessCommand = UserDefaults.standard.string(forKey: ArchiveManager.postProcessCommandKey) ?? ""
            postProcessStatus = ArchiveManager.shared.isPostProcessConfirmed
                ? "已确认：命令将在下载完成后执行" : "尚未确认命令"
            archiveStatus = ArchiveManager.shared.lastError ?? ""
        }
    }
}

// MARK: - Sites / Logins page (browser capture, tokens, site rules, cookies)

private struct MDMSitesLoginsPage: View {
    @Environment(DownloadStore.self) private var store

    @State private var siteRules: [SiteRule] = []
    @State private var newSiteHost = ""
    @State private var cookieHostCount = 0
    @State private var apiToken = ""
    @State private var extensionID = ""
    @State private var gatewayStatus = ""

    var body: some View {
        Form {
            Section("剪贴板监听") {
                Toggle("自动捕获复制的下载链接", isOn: Binding(
                    get: { store.clipboardEnabled },
                    set: { store.setClipboardEnabled($0) }))
                Toggle("智能识别（仅下载类链接）", isOn: Binding(
                    get: { let k = "Siphon.clipboardSmartDetection"
                           return UserDefaults.standard.object(forKey: k) == nil
                               || UserDefaults.standard.bool(forKey: k) },
                    set: { store.setClipboardSmartDetection($0) }))
                Picker("捕获后行为", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "Siphon.clipboardMode") ?? "notify" },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.clipboardMode") }
                )) {
                    Text("弹出通知，点击后下载").tag("notify")
                    Text("自动添加为暂停任务").tag("auto")
                }
                .pickerStyle(.menu)
            }
            Section("视频站解析（yt-dlp）") {
                Toggle("解析视频站链接为直链", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "Siphon.ytdlp") },
                    set: { UserDefaults.standard.set($0, forKey: "Siphon.ytdlp") }))
                HStack(spacing: 8) {
                    Circle().fill(YtDlpResolver.available() ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(YtDlpResolver.available() ? "已检测到 yt-dlp" : "未安装 yt-dlp（brew install yt-dlp）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("本地控制接口") {
                Toggle("启用本地控制接口", isOn: Binding(
                    get: { store.browserCaptureEnabled },
                    set: { store.setBrowserCaptureEnabled($0) }))
                HStack {
                    Text("http://127.0.0.1:\(NativeMessagingServer.port)/add")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text(apiToken).font(.caption.monospaced()).lineLimit(1)
                        .truncationMode(.middle).textSelection(.enabled).help(apiToken)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(apiToken, forType: .string) }
                        label: { Image(systemName: "doc.on.doc") }.help("复制令牌")
                    Button { apiToken = LocalAuthToken.rotate(); LocalAuthToken.publishBootstrapFile() }
                        label: { Image(systemName: "arrow.clockwise") }.help("重新生成令牌")
                }
                Text("除 /ping 外所有请求需带 Authorization: Bearer <令牌>。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("浏览器扩展") {
                TextField("扩展 ID（留空使用默认）", text: $extensionID)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("安装原生网关") {
                        do {
                            let id = extensionID.trimmingCharacters(in: .whitespaces)
                            let written = try NativeMessagingHostInstaller.install(
                                extensionID: id.isEmpty ? "siphon-connector@inkeju.com" : id)
                            gatewayStatus = "已写入 \(written.count) 份清单"
                        } catch { gatewayStatus = error.localizedDescription }
                    }
                    Button("卸载网关", role: .destructive) {
                        NativeMessagingHostInstaller.uninstall(); gatewayStatus = "已卸载"
                    }
                    if let folder = NativeMessagingHostInstaller.extensionFolderURL() {
                        Button("打开扩展目录") { NSWorkspace.shared.open(folder) }
                    }
                }
                if !gatewayStatus.isEmpty {
                    Text(gatewayStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("站点规则（Referer / 文件名 / 请求头）") {
                ForEach($siteRules) { $rule in
                    DisclosureGroup($rule.wrappedValue.host.isEmpty ? "未命名站点" : $rule.wrappedValue.host) {
                        TextField("主机（example.com 或 *.example.com）", text: $rule.host)
                            .textFieldStyle(.roundedBorder)
                        TextField("Referer（可选，防盗链）", text: $rule.referer)
                            .textFieldStyle(.roundedBorder)
                        TextField("User-Agent（可选）", text: $rule.userAgent)
                            .textFieldStyle(.roundedBorder)
                        TextField("附加请求头（每行 Key: Value）", text: Binding(
                            get: { Self.headerText($rule.wrappedValue.extraHeaders) },
                            set: { $rule.wrappedValue.extraHeaders = Self.parseHeaders($0) }),
                                  axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        HStack {
                            Button("保存并应用") { SiteRuleStore.shared.replaceAll(siteRules) }
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
                    Text("已缓存 Cookie 主机：\(cookieHostCount)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空 Cookie 缓存", role: .destructive) {
                        CookieJar.shared.clear(); cookieHostCount = 0
                    }.controlSize(.small)
                }
                Text("规则只填补调用方未显式提供的请求头；Cookie 由扩展随链接透传并按主机缓存复用。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            siteRules = SiteRuleStore.shared.rules
            cookieHostCount = CookieJar.shared.hostCount
            apiToken = LocalAuthToken.current()
            extensionID = NativeMessagingHostInstaller.extensionID
        }
    }

    private static func headerText(_ headers: [String: String]) -> String {
        headers.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
    private static func parseHeaders(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            out[key] = value
        }
        return out
    }
}
