import Foundation
import Network
import Security

/// Live state for streaming previews. Engines report downloaded bytes through
/// `DownloadStore.engineDidUpdate`; the preview server uses that watermark to
/// avoid serving not-yet-written ranges (a preallocated `.part` file is full
/// size from the first byte, but its tail is still zeros on disk).
public final class PreviewRegistry: @unchecked Sendable {
    public static let shared = PreviewRegistry()

    public struct Entry: Sendable {
        public var taskID: UUID
        public var fileURL: URL
        public var totalBytes: Int64
        public var downloadedBytes: Int64
        public var updatedAt: Date
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    public init() {}

    public func register(taskID: UUID, fileURL: URL, totalBytes: Int64,
                         downloadedBytes: Int64) {
        lock.lock()
        entries[taskID] = Entry(taskID: taskID, fileURL: fileURL,
                                totalBytes: totalBytes,
                                downloadedBytes: max(0, downloadedBytes),
                                updatedAt: Date())
        lock.unlock()
    }

    /// Keep the watermark monotonic: a resumed transfer may briefly report fewer
    /// bytes, but the file on disk has not shrunk.
    public func update(taskID: UUID, downloaded: Int64, total: Int64) {
        lock.lock()
        guard var entry = entries[taskID] else { lock.unlock(); return }
        entry.downloadedBytes = max(entry.downloadedBytes, downloaded)
        if total > 0 { entry.totalBytes = total }
        entry.updatedAt = Date()
        entries[taskID] = entry
        lock.unlock()
    }

    /// Follow `.part` → final name after a completed atomic rename. No-op when
    /// nobody is previewing this task.
    @discardableResult
    public func retarget(taskID: UUID, fileURL: URL, totalBytes: Int64,
                         downloadedBytes: Int64) -> Bool {
        lock.lock()
        guard entries[taskID] != nil else { lock.unlock(); return false }
        entries[taskID] = Entry(taskID: taskID, fileURL: fileURL,
                                totalBytes: max(totalBytes, 0),
                                downloadedBytes: max(downloadedBytes, 0),
                                updatedAt: Date())
        lock.unlock()
        return true
    }

    public func entry(for taskID: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[taskID]
    }

    public func unregister(taskID: UUID) {
        lock.lock(); entries.removeValue(forKey: taskID); lock.unlock()
    }
}

/// Loopback HTTP server that lets AVPlayer stream a partially downloaded media
/// file. Requests must come from loopback and carry the per-process preview token:
///
///     GET /preview/<task-uuid>?token=<32 hex>
///
/// `Range` is honoured (206 / 416). Ranges that are not written yet block for
/// up to 30 s (the player behaves like a slow origin), then the connection ends.
public final class PreviewServer {
    public static let defaultPort: UInt16 = 17803

    public let port: UInt16
    public let token: String
    public private(set) var lastError: String?
    public var isRunning: Bool { listener != nil }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Siphon.PreviewServer", attributes: .concurrent)
    private let registry: PreviewRegistry

    public init(port: UInt16 = PreviewServer.defaultPort,
                token: String? = nil,
                registry: PreviewRegistry = .shared) {
        self.port = port
        self.token = token ?? PreviewServer.randomToken()
        self.registry = registry
    }

    /// 256 bits from the system CSPRNG. `NSUUID` is documented as random but
    /// not as a cryptographic source; this token guards direct reads of files
    /// on disk, so derive it from `SecRandomCopyBytes` instead.
    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            // CSPRNG failure must never produce an empty (trivially guessable)
            // token; NSUUID is still 122 bits of system randomness.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Length-independent, branch-free comparison so a guess cannot be refined
    /// byte by byte from response timing.
    public static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    public func url(for taskID: UUID) -> URL? {
        URL(string: "http://127.0.0.1:\(port)/preview/\(taskID.uuidString)?token=\(token)")
    }

    @discardableResult
    public func start() -> Bool {
        stop()
        lastError = nil
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any)
        guard let listener = try? NWListener(using: params) else {
            lastError = "无法创建边下边播监听（端口 \(port) 不可用）"
            return false
        }
        let ready = DispatchSemaphore(value: 0)
        var readyOK = false
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                readyOK = true
                ready.signal()
            case .failed(let error):
                self?.lastError = "边下边播服务启动失败：\(error.localizedDescription)"
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 1.5)
        guard readyOK else {
            listener.cancel()
            lastError = lastError ?? "边下边播服务启动超时（端口 \(port)）"
            return false
        }
        self.listener = listener
        return true
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
                guard let self else { conn.cancel(); return }
                if let data, !data.isEmpty { buffer.append(data) }
                if error != nil {
                    conn.cancel()
                    return
                }
                guard PreviewServer.hasHeaderBlock(buffer) else {
                    read()
                    return
                }
                self.serve(conn, request: buffer)
            }
        }
        read()
    }

    static func hasHeaderBlock(_ data: Data) -> Bool {
        data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil
    }

    private func serve(_ conn: NWConnection, request: Data) {
        guard let raw = String(data: request, encoding: .utf8) else {
            send(conn, status: "400 Bad Request", body: "bad request")
            return
        }
        let lines = raw.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            send(conn, status: "400 Bad Request", body: "bad request")
            return
        }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            send(conn, status: "405 Method Not Allowed", body: "method not allowed")
            return
        }
        guard Self.isLoopbackHost(lines) else {
            send(conn, status: "403 Forbidden", body: "invalid host")
            return
        }

        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        let query = split.count > 1 ? String(split[1]) : ""
        guard !token.isEmpty,
              let tokenValue = PreviewServer.queryValue("token", in: query),
              PreviewServer.constantTimeEqual(tokenValue, token) else {
            send(conn, status: "403 Forbidden", body: "invalid token")
            return
        }
        let prefix = "/preview/"
        guard path.hasPrefix(prefix),
              let id = UUID(uuidString: String(path.dropFirst(prefix.count))),
              let entry = registry.entry(for: id) else {
            send(conn, status: "404 Not Found", body: "unknown preview")
            return
        }

        let filesize = PreviewServer.fileSize(entry.fileURL)
        let total = entry.totalBytes > 0 ? entry.totalBytes : filesize
        guard total > 0 else {
            send(conn, status: "503 Service Unavailable", body: "not started")
            return
        }

        let rangeHeader = PreviewServer.header(named: "Range", in: lines)
        let range = PreviewServer.parseRange(rangeHeader, total: total)
        guard !range.invalid, range.start < total, range.end >= range.start else {
            send(conn, status: "416 Range Not Satisfiable",
                 extraHeaders: ["Content-Range": "bytes */\(total)"],
                 body: "range")
            return
        }

        let contentType = PreviewServer.contentType(for: entry.fileURL)
        let length = range.end - range.start + 1
        let head = "HTTP/1.1 206 Partial Content\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(length)\r\n"
            + "Content-Range: bytes \(range.start)-\(range.end)/\(total)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        let isHead = method == "HEAD"
        conn.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in
            // Cancel only after the headers are flushed; cancelling immediately
            // can reset the connection and leave the client without a status.
            if isHead { conn.cancel() }
        })

        if isHead { return }
        guard waitUntilAvailable(taskID: id, fileURL: entry.fileURL,
                                 offset: range.start, timeout: 30) else {
            conn.cancel()
            return
        }
        stream(conn, taskID: id, fileURL: entry.fileURL,
               start: range.start, end: range.end, total: total)
    }

    /// Poll the download watermark until the requested offset is present. Allows
    /// the player to open the URL immediately, even before the first frame arrives.
    private func waitUntilAvailable(taskID: UUID, fileURL: URL, offset: Int64,
                                    timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let size = PreviewServer.fileSize(fileURL)
            let entry = registry.entry(for: taskID)
            let downloaded = entry?.downloadedBytes ?? 0
            let watermark = downloaded > 0 ? min(size, downloaded) : size
            if watermark > offset || (offset == 0 && size > 0) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Read and send 1 MiB chunks, pausing at holes until the engine catches up.
    /// Backpressure comes from waiting on each `send` completion.
    private func stream(_ conn: NWConnection, taskID: UUID, fileURL: URL,
                        start: Int64, end: Int64, total: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            conn.cancel()
            return
        }
        defer { try? handle.close() }
        var sent = start
        var connectionClosed = false
        let deadline = Date().addingTimeInterval(30)

        while sent <= end, !connectionClosed {
            let size = PreviewServer.fileSize(fileURL)
            let entry = registry.entry(for: taskID)
            let downloaded = entry?.downloadedBytes ?? 0
            let watermark = downloaded > 0 ? min(size, downloaded) : size
            let availableEnd = watermark - 1
            if availableEnd < sent {
                if Date() >= deadline {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            let upper = min(end, availableEnd)
            let count = Int(min(Int64(1_048_576), upper - sent + 1))
            handle.seek(toFileOffset: UInt64(sent))
            let chunk = handle.readData(ofLength: count)
            guard !chunk.isEmpty else {
                if Date() >= deadline { break }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            let sem = DispatchSemaphore(value: 0)
            conn.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { connectionClosed = true }
                sem.signal()
            })
            sem.wait()
            sent += Int64(chunk.count)
        }
        conn.cancel()
    }

    // MARK: - helpers

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// DNS-rebinding guard. A request with no Host header used to be accepted:
    /// a raw loopback socket could omit it entirely and skip the check.
    static func isLoopbackHost(_ lines: [String]) -> Bool {
        guard let host = header(named: "Host", in: lines),
              !host.isEmpty,
              let name = hostName(from: host) else { return false }
        return loopbackHosts.contains(name)
    }

    /// Strip an optional port and IPv6 brackets: `[::1]:17803` → `::1`.
    static func hostName(from host: String) -> String? {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let inner = String(value[value.index(after: value.startIndex)..<close])
            return inner.isEmpty ? nil : inner
        }
        if value.filter({ $0 == ":" }).count > 1 { return value }
        let name = String(value.split(separator: ":").first ?? "")
        return name.isEmpty ? nil : name
    }

    private static func header(named name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let field = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            if field.lowercased() == name.lowercased() {
                return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func send(_ conn: NWConnection, status: String,
                      extraHeaders: [String: String] = [:], body: String) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        conn.send(content: (head + body).data(using: .utf8),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    static func queryValue(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, String(kv[0]) == name else { continue }
            return String(kv[1])
        }
        return nil
    }

    struct ByteRange {
        var start: Int64
        var end: Int64
        var invalid: Bool
    }

    /// Parse a single `bytes=` range. A missing header means "whole file".
    static func parseRange(_ raw: String?, total: Int64) -> ByteRange {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return ByteRange(start: 0, end: total - 1, invalid: false)
        }
        guard value.hasPrefix("bytes=") else {
            return ByteRange(start: 0, end: -1, invalid: true)
        }
        value = String(value.dropFirst("bytes=".count))
        guard !value.contains(",") else {
            return ByteRange(start: 0, end: -1, invalid: true)
        }
        let halves = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else {
            return ByteRange(start: 0, end: -1, invalid: true)
        }
        let left = String(halves[0]), right = String(halves[1])
        if left.isEmpty {
            // Suffix range: last N bytes.
            guard let n = Int64(right), n > 0 else {
                return ByteRange(start: 0, end: -1, invalid: true)
            }
            let start = max(0, total - n)
            return ByteRange(start: start, end: total - 1, invalid: false)
        }
        guard let start = Int64(left), start >= 0 else {
            return ByteRange(start: 0, end: -1, invalid: true)
        }
        var end = right.isEmpty ? total - 1 : (Int64(right) ?? -1)
        if end < 0 { return ByteRange(start: 0, end: -1, invalid: true) }
        end = min(end, total - 1)
        if start >= total || end < start {
            return ByteRange(start: start, end: end, invalid: true)
        }
        return ByteRange(start: start, end: end, invalid: false)
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? NSNumber)?.int64Value ?? 0
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mov": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "ts": return "video/mp2t"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}
