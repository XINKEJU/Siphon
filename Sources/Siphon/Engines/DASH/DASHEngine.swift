import Foundation
import AVFoundation

/// Native MPEG-DASH downloader.
///
/// Responsibilities kept here: MPD parsing and choosing the best representation.
/// Segment fetching / ordered assembly / resume is delegated to `SegmentAssembler`.
///
/// Output is the initialization segment followed by media segments in order, which is a
/// valid fragmented-MP4 byte stream. To turn that into a single, self-contained MP4 we
/// formerly shelled out to `ffmpeg -c copy`; now we do a dependency-free AVFoundation
/// passthrough remux (`flatten`), so no external binary is required for DASH either.
@MainActor
public final class DASHEngine: @preconcurrency DownloadEngine {
    public let name = "dash"
    public let supportedProtocols: Set<DownloadProtocol> = [.dash]
    public weak var delegate: (any EngineDelegate)? {
        didSet { assembler.delegate = self }
    }

    private let assembler = SegmentAssembler(concurrency: 6)
    private var outputs: [UUID: URL] = [:]

    public init() {}
    public func canHandle(_ p: DownloadProtocol) -> Bool { p == .dash }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {}

    public func submit(_ task: DownloadTask) async throws {
        if outputs[task.id] != nil {
            do { try await assembler.resume(task.id) } catch {
                delegate?.engineDidChangeState(taskID: task.id, state: .error, error: error)
            }
            return
        }

        let data = try await Self.fetchData(task.source, options: task.options)
        guard let xml = String(data: data, encoding: .utf8),
              let best = DASHMPDParser.parse(xml, baseURL: task.source)
                .max(by: { $0.bandwidth < $1.bandwidth }) else {
            delegate?.engineDidChangeState(taskID: task.id, state: .error,
                                             error: URLError(.cannotParseResponse))
            return
        }

        var out = task.destination
        if out.pathExtension.isEmpty {
            out = out.deletingPathExtension().appendingPathExtension("mp4")
        }
        outputs[task.id] = out

        var requests: [SegmentRequest] = []
        if let i = best.initURL { requests.append(SegmentRequest(url: i)) }
        requests.append(contentsOf: best.segments.map { SegmentRequest(url: $0.url) })

        try assembler.start(taskID: task.id, destination: out, requests: requests,
                            headers: task.options, credentialOrigin: task.source,
                            resumeContext: SegmentResumeContext(
                                kind: "dash", source: task.source.absoluteString))
        delegate?.engineDidChangeState(taskID: task.id, state: .active, error: nil)
    }

    public func pause(_ id: UUID) async { assembler.pause(id) }

    public func resume(_ id: UUID) async {
        do { try await assembler.resume(id) } catch {
            delegate?.engineDidChangeState(taskID: id, state: .error, error: error)
        }
    }

    public func remove(_ id: UUID) async {
        assembler.remove(id)
        outputs.removeValue(forKey: id)
    }

    private static func fetchData(_ url: URL, options: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in options where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, _) = try await CredentialScope.session.data(for: req)
        return data
    }
}

extension DASHEngine: EngineDelegate {
    public func engineDidUpdate(taskID: UUID, progress: DownloadProgress) {
        delegate?.engineDidUpdate(taskID: taskID, progress: progress)
    }

    public func engineDidChangeState(taskID: UUID, state: DownloadState, error: Error?) {
        if state == .completed, let fragmented = outputs[taskID] {
            // Flatten the fragmented-MP4 output into a single self-contained MP4 in the
            // background. If export is unavailable or fails we keep the fragmented file,
            // which is still playable, so playback is never lost.
            Task.detached(priority: .utility) { await Self.flatten(fragmented) }
        }
        delegate?.engineDidChangeState(taskID: taskID, state: state, error: error)
    }

    /// Replace the fragmented-MP4 byte stream with one flattened, seekable MP4 using
    /// AVFoundation's passthrough export (no re-encode, no ffmpeg dependency).
    /// Uses the async `export(to:as:)` API — the configure-then-`export()` form
    /// (mutable outputURL/outputFileType) is deprecated on macOS 15+.
    private static func flatten(_ fragmented: URL) async {
        let asset = AVURLAsset(url: fragmented)
        let flat = fragmented.deletingLastPathComponent()
            .appendingPathComponent(fragmented.deletingPathExtension().lastPathComponent + "_flat.mp4")
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else { return }
        do {
            try await session.export(to: flat, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: flat)
            return
        }
        if let size = try? FileManager.default.attributesOfItem(atPath: flat.path)[.size],
           (size as? NSNumber)?.int64Value ?? 0 > 0 {
            try? FileManager.default.removeItem(at: fragmented)
            try? FileManager.default.moveItem(at: flat, to: fragmented)
        } else {
            try? FileManager.default.removeItem(at: flat)
        }
    }
}
