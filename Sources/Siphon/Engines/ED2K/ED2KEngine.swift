import Foundation

// MARK: - Honest scope statement
//
// This module implements the parts of eD2K that are self-contained and verifiable:
//   * MD4 (RFC 1320), the eD2K file hash and local-file verification
//   * ed2k:// link parsing (file size, hash, sources)
//   * the transport-facing backend abstraction below
//
// A *complete* eD2K transfer needs a full ED2K/Kademlia client: server login +
// ID assignment, `OP_ASKFILES` / search-by-hash, source exchange (OP_REQUESTFILENAME
// / OP_REQFILENAMESP), the peer handshake, 180 KiB part requests, the credit system,
// and Kad DHT source finding. That is a separate native library, not something a UI
// scaffold can reimplement correctly in one pass. The recommended integration paths
// are documented in README.md under "eD2K 传输后端".

public enum ED2KError: Error, LocalizedError {
    case backendUnavailable
    case invalidLink(String)
    case hashMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "eD2K 传输后端尚未接入。已解析链接并计算 eD2K 哈希，但 P2P 传输需要集成 libed2k / aMule 内核（见 README）。"
        case .invalidLink(let s): return "无效的 ed2k 链接：\(s)"
        case .hashMismatch(let e, let a): return "校验失败：期望 \(e)，实际 \(a)"
        }
    }
}

/// Contract for a real eD2K core. Implement this by bridging `libed2k` (C++) or
/// spawning an `aMule`/`amulecmd` daemon. `ED2KEngine` stays UI-facing and backend-agnostic.
public protocol ED2KBackend: AnyObject {
    /// Connect to an ED2K server / bootstrap Kad.
    func connect() async throws
    /// Begin transferring `link` into `destination`; report progress via `onProgress`.
    func download(_ link: ED2KLink, destination: URL,
                  onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws
    func cancel(fileHashHex: String) async
}

/// Default backend: deliberately reports that the native core is not wired up yet.
/// Kept explicit so the app never *pretends* an eD2K download succeeded.
public final class UnavailableED2KBackend: ED2KBackend {
    public init() {}
    public func connect() async throws { throw ED2KError.backendUnavailable }
    public func download(_ link: ED2KLink, destination: URL,
                         onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        throw ED2KError.backendUnavailable
    }
    public func cancel(fileHashHex: String) async {}
}

/// UI-facing eD2K engine. Parses links, tracks GIDs, and delegates the actual transfer.
public final class ED2KEngine: DownloadEngine {
    public let name = "ed2k"
    public let supportedProtocols: Set<DownloadProtocol> = [.ed2k]
    public weak var delegate: (any EngineDelegate)?

    private let backend: ED2KBackend
    private var links: [UUID: ED2KLink] = [:]
    private var running: Set<UUID> = []

    public init(backend: ED2KBackend = UnavailableED2KBackend()) {
        self.backend = backend
    }

    public func canHandle(_ p: DownloadProtocol) -> Bool { p == .ed2k }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {}

    public func submit(_ task: DownloadTask) async throws {
        let link = try ED2KURI.parse(task.source)
        links[task.id] = link
        running.insert(task.id)

        // Provide real, useful progress even before a backend exists: report the
        // target size so the UI can render a 0% task with the correct total.
        var p = DownloadProgress()
        p.totalBytes = link.fileSize
        await delegate?.engineDidUpdate(taskID: task.id, progress: p)

        do {
            try await backend.connect()
            try await backend.download(link, destination: task.destination) { [weak self] progress in
                Task { @MainActor in
                    self?.delegate?.engineDidUpdate(taskID: task.id, progress: progress)
                }
            }
            // Verify the resulting file against the link hash — the core eD2K guarantee.
            if FileManager.default.fileExists(atPath: task.destination.path),
               let ok = try? ED2KHash.verify(fileAt: task.destination, matchesHex: link.hashHex),
               !ok {
                let actual = (try? ED2KHash.hex(ED2KHash.hash(fileAt: task.destination))) ?? "?"
                await delegate?.engineDidChangeState(taskID: task.id, state: .error,
                                                     error: ED2KError.hashMismatch(expected: link.hashHex, actual: actual))
                return
            }
            await delegate?.engineDidChangeState(taskID: task.id, state: .completed, error: nil)
        } catch {
            running.remove(task.id)
            await delegate?.engineDidChangeState(taskID: task.id, state: .error, error: error)
        }
    }

    public func pause(_ id: UUID) async {
        running.remove(id)
        await delegate?.engineDidChangeState(taskID: id, state: .paused, error: nil)
    }

    public func resume(_ id: UUID) async {
        guard let link = links[id] else { return }
        running.insert(id)
        do {
            try await backend.download(link, destination: URL(fileURLWithPath: NSTemporaryDirectory())) { _ in }
            await delegate?.engineDidChangeState(taskID: id, state: .active, error: nil)
        } catch {
            await delegate?.engineDidChangeState(taskID: id, state: .error, error: error)
        }
    }

    public func remove(_ id: UUID) async {
        if let link = links.removeValue(forKey: id) {
            await backend.cancel(fileHashHex: link.hashHex)
        }
        running.remove(id)
    }

    /// Public helper used by the UI / tests: compute the eD2K hash of a local file.
    public static func hashOfFile(at url: URL) throws -> String {
        ED2KHash.hex(try ED2KHash.hash(fileAt: url))
    }
}
