import Foundation

/// MDM's five user-visible states. The engine has finer states (probing,
/// verifying, merging, stopping); the list only ever shows these five.
/// Mapped onto Siphon's persisted `DownloadState` so existing `tasks.json`
/// files remain valid — this is an adapter, not a second state machine.
public enum MDMStatus: String, CaseIterable, Sendable, Identifiable {
    case queued
    case downloading
    case stopped
    case complete
    case error

    public var id: String { rawValue }

    public init(_ state: DownloadState) {
        switch state {
        case .pending:   self = .queued
        case .active:    self = .downloading
        case .paused:    self = .stopped
        case .completed: self = .complete
        case .error:     self = .error
        case .removed:   self = .stopped
        }
    }

    public var state: DownloadState {
        switch self {
        case .queued: return .pending
        case .downloading: return .active
        case .stopped: return .paused
        case .complete: return .completed
        case .error: return .error
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return MDMI18n.t("status.queued")
        case .downloading: return MDMI18n.t("status.downloading")
        case .stopped: return MDMI18n.t("status.stopped")
        case .complete: return MDMI18n.t("status.complete")
        case .error: return MDMI18n.t("status.error")
        }
    }

    public var isTerminal: Bool { self == .complete }
}

/// The four root branches of MDM's category tree plus the built-in file-type
/// categories. Custom categories are user-defined strings resolved at use.
public enum MDMCategory: String, CaseIterable, Sendable, Identifiable {
    case all, unfinished, finished, queues
    case general, compressed, documents, music, programs, video, torrents

    public var id: String { rawValue }

    public var isRoot: Bool {
        switch self {
        case .all, .unfinished, .finished, .queues: return true
        default: return false
        }
    }

    public var symbolName: String {
        switch self {
        case .all: return "tray.full"
        case .unfinished: return "arrow.down.circle"
        case .finished: return "checkmark.circle"
        case .queues: return "list.bullet.indent"
        case .general: return "doc"
        case .compressed: return "archivebox"
        case .documents: return "doc.text"
        case .music: return "music.note"
        case .programs: return "app.dashed"
        case .video: return "film"
        case .torrents: return "arrow.triangle.2.circlepath"
        }
    }

    public var displayName: String {
        switch self {
        case .all: return MDMI18n.t("category.all")
        case .unfinished: return MDMI18n.t("category.unfinished")
        case .finished: return MDMI18n.t("category.finished")
        case .queues: return MDMI18n.t("category.queues")
        case .general: return MDMI18n.t("category.general")
        case .compressed: return MDMI18n.t("category.compressed")
        case .documents: return MDMI18n.t("category.documents")
        case .music: return MDMI18n.t("category.music")
        case .programs: return MDMI18n.t("category.programs")
        case .video: return MDMI18n.t("category.video")
        case .torrents: return MDMI18n.t("category.torrents")
        }
    }

    /// File-type classification, ordered like MDM's default IDM categories.
    public static func categorize(fileName: String) -> MDMCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ["zip", "rar", "7z", "tar", "gz", "xz", "bz2", "tgz", "iso", "dmg"].contains(ext) {
            return .compressed
        }
        if ["mp3", "m4a", "flac", "wav", "ogg", "opus", "aac", "alac"].contains(ext) {
            return .music
        }
        if ["mp4", "mkv", "mov", "avi", "webm", "m4v", "ts", "flv"].contains(ext) {
            return .video
        }
        if ["torrent", "magnet", "metalink"].contains(ext) {
            return .torrents
        }
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "csv", "epub"].contains(ext) {
            return .documents
        }
        if ["exe", "msi", "app", "pkg", "deb", "rpm", "dmg", "apk", "bin"].contains(ext) {
            return .programs
        }
        return .general
    }

    public func contains(_ task: DownloadTask) -> Bool {
        switch self {
        case .all: return true
        case .unfinished: return task.state == .pending || task.state == .active || task.state == .paused || task.state == .error
        case .finished: return task.state == .completed
        case .queues: return !task.queueName.isEmpty
        default: return Self.categorize(fileName: task.name) == self
        }
    }
}
