import Foundation

/// A single HLS media segment (with optional byte-range).
public struct HLSSegment: Sendable {
    public let url: URL
    public let byteRange: (length: Int, offset: Int)?
}

/// Parsed representation of an HLS playlist. A master playlist carries variant streams;
/// a media playlist carries the actual segments plus an optional AES-128 key.
public struct HLSPlaylist: Sendable {
    public var isMaster: Bool
    public var variants: [(url: URL, bandwidth: Int)]
    public var segments: [HLSSegment]
    public var keyURL: URL?
    public var keyIV: Data?   // 16 bytes when explicitly set in #EXT-X-KEY
    public var mediaSequence: Int64
    /// `EXT-X-MAP` initialization segment. Its presence means the playlist carries
    /// fMP4/CMAF fragments rather than MPEG-TS; the init segment must be written first.
    public var mapURL: URL? = nil
    public var mapByteRange: (length: Int, offset: Int)? = nil

    public var isFMP4: Bool { mapURL != nil }
}

public enum HLSParser {
    /// Parse raw playlist text. For a master playlist, call `resolveVariant` afterwards.
    public static func parse(_ text: String, baseURL: URL) -> HLSPlaylist {
        var pl = HLSPlaylist(isMaster: false, variants: [], segments: [],
                             keyURL: nil, keyIV: nil, mediaSequence: 0)
        let lines = text.components(separatedBy: "\n")
        var pendingByteRange: (Int, Int)?
        /// Whether the pending `#EXT-X-BYTERANGE` carried an explicit `@offset`.
        /// When false, the offset must continue from the previous segment's end (RFC 8216).
        var pendingByteRangeHasOffset = false
        /// End offset (exclusive) of the last resolved byte-range, used to derive
        /// implicit offsets for subsequent ranges.
        var lastByteRangeEnd: Int? = nil
        var pendingKeyURI: String?
        var pendingKeyIV: String?
        var mediaSequence: Int64 = 0

        // State machine: a URI line belongs to the most recent STREAM-INF/EXTINF tag.
        // Intervening tags (e.g. #EXT-X-BYTERANGE, #EXT-X-DISCONTINUITY) are legal
        // between EXTINF and its URI, so we never assume "the next line is the URI".
        enum Awaiting { case none, variant(bandwidth: Int), segment }
        var awaiting: Awaiting = .none

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let attrs = parseAttributes(attributeBody(line, prefix: "#EXT-X-STREAM-INF"))
                awaiting = .variant(bandwidth: attrs["BANDWIDTH"].flatMap(Int.init) ?? 0)
                continue
            }
            if line.hasPrefix("#EXT-X-KEY") {
                let attrs = parseAttributes(attributeBody(line, prefix: "#EXT-X-KEY"))
                pendingKeyURI = attrs["URI"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                pendingKeyIV = attrs["IV"]
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                let v = String(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count))
                mediaSequence = Int64(v) ?? 0
                continue
            }
            if line.hasPrefix("#EXTINF") {
                awaiting = .segment
                continue
            }
            if line.hasPrefix("#EXT-X-BYTERANGE") {
                let body = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                pendingByteRange = parseByteRange(body)
                pendingByteRangeHasOffset = body.contains("@")
                continue
            }
            if line.hasPrefix("#EXT-X-MAP") {
                let attrs = parseAttributes(attributeBody(line, prefix: "#EXT-X-MAP"))
                if let uri = attrs["URI"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) {
                    pl.mapURL = resolve(uri, base: baseURL)
                }
                if let br = attrs["BYTERANGE"] {
                    let hasOffset = br.contains("@")
                    var parsed = parseByteRange(br)
                    if let p = parsed, !hasOffset { parsed = (p.0, lastByteRangeEnd ?? 0) }
                    pl.mapByteRange = parsed
                }
                continue
            }
            if line.hasPrefix("#") { continue }   // any other tag: ignore

            switch awaiting {
            case .variant(let bw):
                pl.variants.append((resolve(line, base: baseURL), bw))
                awaiting = .none
            case .segment:
                var br = pendingByteRange
                if let b = br, !pendingByteRangeHasOffset {
                    // RFC 8216: a BYTERANGE without an explicit `@offset` continues
                    // from the end of the previous segment's range.
                    br = (b.0, lastByteRangeEnd ?? 0)
                }
                if let b = br { lastByteRangeEnd = b.1 + b.0 }
                pl.segments.append(HLSSegment(url: resolve(line, base: baseURL), byteRange: br))
                pendingByteRange = nil
                pendingByteRangeHasOffset = false
                awaiting = .none
            case .none:
                break
            }
        }

        pl.mediaSequence = mediaSequence
        if !pl.variants.isEmpty {
            pl.isMaster = true
        } else {
            if let ku = pendingKeyURI { pl.keyURL = resolve(ku, base: baseURL) }
            if let iv = pendingKeyIV { pl.keyIV = hexToData(iv) }
        }
        return pl
    }

    /// Pick the highest-bandwidth variant (or the only one).
    public static func bestVariant(_ pl: HLSPlaylist) -> URL? {
        pl.variants.max(by: { $0.bandwidth < $1.bandwidth })?.url
    }

    // MARK: - helpers
    /// `"<length>@<offset>"`, with offset defaulting to 0.
    private static func parseByteRange(_ body: String) -> (Int, Int)? {
        let parts = body.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            .components(separatedBy: "@")
        guard let l = Int(parts[0]) else { return nil }
        if parts.count == 2, let o = Int(parts[1]) { return (l, o) }
        return (l, 0)
    }

    private static func resolve(_ uri: String, base: URL) -> URL {
        if let u = URL(string: uri, relativeTo: base) { return u }
        return URL(string: uri) ?? base
    }

    /// Strip the tag name and the leading `:` so attribute keys start cleanly.
    private static func attributeBody(_ line: String, prefix: String) -> String {
        var body = String(line.dropFirst(prefix.count))
        if body.hasPrefix(":") { body.removeFirst() }
        return body
    }

    /// Parse `key="value",key2=value2` attribute lists (quote-aware).
    private static func parseAttributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        let chars = Array(s)
        while i < chars.count {
            // read key
            var key = ""
            while i < chars.count, chars[i] != "=" { key.append(chars[i]); i += 1 }
            guard i < chars.count else { break }
            i += 1 // skip '='
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" { value.append(chars[i]); i += 1 }
                i += 1 // skip closing quote
            } else {
                while i < chars.count, chars[i] != "," { value.append(chars[i]); i += 1 }
            }
            if i < chars.count, chars[i] == "," { i += 1 }
            result[key.trimmingCharacters(in: .whitespaces)] = value
        }
        return result
    }

    /// Convert an HLS IV (e.g. `0x1A2B...`) to 16 bytes, or nil if malformed.
    private static func hexToData(_ hex: String) -> Data? {
        let h = hex.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "")
        var data = Data()
        var i = h.startIndex
        while i < h.endIndex {
            let next = h.index(i, offsetBy: 2, limitedBy: h.endIndex) ?? h.endIndex
            if let b = UInt8(h[i..<next], radix: 16) { data.append(b) }
            i = next
        }
        return data.count == 16 ? data : nil
    }
}
