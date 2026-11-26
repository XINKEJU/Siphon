import Foundation

/// MDM-aligned product identity.
///
/// Mister Download Manager keeps a small, stable set of public identifiers:
/// an application id (dock/grouping), a self-reported user agent, and a
/// reserved pair of sidecar suffixes for part data and resume state. Siphon
/// keeps its own bundle id and user-facing name on macOS but adopts the same
/// contract shape so command lines, IPC clients and on-disk layouts can be
/// reasoned about with one vocabulary.
public enum MDMProduct {
    public static let name = "Siphon"
    public static let longName = "Siphon Download Manager"
    public static let appID = "com.xinkeju.siphon.macos"

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Sent when a site refuses a browser-like request and the app has to
    /// identify itself. Never used to impersonate a browser.
    public static var userAgent: String { "\(name)/\(version)" }

    /// MDM reserves `.mdm.part` / `.mdm.json`. Existing Siphon downloads use
    /// `.part` plus an internal sidecar, so the resolver below accepts both:
    /// new tasks use the MDM spelling, old tasks stay readable. No data is
    /// silently renamed — migration is an explicit operation.
    public static let partSuffix = "mdm.part"
    public static let stateSuffix = "mdm.json"
    public static let legacyPartSuffix = "part"

    public static func dataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["SIPHON_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Siphon", isDirectory: true)
    }

    public static func partURL(for destination: URL) -> URL {
        destination.deletingPathExtension().appendingPathExtension(partSuffix)
    }

    public static func stateURL(for destination: URL) -> URL {
        destination.deletingPathExtension().appendingPathExtension(stateSuffix)
    }

    /// Sidecar candidates for an existing download, MDM spelling first.
    public static func existingPartURLs(for destination: URL) -> [URL] {
        [partURL(for: destination),
         destination.appendingPathExtension(partSuffix),
         destination.appendingPathExtension(legacyPartSuffix)]
    }
}

/// The two queues MDM ships with. User-created queues are identified by their
/// name; these two are resolved by semantics, not by a localised label.
public enum MDMQueue: String, Sendable, CaseIterable {
    case main
    case synchronization

    public var title: String {
        switch self {
        case .main: return MDMI18n.t("queue.main")
        case .synchronization: return MDMI18n.t("queue.synchronization")
        }
    }

    /// Synchronisation keeps completed entries in the list, main removes them
    /// once a job is done. This is the behavioural difference, not a UI hint.
    public var keepsCompleted: Bool { self == .synchronization }
}
