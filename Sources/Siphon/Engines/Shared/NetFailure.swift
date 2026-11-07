import Foundation

// MARK: - typed network failures (FluxDown net_failure.rs model)

enum NetFailure: Error {
    case timeout
    case connectFailed
    case dns
    case connectionReset
    case httpStatus(Int)          // includes 403 / 429 / 503 …
    case rangeMismatch            // 206 Content-Range start ≠ requested
    case serverIgnoredRanges      // 200 to a Range request
    case checksumMismatch
    case unsupportedChecksum(String)
    case incompleteBody
    case resumeUnsupported
    case sizeExpansionExhausted
    case lowSpeed                  // 持续低于低速阈值：换源/重试
    case diskWrite(String)         // deterministic local I/O failure (e.g. EFBIG)
    case cancelled
    case unknown(String)

    static func classify(_ error: Error) -> NetFailure {
        if let f = error as? NetFailure { return f }
        if let ue = error as? URLError {
            switch ue.code {
            case .timedOut: return .timeout
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .dns
            case .cannotLoadFromNetwork: return .connectFailed
            case .networkConnectionLost: return .connectionReset
            case .cancelled: return .cancelled
            default: return .unknown(ue.code.rawValue.description)
            }
        }
        if error is POSIXError { return .connectFailed }
        return .unknown("\(error)")
    }

    /// Whether retrying is pointless for this failure class.
    var isFatal: Bool {
        switch self {
        case .checksumMismatch, .unsupportedChecksum, .dns, .diskWrite, .lowSpeed: return true
        default: return false
        }
    }

    /// Fixed wait only for rate-limiting / timeouts (aria2: only 503 waits).
    func retryDelay(jittered: Bool) -> TimeInterval? {
        let base: TimeInterval?
        switch self {
        case .timeout, .connectionReset: base = 0.5
        case .httpStatus(503): base = 1.0
        case .httpStatus(429): base = 2.0
        default: base = nil
        }
        guard var d = base else { return nil }
        if jittered { d += Double.random(in: 0...(d * 0.25)) }
        return d
    }
}

extension NetFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout: return "连接超时"
        case .connectFailed: return "无法连接服务器"
        case .dns: return "域名解析失败"
        case .connectionReset: return "连接被重置"
        case .httpStatus(let code): return "服务器返回 HTTP \(code)"
        case .rangeMismatch: return "服务器返回的 Range 与请求不一致"
        case .serverIgnoredRanges: return "服务器不支持分段下载（忽略 Range）"
        case .checksumMismatch: return "校验和不匹配：下载内容与预期不符"
        case .unsupportedChecksum(let a): return "不支持的校验算法：\(a)"
        case .incompleteBody: return "下载不完整"
        case .resumeUnsupported: return "服务器不支持断点续传"
        case .sizeExpansionExhausted: return "文件大小持续增长，无法完成下载"
        case .lowSpeed: return "连接持续低速，已停止并尝试其他来源"
        case .diskWrite(let s): return "磁盘写入失败：\(s)"
        case .cancelled: return "已取消"
        case .unknown(let s): return "网络错误：\(s)"
        }
    }
}
