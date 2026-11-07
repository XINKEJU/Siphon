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
