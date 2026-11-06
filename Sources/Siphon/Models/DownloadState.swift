import Foundation

public enum DownloadState: String, CaseIterable, Identifiable, Sendable {
    case pending, active, paused, completed, error, removed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pending:   return "等待中"
        case .active:    return "下载中"
        case .paused:    return "已暂停"
        case .completed: return "已完成"
        case .error:     return "出错"
        case .removed:   return "已移除"
        }
    }

    public var isTerminal: Bool { self == .completed || self == .removed }
}
