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
        case .sitesLogins, .archives: IntegrationSettingsView()
        case .fileTypes: MDMFileTypesPage()
        case .saveTo: MDMSaveToPage()
        case .remote: MDMRemotePage()
        case .proxySocks: GatewaySettingsView()
        case .accounts: MDMAccountsPage()
        case .sounds: MDMSoundsPage()
        case .regional: MDMRegionalPage()
        }
    }
}

private struct MDMFileTypesPage: View {
    private let types = MDMCategory.allCases.filter { !$0.isRoot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按扩展名归类下载，分类树与列表列共用同一套规则。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(types, id: \.self) { category in
                HStack {
                    Image(systemName: category.symbolName)
                    Text(category.displayName)
                    Spacer()
                    Text(exampleExtensions(category))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private func exampleExtensions(_ category: MDMCategory) -> String {
        switch category {
        case .compressed: return "zip rar 7z tar gz xz iso"
        case .documents: return "pdf docx xlsx pptx txt epub"
        case .music: return "mp3 m4a flac wav opus"
        case .programs: return "exe msi app pkg deb apk"
        case .video: return "mp4 mkv mov webm ts"
        case .torrents: return "torrent magnet metalink"
        default: return "其他"
        }
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
            Text("路径写回 DownloadStore.downloadDirectory；新任务立即生效，已有任务保持原目标。")
                .font(.caption).foregroundStyle(.secondary)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("凭据只存系统钥匙串或 0600 文件；列表、API 与日志都不会回显令牌。")
                .font(.caption).foregroundStyle(.secondary)
            Text("Sites Logins 页管理站点登录；本页保留给后续 debrid / 账户服务。")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

private struct MDMSoundsPage: View {
    @AppStorage("Siphon.soundsEnabled") private var enabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("下载完成提示音", isOn: $enabled)
            Text("系统通知与 Dock 进度始终可用；提示音需要用户显式开启。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("界面语言", selection: $selected) {
                ForEach(languages) { Text($0.name).tag($0.code) }
            }
            .onChange(of: selected) { _, newValue in MDMI18n.shared.language = newValue }
            Text("MDM 的 87 语言通道以 tsv 目录驱动；Siphon 目前内置中文与英文，新增语言只需扩充目录。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
