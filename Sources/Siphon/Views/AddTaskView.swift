import SwiftUI
import AppKit

/// "New download" sheet. Grouped form for content, glass identity card above,
/// and a single glass button group at the bottom. macOS convention: labelled
/// rows, explicit destination picker, prominent default action.
struct AddTaskView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var name = ""
    @State private var queueName = "Default"
    @State private var priority = 0
    @State private var showAdvanced = false
    @State private var userAgent = ""
    @State private var referer = ""
    @State private var checksumText = ""
    @State private var detected: DownloadProtocol = .https
    @State private var clipboardLink: String?
    @State private var videoSite = false
    @State private var ytdlpQuality: YtDlpResolver.Quality = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Floating identity card. It also surfaces the detected protocol,
            // so the glass has a meaningful job instead of being decorative.
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新建下载").font(.title3.weight(.semibold))
                    Text("链接、专用链、网关地址，或多行批量列表")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                ProtocolBadge(proto: detected)
            }
            .padding(18)
            .glassCard(cornerRadius: 16)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .onAppear(perform: loadClipboard)

            Divider().padding(.top, 14)

            Form {
                Section {
                    TextField("链接（可多行，每行一个）", text: $urlString, prompt: Text("https://… / thunder:// / ipfs:// / s3:// / img_{001..100}.jpg"), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .onChange(of: urlString) { _, v in updateDetection(v) }

                    LabeledContent("下载引擎", value: detected.transport.displayName)

                    Text(URINormalizer.capabilitySummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("文件名（可选）", text: $name)
                        .textFieldStyle(.roundedBorder)

                    if videoSite {
                        Picker("视频画质", selection: $ytdlpQuality) {
                            ForEach(YtDlpResolver.Quality.allCases) { q in
                                Text(q.label).tag(q)
                            }
                        }
                        Text("由 yt-dlp 下载，音视频分离时通过 ffmpeg 自动合并（需要本机安装 ffmpeg）。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    Picker("队列", selection: $queueName) {
                        ForEach(store.queues.queues) { q in
                            Text(q.name).tag(q.name)
                        }
                    }
                    Picker("优先级", selection: $priority) {
                        Text("低（-1）").tag(-1)
                        Text("普通（0）").tag(0)
                        Text("高（1）").tag(1)
                    }

                    HStack {
                        Text("保存到")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(store.downloadDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("更改…") { chooseDirectory() }
                            .controlSize(.small)
                    }
                }

                DisclosureGroup("高级选项", isExpanded: $showAdvanced) {
                    TextField("User-Agent", text: $userAgent)
                        .textFieldStyle(.roundedBorder)
                    TextField("Referer", text: $referer)
                        .textFieldStyle(.roundedBorder)
                    Text("自定义请求头会传给 aria2、libcurl 与原生 HLS/DASH 引擎。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    TextField("校验和（可选）", text: $checksumText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("下载完成后自动校验，不符则自动重下一次。支持 sha512:/sha384:/sha256:/sha1:/md5: 前缀；纯十六进制串按 SHA-256 处理。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 250)

            Divider()

            // One lens system for the whole action row, so adjacent glass
            // buttons merge rather than stacking separate blurs.
            GlassGroup(spacing: 10) {
                if let clip = clipboardLink {
                    Button("粘贴剪贴板链接") {
                        urlString = clip
                        updateDetection(urlString)
                    }
                    .controlSize(.small)
                    .glassButton()
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
                Button("开始下载") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                    .glassButton(prominent: true)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    private var isValid: Bool {
        let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.contains("\n") { return !PlaylistImporter.parse(t).isEmpty }
        return URL(string: t)?.scheme != nil
    }

    /// Read the pasteboard once on appear, not on every body evaluation.
    private func loadClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://") { clipboardLink = t }
    }

    private func updateDetection(_ v: String) {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        videoSite = false
        if t.contains("\n") { detected = .playlist; return }
        guard let u = URL(string: t) else { return }
        detected = DownloadProtocol.detect(from: u)
        // 只有 yt-dlp 可用且站点受支持时才展示画质选项。
        videoSite = UserDefaults.standard.bool(forKey: "Siphon.ytdlp")
            && YtDlpResolver.available()
            && YtDlpResolver.isSupported(u)
    }

    private func commit() {
        var options: [String: String] = [:]
        if !userAgent.isEmpty { options["User-Agent"] = userAgent }
        if !referer.isEmpty { options["Referer"] = referer }
        let trimmedChecksum = checksumText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.add(urlString: urlString,
                  name: name.isEmpty ? nil : name,
                  queueName: queueName,
                  options: options,
                  checksum: trimmedChecksum.isEmpty ? nil : trimmedChecksum.lowercased(),
                  priority: priority,
                  ytdlpQuality: videoSite ? ytdlpQuality : .auto)
        dismiss()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            store.downloadDirectory = url
        }
    }
}
