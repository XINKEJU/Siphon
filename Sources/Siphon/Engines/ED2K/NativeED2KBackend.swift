import Foundation

/// Native Swift eD2K / eMule **client-to-client TCP transport**.
///
/// This is a real wire-protocol implementation, not a stub. It speaks the
/// eDonkey/eMule TCP framing defined in `ED2KProtocol.swift`:
///
///   1. HELLO (0xE3/0x01) + eMule info (0xC5/0x01), read HELLOANSWER (0x4C)
///   2. STARTUPLOADREQ (0x54), read ACCEPTUPLOADREQ (0x55)
///   3. REQUESTPARTS (0x47), read SENDINGPART (0x46) for each 180 KiB block
///   4. write each block at its absolute offset, report progress, verify size
///   5. END_OF_DOWNLOAD (0x49)
///
/// Sources come from the link's own `|sources,host:port|` entries and, when the
/// link carries none, from an eD2K server via OP_GETSOURCES / OP_FOUND_SOURCES.
/// `ED2KEngine` verifies the final file against the link's eD2K hash, so a peer
/// that lies about its data can never produce a "successful" download.
///
/// Honest scope: this implements the **client TCP transfer path**. It does NOT
/// implement Kad (UDP DHT) bootstrapping, protocol obfuscation/encryption,
/// AICH hashsets, source exchange or the credit system — those require a live
/// P2P network and a full eMule stack. A link with no sources and no configured
/// server therefore fails with an explicit `noSources` error instead of hanging
/// or pretending to succeed. No part of this backend fabricates file bytes.
public final class NativeED2KBackend: ED2KBackend, @unchecked Sendable {

    /// Cancellation state lives in its own synchronously-locked object so no
    /// `NSLock` call is made directly from an async context (Swift 6 warning).
    private final class CancelState: @unchecked Sendable {
        private let lock = NSLock()
        private var set: Set<String> = []
        func cancel(_ hash: String) {
            lock.lock(); defer { lock.unlock() }
            set.insert(hash.lowercased())
        }
        func resumeTransfer(_ hash: String) {
            lock.lock(); defer { lock.unlock() }
            set.remove(hash.lowercased())
        }
        func contains(_ hash: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return set.contains(hash.lowercased())
        }
    }

    private let cancelled = CancelState()
    private let workQueue = DispatchQueue(label: "siphon.ed2k.tcp", qos: .userInitiated)

    /// Optional eD2K servers used for source discovery, e.g. `["server:4661"]`.
    /// Empty means "only use sources embedded in the link".
    private let servers: [(host: String, port: Int)]

    public init(servers: [(host: String, port: Int)] = []) {
        self.servers = servers
    }

    public func connect() async throws {
        // Connections are per-source and opened lazily inside download(). There
        // is no long-lived socket to establish here; keeping this a no-op also
        // avoids failing a link that already carries usable sources.
    }

    public func cancel(fileHashHex: String) async {
        cancelled.cancel(fileHashHex)
    }

    public func resumeTransfer(fileHashHex: String) async {
        cancelled.resumeTransfer(fileHashHex)
    }

    private func isCancelled(_ hash: String) -> Bool {
        cancelled.contains(hash)
    }

    public func download(_ link: ED2KLink, destination: URL,
                         onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            workQueue.async {
                do {
                    try self.transfer(link: link, destination: destination,
                                      onProgress: onProgress)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Transfer (runs on workQueue, blocking BSD sockets)

    private func transfer(link: ED2KLink, destination: URL,
                          onProgress: @escaping @Sendable (DownloadProgress) -> Void) throws {
        let fileHash = try ed2kHashBytes(link.hashHex)
        guard link.fileSize > 0 else { throw ED2KError.invalidLink("文件大小为 0") }
        let total = UInt64(link.fileSize)          // all offsets are unsigned
        let use64 = total > UInt64(UInt32.max)

        var sources = link.sources
        if sources.isEmpty && !servers.isEmpty {
            sources = discoverSources(fileHash: fileHash, fileSize: total)
        }
        guard !sources.isEmpty else {
            throw ED2KTransportError.noSources(
                "链接未携带 |sources,host:port|，且未配置可用的 eD2K 服务器；" +
                "Kad DHT 引导未实现，无法凭哈希自行寻源")
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destination.path) {
            guard fm.createFile(atPath: destination.path, contents: Data()) else {
                throw ED2KTransportError.ioFailed("无法创建目标文件")
            }
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: total)

        let progressTotal = link.fileSize                 // Int64 for DownloadProgress
        let blockSize = UInt64(ED2KOpcode.blockSize)
        let blockCount = Int((total + blockSize - 1) / blockSize)
        func rangeOf(_ i: Int) -> (start: UInt64, end: UInt64) {
            let start = UInt64(i) * blockSize
            return (start, min(start + blockSize, total))
        }

        var remaining = Set(0..<blockCount)
        var written: Int64 = 0
        var connectedPeers = 0
        let started = Date()

        for source in sources where !remaining.isEmpty {
            if isCancelled(link.hashHex) { throw ED2KTransportError.cancelled }
            do {
                let got = try drainPeer(source: source, fileHash: fileHash,
                                        total: total, use64: use64,
                                        remaining: &remaining, handle: handle,
                                        blockCount: blockCount, rangeOf: rangeOf,
                                        onProgress: { bytes in
                    written += bytes
                    var p = DownloadProgress()
                    p.totalBytes = progressTotal
                    p.downloadedBytes = min(written, progressTotal)
                    p.connectedPeers = connectedPeers
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed > 0 { p.speedBytesPerSec = Int64(Double(written) / elapsed) }
                    onProgress(p)
                })
                if got > 0 { connectedPeers += 1 }
            } catch let e as ED2KTransportError {
                // A single bad source must not abort the transfer; try the next.
                if case .cancelled = e { throw e }
                continue
            }
        }

        guard remaining.isEmpty else {
            throw ED2KTransportError.incomplete(
                "仍有 \(remaining.count)/\(blockCount) 个分块未取到（\(sources.count) 个源均不可用）")
        }

        var done = DownloadProgress()
        done.totalBytes = progressTotal
        done.downloadedBytes = progressTotal
        done.connectedPeers = connectedPeers
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0 { done.speedBytesPerSec = Int64(Double(progressTotal) / elapsed) }
        onProgress(done)
    }

    /// Talk to one peer until it stops producing blocks. Returns blocks received.
    private func drainPeer(
        source: (host: String, port: Int), fileHash: Data, total: UInt64,
        use64: Bool, remaining: inout Set<Int>, handle: FileHandle,
        blockCount: Int, rangeOf: (Int) -> (start: UInt64, end: UInt64),
        onProgress: (Int64) -> Void
    ) throws -> Int {
        let socket = try ED2KSocket(host: source.host, port: source.port)
        defer { socket.close() }

        try socket.send(frame: ED2KMessages.hello())
        try socket.send(frame: ED2KMessages.emuleInfo())

        // Handshake: skip chatty frames until HELLOANSWER or a bounded number of reads.
        var handshakeOK = false
        for _ in 0..<12 {
            let f = try socket.readFrame()
            if f.marker == ED2KProto.packed { continue }  // zlib variant unsupported
            if f.opcode == ED2KOpcode.helloAnswer || f.opcode == ED2KOpcode.hello {
                handshakeOK = true; break
            }
            if f.opcode == ED2KOpcode.noSuchFile { throw ED2KTransportError.peerRejected("无此文件") }
        }
        guard handshakeOK else { throw ED2KTransportError.peerRejected("握手未收到 HELLOANSWER") }

        try socket.send(frame: ED2KMessages.startUpload(fileHash: fileHash))

        var accepted = false
        for _ in 0..<12 {
            let f = try socket.readFrame()
            if f.marker == ED2KProto.packed { continue }
            if f.opcode == ED2KOpcode.acceptUploadReq { accepted = true; break }
            if f.opcode == ED2KOpcode.noSuchFile { throw ED2KTransportError.peerRejected("无此文件") }
            // QUEUERANK / FILESTATUS / HASHSETANSWER etc. are informational.
        }
        guard accepted else { throw ED2KTransportError.peerRejected("未获上传许可（可能在队列中）") }

        var received = 0
        while !remaining.isEmpty {
            let batch = Array(remaining.sorted().prefix(3))
            let ranges = batch.map(rangeOf)
            let req = use64
                ? ED2KMessages.requestParts64(fileHash: fileHash, ranges: ranges)
                : ED2KMessages.requestParts(fileHash: fileHash, ranges: ranges)
            try socket.send(frame: req)

            var gotInBatch = 0
            for _ in 0..<batch.count {
                let f = try socket.readFrame()
                guard !f.payload.isEmpty else { continue }
                let part: ED2KMessages.Part
                switch (f.marker, f.opcode) {
                case (ED2KProto.edonkey, ED2KOpcode.sendingPart):
                    part = try ED2KMessages.parsePart(f.payload)
                case (ED2KProto.emuleExt, ED2KOpcode.sendingPart64):
                    part = try ED2KMessages.parsePart64(f.payload)
                case (_, ED2KOpcode.outOfPartReqs), (_, ED2KOpcode.queueRank),
                     (_, ED2KOpcode.fileStatus), (_, ED2KOpcode.hashsetAnswer),
                     (_, ED2KOpcode.noSuchFile):
                    if f.opcode == ED2KOpcode.noSuchFile {
                        throw ED2KTransportError.peerRejected("无此文件")
                    }
                    return received
                default:
                    continue
                }
                guard part.fileHash == fileHash else {
                    throw ED2KTransportError.peerRejected("分块文件哈希不匹配")
                }
                let idx = Int(part.start / UInt64(ED2KOpcode.blockSize))
                guard idx >= 0, idx < blockCount, remaining.contains(idx) else { continue }
                let expected = rangeOf(idx)
                guard part.start == expected.start, part.end == expected.end,
                      part.end <= total else {
                    throw ED2KTransportError.peerRejected("分块偏移越界")
                }
                throttle(part.data.count)
                try handle.seek(toOffset: part.start)
                try handle.write(contentsOf: part.data)
                remaining.remove(idx)
                received += 1
                gotInBatch += 1
                onProgress(Int64(part.data.count))
            }
            if gotInBatch == 0 { break }  // peer went quiet; let another source try
        }

        try? socket.send(frame: ED2KMessages.endOfDownload(fileHash: fileHash))
        return received
    }

    /// Bridge the async token bucket onto our dedicated (non-cooperative) queue.
    private func throttle(_ bytes: Int) {
        guard SpeedLimitController.shared.currentLimit > 0, bytes > 0 else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await SpeedLimitController.shared.consume(bytes)
            sem.signal()
        }
        sem.wait()
    }

    // MARK: - Server-side source discovery

    private func discoverSources(fileHash: Data, fileSize: UInt64) -> [(host: String, port: Int)] {
        for server in servers {
            do {
                let s = try ED2KSocket(host: server.host, port: server.port, timeout: 5)
                defer { s.close() }
                try s.send(frame: ED2KMessages.login())
                for _ in 0..<12 {
                    let f = try s.readFrame()
                    if f.opcode == ED2KOpcode.idChange || f.opcode == ED2KOpcode.serverIdent {
                        break
                    }
                }
                try s.send(frame: ED2KMessages.requestSources(fileHash: fileHash,
                                                              fileSize: fileSize))
                for _ in 0..<12 {
                    let f = try s.readFrame()
                    if f.opcode == ED2KOpcode.foundSources {
                        let found = ED2KMessages.parseSources(f.payload)
                        if !found.isEmpty { return found }
                    }
                }
            } catch {
                continue   // try the next server
            }
        }
        return []
    }
}
