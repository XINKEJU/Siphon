import Foundation

/// Tests archive integrity and recovers damaged members. For a remote ZIP the
/// check downloads one entry at a time and verifies its CRC-32; for a local
/// archive it reads the central directory and validates every member in place.
/// Recovery re-fetches only the failing members into a `recovered/` folder and
/// never rewrites the original archive.
public enum ArchiveTestRepairService {

    public struct MemberResult: Sendable, Identifiable {
        public var path: String
        public var ok: Bool
        public var error: String?
        public var size: Int64
        public var id: String { path }
    }

    public struct Report: Sendable {
        public var archive: String
        public var members: [MemberResult]
        public var archivedBytes: Int64

        public var failed: [MemberResult] { members.filter { !$0.ok } }
        public var okCount: Int { members.filter(\.ok).count }
        public var isHealthy: Bool { failed.isEmpty }
    }

    public enum ServiceError: Error, LocalizedError {
        case notAZip
        case emptyArchive
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .notAZip: return "不是有效的 ZIP 归档"
            case .emptyArchive: return "归档为空"
            case .unsupported(let s): return s
            }
        }
    }

    // MARK: - Local archive

    /// Validate a local ZIP file member by member.
    public static func testLocalArchive(at url: URL) throws -> Report {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ServiceError.unsupported("无法读取文件：\(error.localizedDescription)")
        }
        guard let eocd = RemoteZIPReader.parseEOCD(data) else { throw ServiceError.notAZip }
        let cdStart = Int(eocd.cdOffset)
        let cdLength = Int(eocd.cdSize)
        guard cdStart >= 0, cdLength >= 0, cdStart + cdLength <= data.count else {
            throw ServiceError.notAZip
        }
        let cd = data.subdata(in: cdStart..<(cdStart + cdLength))
        let entries = RemoteZIPReader.parseCentralDirectory(cd, limit: max(eocd.count, 1))
        guard !entries.isEmpty else { throw ServiceError.emptyArchive }

        var results: [MemberResult] = []
        var total: Int64 = 0
        for entry in entries where !entry.isDirectory {
            total += entry.uncompressedSize
            do {
                let payload = try extractLocal(entry, from: data)
                results.append(MemberResult(path: entry.path, ok: true, error: nil,
                                            size: Int64(payload.count)))
            } catch {
                results.append(MemberResult(path: entry.path, ok: false,
                                            error: error.localizedDescription,
                                            size: entry.uncompressedSize))
            }
        }
        return Report(archive: url.lastPathComponent, members: results, archivedBytes: total)
    }

    private static func extractLocal(_ entry: RemoteZIPReader.Entry, from data: Data) throws -> Data {
        let header = Int(entry.localHeaderOffset)
        guard header + 30 <= data.count,
              RemoteZIPReader.u32(data, header) == 0x04034b50 else {
            throw ServiceError.notAZip
        }
        let nameLength = Int(RemoteZIPReader.u16(data, header + 26))
        let extraLength = Int(RemoteZIPReader.u16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start >= 0, Int64(start) + entry.compressedSize <= Int64(data.count) else {
            throw ServiceError.notAZip
        }
        let raw = data.subdata(in: start..<(start + Int(entry.compressedSize)))
        let payload: Data
        switch entry.method {
        case 0: payload = raw
        case 8: payload = try RemoteZIPReader.inflate(raw, expectedSize: Int(entry.uncompressedSize))
        default: throw ServiceError.unsupported("不支持的压缩方式：\(entry.method)")
        }
        let actual = RemoteZIPReader.crc32(payload)
        guard actual == entry.crc32 else {
            throw ServiceError.unsupported(
                String(format: "CRC 校验失败（期望 %08X，实际 %08X）", entry.crc32, actual))
        }
        return payload
    }

    // MARK: - Remote archive

    /// Validate a remote archive by streaming every member.
    public static func testRemoteArchive(_ archive: RemoteZIPReader.Archive,
                                         headers: [String: String] = [:],
                                         session: URLSession = .shared,
                                         progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Report {
        let entries = archive.files
        var results: [MemberResult] = []
        var total: Int64 = 0
        for (index, entry) in entries.enumerated() {
            total += entry.uncompressedSize
            do {
                let payload = try await RemoteZIPReader.read(entry, from: archive,
                                                             headers: headers, session: session)
                results.append(MemberResult(path: entry.path, ok: true, error: nil,
                                            size: Int64(payload.count)))
            } catch {
                results.append(MemberResult(path: entry.path, ok: false,
                                            error: error.localizedDescription,
                                            size: entry.uncompressedSize))
            }
            progress?(index + 1, entries.count)
        }
        return Report(archive: archive.url.lastPathComponent, members: results, archivedBytes: total)
    }

    // MARK: - Repair

    /// Re-download failed members into `destination/recovered/<path>`.
    /// Returns the number of recovered files. Existing files are never
    /// overwritten outside this folder, and the source archive is untouched.
    @discardableResult
    public static func recover(_ report: Report,
                               from archive: RemoteZIPReader.Archive,
                               into destination: URL,
                               headers: [String: String] = [:],
                               session: URLSession = .shared) async throws -> Int {
        guard !report.failed.isEmpty else { return 0 }
        let byPath = Dictionary(uniqueKeysWithValues: archive.files.map { ($0.path, $0) })
        let recoveryRoot = destination
            .appendingPathComponent(report.archive.replacingOccurrences(of: ".zip", with: ""))
            .appendingPathComponent("recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)

        var recovered = 0
        for failed in report.failed {
            guard let entry = byPath[failed.path] else { continue }
            let payload = try await RemoteZIPReader.read(entry, from: archive,
                                                         headers: headers, session: session)
            let target = recoveryRoot.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try payload.write(to: target, options: .atomic)
            recovered += 1
        }
        return recovered
    }
}