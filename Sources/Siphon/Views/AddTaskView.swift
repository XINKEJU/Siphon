import SwiftUI
import AppKit

/// "New download" sheet. Follows the macOS form convention: labelled rows in a
/// grouped layout, an explicit destination picker, and a prominent default action.
struct AddTaskView: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var name = ""
    @State private var queueName = "Default"
    @State private var showAdvanced = false
    @State private var userAgent = ""
    @State private var referer = ""
    @State private var detected: DownloadProtocol = .https

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新建下载").font(.title3.weight(.semibold))
                    Text("粘贴链接、磁力、eD2K 或流媒体播放列表地址")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    TextField("链接", text: $urlString, prompt: Text("https://… 或 magnet: / ed2k:// / .m3u8 / .mpd"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: urlString) { _, v in updateDetection(v) }

                    HStack {
                        Text("识别协议")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProtocolBadge(proto: detected)
                        Text(detected.requiresAria2 ? "aria2 引擎" : "原生引擎")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    TextField("文件名（可选）", text: $name)
                        .textFieldStyle(.roundedBorder)

                    Picker("队列", selection: $queueName) {
                        ForEach(store.queues.queues) { q in
                            Text(q.name).tag(q.name)
                        }
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
                    Text("自定义请求头会同时传给 aria2 与原生 HLS/DASH 引擎。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 250)

            Divider()

            HStack {
                if let clip = NSPasteboard.general.string(forType: .string),
                   clip.hasPrefix("http") || clip.hasPrefix("magnet") || clip.hasPrefix("ed2k") {
                    Button("粘贴剪贴板链接") {
                        urlString = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        updateDetection(urlString)
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始下载") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    private var isValid: Bool {
        URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            && !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateDetection(_ v: String) {
        guard let u = URL(string: v.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        detected = DownloadProtocol.detect(from: u)
    }

    private func commit() {
        var options: [String: String] = [:]
        if !userAgent.isEmpty { options["User-Agent"] = userAgent }
        if !referer.isEmpty { options["Referer"] = referer }
        store.add(urlString: urlString,
                  name: name.isEmpty ? nil : name,
                  queueName: queueName,
                  options: options)
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
