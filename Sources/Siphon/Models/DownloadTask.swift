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

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        source: URL,
        destination: URL,
        queueName: String = "Default",
        options: [String: String] = [:]
    ) {
        let proto = DownloadProtocol.detect(from: source)
        self.id = id
        self.name = name ?? (source.lastPathComponent.isEmpty
            ? source.absoluteString : source.lastPathComponent)
        self.source = source
        self.destination = destination
        self.protocol = proto
        self.state = .pending
        self.progress = DownloadProgress()
        self.queueName = queueName
        self.createdAt = Date()
        self.errorDescription = nil
        self.options = options
    }
}
