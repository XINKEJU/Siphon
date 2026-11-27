import Foundation
import Compression

/// Reads a ZIP archive on a remote HTTP(S) server without downloading the
/// whole file: it range-reads the end-of-central-directory, the central
/// directory, then only the entries the caller asks for, verifying each CRC-32.
public struct RemoteZIPReader: Sendable {

    public struct Entry: Sendable, Identifiable, Equatable {
        public let path: String
        public let compressedSize: Int64
        public let uncompressedSize: Int64
        public let crc32: UInt32
        public let method: UInt16
        public let localHeaderOffset: Int64
        public var id: String { path }

        public init(path: String, compressedSize: Int64, uncompressedSize: Int64,
                    crc32: UInt32, method: UInt16, localHeaderOffset: Int64) {
            self.path = path
            self.compressedSize = compressedSize
            self.uncompressedSize = uncompressedSize
            self.crc32 = crc32
            self.method = method
            self.localHeaderOffset = localHeaderOffset
        }

        public var isDirectory: Bool { path.hasSuffix("/") }
        public var isSupported: Bool { method == 0 || method == 8 }
    }

    public struct Archive: Sendable {
        public let url: URL
        public let size: Int64
        public let etag: String?
        public let lastModified: String?
        public let entries: [Entry]

        public var files: [Entry] { entries.filter { !$0.isDirectory } }
    }

    public enum ReaderError: Error, LocalizedError, Equatable {
        case rangeUnsupported
        case noContentLength
        case notAZip
        case zip64Unsupported
        case unsupportedCompression(UInt16)
        case truncated
        case crcMismatch(path: String, expected: UInt32, actual: UInt32)
        case inflateFailed(String)
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .rangeUnsupported: return "服务器不支持按需分段读取（Range）"
            case .noContentLength: return "服务器未提供文件大小"
            case .notAZip: return "不是有效的 ZIP 文件"
            case .zip64Unsupported: return "ZIP64 结构超出支持范围"
            case .unsupportedCompression(let m): return "不支持的压缩方式：\(m)"
            case .truncated: return "数据不完整"
            case .crcMismatch(let p, let e, let a):
                return String(format: "%@ CRC 校验失败（期望 %08X，实际 %08X）", p, e, a)
            case .inflateFailed(let s): return "解压失败：\(s)"
            case .network(let s): return "网络错误：\(s)"
            }
        }
    }

    // MARK: - Open

    /// Probe the remote file, then read its tail and central directory.
    public static func open(_ url: URL,
                            headers: [String: String] = [:],
                            session: URLSession = .shared) async throws -> Archive {
        var total: Int64 = -1
        var etag: String?
        var lastModified: String?

        // A one-byte ranged GET tells us both range support and total size, and
        // works on servers that reject HEAD.
        let probe = try await fetchRange(url, start: 0, end: 0, headers: headers, session: session)
        if let contentRange = probe.contentRange {
            total = contentRange.total
        }
        etag = probe.etag
        lastModified = probe.lastModified
        if total < 0 {
            total = probe.totalLength
        }
        guard total > 0 else { throw ReaderError.noContentLength }
        guard probe.statusCode == 206 else { throw ReaderError.rangeUnsupported }

        let tailLength = Int(min(Int64(65_536), total))
        let tailStart = total - Int64(tailLength)
        let tail = try await fetchRange(url, start: tailStart, end: total - 1,
                                        headers: headers, session: session).data
        guard let eocd = parseEOCD(tail, tailAbsoluteOffset: tailStart) else {
            throw ReaderError.notAZip
        }

        let cdLength = Int(min(eocd.cdSize, 8 * 1024 * 1024))
        guard cdLength > 0, eocd.cdOffset >= 0, eocd.cdOffset + Int64(cdLength) <= total else {
            throw ReaderError.notAZip
        }
        let cd = try await fetchRange(url, start: eocd.cdOffset,
                                      end: eocd.cdOffset + Int64(cdLength) - 1,
                                      headers: headers, session: session).data
        let entries = parseCentralDirectory(cd, limit: max(eocd.count, 1))
        guard !entries.isEmpty else { throw ReaderError.notAZip }

        return Archive(url: url, size: total, etag: etag, lastModified: lastModified,
                       entries: entries)
    }

    // MARK: - Read one entry

    /// Download, decompress and CRC-check a single entry.
    public static func read(_ entry: Entry,
                            from archive: Archive,
                            headers: [String: String] = [:],
                            session: URLSession = .shared) async throws -> Data {
        guard entry.isSupported else { throw ReaderError.unsupportedCompression(entry.method) }
        let headerLength: Int64 = 30
        let local = try await fetchRange(archive.url,
                                         start: entry.localHeaderOffset,
                                         end: entry.localHeaderOffset + headerLength - 1,
                                         headers: headers, session: session).data
        guard local.count >= 30, u32(local, 0) == 0x04034b50 else { throw ReaderError.notAZip }
        let nameLength = Int(u16(local, 26))
        let extraLength = Int(u16(local, 28))
        let dataOffset = entry.localHeaderOffset + headerLength
            + Int64(nameLength) + Int64(extraLength)
        guard entry.compressedSize > 0 else { return Data() }

        let raw = try await fetchRange(archive.url,
                                       start: dataOffset,
                                       end: dataOffset + entry.compressedSize - 1,
                                       headers: headers, session: session).data
        guard Int64(raw.count) == entry.compressedSize else { throw ReaderError.truncated }

        let payload: Data
        switch entry.method {
        case 0:
            payload = raw
        case 8:
            payload = try inflate(raw, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ReaderError.unsupportedCompression(entry.method)
        }

        let actual = crc32(payload)
        guard actual == entry.crc32 else {
            throw ReaderError.crcMismatch(path: entry.path, expected: entry.crc32, actual: actual)
        }
        return payload
    }

    // MARK: - ZIP parsing (pure, used by tests and local archives)

    public struct EndOfCentralDirectory {
        public var count: Int
        public var cdSize: Int64
        public var cdOffset: Int64
    }

    /// Locate and parse the EOCD record inside `data`. `tailAbsoluteOffset` is
    /// added so the returned `cdOffset` is absolute in the whole file.
    public static func parseEOCD(_ data: Data, tailAbsoluteOffset: Int64 = 0) -> EndOfCentralDirectory? {
        guard data.count >= 22 else { return nil }
        var searchEnd = data.count - 22
        let lowerBound = max(0, data.count - 22 - 65_536)
        var found: Int?
        while searchEnd >= lowerBound {
            if u32(data, searchEnd) == 0x06054b50 { found = searchEnd; break }
            searchEnd -= 1
        }
        guard let eocd = found else { return nil }
        var count = Int(u16(data, eocd + 10))
        var cdSize = Int64(u32(data, eocd + 12))
        var cdOffset = Int64(u32(data, eocd + 16))

        let needsZip64 = count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF
        if needsZip64 {
            guard let zip64 = parseZip64(data, eocdOffset: eocd) else {
                return EndOfCentralDirectory(count: count, cdSize: cdSize, cdOffset: cdOffset)
            }
            count = zip64.count
            cdSize = zip64.cdSize
            cdOffset = zip64.cdOffset
        }
        return EndOfCentralDirectory(count: count, cdSize: cdSize,
                                     cdOffset: cdOffset + tailAbsoluteOffset)
    }

    private static func parseZip64(_ data: Data, eocdOffset: Int) -> EndOfCentralDirectory? {
        // The ZIP64 EOCD locator sits immediately before the classic EOCD.
        var locator = eocdOffset - 20
        let lower = max(0, eocdOffset - 40)
        while locator >= lower {
            if u32(data, locator) == 0x07064b50 { break }
            locator -= 1
        }
        guard locator >= lower, u32(data, locator) == 0x07064b50 else { return nil }
        let zip64OffsetInTail = Int(u64(data, locator + 8))
        // Only usable if the ZIP64 EOCD is inside the tail buffer.
        guard zip64OffsetInTail >= 0, zip64OffsetInTail + 56 <= data.count else { return nil }
        guard u32(data, zip64OffsetInTail) == 0x06064b50 else { return nil }
        let count = Int(u64(data, zip64OffsetInTail + 32))
        let cdSize = Int64(bitPattern: u64(data, zip64OffsetInTail + 40))
        let cdOffset = Int64(bitPattern: u64(data, zip64OffsetInTail + 48))
        return EndOfCentralDirectory(count: count, cdSize: cdSize, cdOffset: cdOffset)
    }

    /// Parse central-directory records from the start of `data`.
    public static func parseCentralDirectory(_ data: Data, limit: Int) -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        while offset + 46 <= data.count, entries.count < limit {
            guard u32(data, offset) == 0x02014b50 else { break }
            let flags = u16(data, offset + 8)
            let method = u16(data, offset + 10)
            let crc = u32(data, offset + 16)
            var compressed = Int64(u32(data, offset + 20))
            var uncompressed = Int64(u32(data, offset + 24))
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            var localOffset = Int64(u32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            // UTF-8 flag (bit 11) is respected; legacy CP437 names are shown raw.
            let rawName = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: rawName, encoding: .utf8)
                ?? String(decoding: rawName, as: UTF8.self)
            _ = flags

            if extraLength > 0, nameStart + nameLength + extraLength <= data.count {
                let extra = data.subdata(in: (nameStart + nameLength)..<(nameStart + nameLength + extraLength))
                var pos = 0
                while pos + 4 <= extra.count {
                    let id = u16(extra, pos)
                    let size = Int(u16(extra, pos + 2))
                    let body = pos + 4
                    if id == 0x0001, body + size <= extra.count {
                        var p = body
                        if uncompressed == 0xFFFF_FFFF, p + 8 <= body + size {
                            uncompressed = Int64(bitPattern: u64(extra, p)); p += 8
                        }
                        if compressed == 0xFFFF_FFFF, p + 8 <= body + size {
                            compressed = Int64(bitPattern: u64(extra, p)); p += 8
                        }
                        if localOffset == 0xFFFF_FFFF, p + 8 <= body + size {
                            localOffset = Int64(bitPattern: u64(extra, p)); p += 8
                        }
                    }
                    pos = body + size
                }
            }

            entries.append(Entry(path: name, compressedSize: compressed,
                                 uncompressedSize: uncompressed, crc32: crc,
                                 method: method, localHeaderOffset: localOffset))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Deflate

    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if data.isEmpty { return Data() }
        if expectedSize <= 0 { return Data() }

        func run(_ input: Data) -> Data? {
            var output = Data(count: expectedSize)
            let written = output.withUnsafeMutableBytes { dst -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return input.withUnsafeBytes { src -> Int in
                    guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dstBase, expectedSize, srcBase, input.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            return output.prefix(written)
        }

        if let result = run(data) { return result }
        // Some encoders prepend a zlib header; retry after stripping the 2-byte
        // header if the first body is not raw DEFLATE.
        if data.count > 6 {
            let body = data.subdata(in: 2..<data.count)
            if let result = run(body) { return result }
        }
        throw ReaderError.inflateFailed("DEFLATE 数据无法解压")
    }

    // MARK: - HTTP range

    struct RangeResponse {
        var data: Data
        var statusCode: Int
        var totalLength: Int64
        var contentRange: (start: Int64, end: Int64, total: Int64)?
        var etag: String?
        var lastModified: String?
    }

    static func fetchRange(_ url: URL, start: Int64, end: Int64,
                           headers: [String: String],
                           session: URLSession) async throws -> RangeResponse {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReaderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ReaderError.network("无 HTTP 响应")
        }
        let total = Int64(http.value(forHTTPHeaderField: "Content-Range")
            .flatMap { $0.split(separator: "/").last.map(String.init) } ?? "")
            ?? http.expectedContentLength
        var parsedRange: (Int64, Int64, Int64)?
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
            // "bytes 0-0/12345"
            let parts = contentRange.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
            if parts.count == 2,
               let totalValue = Int64(parts[1]),
               let span = parts[0].split(separator: "-").first,
               let startValue = Int64(span) {
                parsedRange = (startValue, totalValue - 1, totalValue)
            }
        }
        return RangeResponse(data: data,
                             statusCode: http.statusCode,
                             totalLength: total,
                             contentRange: parsedRange,
                             etag: http.value(forHTTPHeaderField: "ETag"),
                             lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    // MARK: - little-endian helpers

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let start = data.startIndex + offset
        return UInt16(data[start]) | (UInt16(data[start + 1]) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let s = data.startIndex + offset
        return UInt32(data[s])
            | (UInt32(data[s + 1]) << 8)
            | (UInt32(data[s + 2]) << 16)
            | (UInt32(data[s + 3]) << 24)
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        let lo = UInt64(u32(data, offset))
        let hi = UInt64(u32(data, offset + 4))
        return lo | (hi << 32)
    }
}