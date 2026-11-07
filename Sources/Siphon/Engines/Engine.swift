import Foundation

/// Receives progress/state events from any engine. Always delivered on the main actor
/// so SwiftUI bindings can be updated directly.
@MainActor
public protocol EngineDelegate: AnyObject {
    func engineDidUpdate(taskID: UUID, progress: DownloadProgress)
    func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?)
}

/// Uniform interface every download engine exposes. Implementations:
/// Aria2Engine (HTTP/FTP/SFTP/BT/Metalink/magnet), HLSEngine, DASHEngine, ED2KEngine.
/// 一个下载分段的实时进度快照（用于检查器里的分段可视化）。
public struct SegmentSnapshot: Sendable, Identifiable, Equatable {
    public let start: Int64
    /// 含结束字节；`-1` 表示总大小未知。
    public let end: Int64
    public let cursor: Int64

    public var id: Int64 { start }
    public var knownEnd: Bool { end >= start }
    public var span: Int64 { knownEnd ? end - start + 1 : 0 }
    /// 该分段已完成的比例（0...1）。
    public var fraction: Double {
        guard knownEnd, span > 0 else { return 0 }
        return min(1, max(0, Double(cursor - start) / Double(span)))
    }

    public init(start: Int64, end: Int64, cursor: Int64) {
        self.start = start; self.end = end; self.cursor = cursor
    }
}

public protocol DownloadEngine: AnyObject {
    var name: String { get }
    var supportedProtocols: Set<DownloadProtocol> { get }
    var delegate: (any EngineDelegate)? { get set }

    func canHandle(_ p: DownloadProtocol) -> Bool
    func submit(_ task: DownloadTask) async throws
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func remove(_ id: UUID) async
    /// 活跃分段快照；不支持分段可视化的引擎返回空数组。
    func segmentSnapshot(for id: UUID) -> [SegmentSnapshot]
    /// `nil` clears the limit. Native engines honour the token bucket; aria2 forwards to `--max-overall-download-limit`.
    func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async
    /// Hot-updatable per-task speed limit (bytes/s). Folds under the global cap:
    /// the effective limit is `min(global, perTask)`. Engines that cannot throttle
    /// a single task (e.g. subprocess tools) may implement this as a no-op.
    func setTaskSpeedLimit(_ id: UUID, bytesPerSec: Int64?) async
}

public extension DownloadEngine {
    /// Default no-op so engines that don't support per-task throttling don't have
    /// to implement it. Native engines override this.
    func setTaskSpeedLimit(_ id: UUID, bytesPerSec: Int64?) async {}
    /// 默认不支持分段可视化。
    func segmentSnapshot(for id: UUID) -> [SegmentSnapshot] { [] }
}
