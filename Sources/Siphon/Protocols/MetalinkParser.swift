import Foundation

/// Metalink document parser (RFC 5854 "Metalink v4" and the older v3 dialect).
///
/// Extracts, per `<file>`: the priority-ordered mirror URL list, the declared
/// total size and a whole-file hash. `URINormalizer` uses this to expand a
/// `.metalink` / `.meta4` document into native HTTP tasks — multi-CDN failover
/// and integrity verification then run in `HTTPDownloadEngine` instead of being
/// delegated to aria2.
public enum MetalinkParser {

    public struct File: Sendable, Equatable {
        public var name: String
        /// Best-first: priority ascending (v4 `<url priority>`), document order as
        /// tie-break. Duplicates removed.
        public var urls: [URL]
        /// Declared `<size>` in bytes; 0 when absent.
        public var size: Int64
        /// `"algorithm:hex"` spec understood by `HTTPDownloadEngine.verifyChecksum`
        /// (md5 / sha1 / sha256). `nil` when the document declares no supported hash.
        public var checksum: String?
        /// Per-piece SHA-1 hex hashes from `<pieces type="sha-1">` (aria2
        /// ChunkChecksum model): the engine verifies blocks as they land and
        /// re-fetches only the bad ranges. Empty when absent or not sha-1.
        public var pieces: [String]
        /// Byte length of one piece (> 0 iff `pieces` is non-empty).
        public var pieceLength: Int64
    }

    public static func parse(_ text: String) -> [File] {
        guard let data = text.data(using: .utf8) else { return [] }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [File] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.files
    }

    // MARK: - SAX delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        private struct URLCandidate {
            var url: String
            var priority: Int
            var order: Int
        }

        var files: [File] = []
        private var urls: [URLCandidate] = []
        private var size: Int64 = 0
        private var hashes: [String: String] = [:]
        private var fileName: String = ""
        private var capture: CaptureKind?
        private var hashType: String?
        private var buffer = ""
        private var urlOrder = 0
        private var inFile = false
        private var piecesType: String?
        private var piecesLength: Int64 = 0
        private var pieces: [String] = []
        private var inPieces = false

        private enum CaptureKind { case url, size, hash }

        /// Namespace-agnostic local name (v3 and v4 use different XML namespaces).
        private func local(_ elementName: String) -> String {
            elementName.components(separatedBy: ":").last ?? elementName
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch local(elementName) {
            case "file":
                inFile = true
                fileName = attributeDict["name"] ?? ""
                urls = []; size = 0; hashes = [:]; urlOrder = 0
                piecesType = nil; piecesLength = 0; pieces = []; inPieces = false
            case "pieces" where inFile:
                inPieces = true
                piecesType = (attributeDict["type"] ?? "").lowercased()
                    .replacingOccurrences(of: "-", with: "")
                piecesLength = Int64(attributeDict["length"] ?? "") ?? 0
                pieces = []
            case "url" where inFile:
                capture = .url
                urlOrder += 1
                // v4: lower `priority` wins. v3: higher `preference` (0–100) wins —
                // mapped into the same scale. Missing attributes sort after all
                // explicit ones, preserving document order among themselves.
                let p = attributeDict["priority"].flatMap(Int.init)
                    ?? attributeDict["preference"].flatMap(Int.init).map { 101 - max(0, min(100, $0)) }
                    ?? Int.max
                urls.append(URLCandidate(url: "", priority: max(1, p), order: urlOrder))
            case "size" where inFile:
                capture = .size
                buffer = ""
            case "hash" where inFile:
                capture = .hash
                buffer = ""
                // Inside <pieces> the hashes are the per-piece list; outside they
                // are whole-file hashes (v4 under <file>, v3 under <verification>).
                hashType = inPieces ? "piece" : normalizeAlgo(attributeDict["type"] ?? "")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capture != nil else { return }
            buffer += string
            if case .url = capture, let last = urls.indices.last {
                urls[last].url += string
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard capture != nil, let s = String(data: CDATABlock, encoding: .utf8) else { return }
            buffer += s
            if case .url = capture, let last = urls.indices.last {
                urls[last].url += s
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch local(elementName) {
            case "file":
                defer { inFile = false; capture = nil; buffer = ""; hashType = nil; inPieces = false }
                let sorted = urls
                    .sorted { $0.priority != $1.priority
                        ? $0.priority < $1.priority : $0.order < $1.order }
                    .compactMap { URL(string: $0.url.trimmingCharacters(in: .whitespacesAndNewlines)) }
                var seen = Set<URL>()
                let unique = sorted.filter { seen.insert($0).inserted }
                // Only SHA-1 piece lists are actionable (each hash = 40 hex chars).
                let validPieces = piecesType == "sha1" && piecesLength > 0
                    && pieces.allSatisfy { $0.count == 40 }
                    ? pieces : []
                files.append(File(
                    name: fileName.replacingOccurrences(of: "/", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    urls: unique,
                    size: size,
                    checksum: bestHash(hashes),
                    pieces: validPieces,
                    pieceLength: validPieces.isEmpty ? 0 : piecesLength))
            case "size" where inFile:
                size = Int64(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                capture = nil; buffer = ""
            case "hash" where inFile:
                if hashType == "piece" {
                    pieces.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                } else if let t = hashType {
                    hashes[t] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                capture = nil; buffer = ""; hashType = nil
            case "pieces" where inFile:
                inPieces = false
            case "url" where inFile:
                capture = nil
            default:
                break
            }
        }

        private func normalizeAlgo(_ raw: String) -> String? {
            let a = raw.lowercased().replacingOccurrences(of: "-", with: "")
            return ["md5", "sha1", "sha256"].contains(a) ? a : nil
        }

        /// Prefer the strongest supported hash: sha256 > sha1 > md5.
        private func bestHash(_ hashes: [String: String]) -> String? {
            for algo in ["sha256", "sha1", "md5"] {
                if let hex = hashes[algo], !hex.isEmpty {
                    return "\(algo):\(hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                }
            }
            return nil
        }
    }
}
