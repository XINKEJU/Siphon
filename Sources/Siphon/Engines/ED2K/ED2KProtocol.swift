import Foundation

// MARK: - eDonkey / eMule TCP wire protocol
//
// Frame layout (Wireshark `packet-edonkey.c`, eMule Protocol Specification §6):
//
//   [0]      protocol marker: 0xE3 (eDonkey), 0xC5 (eMule ext), 0xD4 (zlib packed)
//   [1..4]   size, little-endian UInt32 = 1 (opcode) + payload.count
//   [5]      opcode
//   [6..]    payload
//
// `size` therefore counts the opcode byte. A reader must consume exactly
// `5 + size` bytes per frame; TCP is a byte stream so frames are reassembled
// with a length-prefixed read, never with a single recv().
//
// Verified against:
//   wireshark/epan/dissectors/packet-edonkey.c (EDONKEY_TCP_HEADER_LENGTH = 5,
//   dissect_edonkey_tcp_message(msg_type, ..., offset+6, size-1, ...))
//   ramonmillan.com "eMule Protocol Specification" §6.4.1–6.4.5

public enum ED2KProto {
    public static let edonkey: UInt8 = 0xE3
    public static let emuleExt: UInt8 = 0xC5
    public static let packed: UInt8 = 0xD4
}

public enum ED2KOpcode {
    // Client <-> client
    public static let hello: UInt8 = 0x01
    public static let sendingPart: UInt8 = 0x46
    public static let requestParts: UInt8 = 0x47
    public static let noSuchFile: UInt8 = 0x48
    public static let endOfDownload: UInt8 = 0x49
    public static let viewFiles: UInt8 = 0x4A
    public static let helloAnswer: UInt8 = 0x4C
    public static let fileStatusRequest: UInt8 = 0x4F
    public static let fileStatus: UInt8 = 0x50
    public static let hashsetRequest: UInt8 = 0x51
    public static let hashsetAnswer: UInt8 = 0x52
    public static let startUploadReq: UInt8 = 0x54
    public static let acceptUploadReq: UInt8 = 0x55
    public static let cancelTransfer: UInt8 = 0x56
    public static let outOfPartReqs: UInt8 = 0x57
    public static let requestFileName: UInt8 = 0x58
    public static let requestFileNameAnswer: UInt8 = 0x59
    public static let queueRank: UInt8 = 0x5C

    // Client <-> server
    public static let loginRequest: UInt8 = 0x01
    public static let getSources: UInt8 = 0x19
    public static let foundSources: UInt8 = 0x42
    public static let idChange: UInt8 = 0x40
    public static let serverMessage: UInt8 = 0x38
    public static let serverStatus: UInt8 = 0x34
    public static let serverIdent: UInt8 = 0x41

    /// eMule transfers data in 180 KiB blocks; a REQUESTPARTS frame carries up to 3.
    public static let blockSize: Int = 180 * 1024

    // eMule extension layer (marker 0xC5) — 64-bit offsets for files > 4 GiB.
    // Wireshark: EMULE_MSG_REQUEST_PARTS_64 / EMULE_MSG_SENDING_PART_64.
    public static let requestParts64: UInt8 = 0xA3
    public static let sendingPart64: UInt8 = 0xA2
}

// MARK: - Little-endian byte helpers

/// Minimal sequential writer. eDonkey uses little-endian for every multi-byte
/// integer except IPv4 addresses inside address lists (network byte order).
public struct ED2KWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }

    public mutating func u16(_ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    public mutating func u32(_ v: UInt32) {
        data.append(UInt8(truncatingIfNeeded: v))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v >> 16))
        data.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    public mutating func u64(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }

    public mutating func bytes(_ b: Data) { data.append(b) }

    /// `<String> ::= <length:u16 LE> <bytes>`
    public mutating func string(_ s: String) {
        let b = Data(s.utf8)
        u16(UInt16(b.count))
        bytes(b)
    }

    /// A long-name meta tag: `<type:u8> <nameLen:u16> <name> <value>`.
    /// Short-name tags (type | 0x80 with a 1-byte special ID) are optional in
    /// the protocol; long names are always accepted and keep this code simple.
    public mutating func stringTag(name: String, value: String) {
        u8(0x02)                       // EDONKEY_MTAG_STRING
        let n = Data(name.utf8)
        u16(UInt16(n.count)); bytes(n)
        string(value)
    }

    public mutating func dwordTag(name: String, value: UInt32) {
        u8(0x03)                       // EDONKEY_MTAG_DWORD
        let n = Data(name.utf8)
        u16(UInt16(n.count)); bytes(n)
        u32(value)
    }
}

public struct ED2KReader {
    public let data: Data
    public private(set) var offset: Int = 0

    public init(_ data: Data) { self.data = data }

    public var remaining: Int { data.count - offset }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ED2KTransportError.truncatedFrame }
        let v = data[data.startIndex + offset]; offset += 1; return v
    }

    public mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw ED2KTransportError.truncatedFrame }
        let v = UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
        offset += 2; return v
    }

    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ED2KTransportError.truncatedFrame }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[data.startIndex + offset + i]) << UInt32(i * 8) }
        offset += 4; return v
    }

    public mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw ED2KTransportError.truncatedFrame }
        let start = data.startIndex + offset
        offset += n
        return data.subdata(in: start..<(start + n))
    }

    public mutating func skip(_ n: Int) throws {
        guard n >= 0, remaining >= n else { throw ED2KTransportError.truncatedFrame }
        offset += n
    }
}

// MARK: - Frame

public struct ED2KFrame {
    public let marker: UInt8
    public let opcode: UInt8
    public let payload: Data

    public init(marker: UInt8 = ED2KProto.edonkey, opcode: UInt8, payload: Data = Data()) {
        self.marker = marker; self.opcode = opcode; self.payload = payload
    }

    /// Serialise as `[marker][size:u32 LE][opcode][payload]`, size = 1 + payload.
    public func encoded() -> Data {
        var w = ED2KWriter()
        w.u8(marker)
        w.u32(UInt32(1 + payload.count))
        w.u8(opcode)
        w.bytes(payload)
        return w.data
    }
}

public enum ED2KTransportError: Error, LocalizedError {
    case truncatedFrame
    case invalidMarker(UInt8)
    case frameTooLarge(UInt32)
    case connectionFailed(String)
    case ioFailed(String)
    case peerRejected(String)
    case noSources(String)
    case incomplete(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .truncatedFrame: return "eD2K 报文不完整"
        case .invalidMarker(let m): return String(format: "eD2K 未知协议标记 0x%02X", m)
        case .frameTooLarge(let n): return "eD2K 报文过大（\(n) 字节）"
        case .connectionFailed(let s): return "无法连接 eD2K 节点：\(s)"
        case .ioFailed(let s): return "eD2K 传输失败：\(s)"
        case .peerRejected(let s): return "eD2K 节点拒绝传输：\(s)"
        case .noSources(let s): return "没有可用的 eD2K 源：\(s)"
        case .incomplete(let s): return "eD2K 下载不完整：\(s)"
        case .cancelled: return "eD2K 下载已取消"
        }
    }
}

// MARK: - Message builders / parsers

public enum ED2KMessages {
    /// A stable client identity. eMule requires userHash[5] == 0x0E and
    /// userHash[14] == 0x6F; other clients use exactly that to distinguish a
    /// client-to-client HELLO from a server LOGINREQUEST (see Wireshark's
    /// `helloClient` heuristic). We satisfy it so real peers accept us.
    public static let clientHash: Data = {
        var b = Data(repeating: 0x33, count: 16)
        b[5] = 0x0E
        b[14] = 0x6F
        return b
    }()

    /// Client-to-client HELLO: `0x10 <clientInfo> <serverAddress>`.
    public static func hello(port: UInt16 = 4662) -> ED2KFrame {
        var w = ED2KWriter()
        w.u8(0x10)                                  // user hash size = 16
        w.bytes(clientHash)
        w.u32(0)                                    // client ID (LowID until server assigns one)
        w.u16(port)
        w.u32(2)                                    // tag count
        w.stringTag(name: "name", value: "Siphon")
        w.stringTag(name: "version", value: "1.0")
        w.u32(0)                                    // server IP
        w.u16(0)                                    // server port
        return ED2KFrame(opcode: ED2KOpcode.hello, payload: w.data)
    }

    /// Server LOGINREQUEST: `<clientInfo>` with no 0x10 prefix.
    public static func login(port: UInt16 = 4662) -> ED2KFrame {
        var w = ED2KWriter()
        w.bytes(clientHash)
        w.u32(0)
        w.u16(port)
        w.u32(2)
        w.stringTag(name: "name", value: "Siphon")
        w.stringTag(name: "version", value: "1.0")
        return ED2KFrame(opcode: ED2KOpcode.loginRequest, payload: w.data)
    }

    public static func requestSources(fileHash: Data, fileSize: UInt64) -> ED2KFrame {
        var w = ED2KWriter()
        w.bytes(fileHash)
        if fileSize <= UInt32.max {
            w.u32(UInt32(fileSize))
        } else {
            w.u32(0)                                // 0 => 64-bit size follows
            w.u64(fileSize)
        }
        return ED2KFrame(opcode: ED2KOpcode.getSources, payload: w.data)
    }

    /// OP_FOUND_SOURCES: `<fileHash 16> <count:u8> (<ip 4 network order><port:u16 LE>)*`
    public static func parseSources(_ payload: Data) -> [(host: String, port: Int)] {
        var r = ED2KReader(payload)
        guard (try? r.bytes(16)) != nil, let count = try? r.u8() else { return [] }
        var out: [(host: String, port: Int)] = []
        for _ in 0..<count {
            guard let ip = try? r.bytes(4), let port = try? r.u16() else { break }
            let host = "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
            out.append((host, Int(port)))
        }
        return out
    }

    /// eMule extension HELLO (0xC5 / 0x01). Modern peers expect this alongside
    /// the classic 0xE3 HELLO: `<version:u16> <tagCount:u32> <tags>`.
    public static func emuleInfo() -> ED2KFrame {
        var w = ED2KWriter()
        w.u16(0x3C)
        w.u32(0)
        return ED2KFrame(marker: ED2KProto.emuleExt, opcode: 0x01, payload: w.data)
    }

    public static func startUpload(fileHash: Data) -> ED2KFrame {
        ED2KFrame(opcode: ED2KOpcode.startUploadReq, payload: fileHash)
    }

    /// OP_REQUESTPARTS: `<fileHash 16> <start[3]:u32> <end[3]:u32>`.
    /// The three starts come first, then the three ends — they are NOT interleaved
    /// (Wireshark `case EDONKEY_MSG_REQUEST_PARTS`). Unused slots are 0/0.
    /// End offsets are exclusive, eMule block size is 180 KiB.
    public static func requestParts(fileHash: Data, ranges: [(start: UInt64, end: UInt64)]) -> ED2KFrame {
        var w = ED2KWriter()
        w.bytes(fileHash)
        for i in 0..<3 {
            w.u32(i < ranges.count ? UInt32(ranges[i].start) : 0)
        }
        for i in 0..<3 {
            w.u32(i < ranges.count ? UInt32(ranges[i].end) : 0)
        }
        return ED2KFrame(opcode: ED2KOpcode.requestParts, payload: w.data)
    }

    public struct Part {
        public let fileHash: Data
        public let start: UInt64
        public let end: UInt64
        public let data: Data
    }

    /// OP_SENDINGPART: `<fileHash 16> <start:u32> <end:u32> <data>`.
    public static func parsePart(_ payload: Data) throws -> Part {
        var r = ED2KReader(payload)
        let hash = try r.bytes(16)
        let start = try r.u32()
        let end = try r.u32()
        let body = try r.bytes(r.remaining)
        guard end >= start, UInt64(body.count) == UInt64(end - start) else {
            throw ED2KTransportError.truncatedFrame
        }
        return Part(fileHash: hash, start: UInt64(start), end: UInt64(end), data: body)
    }

    /// 64-bit counterpart of `requestParts`, carried on the 0xC5 eMule layer.
    /// Layout: `<fileHash 16> <start[3]:u64> <end[3]:u64>`.
    public static func requestParts64(fileHash: Data,
                                      ranges: [(start: UInt64, end: UInt64)]) -> ED2KFrame {
        var w = ED2KWriter()
        w.bytes(fileHash)
        for i in 0..<3 { w.u64(i < ranges.count ? ranges[i].start : 0) }
        for i in 0..<3 { w.u64(i < ranges.count ? ranges[i].end : 0) }
        return ED2KFrame(marker: ED2KProto.emuleExt,
                         opcode: ED2KOpcode.requestParts64, payload: w.data)
    }

    /// OP_SENDINGPART_64: `<fileHash 16> <start:u64> <end:u64> <data>`.
    public static func parsePart64(_ payload: Data) throws -> Part {
        var r = ED2KReader(payload)
        let hash = try r.bytes(16)
        var start: UInt64 = 0
        var end: UInt64 = 0
        for i in 0..<8 { start |= UInt64(try r.u8()) << UInt64(i * 8) }
        for i in 0..<8 { end |= UInt64(try r.u8()) << UInt64(i * 8) }
        let body = try r.bytes(r.remaining)
        guard end >= start, UInt64(body.count) == end - start else {
            throw ED2KTransportError.truncatedFrame
        }
        return Part(fileHash: hash, start: start, end: end, data: body)
    }

    public static func endOfDownload(fileHash: Data) -> ED2KFrame {
        ED2KFrame(opcode: ED2KOpcode.endOfDownload, payload: fileHash)
    }
}

/// Convert a 32-hex-character eD2K hash string to its 16 raw bytes.
public func ed2kHashBytes(_ hex: String) throws -> Data {
    guard hex.count == 32 else { throw ED2KError.invalidLink(hex) }
    var out = Data()
    var i = hex.startIndex
    for _ in 0..<16 {
        let j = hex.index(i, offsetBy: 2)
        guard let b = UInt8(hex[i..<j], radix: 16) else { throw ED2KError.invalidLink(hex) }
        out.append(b)
        i = j
    }
    return out
}
