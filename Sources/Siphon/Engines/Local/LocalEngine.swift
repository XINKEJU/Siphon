import Foundation

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
            if task.protocol == .data {
                try await writeData(task)
            } else {
                try await copyFile(task)
            }
            guard !cancelled.contains(task.id) else {
                await delegate?.engineDidChangeState(taskID: task.id, state: .paused, error: nil)
                return
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: task.destination.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            var p = DownloadProgress(); p.totalBytes = size; p.downloadedBytes = size
            await delegate?.engineDidUpdate(taskID: task.id, progress: p)
            await delegate?.engineDidChangeState(taskID: task.id, state: .completed, error: nil)
        } catch {
            await delegate?.engineDidChangeState(taskID: task.id, state: .error, error: error)
        }
    }

    private func writeData(_ task: DownloadTask) async throws {
        let payload = try DataURICodec.decode(task.source.absoluteString)
        try? FileManager.default.createDirectory(
            at: task.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: task.destination)
    }

    private func copyFile(_ task: DownloadTask) async throws {
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
