import Foundation
import OSLog

private let torrentLog = Logger(subsystem: "com.xinkeju.siphon.macos", category: "torrent")

/// BitTorrent backend backed by aria2's JSON-RPC. Implements the `TorrentBackend`
/// contract to the extent aria2 supports it; unsupported operations throw a
/// descriptive error instead of pretending to succeed.
public final class Aria2TorrentBackend: TorrentBackend {
    private let engine: Aria2Engine
    private let rpc: Aria2RPC

    public init(engine: Aria2Engine, rpc: Aria2RPC) {
        self.engine = engine
        self.rpc = rpc
    }

    public var supportsPerTaskUploadLimit: Bool { false }
    public var supportsBlocklist: Bool { false }
    public var supportsFileRename: Bool { false }

    public func snapshot(taskID: UUID) async -> TorrentSnapshot {
        guard let gid = engine.gid(for: taskID) else { return TorrentSnapshot() }
        async let status = try? rpc.tellStatus(gid)
        async let files = try? rpc.getFiles(gid)
        async let peers = try? rpc.getPeers(gid)
        async let trackers = try? rpc.getTrackers(gid)
        async let options = try? rpc.getOption(gid)

        let s = await status ?? [:]
        let f = await files ?? []
        let p = await peers ?? []
        let t = await trackers ?? []
        let o = await options ?? [:]

        let total = Int64(s["totalLength"] as? String ?? "0") ?? 0
        let done = Int64(s["completedLength"] as? String ?? "0") ?? 0
        let up = Int64(s["uploadLength"] as? String ?? "0") ?? 0
        let downSpeed = Int64(s["downloadSpeed"] as? String ?? "0") ?? 0
        let upSpeed = Int64(s["uploadSpeed"] as? String ?? "0") ?? 0
        let seeders = Int(s["numSeeders"] as? String ?? "0") ?? 0
        let connections = Int(s["connections"] as? String ?? "0") ?? 0
        let pieceLen = Int64(s["pieceLength"] as? String ?? "0") ?? 0
        let numPieces = Int(s["numPieces"] as? String ?? "0") ?? 0
        let bitfield = s["bitfield"] as? String ?? ""

        let fileModels = f.compactMap { item -> TorrentSnapshot.File? in
            guard let idx = (item["index"] as? String).flatMap(Int.init) else { return nil }
            let len = Int64(item["length"] as? String ?? "0") ?? 0
            let completed = Int64(item["completedLength"] as? String ?? "0") ?? 0
            return TorrentSnapshot.File(index: idx,
                                        path: item["path"] as? String ?? "",
                                        length: len, completed: completed,
                                        selected: item["selected"] as? String == "true")
        }

        let peerModels = p.enumerated().map { idx, item in
            TorrentSnapshot.Peer(id: "\(idx)",
                                 address: "\(item["ip"] as? String ?? "?"):\(item["port"] as? String ?? "?")",
                                 client: item["peerId"] as? String ?? "",
                                 downloadSpeed: Int64(item["downloadSpeed"] as? String ?? "0") ?? 0,
                                 uploadSpeed: Int64(item["uploadSpeed"] as? String ?? "0") ?? 0,
                                 downloaded: 0, uploaded: 0,
                                 progress: Self.bitfieldProgress(item["bitfield"] as? String ?? ""),
                                 isChoking: item["peerChoking"] as? String == "true",
                                 isInterested: item["amInterested"] as? String == "true")
        }

        let trackerModels = t.enumerated().map { idx, item in
            TorrentSnapshot.Tracker(id: "\(idx)",
                                    url: item["uri"] as? String ?? "",
                                    status: item["status"] as? String ?? "unknown",
                                    seeders: 0, leechers: 0, downloaded: 0)
        }

        let pieces = Self.pieces(from: bitfield, count: numPieces, pieceLength: pieceLen, total: total)

        let ratio = done > 0 ? Double(up) / Double(done) : 0
        let sequential = (o["stream-piece-selector"] as? String) == "inorder"
        let btInfo = (s["bittorrent"] as? [String: Any])?["info"] as? [String: Any]
        let torrentName = btInfo?["name"] as? String ?? ""

        return TorrentSnapshot(files: fileModels, peers: peerModels, trackers: trackerModels,
                               pieces: pieces, infoHash: s["infoHash"] as? String,
                               name: torrentName,
                               totalSize: total, downloaded: done, uploaded: up,
                               downloadSpeed: downSpeed, uploadSpeed: upSpeed,
                               seeders: seeders, leechers: max(0, connections - seeders),
                               shareRatio: ratio, seedingTime: 0,
                               isSequential: sequential, pieceLength: pieceLen, numPieces: numPieces)
    }

    public func selectFiles(taskID: UUID, indexes: [Int]) async throws {
        guard let gid = engine.gid(for: taskID), !indexes.isEmpty else {
            throw TorrentBackendError.notAvailable
        }
        try await rpc.changeOption(gid,
            ["select-file": indexes.sorted().map(String.init).joined(separator: ",")])
    }

    public func renameFile(taskID: UUID, index: Int, newPath: String) async throws {
        // aria2 has no RPC for renaming individual files inside a torrent.
        throw TorrentBackendError.unsupported("aria2 does not support per-file rename")
    }

    public func setSequential(taskID: UUID, enabled: Bool) async throws {
        guard let gid = engine.gid(for: taskID) else { throw TorrentBackendError.notAvailable }
        try await rpc.changeOption(gid,
            ["stream-piece-selector": enabled ? "inorder" : "geom"])
    }

    public func recheck(taskID: UUID) async throws {
        guard let gid = engine.gid(for: taskID) else { throw TorrentBackendError.notAvailable }
        // aria2 verifies pieces on resume when `check-integrity=true`.
        try await rpc.changeOption(gid, ["check-integrity": "true"])
        try await rpc.unpause(gid)
    }

    public func setSeedRatio(taskID: UUID, ratio: Double?) async throws {
        // aria2 only exposes seed-ratio globally.
        try await rpc.setSeedRatio(ratio ?? 0)
    }

    public func setSeedTime(taskID: UUID, minutes: Int?) async throws {
        try await rpc.setSeedTime(minutes ?? 0)
    }

    public func setUploadLimit(taskID: UUID, bytesPerSec: Int64?) async throws {
        // aria2 does not support per-task upload limits; only global.
        throw TorrentBackendError.unsupported("per-task upload limit requires librqbit helper")
    }

    public func setGlobalUploadLimit(_ bytesPerSec: Int64?) async throws {
        try await rpc.setMaxOverallUploadLimit(bytesPerSec ?? 0)
    }

    public func reloadBlocklist() async throws {
        throw TorrentBackendError.unsupported("blocklist requires librqbit helper")
    }

    // MARK: - bitfield helpers

    /// aria2 returns a hex bitfield where each hex digit represents 4 pieces.
    static func pieces(from bitfield: String, count: Int, pieceLength: Int64, total: Int64) -> [TorrentSnapshot.Piece] {
        guard count > 0 else { return [] }
        var result: [TorrentSnapshot.Piece] = []
        result.reserveCapacity(min(count, 4096))
        for i in 0..<count {
            let byteIdx = i / 4
            let bitIdx = 3 - (i % 4)
            var complete = false
            if byteIdx < bitfield.count / 2 {
                let hexPair = bitfield.dropFirst(byteIdx * 2).prefix(2)
                if let byte = UInt8(hexPair, radix: 16) {
                    complete = (byte >> bitIdx) & 1 == 1
                }
            }
            let len: Int64
            if i == count - 1, total > 0, pieceLength > 0 {
                len = total - Int64(count - 1) * pieceLength
            } else {
                len = pieceLength
            }
            result.append(TorrentSnapshot.Piece(index: i,
                                                state: complete ? .complete : .missing,
                                                length: len, completed: complete ? len : 0))
        }
        return result
    }

    static func bitfieldProgress(_ bitfield: String) -> Double {
        let total = bitfield.count * 4
        guard total > 0 else { return 0 }
        var set = 0
        for c in bitfield {
            if let v = c.hexDigitValue {
                set += v.nonzeroBitCount
            }
        }
        return Double(set) / Double(total)
    }
}

public enum TorrentBackendError: LocalizedError {
    case notAvailable
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "Torrent is not ready or metadata has not been resolved."
        case .unsupported(let msg): return msg
        }
    }
}
