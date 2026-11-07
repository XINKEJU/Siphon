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
    private var livePolls: [UUID: Task<Void, Never>] = [:]
    private var liveContext: [UUID: (url: URL, options: [String: String])] = [:]

    public init() {}
    public func canHandle(_ p: DownloadProtocol) -> Bool { p == .hls }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {}

    public func submit(_ task: DownloadTask) async throws {
        if outputs[task.id] != nil { try assembler.resume(task.id); return }

        let text = try await playlistText(task.source, options: task.options, origin: task.source)
        var pl = HLSParser.parse(text, baseURL: task.source)
        var mediaURL = task.source
        var mediaText = text
        if pl.isMaster, let variant = HLSParser.bestVariant(pl) {
            mediaText = try await playlistText(variant, options: task.options, origin: task.source)
            mediaURL = variant
            pl = HLSParser.parse(mediaText, baseURL: variant)
        }
        // A playlist without #EXT-X-ENDLIST is a live stream (FluxDown/Motrix
        // record-by-polling model): we seed the initial window, then poll for new
        // segments instead of treating the snapshot as the whole file.
        let isLive = !mediaText.contains("#EXT-X-ENDLIST")

        var out = task.destination
        if out.pathExtension.isEmpty {
            out = out.deletingPathExtension()
                .appendingPathExtension(pl.isFMP4 ? "mp4" : "ts")
        }
        outputs[task.id] = out

        // Resolve the AES-128 key once, then build a stateless per-segment decrypt closure.
        // Each request carries its own media sequence number so the default-IV derivation
        // stays correct even while a live playlist slides and appends new segments.
        var key: Data?
        if let keyURL = pl.keyURL {
            key = try? await Self.fetchData(keyURL, options: task.options, origin: task.source)
        }
        let baseIV = pl.keyIV
        let firstSequence = pl.mediaSequence
        let mapURL = pl.mapURL
        let transform: (@Sendable (Data, SegmentRequest) -> Data)? = key.map { k in
            { @Sendable data, req in
                // The fMP4 init segment is never encrypted.
                if let mapURL, req.url == mapURL { return data }
                // Per RFC 8216 §5.2 the default IV is the 128-bit big-endian media
                // sequence number; fall back to the initial window start for VOD.
                let seq = req.mediaSequence ?? firstSequence
                let iv = baseIV ?? Self.defaultIV(mediaSequence: seq, order: 0)
                return Self.decryptAES128(data, key: k, iv: iv) ?? data
            }
        }

        var requests: [SegmentRequest] = []
        if let map = pl.mapURL {
            // Init segment has no media sequence (it is written unencrypted regardless).
            requests.append(SegmentRequest(url: map, byteRange: pl.mapByteRange))
        }
        requests.append(contentsOf: pl.segments.enumerated().map { idx, seg in
            SegmentRequest(url: seg.url, byteRange: seg.byteRange,
                           mediaSequence: firstSequence + Int64(idx))
        })
        try assembler.start(taskID: task.id, destination: out, requests: requests,
                            headers: task.options, credentialOrigin: task.source,
                            transform: transform)
        await delegate?.engineDidChangeState(taskID: task.id, state: .active, error: nil)

        // A live stream (no #EXT-X-ENDLIST) is recorded by polling the playlist for new
        // segments. We seed the current window above, then keep appending as the edge
        // advances. When the stream ends (ENDLIST appears) the poll stops and the
        // assembler finishes normally.
        if isLive {
            assembler.setLive(true)
            startLivePoll(task.id, mediaURL: mediaURL, options: task.options,
                          origin: task.source,
                          known: requests.compactMap { $0.mediaSequence != nil ? $0.url : nil })
        }
    }

    public func pause(_ id: UUID) async { assembler.pause(id) }

    public func resume(_ id: UUID) async {
        do { try assembler.resume(id) } catch {
            await delegate?.engineDidChangeState(taskID: id, state: .error, error: error)
        }
    }

    public func remove(_ id: UUID) async {
        livePolls[id]?.cancel()
        livePolls.removeValue(forKey: id)
        liveContext.removeValue(forKey: id)
        assembler.remove(id)
        outputs.removeValue(forKey: id)
    }

    // MARK: - live (HLS live recording)

    /// Periodically re-read the media playlist of a live stream, append any segments
    /// that have not been seen yet to the running assembler, and stop once the stream
    /// ends (the playlist gains #EXT-X-ENDLIST). Mirrors the FluxDown / Motrix
    /// "record live by polling" model.
    private func startLivePoll(_ id: UUID, mediaURL: URL, options: [String: String],
                              origin: URL, known initial: [URL]) {
        var knownSeen = Set(initial)
        liveContext[id] = (url: mediaURL, options: options)
        livePolls[id] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { break }
                if Task.isCancelled { break }
                do {
                    let text = try await self.playlistText(mediaURL, options: options, origin: origin)
                    let pl = HLSParser.parse(text, baseURL: mediaURL)
                    let ended = text.contains("#EXT-X-ENDLIST")
                    let newReqs: [SegmentRequest] = zip(pl.segments.indices, pl.segments).compactMap { idx, seg in
                        guard !knownSeen.contains(seg.url) else { return nil }
                        knownSeen.insert(seg.url)
                        return SegmentRequest(url: seg.url, byteRange: seg.byteRange,
                                             mediaSequence: Int64(pl.mediaSequence) + Int64(idx))
                    }
                    if !newReqs.isEmpty {
                        self.assembler.appendSegments(newReqs)
                        await self.delegate?.engineDidChangeState(taskID: id, state: .active, error: nil)
                    }
                    if ended {
                        // No more segments will appear; let the assembler finish.
                        self.assembler.setLive(false)
                        break
                    }
                } catch {
                    // Transient playlist fetch error: keep polling until cancelled.
                }
            }
        }
    }

    // MARK: - HLS specifics
    private func playlistText(_ url: URL, options: [String: String], origin: URL) async throws -> String {
        let data = try await Self.fetchData(url, options: options, origin: origin)
        guard let t = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return t
    }

    private static func fetchData(_ url: URL, options: [String: String], origin: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let scoped = CredentialScope.headers(options, from: origin, to: url)
        for (k, v) in scoped where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, _) = try await CredentialScope.session.data(for: req)
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
