import Foundation
import Observation

/// MDM-aligned category store: the single source of truth for download
/// categories. Built-in file-type categories are seeded as default records;
/// users can add their own. Every category has a stable key, a display name,
/// an SF Symbol, a subfolder under the download root, the extensions that map
/// into it, and whether new tasks in it start immediately.
///
/// Persisted to `categories.json` (with a `.bak` fallback) next to `tasks.json`
/// in `MDMProduct.dataDirectory()`. `DownloadTask.category` stays a `String`
/// key so existing `tasks.json` files remain valid: built-in keys equal
/// `MDMCategory` rawValues, custom keys are UUID strings.
@MainActor
@Observable
public final class CategoryStore {
    public static let shared = CategoryStore()

    public private(set) var categories: [UserCategory]

    private let fileURL: URL
    private let backupURL: URL

    private init() {
        let dir = MDMProduct.dataDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("categories.json")
        self.backupURL = dir.appendingPathComponent("categories.json.bak")
        if let loaded = Self.load(fileURL: fileURL, backupURL: backupURL) {
            self.categories = loaded
        } else {
            self.categories = Self.defaultBuiltins()
            persist()
        }
    }

    // MARK: - resolution

    /// The category whose key matches (a built-in rawValue or a custom UUID
    /// string). Returns nil for empty / General-catch-all keys.
    public func category(forKey key: String?) -> UserCategory? {
        guard let key, !key.isEmpty else { return nil }
        return categories.first { $0.key == key }
    }

    /// The category whose extension list matches the file name. The longest
    /// matching extension wins (so `.tar.gz` beats `.gz`), regardless of which
    /// category declares it. Returns nil when nothing matches (→ General).
    public func category(for fileName: String) -> UserCategory? {
        let lower = fileName.lowercased()
        var best: (UserCategory, Int)?
        for cat in categories {
            for ext in cat.extensions where lower.hasSuffix("." + ext) {
                if best == nil || ext.count > best!.1 { best = (cat, ext.count) }
            }
        }
        return best?.0
    }

    /// On-disk subfolder for a category key, or nil for root / General.
    public func folderName(forKey key: String?) -> String? {
        guard let folder = category(forKey: key)?.folderName, !folder.isEmpty else { return nil }
        return folder
    }

    public func displayName(forKey key: String?) -> String {
        category(forKey: key)?.name ?? MDMCategory.general.displayName
    }

    /// Resolve which category a task belongs to: an explicit assignment wins,
    /// otherwise derive from the file name. Unmatched files resolve to General.
    public func resolvedKey(for task: DownloadTask) -> String {
        if let key = task.category, !key.isEmpty { return key }
        return category(for: task.name)?.key ?? MDMCategory.general.rawValue
    }

    // MARK: - persistence (mirrors DownloadStore: atomic write + .bak fallback)

    private static func load(fileURL: URL, backupURL: URL) -> [UserCategory]? {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UserCategory].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        if let data = try? Data(contentsOf: backupURL),
           let decoded = try? JSONDecoder().decode([UserCategory].self, from: data),
           !decoded.isEmpty {
            try? data.write(to: fileURL, options: .atomic)
            return decoded
        }
        return nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(categories) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let old = try? Data(contentsOf: fileURL) {
            try? old.write(to: backupURL, options: .atomic)
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - mutations

    @discardableResult
    public func add(name: String, symbolName: String, folderName: String,
                    extensions: [String], autoStart: Bool) -> UserCategory {
        let cat = UserCategory(key: UUID().uuidString,
                               name: name, symbolName: symbolName,
                               folderName: folderName,
                               extensions: Self.normalize(extensions),
                               autoStart: autoStart, isBuiltin: false)
        categories.append(cat)
        persist()
        return cat
    }

    public func update(_ updated: UserCategory) {
        guard let i = categories.firstIndex(where: { $0.key == updated.key }) else { return }
        var copy = updated
        copy.extensions = Self.normalize(updated.extensions)
        categories[i] = copy
        persist()
    }

    /// Remove a custom category. Built-ins cannot be removed. Tasks that were
    /// assigned to it are migrated to General (their `category` is cleared);
    /// already-downloaded files are never moved on disk.
    public func remove(key: String, store: DownloadStore) {
        guard let cat = category(forKey: key), !cat.isBuiltin else { return }
        categories.removeAll { $0.key == key }
        for i in store.tasks.indices where store.tasks[i].category == key {
            store.tasks[i].category = nil
        }
        persist()
    }

    /// Lowercase, strip leading dots, drop blanks, longest first.
    private static func normalize(_ extensions: [String]) -> [String] {
        extensions
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    // MARK: - default built-ins (match MDMCategory keys + current folder names)

    private static func defaultBuiltins() -> [UserCategory] {
        func builtin(_ cat: MDMCategory, name: String, folder: String, exts: [String]) -> UserCategory {
            UserCategory(key: cat.rawValue, name: name, symbolName: cat.symbolName,
                         folderName: folder, extensions: exts, autoStart: true, isBuiltin: true)
        }
        return [
            builtin(.general, name: MDMCategory.general.displayName, folder: "", exts: []),
            builtin(.compressed, name: "压缩包", folder: "压缩包",
                    exts: ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "tgz", "iso", "dmg"]),
            builtin(.documents, name: "文档", folder: "文档",
                    exts: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "csv", "epub", "md"]),
            builtin(.music, name: "音乐", folder: "音乐",
                    exts: ["mp3", "m4a", "flac", "wav", "ogg", "opus", "aac", "alac", "wma"]),
            builtin(.programs, name: "软件", folder: "软件",
                    exts: ["exe", "msi", "app", "pkg", "deb", "rpm", "apk", "bin", "ipa"]),
            builtin(.video, name: "视频", folder: "视频",
                    exts: ["mp4", "mkv", "mov", "avi", "webm", "m4v", "ts", "flv", "wmv", "m2ts"]),
            builtin(.torrents, name: "种子", folder: "种子",
                    exts: ["torrent", "magnet", "metalink", "meta4"]),
        ]
    }
}

/// One category record. `key` is the stable identifier stored in
/// `DownloadTask.category`; built-in keys mirror `MDMCategory` rawValues so
/// existing task lists keep resolving after the migration.
public struct UserCategory: Codable, Identifiable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var symbolName: String
    public var folderName: String
    public var extensions: [String]
    public var autoStart: Bool
    public var isBuiltin: Bool

    public var id: String { key }

    public init(key: String, name: String, symbolName: String, folderName: String,
                extensions: [String], autoStart: Bool, isBuiltin: Bool) {
        self.key = key
        self.name = name
        self.symbolName = symbolName
        self.folderName = folderName
        self.extensions = extensions
        self.autoStart = autoStart
        self.isBuiltin = isBuiltin
    }
}
