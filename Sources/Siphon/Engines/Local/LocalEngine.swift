import Foundation
import OSLog

/// Handles `file://` imports and `data:` URIs.
///
/// Why not just hand `file://` to aria2? aria2's `addUri` does not accept local
/// files as a source (except torrent/metalink via dedicated RPC methods), and a
/// `data:` URI is pure payload with no network stack. Both are cheap to do in Swift.
public final class LocalEngine: DownloadEngine {
    public let name = "local"
    public let supportedProtocols: Set<DownloadProtocol> = [.file, .data, .playlist]
    public weak var delegate: (any EngineDelegate)?

    private var cancelled: Set<UUID> = []
    private var tasks: [UUID: DownloadTask] = [:]

    private static let logger = Logger(subsystem: "com.xinkeju.siphon.macos",
                                       category: "local-engine")

    public init() {}
    public func canHandle(_ p: DownloadProtocol) -> Bool { supportedProtocols.contains(p) }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {
        SpeedLimitController.shared.setLimit(bytesPerSec)
    }

    public func submit(_ task: DownloadTask) async throws {
        tasks[task.id] = task
        cancelled.remove(task.id)
        Task { [weak self] in await self?.run(task) }
    }

    public func pause(_ id: UUID) async { cancelled.insert(id) }
    public func resume(_ id: UUID) async {
        cancelled.remove(id)
        if let t = tasks[id] { Task { [weak self] in await self?.run(t) } }
    }
    public func remove(_ id: UUID) async {
        cancelled.insert(id)
        tasks.removeValue(forKey: id)
    }

    private func run(_ task: DownloadTask) async {
        do {
            // Both writers return an independently known byte count, so the
            // completion check compares the destination against the source
            // instead of trusting whatever the destination happens to report.
            let expected: Int64 = task.protocol == .data
                ? try await writeData(task)
                : try await copyFile(task)
            guard !cancelled.contains(task.id) else {
                await delegate?.engineDidChangeState(taskID: task.id, state: .paused, error: nil)
                return
            }
            let evidence = CompletionSizePolicy.evidence(
                at: task.destination, expected: expected, allowsEmpty: expected == 0)
            if let reason = CompletionSizePolicy.failure(evidence) {
                Self.logger.error("completion size check failed for \(task.name, privacy: .private): \(reason, privacy: .public)")
                throw ExternalRunnerError.transferFailed(reason)
            }
            var p = DownloadProgress()
            p.totalBytes = evidence.actualBytes
            p.downloadedBytes = evidence.actualBytes
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
            await delegate?.engineDidChangeState(taskID: task.id, state: .completed, error: nil)
        } catch {
            await delegate?.engineDidChangeState(taskID: task.id, state: .error, error: error)
        }
    }

    private func writeData(_ task: DownloadTask) async throws -> Int64 {
        let payload = try DataURICodec.decode(task.source.absoluteString)
        try? FileManager.default.createDirectory(
            at: task.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: task.destination)
        return Int64(payload.count)
    }

    private func copyFile(_ task: DownloadTask) async throws -> Int64 {
        let src = task.source
        guard src.isFileURL else { throw ExternalRunnerError.invalidURL(src.absoluteString) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            throw ExternalRunnerError.transferFailed("本地文件不存在：\(src.path)")
        }
        let attrs = try fm.attributesOfItem(atPath: src.path)
        let total = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        try? fm.createDirectory(at: task.destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.removeItem(at: task.destination)
        guard fm.createFile(atPath: task.destination.path, contents: nil) else {
            throw ExternalRunnerError.transferFailed("无法创建目标文件")
        }
        let input = try FileHandle(forReadingFrom: src)
        let output = try FileHandle(forWritingTo: task.destination)
        defer { try? input.close(); try? output.close() }

        var written: Int64 = 0
        while !cancelled.contains(task.id) {
            let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            await SpeedLimitController.shared.consume(chunk.count)
            try output.write(contentsOf: chunk)
            written += Int64(chunk.count)
            var p = DownloadProgress()
            p.totalBytes = total; p.downloadedBytes = written
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
        }
        return total
    }
}

/// RFC 2397 `data:[<mediatype>][;base64],<data>`.
public enum DataURICodec {
    public enum Error: Swift.Error, LocalizedError {
        case malformed
        case invalidBase64
        public var errorDescription: String? {
            switch self {
            case .malformed: return "data: URI 缺少逗号分隔符"
            case .invalidBase64: return "data: URI 的 base64 内容无效"
            }
        }
    }

    public static func decode(_ raw: String) throws -> Data {
        guard raw.lowercased().hasPrefix("data:"),
              let comma = raw.firstIndex(of: ",") else { throw Error.malformed }
        let meta = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<comma]).lowercased()
        let body = String(raw[raw.index(after: comma)...])
        if meta.contains(";base64") {
            var b64 = body.replacingOccurrences(of: " ", with: "+")
            let rem = b64.count % 4
            if rem == 2 { b64 += "==" } else if rem == 3 { b64 += "=" }
            guard let d = Data(base64Encoded: b64) else { throw Error.invalidBase64 }
            return d
        }
        return Data((body.removingPercentEncoding ?? body).utf8)
    }

    public static func encode(_ data: Data, mimeType: String = "application/octet-stream") -> String {
        "data:\(mimeType);base64," + data.base64EncodedString()
    }
}
