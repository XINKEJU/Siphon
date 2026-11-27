import Foundation

/// One checkable node of a "package" (an index page, an FTP folder, a Hugging
/// Face repository, or a GitHub release). The tree is the shared output of
/// every grabber, so the dialog and the store only ever see this shape.
public struct PackageNode: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case file, folder
    }

    /// Stable identity: the absolute URL for files, the folder path for folders.
    public let id: String
    public var name: String
    public var url: URL?
    public var size: Int64?
    public var checksum: String?
    public var kind: Kind
    public var children: [PackageNode]
    public var isSelected: Bool

    public init(id: String, name: String, url: URL? = nil, size: Int64? = nil,
                checksum: String? = nil, kind: Kind = .file,
                children: [PackageNode] = [], isSelected: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.size = size
        self.checksum = checksum
        self.kind = kind
        self.children = children
        self.isSelected = isSelected
    }

    public static func folder(name: String, path: String, children: [PackageNode]) -> PackageNode {
        PackageNode(id: "dir:\(path)", name: name, kind: .folder, children: children)
    }

    public var isFolder: Bool { kind == .folder }

    /// Total size of every selected file underneath this node.
    public var selectedSize: Int64 {
        if isFolder {
            return children.reduce(0) { $0 + $1.selectedSize }
        }
        return isSelected ? (size ?? 0) : 0
    }

    public var fileCount: Int {
        isFolder ? children.reduce(0) { $0 + $1.fileCount } : 1
    }

    public var selectedFileCount: Int {
        if isFolder {
            return children.reduce(0) { $0 + $1.selectedFileCount }
        }
        return isSelected ? 1 : 0
    }

    /// Every file in the subtree, in document order.
    public var allFiles: [PackageNode] {
        isFolder ? children.flatMap(\.allFiles) : [self]
    }

    /// Apply a selection to this node and everything under it.
    public mutating func setSelected(_ value: Bool) {
        isSelected = value
        for i in children.indices { children[i].setSelected(value) }
    }

    /// Toggle one node. Folders cascade; a folder's own flag is derived from
    /// its children after any child changes.
    public mutating func toggle(_ nodeID: String) -> Bool {
        if id == nodeID {
            setSelected(!isSelected)
            return true
        }
        guard isFolder else { return false }
        for i in children.indices {
            if children[i].toggle(nodeID) {
                refreshFolderSelection()
                return true
            }
        }
        return false
    }

    /// Recompute this folder's checkbox from its children (all / none / mixed).
    public mutating func refreshFolderSelection() {
        guard isFolder else { return }
        for i in children.indices { children[i].refreshFolderSelection() }
        isSelected = children.allSatisfy(\.isSelected)
    }

    /// A file with the relative save path it should land at, built from the
    /// folder chain. Used by the dialog to place package downloads.
    public struct Transfer: Sendable, Equatable {
        public var name: String
        public var url: URL
        public var relativeDirectory: String
        public var size: Int64?
        public var checksum: String?
    }

    /// Flatten the selected files with their relative directories.
    public func selectedTransfers(prefix: String = "") -> [Transfer] {
        if isFolder {
            let next = prefix.isEmpty ? name : prefix + "/" + name
            return children.flatMap { $0.selectedTransfers(prefix: next) }
        }
        guard isSelected, let url else { return [] }
        return [Transfer(name: name, url: url, relativeDirectory: prefix,
                         size: size, checksum: checksum)]
    }
}

public struct PackageFTPEntry: Sendable, Equatable {
    public let name: String
    public let size: Int64
    public let isDirectory: Bool

    public init(name: String, size: Int64, isDirectory: Bool) {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
    }
}

/// Parsers for each package source. All are pure functions over already-fetched
/// bytes so they can be tested offline without touching a network.
public enum PackageParser {

    public struct Limits: Sendable {
        public var maxEntries: Int
        public var maxPerDirectory: Int
        public var maxDepth: Int

        public init(maxEntries: Int = 10_000, maxPerDirectory: Int = 500, maxDepth: Int = 3) {
            self.maxEntries = maxEntries
            self.maxPerDirectory = maxPerDirectory
            self.maxDepth = maxDepth
        }

        public static let `default` = Limits()
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case unparseable(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "没有找到可下载的条目"
            case .unparseable(let s): return "无法解析：\(s)"
            }
        }
    }

    // MARK: - HTML / "Index of"

    /// Extract anchors from an index-of / directory page. Relative URLs are
    /// resolved against `baseURL`; parent links, sort links and non-http
    /// schemes are skipped, and duplicates are collapsed.
    public static func parseHTML(_ html: String, baseURL: URL,
                                 limits: Limits = .default) -> [PackageNode] {
        struct Anchor { var href: String; var text: String; var size: Int64? }
        var anchors: [Anchor] = []

        let pattern = #"(?is)<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(html.startIndex..., in: html)
        var cursor = 0
        re.enumerateMatches(in: html, range: full) { match, _, _ in
            guard let match,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html),
                  let wholeRange = Range(match.range, in: html) else { return }
            let href = String(html[hrefRange])
            let text = decodeEntities(stripTags(String(html[textRange])))

            // Size often appears as free text right after the closing </a>
            // ("file.zip  1.2M"). Stop at the next anchor so a row never picks
            // up its neighbour's size.
            let afterIndex = wholeRange.upperBound
            let nextIndex = html.index(afterIndex, offsetBy: 120, limitedBy: html.endIndex) ?? html.endIndex
            var trailing = String(html[afterIndex..<nextIndex])
            if let nextAnchor = trailing.range(of: "<a", options: [.caseInsensitive]) {
                trailing = String(trailing[..<nextAnchor.lowerBound])
            }
            let size = parseSizeToken(in: trailing)

            anchors.append(Anchor(href: href, text: text, size: size))
            cursor += 1
            _ = cursor
        }
        guard !anchors.isEmpty else { return [] }

        var seen = Set<String>()
        var files: [PackageNode] = []
        var folders: [PackageNode] = []

        for anchor in anchors {
            let raw = anchor.href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty,
                  !raw.hasPrefix("#"),
                  !raw.lowercased().hasPrefix("mailto:"),
                  !raw.lowercased().hasPrefix("javascript:") else { continue }
            // Directory-listing sort links (?C=N;O=D) are navigation, not files.
            if raw.hasPrefix("?") || raw.contains("?C=") { continue }
            guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL else { continue }
            guard resolved.scheme == "http" || resolved.scheme == "https" || resolved.scheme == "ftp" else { continue }
            let isFolder = raw.hasSuffix("/") || anchor.text.hasSuffix("/")
            let name = isFolder
                ? decodedLastComponent(resolved)
                : (anchor.text.isEmpty ? decodedLastComponent(resolved) : anchor.text)
            // Skip the "parent directory" row and self links.
            let lowerName = name.lowercased()
            if lowerName.contains("parent directory") || raw == "../" || raw == ".." { continue }
            if resolved.absoluteString == baseURL.absoluteString { continue }
            guard seen.insert(resolved.absoluteString).inserted else { continue }

            var node = isFolder
                ? PackageNode(id: "dir:\(resolved.absoluteString)", name: name,
                              url: resolved, kind: .folder)
                : PackageNode(id: resolved.absoluteString, name: name, url: resolved,
                              size: anchor.size, kind: .file)
            node.isSelected = true
            if isFolder { folders.append(node) } else { files.append(node) }
        }

        var result = folders + files
        if result.count > limits.maxPerDirectory {
            result = Array(result.prefix(limits.maxPerDirectory))
        }
        return result
    }

    // MARK: - FTP

    /// Map a one-level FTP listing to nodes. Subdirectories are kept as folders
    /// with no children (the resolver recurses); files carry their real size.
    public static func parseFTP(entries: [PackageFTPEntry],
                                baseURL: URL,
                                limits: Limits = .default) -> [PackageNode] {
        var out: [PackageNode] = []
        for entry in entries {
            guard let url = URL(string: entry.name, relativeTo: baseURL)?.absoluteURL else { continue }
            if entry.isDirectory {
                out.append(PackageNode(id: "dir:\(url.absoluteString)", name: entry.name,
                                       url: url, kind: .folder))
            } else {
                out.append(PackageNode(id: url.absoluteString, name: entry.name, url: url,
                                       size: entry.size, kind: .file))
            }
        }
        if out.count > limits.maxPerDirectory { out = Array(out.prefix(limits.maxPerDirectory)) }
        return out
    }

    // MARK: - GitHub

    /// Parse a GitHub release JSON payload into assets plus the two source
    /// archives. `tag` is optional: when present the archive URLs use it,
    /// otherwise they fall back to the generic archive endpoints.
    public static func parseGitHubRelease(_ data: Data,
                                          owner: String,
                                          repo: String,
                                          tag: String? = nil,
                                          limits: Limits = .default) throws -> [PackageNode] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.unparseable("GitHub release JSON")
        }
        let resolvedTag = tag ?? obj["tag_name"] as? String
        var files: [PackageNode] = []

        if let assets = obj["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString) else { continue }
                let size = (asset["size"] as? NSNumber)?.int64Value
                files.append(PackageNode(id: url.absoluteString, name: name, url: url,
                                         size: size, kind: .file))
            }
        }

        let archiveTag = resolvedTag ?? "HEAD"
        let zipString = "https://github.com/\(owner)/\(repo)/archive/refs/tags/\(archiveTag).zip"
        let tarString = "https://github.com/\(owner)/\(repo)/archive/refs/tags/\(archiveTag).tar.gz"
        var archives: [PackageNode] = []
        if let zip = URL(string: zipString) {
            archives.append(PackageNode(id: zip.absoluteString,
                                        name: "\(repo)-\(archiveTag).zip",
                                        url: zip, kind: .file))
        }
        if let tar = URL(string: tarString) {
            archives.append(PackageNode(id: tar.absoluteString,
                                        name: "\(repo)-\(archiveTag).tar.gz",
                                        url: tar, kind: .file))
        }

        var out = files + archives
        if out.count > limits.maxEntries { out = Array(out.prefix(limits.maxEntries)) }
        guard !out.isEmpty else { throw ParseError.empty }
        return out
    }

    // MARK: - Hugging Face

    /// Parse `GET /api/models/{repo}/tree/{revision}?recursive=true`. Files keep
    /// their LFS SHA-256 when present; directories become nested folders.
    public static func parseHuggingFaceTree(_ data: Data,
                                            repo: String,
                                            revision: String,
                                            limits: Limits = .default) throws -> PackageNode {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ParseError.unparseable("Hugging Face tree JSON")
        }
        var fileChildren: [String: [PackageNode]] = [:]
        var folderPaths = Set<String>()

        func resolveURL(_ path: String) -> URL? {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(encoded)")
        }
        func parentPath(_ path: String) -> String {
            guard let slash = path.lastIndex(of: "/") else { return "" }
            return String(path[..<slash])
        }
        /// Register a directory and every implied ancestor so files in a folder
        /// that the API did not list explicitly still get their parent node.
        func registerFolder(_ path: String) {
            var current = path
            while !current.isEmpty, folderPaths.insert(current).inserted {
                current = parentPath(current)
            }
        }

        for row in rows.prefix(limits.maxEntries) {
            guard let path = row["path"] as? String, !path.isEmpty else { continue }
            let type = row["type"] as? String ?? "file"
            if type == "directory" {
                registerFolder(path)
                continue
            }
            guard let url = resolveURL(path) else { continue }
            registerFolder(parentPath(path))
            var checksum: String?
            if let lfs = row["lfs"] as? [String: Any], let oid = lfs["oid"] as? String, !oid.isEmpty {
                checksum = "sha256:\(oid)"
            }
            let size = (row["size"] as? NSNumber)?.int64Value
            let node = PackageNode(id: url.absoluteString,
                                   name: path.split(separator: "/").last.map(String.init) ?? path,
                                   url: url, size: size, checksum: checksum, kind: .file)
            fileChildren[parentPath(path), default: []].append(node)
        }

        func build(_ path: String) -> PackageNode {
            var kids: [PackageNode] = folderPaths
                .filter { parentPath($0) == path }
                .sorted()
                .map { build($0) }
            kids += (fileChildren[path] ?? []).sorted { $0.name < $1.name }
            var node = PackageNode(id: "dir:\(path)",
                                   name: path.split(separator: "/").last.map(String.init) ?? path,
                                   kind: .folder, children: kids, isSelected: true)
            node.refreshFolderSelection()
            return node
        }

        var top: [PackageNode] = folderPaths
            .filter { parentPath($0).isEmpty }
            .sorted()
            .map { build($0) }
        top += (fileChildren[""] ?? []).sorted { $0.name < $1.name }
        guard !top.isEmpty else { throw ParseError.empty }
        var root = PackageNode.folder(name: repo, path: repo, children: top)
        root.setSelected(true)
        return root
    }

    // MARK: - helpers

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodedLastComponent(_ url: URL) -> String {
        let last = url.lastPathComponent
        return last.removingPercentEncoding ?? last
    }

    /// Parse a human size token ("1.2M", "340K", "12 MB", "1,024") out of free
    /// text. Returns bytes, or nil when no token matches.
    static func parseSizeToken(in text: String) -> Int64? {
        let pattern = #"(?i)(\d+(?:[.,]\d+)?)\s*(b|k|kb|m|mb|g|gb|t|tb)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let numRange = Range(m.range(at: 1), in: text),
              let unitRange = Range(m.range(at: 2), in: text) else { return nil }
        let numeric = String(text[numRange]).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(numeric) else { return nil }
        let unit = String(text[unitRange]).lowercased()
        let factor: Double
        switch unit {
        case "b": factor = 1
        case "k", "kb": factor = 1_024
        case "m", "mb": factor = 1_048_576
        case "g", "gb": factor = 1_073_741_824
        case "t", "tb": factor = 1_099_511_627_776
        default: return nil
        }
        return Int64(value * factor)
    }
}