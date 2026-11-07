import Foundation

/// A single download unit. `Sendable` so it can cross actor boundaries when
/// handed from the UI to an engine and back.
public struct DownloadTask: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var source: URL
    public var destination: URL
    public var `protocol`: DownloadProtocol
    public var state: DownloadState
    public var progress: DownloadProgress
    public var queueName: String
    public var createdAt: Date
    public var errorDescription: String?
    /// Engine-specific options: custom headers, user-agent, referer, etc.
    public var options: [String: String]
    /// The exact string the user supplied, before `URINormalizer` rewrote it.
    /// Kept so a vendor link / gateway URI can be re-opened or retried verbatim.
    public var origin: String?
    /// Expected integrity hash, `"algorithm:hex"` or bare hex (defaults to SHA-256).
    /// Supported algorithms: md5, sha1, sha256. Verified after download completes.
    public var checksum: String?
    /// Mirror / CDN sources for the same file (FluxDown multi_cdn model). The
    /// native HTTP engine probes the primary first and fails over to a mirror
    /// when the primary is unreachable, errors mid-transfer, or is slow.
    public var mirrors: [URL]
    /// Per-piece SHA-1 hashes (Metalink `<pieces>`), block-wise verification
    /// with surgical bad-range re-download. Empty = no piece checksums.
    public var pieceHashes: [String]
    /// Byte length of one piece (> 0 iff pieceHashes non-empty).
    public var pieceLength: Int64

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        source: URL,
        destination: URL,
        queueName: String = "Default",
        options: [String: String] = [:],
        origin: String? = nil,
        checksum: String? = nil,
        mirrors: [URL] = [],
        pieceHashes: [String] = [],
        pieceLength: Int64 = 0,
        protoOverride: DownloadProtocol? = nil
    ) {
        let proto = DownloadProtocol.detect(from: source)
        self.id = id
        self.name = name ?? Self.inferredName(for: source)
        self.source = source
        self.destination = destination
        self.protocol = protoOverride ?? proto
        self.state = .pending
        self.progress = DownloadProgress()
        self.queueName = queueName
        self.createdAt = Date()
        self.errorDescription = nil
        self.options = options
        self.origin = origin
        self.checksum = checksum
        self.mirrors = mirrors
        self.pieceHashes = pieceHashes
        self.pieceLength = pieceLength
    }

    /// Human-readable fallback name. Custom schemes carry their filename in
    /// the URI payload, not in `lastPathComponent` (which is "/" for ed2k).
    private static func inferredName(for source: URL) -> String {
        let raw = source.absoluteString.replacingOccurrences(of: "%7C", with: "|")

        switch source.scheme?.lowercased() {
        case "ed2k":
            // ed2k://|file|<name>|<size>|<hash>|/
            let parts = raw.components(separatedBy: "|")
            if parts.count > 2, !parts[2].isEmpty {
                return (parts[2].removingPercentEncoding ?? parts[2])
            }
        case "magnet":
            if let items = URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems,
               let dn = items.first(where: { $0.name == "dn" })?.value, !dn.isEmpty {
                return dn.replacingOccurrences(of: "+", with: " ")
            }
        default:
            break
        }

        let last = source.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return source.host ?? source.absoluteString
    }
}
