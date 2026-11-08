import Foundation

// MARK: - Scope
//
// This module now ships a working native eD2K client:
//   * MD4 (RFC 1320), the eD2K file hash and local-file verification
//   * ed2k:// link parsing (file size, hash, embedded sources)
//   * a real eDonkey/eMule TCP transfer backend (`NativeED2KBackend`):
//     HELLO handshake, source discovery via OP_GETSOURCES, 180 KiB part
//     requests (32- and 64-bit), ordered writes and per-link hash verification
//   * the backend abstraction below, so tests can inject a capture backend
//
// Not implemented (requires a live P2P network and a full eMule stack):
// Kad/UDP DHT bootstrapping, protocol obfuscation, AICH hashsets, source
// exchange and the credit system. Links without embedded sources therefore need
// a configured eD2K server; otherwise the backend fails explicitly with
// `noSources` rather than pretending to download.

public enum ED2KError: Error, LocalizedError {
    case backendUnavailable
    case invalidLink(String)
    case hashMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "eD2K 传输后端未启用。"
        case .invalidLink(let s): return "无效的 ed2k 链接：\(s)"
        case .hashMismatch(let e, let a): return "校验失败：期望 \(e)，实际 \(a)"
        }
    }
}

/// Contract for a real eD2K core. `NativeED2KBackend` implements the native
/// eDonkey/eMule TCP transfer; tests may inject a capture backend instead.
public protocol ED2KBackend: AnyObject {
    /// Connect to an ED2K server / bootstrap Kad.
    func connect() async throws
    /// Begin transferring `link` into `destination`; report progress via `onProgress`.
    func download(_ link: ED2KLink, destination: URL,
                  onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws
    func cancel(fileHashHex: String) async
    /// Clear a previously-requested cancellation so the transfer can restart.
    func resumeTransfer(fileHashHex: String) async
}

/// Opt-out backend: explicitly refuses every transfer. Only used when a caller
/// wants to disable eD2K entirely; the app's default is `NativeED2KBackend`.
public final class UnavailableED2KBackend: ED2KBackend {
    public init() {}
    public func connect() async throws { throw ED2KError.backendUnavailable }
    public func download(_ link: ED2KLink, destination: URL,
                         onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        throw ED2KError.backendUnavailable
    }
    public func cancel(fileHashHex: String) async {}
    public func resumeTransfer(fileHashHex: String) async {}
}

/// UI-facing eD2K engine. Parses links, tracks GIDs, and delegates the actual transfer.
public final class ED2KEngine: DownloadEngine {
    public let name = "ed2k"
    public let supportedProtocols: Set<DownloadProtocol> = [.ed2k]
    public weak var delegate: (any EngineDelegate)?

    private var backend: ED2KBackend
    private var links: [UUID: ED2KLink] = [:]
    private var destinations: [UUID: URL] = [:]
    private var running: Set<UUID> = []

    public init(backend: ED2KBackend? = nil) {
        self.backend = backend ?? NativeED2KBackend(servers: ED2KServerList.shared.servers)
        NotificationCenter.default.addObserver(
            forName: ED2KServerList.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.reloadServers()
        }
    }

    /// Rebuild the transfer backend with the latest configured servers/Kad nodes.
    private func reloadServers() {
        backend = NativeED2KBackend(servers: ED2KServerList.shared.servers)
    }

    public func canHandle(_ p: DownloadProtocol) -> Bool { p == .ed2k }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {}

    public func submit(_ task: DownloadTask) async throws {
        let link = try ED2KURI.parse(task.source)
        links[task.id] = link
        destinations[task.id] = task.destination
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
            // Verify against the link hash — the core eD2K guarantee. The old
            // `try? ... , let ok = ..., !ok` chain turned a *thrown* verification
            // error into `nil` and fell through to `.completed`: a corrupt or
            // unreadable file was reported as a successful download.
            guard FileManager.default.fileExists(atPath: task.destination.path) else {
                await delegate?.engineDidChangeState(taskID: task.id, state: .error,
                    error: ED2KError.hashMismatch(expected: link.hashHex, actual: "文件缺失"))
                return
            }
            let matches: Bool
            do {
                matches = try ED2KHash.verify(fileAt: task.destination,
                                              matchesHex: link.hashHex)
            } catch {
                await delegate?.engineDidChangeState(taskID: task.id, state: .error,
                                                     error: error)
                return
            }
            guard matches else {
                let actual = (try? ED2KHash.hex(ED2KHash.hash(fileAt: task.destination))) ?? "?"
                await delegate?.engineDidChangeState(taskID: task.id, state: .error,
                    error: ED2KError.hashMismatch(expected: link.hashHex, actual: actual))
                return
            }
            await delegate?.engineDidChangeState(taskID: task.id, state: .completed, error: nil)
        } catch {
            running.remove(task.id)
            if case ED2KTransportError.cancelled = error {
                await delegate?.engineDidChangeState(taskID: task.id, state: .paused, error: nil)
            } else {
                await delegate?.engineDidChangeState(taskID: task.id, state: .error, error: error)
            }
        }
    }

    public func pause(_ id: UUID) async {
        running.remove(id)
        // Actually stop the wire transfer, not just the bookkeeping — otherwise
        // the download keeps running at full speed while marked paused, and a
        // later resume spawns a second concurrent writer on the same file.
        if let link = links[id] {
            await backend.cancel(fileHashHex: link.hashHex)
        }
        await delegate?.engineDidChangeState(taskID: id, state: .paused, error: nil)
    }

    public func resume(_ id: UUID) async {
        guard let link = links[id], let destination = destinations[id] else { return }
        await backend.resumeTransfer(fileHashHex: link.hashHex)
        running.insert(id)
        do {
            try await backend.download(link, destination: destination) { _ in }
            await delegate?.engineDidChangeState(taskID: id, state: .active, error: nil)
        } catch {
            await delegate?.engineDidChangeState(taskID: id, state: .error, error: error)
        }
    }

    public func remove(_ id: UUID) async {
        if let link = links.removeValue(forKey: id) {
            await backend.cancel(fileHashHex: link.hashHex)
        }
        destinations.removeValue(forKey: id)
        running.remove(id)
    }

    /// Public helper used by the UI / tests: compute the eD2K hash of a local file.
    public static func hashOfFile(at url: URL) throws -> String {
        ED2KHash.hex(try ED2KHash.hash(fileAt: url))
    }
}
