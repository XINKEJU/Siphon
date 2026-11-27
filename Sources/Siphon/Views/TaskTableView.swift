import SwiftUI
import AppKit

/// Native task grid: SwiftUI owns the surrounding chrome, while AppKit provides
/// fourteen real columns, native multi-selection and persistent column geometry.
@MainActor
struct TaskTableRepresentable: NSViewRepresentable {
    let tasks: [DownloadTask]
    let store: DownloadStore
    @Binding var selectedTaskIDs: Set<UUID>
    @Binding var previewTask: DownloadTask?
    @Binding var isDropTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Bool
    let onOpen: ((DownloadTask) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            tasks: tasks,
            store: store,
            selection: $selectedTaskIDs,
            preview: $previewTask,
            dropTargeted: $isDropTargeted,
            onDrop: onDrop,
            onOpen: onOpen
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}

private enum TaskTableColumn: String, CaseIterable {
    case fileName, queue, size, status, timeLeft, transferRate, lastTry
    case description, added, source, peers, shareRatio, uploadSpeed, saveTo

    var title: String {
        switch self {
        case .fileName: return MDMI18n.t("column.fileName")
        case .queue: return MDMI18n.t("column.queue")
        case .size: return MDMI18n.t("column.size")
        case .status: return MDMI18n.t("column.status")
        case .timeLeft: return MDMI18n.t("column.timeLeft")
        case .transferRate: return MDMI18n.t("column.rate")
        case .lastTry: return MDMI18n.t("column.lastTry")
        case .description: return MDMI18n.t("column.description")
        case .added: return MDMI18n.t("column.added")
        case .source: return MDMI18n.t("column.source")
        case .peers: return MDMI18n.t("column.peers")
        case .shareRatio: return MDMI18n.t("column.shareRatio")
        case .uploadSpeed: return MDMI18n.t("column.uploadSpeed")
        case .saveTo: return MDMI18n.t("column.saveTo")
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .fileName: return 260
        case .queue: return 70
        case .size: return 86
        case .status: return 110
        case .timeLeft: return 84
        case .transferRate: return 100
        case .lastTry: return 140
        case .description: return 140
        case .added: return 140
        case .source: return 180
        case .peers: return 70
        case .shareRatio: return 90
        case .uploadSpeed: return 105
        case .saveTo: return 220
        }
    }
}

private struct TaskTableLayout: Codable {
    var order: [String] = TaskTableColumn.allCases.map(\.rawValue)
    var widths: [String: Double] = [:]
    var hidden: [String] = []
    var sortColumn: String? = TaskTableColumn.added.rawValue
    var sortAscending = false
}

/// The header is a single compact strip: clicking a column title sorts by it,
/// with the native sort indicator. Right-click opens the column visibility menu.
@MainActor
private final class TaskTableHeaderView: NSTableHeaderView {
    var visibilityMenu: (@MainActor () -> NSMenu)?

    private var titleHeight: CGFloat = 22

    override var isFlipped: Bool { true }

    override func headerRect(ofColumn column: Int) -> NSRect {
        var rect = super.headerRect(ofColumn: column)
        rect.origin.y = 0
        rect.size.height = titleHeight
        return rect
    }

    func sync(columns: [NSTableColumn], theme: MDMThemeStore) {
        titleHeight = theme.scaled(22)
        if frame.height != titleHeight {
            frame.size.height = titleHeight
            invalidateIntrinsicContentSize()
        }
        for column in columns {
            column.headerCell.font = .systemFont(ofSize: theme.scaled(11), weight: .medium)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = visibilityMenu?() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

@MainActor
private final class TaskNativeTableView: NSTableView {
    var contextMenuForRow: (@MainActor (Int) -> NSMenu?)?
    var dropProviders: @MainActor ([NSItemProvider]) -> Bool = { _ in false }
    var dropTargeted: @MainActor (Bool) -> Void = { _ in }
    var cancelSelection: @MainActor () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    override func rightMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let menu = contextMenuForRow?(row) else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func cancelOperation(_ sender: Any?) {
        cancelSelection()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTargeted(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTargeted(false)
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL],
           !urls.isEmpty {
            return dropProviders(urls.map { NSItemProvider(object: $0) })
        }
        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
           !strings.isEmpty {
            return dropProviders(strings.map { NSItemProvider(object: $0) })
        }
        return false
    }
}

@MainActor
private final class TaskTableRowView: NSTableRowView {
    var rowBackground = NSColor.clear
    var selectionBackground = NSColor.selectedContentBackgroundColor

    override func drawBackground(in dirtyRect: NSRect) {
        rowBackground.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        selectionBackground.setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class TaskActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() { handler() }
}

@MainActor
extension TaskTableRepresentable {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        private weak var scrollView: NSScrollView?
        private weak var tableView: TaskNativeTableView?
        private weak var headerView: TaskTableHeaderView?
        private var observers: [NSObjectProtocol] = []

        private var tasks: [DownloadTask] = []
        private var rows: [DownloadTask] = []
        private var store: DownloadStore?
        private var selection: Binding<Set<UUID>>?
        private var preview: Binding<DownloadTask?>?
        private var dropTargeted: Binding<Bool>?
        private var onOpen: ((DownloadTask) -> Void)?
        private let theme = MDMThemeStore.shared

        private var layoutState = Coordinator.loadLayout()
        private var sortColumn: TaskTableColumn = .added
        private var sortAscending = false
        private var isConfiguring = false
        private var isSynchronizingSelection = false

        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        func makeScrollView() -> NSScrollView {
            isConfiguring = true
            defer { isConfiguring = false }

            if let saved = layoutState.sortColumn.flatMap(TaskTableColumn.init(rawValue:)) {
                sortColumn = saved
            }
            sortAscending = layoutState.sortAscending

            let table = TaskNativeTableView(frame: .zero)
            table.delegate = self
            table.dataSource = self
            table.target = self
            table.doubleAction = #selector(doubleClicked(_:))
            table.allowsMultipleSelection = true
            table.allowsEmptySelection = true
            table.allowsColumnSelection = false
            table.allowsColumnReordering = true
            table.allowsColumnResizing = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.usesAlternatingRowBackgroundColors = false
            table.selectionHighlightStyle = .regular
            table.gridStyleMask = [.solidHorizontalGridLineMask]
            table.intercellSpacing = NSSize(width: 6, height: 2)
            table.rowSizeStyle = .custom

            let header = TaskTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 22))
            table.headerView = header
            self.tableView = table
            self.headerView = header

            for columnID in normalizedColumnOrder() {
                guard let kind = TaskTableColumn(rawValue: columnID) else { continue }
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(kind.rawValue))
                column.title = kind.title
                column.minWidth = 42
                column.maxWidth = 1_500
                let savedWidth = layoutState.widths[kind.rawValue].map { CGFloat($0) }
                column.width = min(1_500, max(42, savedWidth ?? kind.defaultWidth))
                column.resizingMask = .userResizingMask
                column.sortDescriptorPrototype = NSSortDescriptor(key: kind.rawValue, ascending: true)
                column.isHidden = layoutState.hidden.contains(kind.rawValue)
                table.addTableColumn(column)
            }
            table.sortDescriptors = [NSSortDescriptor(key: sortColumn.rawValue,
                                                       ascending: sortAscending)]

            let scroll = NSScrollView(frame: .zero)
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = true
            self.scrollView = scroll

            header.visibilityMenu = { [weak self] in
                self?.makeVisibilityMenu() ?? NSMenu()
            }
            table.contextMenuForRow = { [weak self] row in
                self?.contextMenu(at: row)
            }
            table.dropProviders = { [weak self] providers in
                guard let self, let handler = self.onDrop else { return false }
                return handler(providers)
            }
            table.dropTargeted = { [weak self] targeted in
                self?.dropTargeted?.wrappedValue = targeted
            }
            table.cancelSelection = { [weak self] in
                guard let self, let selection = self.selection else { return }
                if selection.wrappedValue.count > 1 { self.store?.clearSelection() }
            }

            for name in [NSTableView.columnDidMoveNotification, NSTableView.columnDidResizeNotification] {
                let observer = NotificationCenter.default.addObserver(
                    forName: name, object: table, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.columnGeometryChanged() }
                }
                observers.append(observer)
            }
            applyTheme()
            return scroll
        }

        private var onDrop: (([NSItemProvider]) -> Bool)?

        func update(tasks: [DownloadTask], store: DownloadStore,
                    selection: Binding<Set<UUID>>, preview: Binding<DownloadTask?>,
                    dropTargeted: Binding<Bool>, onDrop: @escaping ([NSItemProvider]) -> Bool,
                    onOpen: ((DownloadTask) -> Void)?) {
            self.tasks = tasks
            self.store = store
            self.selection = selection
            self.preview = preview
            self.dropTargeted = dropTargeted
            self.onDrop = onDrop
            self.onOpen = onOpen
            applyTheme()
            refreshRows()
        }

        private func applyTheme() {
            guard let tableView, let headerView else { return }
            tableView.backgroundColor = color(.listBackground)
            tableView.gridColor = color(.groupLine)
            tableView.rowHeight = theme.scaled(22)
            tableView.intercellSpacing = NSSize(width: theme.scaled(6), height: theme.scaled(2))
            scrollView?.backgroundColor = color(.listBackground)
            headerView.sync(columns: tableView.tableColumns, theme: theme)
            scrollView?.tile()
        }

        private func color(_ role: MDMRole) -> NSColor {
            NSColor(theme.color(role))
        }

        private func normalizedColumnOrder() -> [String] {
            let all = TaskTableColumn.allCases.map(\.rawValue)
            var result = layoutState.order.filter { all.contains($0) }
            var seen = Set(result)
            result = result.filter { seen.remove($0) != nil }
            result.append(contentsOf: all.filter { !result.contains($0) })
            return result
        }

        private static func loadLayout() -> TaskTableLayout {
            guard let data = UserDefaults.standard.data(forKey: layoutDefaultsKey),
                  let decoded = try? JSONDecoder().decode(TaskTableLayout.self, from: data) else {
                return TaskTableLayout()
            }
            return decoded
        }

        private static let layoutDefaultsKey = "Siphon.mdm.taskTable.layout.v1"

        private func saveLayout() {
            guard let tableView else { return }
            layoutState.order = tableView.tableColumns.map { $0.identifier.rawValue }
            layoutState.widths = Dictionary(uniqueKeysWithValues: tableView.tableColumns.map {
                ($0.identifier.rawValue, Double($0.width))
            })
            layoutState.hidden = tableView.tableColumns.filter(\.isHidden).map {
                $0.identifier.rawValue
            }
            layoutState.sortColumn = sortColumn.rawValue
            layoutState.sortAscending = sortAscending
            if let data = try? JSONEncoder().encode(layoutState) {
                UserDefaults.standard.set(data, forKey: Self.layoutDefaultsKey)
            }
        }

        @objc private func columnGeometryChanged() {
            guard !isConfiguring else { return }
            saveLayout()
            if let tableView {
                headerView?.sync(columns: tableView.tableColumns, theme: theme)
            }
        }

        private func makeVisibilityMenu() -> NSMenu {
            let menu = NSMenu()
            guard let tableView else { return menu }
            for column in tableView.tableColumns {
                let item = TaskActionMenuItem(title: column.title) { [weak self, weak column] in
                    guard let self, let column else { return }
                    column.isHidden.toggle()
                    self.saveLayout()
                    self.applyTheme()
                    self.refreshRows()
                }
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
            return menu
        }

        private func refreshRows() {
            guard let tableView else { return }
            let previousIDs = rows.map(\.id)
            rows = tasks
            rows.sort { lhs, rhs in
                let result = compare(lhs, rhs, column: sortColumn)
                if result == .orderedSame {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
            if previousIDs != rows.map(\.id) {
                tableView.reloadData()
            } else if !rows.isEmpty {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count),
                                     columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            }
            restoreSelection()
            headerView?.sync(columns: tableView.tableColumns, theme: theme)
        }

        private func restoreSelection() {
            guard let tableView, let selection else { return }
            let ids = selection.wrappedValue
            let indexes = IndexSet(rows.enumerated().compactMap { index, task in
                ids.contains(task.id) ? index : nil
            })
            guard tableView.selectedRowIndexes != indexes else { return }
            isSynchronizingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isSynchronizingSelection = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn, rows.indices.contains(row),
                  let column = TaskTableColumn(rawValue: tableColumn.identifier.rawValue) else {
                return nil
            }
            let identifier = NSUserInterfaceItemIdentifier("TaskTableCell.\(column.rawValue)")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.maximumNumberOfLines = 1
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -3),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            let task = rows[row]
            let value = text(for: task, column: column)
            cell.textField?.stringValue = value
            cell.textField?.font = font(for: column)
            cell.textField?.textColor = textColor(for: task, column: column)
            cell.textField?.lineBreakMode = [.fileName, .source, .saveTo].contains(column)
                ? .byTruncatingMiddle : .byTruncatingTail
            cell.toolTip = value == "—" ? nil : value
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = TaskTableRowView()
            view.rowBackground = color(row.isMultiple(of: 2) ? .listRow : .listRowAlternate)
            view.selectionBackground = color(.selection)
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection, let tableView, let selection else { return }
            selection.wrappedValue = Set(tableView.selectedRowIndexes.compactMap { index in
                rows.indices.contains(index) ? rows[index].id : nil
            })
        }

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isConfiguring, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let column = TaskTableColumn(rawValue: key) else { return }
            sortColumn = column
            sortAscending = descriptor.ascending
            saveLayout()
            refreshRows()
        }

        @objc private func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            let task = rows[row]
            isSynchronizingSelection = true
            sender.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isSynchronizingSelection = false
            selection?.wrappedValue = [task.id]
            onOpen?(task)
        }

        private func font(for column: TaskTableColumn) -> NSFont {
            switch column {
            case .size, .timeLeft, .transferRate, .peers, .shareRatio, .uploadSpeed:
                return .monospacedDigitSystemFont(ofSize: theme.scaled(11), weight: .regular)
            default:
                return .systemFont(ofSize: theme.scaled(11))
            }
        }

        private func textColor(for task: DownloadTask, column: TaskTableColumn) -> NSColor {
            if column == .status {
                switch task.state {
                case .completed: return color(.success)
                case .error: return color(.error)
                case .paused: return color(.warning)
                default: return color(.progressBar)
                }
            }
            switch column {
            case .queue, .description, .peers, .shareRatio, .uploadSpeed:
                return color(.secondaryText)
            default:
                return color(.text)
            }
        }

        private func isBT(_ task: DownloadTask) -> Bool {
            [.bittorrent, .magnet, .metalink].contains(task.protocol)
        }

        private func shareRatio(for task: DownloadTask) -> Double? {
            guard isBT(task), let uploaded = task.progress.uploadedBytes,
                  task.progress.downloadedBytes > 0 else { return nil }
            return Double(uploaded) / Double(task.progress.downloadedBytes)
        }

        private func text(for task: DownloadTask, column: TaskTableColumn) -> String {
            switch column {
            case .fileName:
                return task.name
            case .queue:
                return task.queueName
            case .size:
                return task.progress.totalBytes > 0 ? Formatting.bytes(task.progress.totalBytes) : "—"
            case .status:
                return MDMStatus(task.state).displayName
            case .timeLeft:
                return Formatting.eta(downloaded: task.progress.downloadedBytes,
                                      total: task.progress.totalBytes,
                                      speed: task.progress.speedBytesPerSec)
            case .transferRate:
                return task.progress.speedBytesPerSec > 0
                    ? Formatting.speed(task.progress.speedBytesPerSec) : "—"
            case .lastTry:
                return task.lastAttemptAt.map(dateFormatter.string(from:)) ?? "—"
            case .description:
                return task.note ?? task.errorDescription ?? "—"
            case .added:
                return dateFormatter.string(from: task.createdAt)
            case .source:
                return task.origin ?? task.source.absoluteString
            case .peers:
                return isBT(task) && task.progress.connectedPeers > 0
                    ? String(task.progress.connectedPeers) : "—"
            case .shareRatio:
                return shareRatio(for: task).map { String(format: "%.2f", $0) } ?? "—"
            case .uploadSpeed:
                guard isBT(task), let speed = task.progress.uploadSpeedBytesPerSec, speed > 0 else {
                    return "—"
                }
                return Formatting.speed(speed)
            case .saveTo:
                return task.destination.path
            }
        }

        private func compare(_ lhs: DownloadTask, _ rhs: DownloadTask,
                             column: TaskTableColumn) -> ComparisonResult {
            switch column {
            case .fileName:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .queue:
                return lhs.queueName.localizedCaseInsensitiveCompare(rhs.queueName)
            case .size:
                return compareValues(lhs.progress.totalBytes, rhs.progress.totalBytes)
            case .status:
                return MDMStatus(lhs.state).rawValue.compare(MDMStatus(rhs.state).rawValue)
            case .timeLeft:
                return compareOptionals(eta(for: lhs), eta(for: rhs))
            case .transferRate:
                return compareValues(lhs.progress.speedBytesPerSec, rhs.progress.speedBytesPerSec)
            case .lastTry:
                return compareOptionals(lhs.lastAttemptAt, rhs.lastAttemptAt)
            case .description:
                return text(for: lhs, column: .description).localizedCaseInsensitiveCompare(
                    text(for: rhs, column: .description))
            case .added:
                return compareValues(lhs.createdAt, rhs.createdAt)
            case .source:
                return text(for: lhs, column: .source).localizedCaseInsensitiveCompare(
                    text(for: rhs, column: .source))
            case .peers:
                return compareOptionals(isBT(lhs) && lhs.progress.connectedPeers > 0 ? lhs.progress.connectedPeers : nil,
                                        isBT(rhs) && rhs.progress.connectedPeers > 0 ? rhs.progress.connectedPeers : nil)
            case .shareRatio:
                return compareOptionals(shareRatio(for: lhs), shareRatio(for: rhs))
            case .uploadSpeed:
                return compareOptionals(isBT(lhs) ? lhs.progress.uploadSpeedBytesPerSec : nil,
                                        isBT(rhs) ? rhs.progress.uploadSpeedBytesPerSec : nil)
            case .saveTo:
                return lhs.destination.path.localizedCaseInsensitiveCompare(rhs.destination.path)
            }
        }

        private func eta(for task: DownloadTask) -> Double? {
            let progress = task.progress
            guard progress.speedBytesPerSec > 0,
                  progress.totalBytes > progress.downloadedBytes else { return nil }
            return Double(progress.totalBytes - progress.downloadedBytes)
                / Double(progress.speedBytesPerSec)
        }

        private func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
            return .orderedSame
        }

        private func compareOptionals<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
            switch (lhs, rhs) {
            case let (lhs?, rhs?): return compareValues(lhs, rhs)
            case (nil, nil): return .orderedSame
            case (nil, _?): return .orderedDescending
            case (_?, nil): return .orderedAscending
            }
        }

        // MARK: - Native context menus

        private func contextMenu(at row: Int) -> NSMenu? {
            guard let tableView, rows.indices.contains(row), let store else { return nil }
            if !tableView.isRowSelected(row) {
                isSynchronizingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isSynchronizingSelection = false
                selection?.wrappedValue = [rows[row].id]
            }
            return store.selectedTasks.count > 1
                ? batchContextMenu(store: store) : singleContextMenu(for: rows[row], store: store)
        }

        private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
            TaskActionMenuItem(title: title, handler: handler)
        }

        private func reveal(_ tasks: [DownloadTask]) {
            let urls = tasks.map(\.destination).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }

        private func batchContextMenu(store: DownloadStore) -> NSMenu {
            let menu = NSMenu()
            let ids = store.selectedTaskIDs
            let selected = store.selectedTasks
            let canPause = selected.contains { $0.state == .active || $0.state == .pending }
            let canResume = selected.contains { $0.state == .paused || $0.state == .error }
            let heading = NSMenuItem(title: "已选 \(selected.count) 项", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            menu.addItem(.separator())
            if canPause { menu.addItem(action("暂停") { store.pauseTasks(ids) }) }
            if canResume { menu.addItem(action("继续") { store.resumeTasks(ids) }) }
            menu.addItem(action("拷贝 \(selected.count) 条链接") { _ = store.copyLinks(ids) })
            let revealItem = action("在访达中显示") { [weak self] in self?.reveal(selected) }
            revealItem.isEnabled = selected.contains {
                FileManager.default.fileExists(atPath: $0.destination.path)
            }
            menu.addItem(revealItem)
            menu.addItem(.separator())
            menu.addItem(speedMenu(store: store, ids: ids))
            menu.addItem(priorityMenu(store: store, ids: ids))
            menu.addItem(.separator())
            menu.addItem(action("从列表移除（保留文件）") { store.removeTasks(ids) })
            menu.addItem(action("删除任务及文件") { store.pendingDeleteIDs = ids })
            menu.addItem(.separator())
            menu.addItem(action("取消选择") { store.clearSelection() })
            return menu
        }

        private func singleContextMenu(for task: DownloadTask, store: DownloadStore) -> NSMenu {
            let menu = NSMenu()
            if task.state == .active || task.state == .pending {
                menu.addItem(action("暂停") { store.pause(task.id) })
            }
            if task.state == .paused || task.state == .error {
                menu.addItem(action("继续") { store.resume(task.id) })
            }
            if FileManager.default.fileExists(atPath: task.destination.path) {
                menu.addItem(action("快速查看") {
                    QuickLookController.shared.present(urls: [task.destination])
                })
            }
            if task.state == .completed {
                menu.addItem(action("用默认应用打开") { store.openWithDefaultApp(task) })
                menu.addItem(action("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([task.destination])
                })
            } else if store.isPreviewable(task) {
                menu.addItem(action("边下边播") { [weak self] in self?.preview?.wrappedValue = task })
            }
            menu.addItem(action("显示详情…") { [weak self] in self?.onOpen?(task) })
            menu.addItem(.separator())
            menu.addItem(speedMenu(store: store, ids: [task.id], task: task))
            menu.addItem(priorityMenu(store: store, ids: [task.id], task: task))
            menu.addItem(.separator())
            menu.addItem(action("拷贝链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.source.absoluteString, forType: .string)
            })
            if !store.selectedTaskIDs.isEmpty {
                menu.addItem(action("取消选择") { store.clearSelection() })
            }
            menu.addItem(action("从列表移除（保留文件）") { store.remove(task.id) })
            menu.addItem(action("删除任务及文件") { store.pendingDeleteIDs = [task.id] })
            return menu
        }

        private func speedMenu(store: DownloadStore, ids: Set<UUID>,
                               task: DownloadTask? = nil) -> NSMenuItem {
            let submenu = NSMenu(title: "限速")
            func setLimit(_ value: Int64?) {
                if let task { store.setTaskSpeedLimit(task.id, value) }
                else { store.setSpeedLimit(ids, bytesPerSec: value) }
            }
            submenu.addItem(action("不限速") { setLimit(nil) })
            submenu.addItem(action("512 KB/s") { setLimit(524288) })
            submenu.addItem(action("1 MB/s") { setLimit(1_048_576) })
            submenu.addItem(action("5 MB/s") { setLimit(5_242_880) })
            let item = NSMenuItem(title: "限速", action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }

        private func priorityMenu(store: DownloadStore, ids: Set<UUID>,
                                  task: DownloadTask? = nil) -> NSMenuItem {
            let submenu = NSMenu(title: "优先级")
            for (title, value) in [("高", 1), ("普通", 0), ("低", -1)] {
                let item = action(title) {
                    if let task { store.setTaskPriority(task.id, value) }
                    else { store.setPriority(ids, value) }
                }
                if let task, task.priority == value { item.state = .on }
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: "优先级", action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }

        func dismantle() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            tableView?.delegate = nil
            tableView?.dataSource = nil
            tableView?.target = nil
            tableView?.contextMenuForRow = nil
            tableView?.dropProviders = { _ in false }
            tableView?.dropTargeted = { _ in }
            tableView?.cancelSelection = {}
            headerView?.visibilityMenu = nil
            store = nil
            onOpen = nil
            onDrop = nil
        }
    }
}
