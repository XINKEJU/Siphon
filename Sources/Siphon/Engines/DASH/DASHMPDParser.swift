import Foundation

/// A DASH media segment URL.
public struct DASHSegment: Sendable { public let url: URL }

/// Everything needed to download one Representation: the initialization data URL plus
/// the ordered list of media segment URLs.
public struct DASHStream: Sendable {
    public let bandwidth: Int
    public let initURL: URL?
    public let segments: [DASHSegment]
}

/// Parses MPEG-DASH MPD documents into a list of `DASHStream`s.
///
/// Supports the common layouts: `SegmentTemplate` with `$Number$` + fixed duration,
/// `SegmentTemplate` with `SegmentTimeline`, and `SegmentList`. Initialization and
/// media URLs are resolved against the MPD base URL and any per-Representation BaseURL.
public enum DASHMPDParser {
    public static func parse(_ xml: String, baseURL: URL) -> [DASHStream] {
        let d = _Parser(xml: xml, baseURL: baseURL)
        return d.parse()
    }

    /// Parse ISO-8601 durations like `PT1H2M3S` or `PT45S` into seconds.
    static func parseDuration(_ s: String) -> Double? {
        guard s.hasPrefix("PT") else { return nil }
        let body = String(s.dropFirst(2))
        var total: Double = 0
        var num = ""
        for ch in body {
            if ch.isNumber || ch == "." {
                num.append(ch)
            } else {
                let v = Double(num) ?? 0
                num = ""
                switch ch {
                case "H": total += v * 3600
                case "M": total += v * 60
                case "S": total += v
                default: break
                }
            }
        }
        return total
    }

    private final class _Parser: NSObject, XMLParserDelegate {
        let xml: String
        let baseURL: URL
        var streams: [DASHStream] = []
        // transient state while descending
        var inRepresentation = false
        var currentBandwidth = 0
        var currentRepID = ""
        var currentBaseURL: String?
        var currentInit: String?
        var currentTemplateInit: String?
        var currentTemplateMedia: String?
        var currentTimescale: Int?
        var currentDur: Int?
        var currentStartNo = 1
        var timeline: [(d: Int, r: Int)] = []
        var segmentListURLs: [String] = []
        var mpdDuration: Double?

        init(xml: String, baseURL: URL) { self.xml = xml; self.baseURL = baseURL }

        func parse() -> [DASHStream] {
            guard let data = xml.data(using: .utf8) else { return [] }
            let xp = XMLParser(data: data)
            xp.delegate = self
            xp.parse()
            return streams
        }

        func resolve(_ s: String) -> URL {
            if let u = URL(string: s, relativeTo: baseURL) { return u }
            return URL(string: s) ?? baseURL
        }

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch element {
            case "MPD":
                if let d = attributes["mediaPresentationDuration"] { mpdDuration = DASHMPDParser.parseDuration(d) }
            case "Representation":
                inRepresentation = true
                currentBandwidth = attributes["bandwidth"].flatMap(Int.init) ?? 0
                currentRepID = attributes["id"] ?? ""
                currentBaseURL = nil; currentInit = nil
                currentTemplateInit = nil; currentTemplateMedia = nil
                currentTimescale = nil; currentDur = nil; currentStartNo = 1
                timeline = []; segmentListURLs = []
            case "BaseURL" where inRepresentation:
                break // captured in foundCharacters
            case "Initialization":
                if let src = attributes["sourceURL"] {
                    if inRepresentation { currentInit = src }
                    else { currentTemplateInit = src }
                }
            case "SegmentTemplate":
                currentTemplateInit = attributes["initialization"] ?? currentTemplateInit
                currentTemplateMedia = attributes["media"]
                currentTimescale = attributes["timescale"].flatMap(Int.init) ?? currentTimescale
                currentDur = attributes["duration"].flatMap(Int.init) ?? currentDur
                currentStartNo = attributes["startNumber"].flatMap(Int.init) ?? 1
            case "SegmentTimeline":
                timeline = []
            case "S":
                let d = attributes["d"].flatMap(Int.init) ?? 0
                let r = (attributes["r"].flatMap(Int.init) ?? 0) + 1
                timeline.append((d, r))
            case "SegmentURL":
                if let m = attributes["media"] { segmentListURLs.append(m) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if inRepresentation, !t.isEmpty, currentBaseURL == nil {
                currentBaseURL = t
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if element == "Representation" {
                inRepresentation = false
                let base = currentBaseURL.map { resolve($0) } ?? baseURL
                let initTemplate = (currentInit ?? currentTemplateInit)?
                    .replacingOccurrences(of: "$RepresentationID$", with: currentRepID)
                let initURL = initTemplate.map { resolve($0) }

                var segs: [DASHSegment] = []
                if !segmentListURLs.isEmpty {
                    segs = segmentListURLs.map { DASHSegment(url: resolve($0)) }
                } else if let media = currentTemplateMedia {
                    segs = buildTemplate(media: media, base: base)
                }

                streams.append(DASHStream(bandwidth: currentBandwidth, initURL: initURL, segments: segs))
            }
        }

        func buildTemplate(media: String, base: URL) -> [DASHSegment] {
            var result: [DASHSegment] = []
            if !timeline.isEmpty {
                var number = currentStartNo
                for (_, r) in timeline {
                    for _ in 0..<r {
                        let s = media
                            .replacingOccurrences(of: "$Number$", with: String(number))
                            .replacingOccurrences(of: "$RepresentationID$", with: currentRepID)
                        result.append(DASHSegment(url: URL(string: s, relativeTo: base) ?? base))
                        number += 1
                    }
                }
            } else if let dur = currentDur, let ts = currentTimescale, let total = mpdDuration {
                let segDur = Double(dur) / Double(ts)
                let count = max(1, Int(ceil(total / segDur)))
                for n in 0..<count {
                    let number = currentStartNo + n
                    let s = media
                        .replacingOccurrences(of: "$Number$", with: String(number))
                        .replacingOccurrences(of: "$RepresentationID$", with: currentRepID)
                    result.append(DASHSegment(url: URL(string: s, relativeTo: base) ?? base))
                }
            }
            return result
        }
    }
}
