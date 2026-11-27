import Foundation

/// Unified BitTorrent snapshot consumed by the five-tab progress window and the
/// automation API. Backends (aria2 today, librqbit helper later) translate their
/// native replies into this value type so SwiftUI never touches RPC dictionaries.
public struct TorrentSnapshot: Sendable, Equatable {
    public struct File: Sendable, Identifiable, Equatable {
        public let index: Int
        public var path: String
        public var length: Int64
        public var completed: Int64
        public var selected: Bool
        public var priority: Int
        public var id: Int { index }
        public var displayName: String { path.split(separator: "/").last.map(String.init) ?? path }
        public var progress: Double { length > 0 ? Double(completed) / Double(length) : 0 }

        public init(index: Int, path: String, length: Int64, completed: Int64 = 0,
                    selected: Bool = true, priority: Int = 0) {
            self.index = index; self.path = path; self.length = length
            self.completed = completed; self.selected = selected; self.priority = priority
        }
    }

    public struct Peer: Sendable, Identifiable, Equatable {
        public let id: String
        public var address: String
        public var client: String
        public var downloadSpeed: Int64
        public var uploadSpeed: Int64
        public var downloaded: Int64
        public var uploaded: Int64
        public var progress: Double
        public var isChoking: Bool
        public var isInterested: Bool

        public init(id: String = UUID().uuidString, address: String, client: String = "",
                    downloadSpeed: Int64 = 0, uploadSpeed: Int64 = 0,
                    downloaded: Int64 = 0, uploaded: Int64 = 0, progress: Double = 0,
                    isChoking: Bool = false, isInterested: Bool = false) {
            self.id = id; self.address = address; self.client = client
            self.downloadSpeed = downloadSpeed; self.uploadSpeed = uploadSpeed
            self.downloaded = downloaded; self.uploaded = uploaded
            self.progress = progress; self.isChoking = isChoking; self.isInterested = isInterested
        }
    }

    public struct Tracker: Sendable, Identifiable, Equatable {
        public let id: String
        public var url: String
        public var status: String
        public var seeders: Int
        public var leechers: Int
        public var downloaded: Int64
        public var nextAnnounce: Date?

        public init(id: String = UUID().uuidString, url: String, status: String = "unknown",
                    seeders: Int = 0, leechers: Int = 0, downloaded: Int64 = 0,
                    nextAnnounce: Date? = nil) {
            self.id = id; self.url = url; self.status = status
            self.seeders = seeders; self.leechers = leechers
            self.downloaded = downloaded; self.nextAnnounce = nextAnnounce
        }
    }

    public struct Piece: Sendable, Identifiable, Equatable {
        public let index: Int
        public var state: State
        public var length: Int64
        public var completed: Int64
        public var id: Int { index }

        public enum State: String, Sendable {
            case missing, downloading, complete, verifying
        }

        public init(index: Int, state: State, length: Int64 = 0, completed: Int64 = 0) {
            self.index = index; self.state = state; self.length = length; self.completed = completed
        }
    }

    public var files: [File]
    public var peers: [Peer]
    public var trackers: [Tracker]
    public var pieces: [Piece]
    public var infoHash: String?
    public var name: String
    public var totalSize: Int64
    public var downloaded: Int64
    public var uploaded: Int64
    public var downloadSpeed: Int64
    public var uploadSpeed: Int64
    public var seeders: Int
    public var leechers: Int
    public var shareRatio: Double
    public var seedingTime: TimeInterval
    public var isSequential: Bool
    public var pieceLength: Int64
    public var numPieces: Int

    public init(files: [File] = [], peers: [Peer] = [], trackers: [Tracker] = [],
                pieces: [Piece] = [], infoHash: String? = nil, name: String = "",
                totalSize: Int64 = 0, downloaded: Int64 = 0, uploaded: Int64 = 0,
                downloadSpeed: Int64 = 0, uploadSpeed: Int64 = 0,
                seeders: Int = 0, leechers: Int = 0, shareRatio: Double = 0,
                seedingTime: TimeInterval = 0, isSequential: Bool = false,
                pieceLength: Int64 = 0, numPieces: Int = 0) {
        self.files = files; self.peers = peers; self.trackers = trackers; self.pieces = pieces
        self.infoHash = infoHash; self.name = name
        self.totalSize = totalSize; self.downloaded = downloaded; self.uploaded = uploaded
        self.downloadSpeed = downloadSpeed; self.uploadSpeed = uploadSpeed
        self.seeders = seeders; self.leechers = leechers; self.shareRatio = shareRatio
        self.seedingTime = seedingTime; self.isSequential = isSequential
        self.pieceLength = pieceLength; self.numPieces = numPieces
    }
}

/// Operations every torrent backend must support. aria2 implements the subset it
/// can express; a future librqbit helper will fill the gaps (per-task upload cap,
/// blocklist, file rename) without changing the UI or automation contracts.
public protocol TorrentBackend: AnyObject {
    func snapshot(taskID: UUID) async -> TorrentSnapshot
    func selectFiles(taskID: UUID, indexes: [Int]) async throws
    func renameFile(taskID: UUID, index: Int, newPath: String) async throws
    func setSequential(taskID: UUID, enabled: Bool) async throws
    func recheck(taskID: UUID) async throws
    func setSeedRatio(taskID: UUID, ratio: Double?) async throws
    func setSeedTime(taskID: UUID, minutes: Int?) async throws
    func setUploadLimit(taskID: UUID, bytesPerSec: Int64?) async throws
    func reloadBlocklist() async throws
    var supportsPerTaskUploadLimit: Bool { get }
    var supportsBlocklist: Bool { get }
    var supportsFileRename: Bool { get }
}
