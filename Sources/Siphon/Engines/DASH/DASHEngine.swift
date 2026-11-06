import Foundation

/// Native MPEG-DASH downloader.
///
/// Responsibilities kept here: MPD parsing and choosing the best representation.
/// Segment fetching / ordered assembly / resume is delegated to `SegmentAssembler`.
///
/// Output is the initialization segment followed by media segments in order, which is a
/// valid fragmented-MP4 byte stream. For a single-file, universally-compatible MP4,
/// pipe the result through `ffmpeg -c copy`.
public final class DASHEngine: DownloadEngine {
    public let name = "dash"
    public let supportedProtocols: Set<DownloadProtocol> = [.dash]
    public weak var delegate: (any EngineDelegate)? {
        didSet { assembler.delegate = delegate }
    }

    private let assembler = SegmentAssembler(concurrency: 6)
    private var outputs: [UUID: URL] = [:]

    public init() {}
    public func canHandle(_ p: DownloadProtocol) -> Bool { p == .dash }
    public func setGlobalSpeedLimit(_ bytesPerSec: Int64?) async {}

    public func submit(_ task: DownloadTask) async throws {
        if outputs[task.id] != nil {
            do { try assembler.resume(task.id) } catch {
                await delegate?.engineDidChangeState(taskID: task.id, state: .error, error: error)
            }
            return
        }

        let data = try await Self.fetchData(task.source, options: task.options)
        guard let xml = String(data: data, encoding: .utf8),
              let best = DASHMPDParser.parse(xml, baseURL: task.source)
                .max(by: { $0.bandwidth < $1.bandwidth }) else {
            await delegate?.engineDidChangeState(taskID: task.id, state: .error,
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
                            headers: task.options)
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

    private static func fetchData(_ url: URL, options: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in options where !["dir", "out"].contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
