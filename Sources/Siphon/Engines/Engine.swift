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
public protocol DownloadEngine: AnyObject {
    var name: String { get }
    var supportedProtocols: Set<DownloadProtocol> { get }
    var delegate: (any EngineDelegate)? { get set }

    func canHandle(_ p: DownloadProtocol) -> Bool
    func submit(_ task: DownloadTask) async throws
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func remove(_ id: UUID) async
    /// `nil` clears the limit. Native engines honour the token bucket; aria2 forwards to `--max-overall-download-limit`.
    func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async
}
