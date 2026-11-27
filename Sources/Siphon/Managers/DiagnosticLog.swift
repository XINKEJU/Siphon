import AppKit
import Foundation

/// File sink for the lifecycle events a bug report actually needs, next to the
/// existing os.Logger channels (which are not readable after the fact).
///
/// Keeps one rotated backup and caps the live file at 2 MB, so a downloader
/// running for months cannot fill the disk with logs.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog()

    private static let maxBytes = 2 * 1024 * 1024
    private let queue = DispatchQueue(label: "Siphon.diagnostic-log", qos: .utility)

    public var fileURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory,
                                               in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/Siphon/siphon.log")
    }

    private init() {}

    /// Append one line. Called from the store's main-actor paths; the write
    /// itself is serialized off the main thread so a slow disk cannot stall a
    /// progress tick.
    public func log(_ message: String) {
        let line = "\(Self.timestamp()) \(message)\n"
        let maxBytes = Self.maxBytes
        let url = fileURL
        queue.async { [maxBytes, url] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            Self.rotateIfNeeded(url, maxBytes: maxBytes)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private static func rotateIfNeeded(_ url: URL, maxBytes: Int) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size >= maxBytes else { return }
        let backup = url.appendingPathExtension("1")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}