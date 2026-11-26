import Foundation

/// MDM uses one command contract for every entry point: browser extension,
/// native messaging host, CLI, local automation API, MCP and remote control.
/// Siphon's existing REST/MCP servers each had a slightly different shape;
/// these types are the shared vocabulary the adapters converge on.
///
/// Sensitive fields (cookies, credentials) are `skip`-encoded on purpose:
/// MDM never persists or echoes them through list/recent answers.
public struct MDMCommand: Codable, Sendable {
    public var url: String?
    public var dir: String?
    public var name: String?
    public var description: String?
    public var checksum: String?
    public var later: Bool?
    public var silent: Bool?
    public var startQueue: String?
    public var referer: String?
    public var pageUrl: String?
    public var userAgent: String?
    public var finalUrl: String?
    public var size: Int64?
    public var mime: String?
    public var post: String?
    public var privateWindow: Bool?
    public var browserHandoff: Bool?
    public var proxy: String?
    public var query: String?
    public var action: String?
    public var ids: [String]?
    public var category: String?
    public var queue: String?
    public var remote: String?
    public var torrentFile: String?

    /// Never encoded into a command that crosses a process boundary.
    public var cookies: [String: String]? = nil

    public init(url: String? = nil,
                dir: String? = nil,
                name: String? = nil,
                description: String? = nil,
                checksum: String? = nil,
                later: Bool? = nil,
                silent: Bool? = nil,
                startQueue: String? = nil,
                referer: String? = nil,
                pageUrl: String? = nil,
                userAgent: String? = nil,
                finalUrl: String? = nil,
                size: Int64? = nil,
                mime: String? = nil,
                post: String? = nil,
                privateWindow: Bool? = nil,
                browserHandoff: Bool? = nil,
                proxy: String? = nil,
                query: String? = nil,
                action: String? = nil,
                ids: [String]? = nil,
                category: String? = nil,
                queue: String? = nil,
                remote: String? = nil,
                torrentFile: String? = nil,
                cookies: [String: String]? = nil) {
        self.url = url
        self.dir = dir
        self.name = name
        self.description = description
        self.checksum = checksum
        self.later = later
        self.silent = silent
        self.startQueue = startQueue
        self.referer = referer
        self.pageUrl = pageUrl
        self.userAgent = userAgent
        self.finalUrl = finalUrl
        self.size = size
        self.mime = mime
        self.post = post
        self.privateWindow = privateWindow
        self.browserHandoff = browserHandoff
        self.proxy = proxy
        self.query = query
        self.action = action
        self.ids = ids
        self.category = category
        self.queue = queue
        self.remote = remote
        self.torrentFile = torrentFile
        self.cookies = cookies
    }

    private enum CodingKeys: String, CodingKey {
        case url, dir, name, description, checksum, later, silent, startQueue, referer, pageUrl
        case userAgent, finalUrl, size, mime, post, privateWindow, browserHandoff
        case proxy, query, action, ids, category, queue, remote, torrentFile
        // cookies deliberately absent
    }
}

/// One list row as seen by API/MCP/remote clients. Deliberately has no path
/// in `MDMRecentAnswer` — the remote page must not learn local directories.
public struct MDMDownloadInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let url: String
    public let fileName: String
    public let status: String
    public let size: Int64
    public let downloaded: Int64
    public let speed: Int64
    public let category: String
    public let queue: String
    public let added: Date
    public let finished: Date?
    public let lastTry: Date?
    public let error: String?

    public init(id: String, url: String, fileName: String, status: String,
                size: Int64, downloaded: Int64, speed: Int64, category: String,
                queue: String, added: Date, finished: Date?, lastTry: Date?,
                error: String?) {
        self.id = id; self.url = url; self.fileName = fileName
        self.status = status; self.size = size; self.downloaded = downloaded
        self.speed = speed; self.category = category; self.queue = queue
        self.added = added; self.finished = finished; self.lastTry = lastTry
        self.error = error
    }

    public init(_ task: DownloadTask) {
        self.id = task.id.uuidString
        self.url = task.source.absoluteString
        self.fileName = task.name
        self.status = MDMStatus(task.state).rawValue
        self.size = task.progress.totalBytes
        self.downloaded = task.progress.downloadedBytes
        self.speed = task.progress.speedBytesPerSec
        self.category = task.category
            ?? MDMCategory.categorize(fileName: task.name).rawValue
        self.queue = task.queueName
        self.added = task.createdAt
        self.finished = task.state == .completed ? Date() : nil
        self.lastTry = task.lastAttemptAt
        self.error = task.errorDescription
    }
}

public struct MDMListAnswer: Codable, Sendable {
    public let downloads: [MDMDownloadInfo]
    public let speed: Int64
    public let queues: [String]
    public let categories: [String]
    public let free: Int64?

    public init(downloads: [MDMDownloadInfo], speed: Int64, queues: [String],
                categories: [String], free: Int64?) {
        self.downloads = downloads; self.speed = speed; self.queues = queues
        self.categories = categories; self.free = free
    }
}

/// Remote/popup answer. No `saveTo` by design: MDM's remote page never
/// exposes local paths, and neither does this type.
public struct MDMRecentAnswer: Codable, Sendable {
    public let recent: [MDMDownloadInfo]
    public init(recent: [MDMDownloadInfo]) { self.recent = recent }
}

public struct MDMAddAnswer: Codable, Sendable {
    public let ok: Bool
    public let id: String?
    public let note: String?
    public init(ok: Bool, id: String? = nil, note: String? = nil) {
        self.ok = ok; self.id = id; self.note = note
    }
}

/// The engine boundary in MDM: the app never sees internals, only a snapshot
/// with state, byte counts, segment table, connection table and recent events.
/// Siphon's engines already expose `SegmentSnapshot`; this struct is the
/// presentation-layer envelope used by the progress window and the API.
public struct MDMEngineSnapshot: Sendable {
    public enum Phase: String, Sendable {
        case probing, downloading, verifying, merging, completing
        case stopping, done, failed, cancelled
    }

    public struct Event: Sendable, Identifiable {
        public let id = UUID()
        public let at: Date
        public let text: String
        public init(at: Date = Date(), text: String) {
            self.at = at; self.text = text
        }
    }

    public struct Connection: Sendable, Identifiable {
        public let index: Int
        public let start: Int64
        public let end: Int64
        public let cursor: Int64
        public var id: Int { index }
    }

    public let phase: Phase
    public let size: Int64
    public let downloaded: Int64
    public let resumable: Bool
    public let segments: [SegmentSnapshot]
    public let connections: [Connection]
    public let events: [Event]
    public let serverCountry: String?
    public let serverRTT: TimeInterval?
    public let finishing: Bool

    public init(phase: Phase, size: Int64, downloaded: Int64, resumable: Bool,
                segments: [SegmentSnapshot], connections: [Connection],
                events: [Event], serverCountry: String?, serverRTT: TimeInterval?,
                finishing: Bool) {
        self.phase = phase; self.size = size; self.downloaded = downloaded
        self.resumable = resumable; self.segments = segments
        self.connections = connections; self.events = events
        self.serverCountry = serverCountry; self.serverRTT = serverRTT
        self.finishing = finishing
    }

    public init(task: DownloadTask, segments: [SegmentSnapshot]) {
        switch task.state {
        case .pending: phase = .probing
        case .active: phase = .downloading
        case .paused: phase = .stopping
        case .completed: phase = .done
        case .error: phase = .failed
        case .removed: phase = .cancelled
        }
        size = task.progress.totalBytes
        downloaded = task.progress.downloadedBytes
        resumable = task.state != .completed
        self.segments = segments
        connections = segments.enumerated().map {
            Connection(index: $0.offset, start: $0.element.start,
                       end: $0.element.end, cursor: $0.element.cursor)
        }
        events = []
        serverCountry = nil
        serverRTT = nil
        finishing = false
    }
}
