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
    @State private var providerID: String? = nil
    @State private var resolving = false
    @State private var resolveError: String?

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

            if DebridService.shared.enabled {
                HStack(alignment: .firstTextBaseline) {
                    Text("解析方式").frame(width: 82, alignment: .leading)
                    Picker("", selection: $providerID) {
                        Text("直连").tag(nil as String?)
                        ForEach(DebridService.shared.providers.filter {
                            DebridService.shared.hasToken(for: $0.id)
                        }, id: \.id) { provider in
                            Text(provider.displayName).tag(Optional(provider.id))
                        }
                    }
                    .labelsHidden()
                    if resolving { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 12))
                if let resolveError {
                    Text(resolveError).font(.caption).foregroundStyle(.red)
                }
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
            var finalURL = url
            var finalName = name.isEmpty ? nil : name
            if let providerID, let link = URL(string: url) {
                resolving = true
                defer { resolving = false }
                do {
                    let resolved = try await DebridService.shared.unrestrict(link, providerID: providerID)
                    finalURL = resolved.url.absoluteString
                    if finalName == nil { finalName = resolved.fileName }
                } catch {
                    resolveError = error.localizedDescription
                    return
                }
            }
            _ = await store.addMDMCommand(MDMCommand(url: finalURL,
                                                     dir: saveTo,
                                                     name: finalName,
                                                     description: description.isEmpty ? nil : description,
                                                     later: later,
                                                     action: "add",
                                                     category: categoryKey,
                                                     queue: queue))
            await MainActor.run { isPresented = false }
        }
    }
}

/// Link grabber. Two modes:
///  - "Links": one URL per line (or pasted page text), resolved by the existing
///    URI normaliser exactly like the main window.
///  - "Package": a page / FTP folder / Hugging Face repo / GitHub release is
///    scanned into a checkable tree; only the checked files are enqueued, with
///    their relative folders preserved under the download directory.
struct MDMLinkGrabberDialog: View {
    @Environment(DownloadStore.self) private var store
    @Binding var isPresented: Bool
    @State private var text = ""

    private enum Mode: String, CaseIterable, Identifiable {
        case links, package
        var id: String { rawValue }
        var title: String { self == .links ? "链接列表" : "网站包" }
    }

    @State private var mode: Mode = .links
    @State private var packageURL = ""
    @State private var root: PackageNode?
    @State private var scanTask: Task<Void, Never>?
    @State private var isScanning = false
    @State private var message = ""

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(MDMI18n.t("dialog.linkGrabber")).font(.headline)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            switch mode {
            case .links: linksMode
            case .package: packageMode
            }

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(MDMI18n.t("action.cancel")) {
                    scanTask?.cancel()
                    isPresented = false
                }
                switch mode {
                case .links:
                    Button("全部添加") {
                        for line in lines { store.addDroppedText(line) }
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(lines.isEmpty)
                case .package:
                    Button("添加所选") { addSelected() }
                        .keyboardShortcut(.defaultAction)
                        .disabled((root?.selectedFileCount ?? 0) == 0)
                }
            }
        }
        .padding(18)
        .frame(width: 600, height: 420)
        .onDisappear { scanTask?.cancel() }
    }

    // MARK: - Links mode

    private var linksMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每行一个链接；支持播放列表、专用链与花括号展开。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Text("\(lines.count) 个链接").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Package mode

    private var packageMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("https://example.com/files/ 或 Hugging Face / GitHub 仓库地址",
                          text: $packageURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { scan() }
                Button(isScanning ? "扫描中…" : "扫描") { scan() }
                    .disabled(isScanning || packageURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("支持 Index-of 页面、FTP 目录、Hugging Face 仓库与 GitHub Release。")
                .font(.caption).foregroundStyle(.secondary)

            if let root {
                HStack(spacing: 12) {
                    Text(root.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(root.selectedFileCount)/\(root.fileCount) 个文件")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Formatting.bytes(root.selectedSize))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("全选") { updateRoot { $0.setSelected(true) } }
                        .controlSize(.small)
                    Button("全不选") { updateRoot { $0.setSelected(false) } }
                        .controlSize(.small)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(root.children) { child in
                            PackageRow(node: child, depth: 0, toggle: toggle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 200)
            } else {
                ContentUnavailableView("尚未扫描", systemImage: "shippingbox",
                                       description: Text("输入地址后点击「扫描」构建可勾选的文件包。"))
                    .frame(minHeight: 200)
            }
        }
    }

    // MARK: - Actions

    private func scan() {
        let trimmed = packageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            message = "请输入完整地址（含 http:// 或 https://）"
            return
        }
        scanTask?.cancel()
        isScanning = true
        message = ""
        root = nil
        scanTask = Task {
            do {
                let tree = try await PackageResolver.resolve(url: url)
                await MainActor.run {
                    root = tree
                    isScanning = false
                    message = "已扫描 \(tree.fileCount) 个文件"
                }
            } catch {
                await MainActor.run {
                    isScanning = false
                    message = error.localizedDescription
                }
            }
        }
    }

    private func toggle(_ id: String) {
        updateRoot { _ = $0.toggle(id) }
    }

    private func updateRoot(_ mutate: (inout PackageNode) -> Void) {
        guard var tree = root else { return }
        mutate(&tree)
        tree.refreshFolderSelection()
        root = tree
    }

    private func addSelected() {
        guard let root else { return }
        let base = store.downloadDirectory
        let transfers = root.selectedTransfers()
        isPresented = false
        Task {
            for transfer in transfers {
                var dir = base
                if !transfer.relativeDirectory.isEmpty {
                    dir = base.appendingPathComponent(transfer.relativeDirectory, isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                _ = await store.addMDMCommand(MDMCommand(url: transfer.url.absoluteString,
                                                         dir: dir.path,
                                                         name: transfer.name,
                                                         checksum: transfer.checksum,
                                                         action: "add"))
            }
        }
    }
}

/// One row of the package tree. Folders cascade their checkbox; files toggle
/// only themselves. `node` is a value so the parent re-renders on any change.
private struct PackageRow: View {
    let node: PackageNode
    let depth: Int
    let toggle: (String) -> Void
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if node.isFolder {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 12)
                }
                Toggle("", isOn: Binding(
                    get: { node.isSelected },
                    set: { _ in toggle(node.id) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.mini)

                Image(systemName: node.isFolder ? "folder" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(node.isFolder ? Color.accentColor : .secondary)
                Text(node.name).font(.system(size: 12)).lineLimit(1)
                Spacer()
                if let size = node.size, !node.isFolder {
                    Text(Formatting.bytes(size))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * 14)

            if node.isFolder && expanded {
                ForEach(node.children) { child in
                    PackageRow(node: child, depth: depth + 1, toggle: toggle)
                }
            }
        }
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
