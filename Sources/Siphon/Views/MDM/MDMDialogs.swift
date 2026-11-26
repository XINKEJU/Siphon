import SwiftUI
import AppKit

/// MDM's core dialogs. They are deliberately small wrappers around the
/// existing store methods: the rewrite changes the window/title/field layout,
/// not the download pipeline. All user-visible labels go through MDMI18n.
struct MDMAddURLDialog: View {
    @Environment(DownloadStore.self) private var store
    @Binding var isPresented: Bool
    @State private var url = ""
    @State private var name = ""
    @State private var description = ""
    @State private var categoryKey: String? = nil
    @State private var saveTo = ""
    @State private var later = false
    @State private var queue = "Default"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MDMI18n.t("dialog.addURL"))
                .font(.headline)
            field(MDMI18n.t("column.source"), text: $url, placeholder: "https://example.com/file.zip")
            field(MDMI18n.t("column.fileName"), text: $name, placeholder: MDMI18n.t("column.fileName"))
            field(MDMI18n.t("dialog.saveTo"), text: $saveTo, placeholder: store.downloadDirectory.path)

            HStack {
                Picker(MDMI18n.t("dialog.category"), selection: $categoryKey) {
                    Text(MDMCategory.general.displayName).tag(nil as String?)
                    ForEach(CategoryStore.shared.categories.filter {
                        $0.key != MDMCategory.general.rawValue
                    }) { cat in
                        Text(cat.name).tag(Optional(cat.key))
                    }
                }
                .frame(maxWidth: .infinity)
                Picker(MDMI18n.t("column.queue"), selection: $queue) {
                    ForEach(store.queues.queues.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 180)
            }

            field(MDMI18n.t("dialog.description"), text: $description, placeholder: "")

            Toggle(MDMI18n.t("dialog.downloadLater"), isOn: $later)

            HStack {
                Button(MDMI18n.t("action.cancel")) { isPresented = false }
                Spacer()
                Button(MDMI18n.t("dialog.downloadLater")) { submit(later: true) }
                    .disabled(url.isEmpty)
                Button(MDMI18n.t("dialog.startDownload")) { submit(later: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(18)
        .frame(width: 540)
        .onAppear { saveTo = store.downloadDirectory.path }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 82, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
        .font(.system(size: 12))
    }

    private func submit(later: Bool) {
        Task {
            _ = await store.addMDMCommand(MDMCommand(url: url,
                                                     dir: saveTo,
                                                     name: name.isEmpty ? nil : name,
                                                     description: description.isEmpty ? nil : description,
                                                     later: later,
                                                     action: "add",
                                                     category: categoryKey,
                                                     queue: queue))
            await MainActor.run { isPresented = false }
        }
    }
}

/// Link grabber: one URL per line, or pasted page text containing URLs.
/// Reuses the existing URI normaliser, so vendor/gateway/playlist links are
/// resolved exactly as they are in the main window.
struct MDMLinkGrabberDialog: View {
    @Environment(DownloadStore.self) private var store
    @Binding var isPresented: Bool
    @State private var text = ""

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MDMI18n.t("dialog.linkGrabber")).font(.headline)
            Text("每行一个链接；支持播放列表、专用链与花括号展开。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            HStack {
                Text("\(lines.count) 个链接").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(MDMI18n.t("action.cancel")) { isPresented = false }
                Button("全部添加") {
                    for line in lines { store.addDroppedText(line) }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(lines.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560, height: 340)
    }
}

struct MDMFindDialog: View {
    @Binding var isPresented: Bool
    @Binding var query: String
    var onFind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MDMI18n.t("dialog.find")).font(.headline)
            HStack {
                TextField(MDMI18n.t("column.fileName"), text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("查找下一个") { onFind() }
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                Spacer()
                Button(MDMI18n.t("action.close")) { isPresented = false }
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}

struct MDMSchedulerDialog: View {
    @Environment(DownloadStore.self) private var store
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MDMI18n.t("dialog.scheduler")).font(.headline)
            Toggle("仅在指定时段下载", isOn: Binding(
                get: { store.scheduleWindow.enabled },
                set: { store.scheduleWindow.enabled = $0 }
            ))
            HStack {
                Text("从")
                TextField("22:00", text: Binding(
                    get: { store.scheduleWindow.start },
                    set: { store.scheduleWindow.start = $0 }
                )).textFieldStyle(.roundedBorder).frame(width: 80)
                Text("到")
                TextField("07:00", text: Binding(
                    get: { store.scheduleWindow.end },
                    set: { store.scheduleWindow.end = $0 }
                )).textFieldStyle(.roundedBorder).frame(width: 80)
            }
            if !store.scheduleWindow.isValid && store.scheduleWindow.enabled {
                Text("时段无效：请输入 HH:mm，且起止时间不同。")
                    .font(.caption).foregroundStyle(.red)
            }
            Picker("全部完成后", selection: Binding(
                get: { store.completionAction },
                set: { store.completionAction = $0 }
            )) {
                ForEach(CompletionAction.allCases) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Spacer()
                Button(MDMI18n.t("action.close")) { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

struct MDMPropertiesDialog: View {
    @Environment(DownloadStore.self) private var store
    let task: DownloadTask
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var queue = "Default"
    @State private var priority = 0
    @State private var connections = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MDMI18n.t("dialog.properties")).font(.headline)
            detail(MDMI18n.t("column.source"), task.source.absoluteString)
            detail(MDMI18n.t("column.saveTo"), task.destination.path)
            detail(MDMI18n.t("column.size"), Formatting.bytes(task.progress.totalBytes))
            detail(MDMI18n.t("column.status"), MDMStatus(task.state).displayName)
            Divider()
            HStack {
                Text(MDMI18n.t("column.fileName")).frame(width: 78, alignment: .leading)
                TextField("", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker(MDMI18n.t("column.queue"), selection: $queue) {
                    ForEach(store.queues.queues.map(\.name), id: \.self) { Text($0).tag($0) }
                }
                Picker("优先级", selection: $priority) {
                    Text("高").tag(1); Text("普通").tag(0); Text("低").tag(-1)
                }
            }
            Stepper("连接数：\(connections)", value: $connections, in: 1...32)
            HStack {
                Spacer()
                Button(MDMI18n.t("action.cancel")) { isPresented = false }
                Button("应用") {
                    var updated = task
                    updated.name = name
                    updated.queueName = queue
                    updated.priority = priority
                    updated.connections = connections
                    store.remove(task.id)
                    store.add(updated)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            name = task.name
            queue = task.queueName
            priority = task.priority
            connections = task.connections
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 78, alignment: .leading).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
    }
}

struct MDMVerifyChecksumDialog: View {
    @Environment(DownloadStore.self) private var store
    @Binding var isPresented: Bool
    @State private var selectedID: UUID?
    @State private var spec = ""
    @State private var result = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MDMI18n.t("dialog.verifyChecksum")).font(.headline)
            Picker(MDMI18n.t("column.fileName"), selection: $selectedID) {
                Text("—").tag(nil as UUID?)
                ForEach(store.tasks.filter { $0.state == .completed }) { task in
                    Text(task.name).tag(task.id as UUID?)
                }
            }
            TextField("sha256:hex / md5:hex", text: $spec).textFieldStyle(.roundedBorder)
            if !result.isEmpty {
                Text(result).font(.caption).foregroundStyle(result.hasPrefix("✓") ? .green : .red)
            }
            HStack {
                Spacer()
                Button(MDMI18n.t("action.cancel")) { isPresented = false }
                Button("验证") { verify() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil || spec.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { selectedID = store.selectedTaskID }

    }

    private func verify() {
        guard let id = selectedID,
              let task = store.tasks.first(where: { $0.id == id }) else { return }
        do {
            result = try ChecksumVerifier.verify(fileAt: task.destination, spec: spec)
                ? "✓ 校验和匹配" : "✗ 校验和不匹配"
        } catch {
            result = "✗ \(error.localizedDescription)"
        }
    }
}
