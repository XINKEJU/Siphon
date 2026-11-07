import Foundation

/// 从 `.torrent` 文件（bencode）中读取文件清单，用于下载前的磁盘空间预检。
///
/// 只实现判断体积所需的最小 bencode 子集：`pieces` 等大字段直接跳过，
/// 不构造完整文档树，避免为几 MB 的哈希数据做额外拷贝。
public enum TorrentProbe {
    public struct Entry: Equatable, Sendable {
        public let path: [String]
        public let length: Int64

        public init(path: [String], length: Int64) {
            self.path = path
            self.length = length
        }
    }

    /// 种子内的文件清单（多文件种子会带上顶层 name 目录）；解析失败返回 `nil`。
    public static func files(in data: Data) -> [Entry]? {
        let bytes = [UInt8](data)
        guard bytes.count > 2, bytes[0] == open else { return nil }
        var i = 1
        var info: Range<Int>?
        while i < bytes.count, bytes[i] != close {
            guard let key = scanString(bytes, &i) else { return nil }
            let start = i
            guard skip(bytes, &i) else { return nil }
            if key == "info" { info = start..<i }
        }
        guard let info else { return nil }
        return entries(bytes, info)
    }

    /// 尚未落盘的字节数（总量 - 已存在的同名文件大小）；无法解析时返回 `nil`。
    /// `destination` 是任务的目标文件路径，同目录视为种子的下载根目录。
    public static func pendingBytes(for data: Data, destination: URL) -> Int64? {
        guard let entries = files(in: data), !entries.isEmpty else { return nil }
        let root = destination.deletingLastPathComponent()
        var total: Int64 = 0
        var existing: Int64 = 0
        for entry in entries {
            total += max(0, entry.length)
            var url = root
            for component in entry.path { url.appendPathComponent(component) }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            existing += max(0, min(size, entry.length))
        }
        return max(0, total - existing)
    }

    // MARK: - bencode 最小解析

    private static let open = UInt8(ascii: "d")
    private static let listOpen = UInt8(ascii: "l")
    private static let close = UInt8(ascii: "e")
    private static let integerOpen = UInt8(ascii: "i")
    private static let colon = UInt8(ascii: ":")
    private static let minus = UInt8(ascii: "-")

    private static func entries(_ b: [UInt8], _ range: Range<Int>) -> [Entry]? {
        var i = range.lowerBound
        guard i < range.upperBound, b[i] == open else { return nil }
        i += 1
        var name: String?
        var utf8Name: String?
        var singleLength: Int64?
        var list: [(path: [String], length: Int64)] = []
        while i < range.upperBound, b[i] != close {
            guard let key = scanString(b, &i) else { return nil }
            switch key {
            case "name":
                guard let s = scanString(b, &i) else { return nil }
                name = s
            case "name.utf-8":
                guard let s = scanString(b, &i) else { return nil }
                utf8Name = s
            case "length":
                guard let n = scanInteger(b, &i) else { return nil }
                singleLength = n
            case "files":
                guard let f = fileList(b, &i, range.upperBound) else { return nil }
                list = f
            default:
                guard skip(b, &i) else { return nil }
            }
        }
        guard i < range.upperBound, b[i] == close, let root = utf8Name ?? name else { return nil }
        if !list.isEmpty {
            return list.map { Entry(path: [root] + $0.path, length: $0.length) }
        }
        guard let singleLength else { return nil }
        return [Entry(path: [root], length: singleLength)]
    }

    private static func fileList(_ b: [UInt8], _ i: inout Int,
                                 _ end: Int) -> [(path: [String], length: Int64)]? {
        guard i < end, b[i] == listOpen else { return nil }
        i += 1
        var out: [(path: [String], length: Int64)] = []
        while i < end, b[i] != close {
            guard b[i] == open else { return nil }
            i += 1
            var path: [String] = []
            var utf8Path: [String]?
            var length: Int64 = 0
            while i < end, b[i] != close {
                guard let key = scanString(b, &i) else { return nil }
                switch key {
                case "path":
                    guard let p = pathList(b, &i, end) else { return nil }
                    path = p
                case "path.utf-8":
                    guard let p = pathList(b, &i, end) else { return nil }
                    utf8Path = p
                case "length":
                    guard let n = scanInteger(b, &i) else { return nil }
                    length = n
                default:
                    guard skip(b, &i) else { return nil }
                }
            }
            guard i < end, b[i] == close else { return nil }
            i += 1
            out.append((utf8Path ?? path, length))
        }
        guard i < end, b[i] == close else { return nil }
        i += 1
        return out
    }

    private static func pathList(_ b: [UInt8], _ i: inout Int, _ end: Int) -> [String]? {
        guard i < end, b[i] == listOpen else { return nil }
        i += 1
        var parts: [String] = []
        while i < end, b[i] != close {
            guard let s = scanString(b, &i) else { return nil }
            parts.append(s)
        }
        guard i < end, b[i] == close else { return nil }
        i += 1
        return parts
    }

    private static func scanInteger(_ b: [UInt8], _ i: inout Int) -> Int64? {
        guard i < b.count, b[i] == integerOpen else { return nil }
        i += 1
        var sign: Int64 = 1
        if i < b.count, b[i] == minus { sign = -1; i += 1 }
        var value: Int64 = 0
        var digits = 0
        while i < b.count, isDigit(b[i]) {
            value = value * 10 + Int64(b[i] - 48)
            i += 1
            digits += 1
        }
        guard digits > 0, i < b.count, b[i] == close else { return nil }
        i += 1
        return sign * value
    }

    private static func scanString(_ b: [UInt8], _ i: inout Int) -> String? {
        var count = 0
        var digits = 0
        while i < b.count, isDigit(b[i]) {
            count = count * 10 + Int(b[i] - 48)
            i += 1
            digits += 1
        }
        guard digits > 0, i < b.count, b[i] == colon, i + 1 + count <= b.count else { return nil }
        i += 1
        let end = i + count
        defer { i = end }
        return String(bytes: b[i..<end], encoding: .utf8)
    }

    private static func skipString(_ b: [UInt8], _ i: inout Int) -> Bool {
        var count = 0
        var digits = 0
        while i < b.count, isDigit(b[i]) {
            count = count * 10 + Int(b[i] - 48)
            i += 1
            digits += 1
        }
        guard digits > 0, i < b.count, b[i] == colon, i + 1 + count <= b.count else { return false }
        i += 1 + count
        return true
    }

    /// 跳过一个值（整数 / 字节串 / 列表 / 字典），不分配任何字符串。
    private static func skip(_ b: [UInt8], _ i: inout Int) -> Bool {
        guard i < b.count else { return false }
        switch b[i] {
        case integerOpen:
            i += 1
            while i < b.count, b[i] != close { i += 1 }
            guard i < b.count else { return false }
            i += 1
            return true
        case listOpen, open:
            i += 1
            while i < b.count, b[i] != close {
                guard skip(b, &i) else { return false }
            }
            guard i < b.count else { return false }
            i += 1
            return true
        case 48...57:
            return skipString(b, &i)
        default:
            return false
        }
    }

    private static func isDigit(_ v: UInt8) -> Bool { v >= 48 && v <= 57 }
}
