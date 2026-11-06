import Foundation
import CommonCrypto

/// Native HLS downloader.
///
/// Responsibilities kept here: playlist resolution (master → best variant), AES-128 key
/// handling, and IV derivation. Segment fetching / ordered assembly / resume is delegated
/// to `SegmentAssembler`. Output is a concatenated MPEG-TS stream, or an fMP4
/// byte stream for CMAF playlists carrying `EXT-X-MAP` (init segment written first).
///
/// Both are produced with zero external dependencies. Converting an fMP4 byte
/// stream into a single-file MP4 with a flat `moov` still needs ffmpeg remux.
public final class HLSEngine: DownloadEngine {
    public let name = "hls"
    public let supportedProtocols: Set<DownloadProtocol> = [.hls]
    public weak var delegate: (any EngineDelegate)? {
        didSet { assembler.delegate = delegate }
    }

    private let assembler = SegmentAssembler(concurrency: 6)
    private var outputs: [UUID: URL] = [:]

    public init() {}
    public func canHandle(_ p: DownloadProtocol) -> Bool { p == .hls }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {}

    public func submit(_ task: DownloadTask) async throws {
        if outputs[task.id] != nil { try assembler.resume(task.id); return }

        let text = try await playlistText(task.source, options: task.options)
        var pl = HLSParser.parse(text, baseURL: task.source)
        if pl.isMaster, let variant = HLSParser.bestVariant(pl) {
            let vtext = try await playlistText(variant, options: task.options)
            pl = HLSParser.parse(vtext, baseURL: variant)
        }

        var out = task.destination
        if out.pathExtension.isEmpty {
            out = out.deletingPathExtension()
                .appendingPathExtension(pl.isFMP4 ? "mp4" : "ts")
        }
        outputs[task.id] = out

        // Resolve the AES-128 key once, then build a stateless per-segment decrypt closure.
        var key: Data?
        if let keyURL = pl.keyURL {
            key = try? await Self.fetchData(keyURL, options: task.options)
        }
        let baseIV = pl.keyIV
        let mediaSequence = pl.mediaSequence
        // With EXT-X-MAP the first request is the (unencrypted) fMP4 init segment,
        // so media segments start at order 1 and their IV sequence must shift too.
        let hasMap = pl.isFMP4
        let transform: (@Sendable (Data, Int) -> Data)? = key.map { k in
            { @Sendable data, order in
                if hasMap, order == 0 { return data }
                let mediaOrder = hasMap ? order - 1 : order
                let iv = baseIV ?? Self.defaultIV(mediaSequence: mediaSequence, order: mediaOrder)
                return Self.decryptAES128(data, key: k, iv: iv) ?? data
            }
        }

        var requests: [SegmentRequest] = []
        if let map = pl.mapURL {
            requests.append(SegmentRequest(url: map, byteRange: pl.mapByteRange))
        }
        requests.append(contentsOf: pl.segments.map {
            SegmentRequest(url: $0.url, byteRange: $0.byteRange)
        })
        try assembler.start(taskID: task.id, destination: out, requests: requests,
                            headers: task.options, transform: transform)
        await delegate?.engineDidChangeState(taskID: task.id, state: .active, error: nil)
    }

    public func pause(_ id: UUID) async { assembler.pause(id) }

    public func resume(_ id: UUID) async {
        do { try assembler.resume(id) } catch {
            await delegate?.engineDidChangeState(taskID: id, state: .error, error: error)
        }
    }

    public func remove(_ id: UUID) async {
        assembler.remove(id)
        outputs.removeValue(forKey: id)
    }

    // MARK: - HLS specifics
    private func playlistText(_ url: URL, options: [String: String]) async throws -> String {
        let data = try await Self.fetchData(url, options: options)
        guard let t = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return t
    }

    private static func fetchData(_ url: URL, options: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in options where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    /// Per RFC 8216 §5.2, when IV is absent it is the 128-bit big-endian media sequence number.
    private static func defaultIV(mediaSequence: Int64, order: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        let seq = UInt64(mediaSequence) + UInt64(order)
        var big = seq.bigEndian
        let bytes = withUnsafeBytes(of: &big) { Data($0) }
        iv.replaceSubrange(8..<16, with: bytes)
        return iv
    }

    private static func decryptAES128(_ data: Data, key: Data, iv: Data) -> Data? {
        let capacity = data.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var num: size_t = 0
        let status = out.withUnsafeMutableBytes { ob in
            data.withUnsafeBytes { ib in
                key.withUnsafeBytes { kb in
                    iv.withUnsafeBytes { vb in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                kb.baseAddress, kCCKeySizeAES128, vb.baseAddress,
                                ib.baseAddress, data.count, ob.baseAddress, capacity, &num)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = num
        return out
    }
}
