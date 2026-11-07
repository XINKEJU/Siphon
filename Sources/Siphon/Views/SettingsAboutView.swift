import SwiftUI
import AppKit

/// 关于 tab（应用信息 / 软件更新）。
struct AboutSettingsView: View {
    private let updater = UpdateChecker.shared
    @State private var updateFeedText = ""

    var body: some View {
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
        .onAppear { updateFeedText = updater.feedURL }
    }
}
