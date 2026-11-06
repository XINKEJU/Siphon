import Foundation

/// Live progress for a single task. All fields are value types so they can be
/// safely handed from background engines to the main-actor UI.
public struct DownloadProgress: Sendable {
    public var downloadedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var speedBytesPerSec: Int64 = 0
    public var connectedPeers: Int = 0

    public init() {}

    public var percent: Double {
        guard totalBytes > 0 else { return downloadedBytes > 0 ? 1.0 : 0.0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }

    public var isIndeterminate: Bool { totalBytes <= 0 && downloadedBytes <= 0 }
}
