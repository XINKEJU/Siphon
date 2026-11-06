import Foundation

/// eD2K (eMule) file hash.
///
/// The file is split into 9,728,000-byte (9500 KiB) chunks. Each chunk is MD4-hashed;
/// if there is more than one chunk the concatenated chunk digests are MD4-hashed again
/// to yield the final 16-byte eD2K hash. A single-chunk file's hash IS its MD4.
///
/// Boundary note: like aMule/libed2k, when the file size is an exact multiple of the
/// chunk size we do NOT append an extra empty-chunk digest.
public enum ED2KHash {
    public static let chunkSize = 9_728_000

    public static func hash(_ data: Data) -> Data {
        guard data.count > chunkSize else { return MD4.hash(data) }
        var digests = Data()
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            digests.append(MD4.hash(chunk))
            offset = end
        }
        return MD4.hash(digests)
    }

    /// Streaming variant — does not load the whole file into memory.
    public static func hash(fileAt url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var digests = Data()
        var chunkCount = 0
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            digests.append(MD4.hash(chunk))
            chunkCount += 1
            if chunk.count < chunkSize { break }
        }
        if chunkCount == 0 { return MD4.hash(Data()) }
        if chunkCount == 1 { return digests }
        return MD4.hash(digests)
    }

    public static func hex(_ data: Data) -> String { MD4.hex(data) }

    /// Verify a local file against the hash carried by an `ed2k://` link.
    public static func verify(fileAt url: URL, matchesHex expected: String) throws -> Bool {
        let actual = hex(try hash(fileAt: url)).lowercased()
        return actual == expected.lowercased()
    }
}
