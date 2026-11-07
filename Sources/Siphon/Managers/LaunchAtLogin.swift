import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+). `swift run` has no
/// bundle identifier, so registration throws; Settings surfaces that error
/// instead of pretending it succeeded.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已随登录启动"
        case .requiresApproval: return "需要在「系统设置 › 通用 › 登录项」中允许"
        case .notRegistered: return "未随登录启动"
        case .notFound: return "当前运行方式不支持开机自启（请使用打包后的 .app）"
        @unknown default: return "状态未知"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
