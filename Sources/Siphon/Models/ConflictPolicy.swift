import Foundation

/// What to do when the target file already exists (on disk or in the task list).
public enum ConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case ask
    case rename
    case skip
    case overwrite

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ask: return "逐次询问"
        case .rename: return "自动重命名"
        case .skip: return "跳过"
        case .overwrite: return "覆盖"
        }
    }

    public static let defaultsKey = "Siphon.conflictPolicy"

    public static var current: ConflictPolicy {
        ConflictPolicy(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .rename
    }
}

/// 同一链接已经下载完成（且目标目录相同）时的处理策略。
/// 与 `ConflictPolicy` 区分：后者按文件名冲突，这里按 URL 判重。
public enum DuplicatePolicy: String, CaseIterable, Identifiable, Sendable {
    case ask
    case skip
    case redownload

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ask: return "逐次询问"
        case .skip: return "跳过"
        case .redownload: return "重新下载"
        }
    }

    public static let defaultsKey = "Siphon.duplicatePolicy"

    public static var current: DuplicatePolicy {
        DuplicatePolicy(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .ask
    }
}
