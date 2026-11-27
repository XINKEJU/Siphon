import Foundation

/// Turns a page / folder / repository URL into a `PackageNode` tree. Network
/// work lives here; all parsing is delegated to the pure `PackageParser` so the
/// rules are testable without a live host.
public enum PackageResolver {

    public enum Source: Sendable, Equatable {
        case html(URL)
        case ftp(URL)
        case huggingFace(repo: String, revision: String)
        case github(owner: String, repo: String, tag: String?)
    }

    public enum ResolveError: Error, LocalizedError {
        case unsupported(String)
        case network(String)
        case empty
        case tooManyEntries

        public var errorDescription: String? {
            switch self {
            case .unsupported(let s): return "不支持的来源：\(s)"
            case .network(let s): return "网络请求失败：\(s)"
            case .empty: return "没有找到可下载的条目"
            case .tooManyEntries: return "条目数超过上限"
            }
        }
    }

    /// Classify a URL before any network traffic happens. Exposed for tests.
    public static func source(for url: URL) -> Source {
        let host = (url.host ?? "").lowercased()
        let parts = url.path.split(separator: "/").map(String.init)

        if url.scheme?.lowercased() == "ftp" { return .ftp(url) }

        if host == "huggingface.co" || host.hasSuffix(".huggingface.co") {
            // /{owner}/{repo}, /datasets/{owner}/{repo}, /spaces/{owner}/{repo}
            var index = 0
            if parts.first == "datasets" || parts.first == "spaces" { index = 1 }
            if parts.count >= index + 2 {
                let repo = "\(parts[index])/\(parts[index + 1])"
                return .huggingFace(repo: repo, revision: "main")
            }
        }

        if host == "github.com" || host == "www.github.com" {
            if parts.count >= 2 {
                let owner = parts[0]
                let repo = parts[1].replacingOccurrences(of: ".git", with: "")
                var tag: String?
                if let releasesIndex = parts.firstIndex(of: "releases") {
                    if parts.count > releasesIndex + 2, parts[releasesIndex + 1] == "tag" {
                        tag = parts[releasesIndex + 2]
                    }
                }
                return .github(owner: owner, repo: repo, tag: tag)
            }
        }

        return .html(url)
    }

    /// FTP listing hook, installed once at launch by `PackageFTPBridge`. Keeps
    /// the resolver free of the curl/ExternalRunner dependency so the parsers
    /// stay testable.
    public nonisolated(unsafe) static var ftpLister: ((URL) async throws -> [PackageFTPEntry])?

    /// Fetch and build the tree.
    public static func resolve(url: URL,
                               session: URLSession = .shared,
                               limits: PackageParser.Limits = .default) async throws -> PackageNode {
        switch source(for: url) {
        case .ftp(let base):
            return try await resolveFTP(base, limits: limits)
        case .huggingFace(let repo, let revision):
            return try await resolveHuggingFace(repo: repo, revision: revision,
                                                session: session, limits: limits)
        case .github(let owner, let repo, let tag):
            return try await resolveGitHub(owner: owner, repo: repo, tag: tag,
                                           session: session, limits: limits)
        case .html(let base):
            return try await resolveHTML(base, session: session, limits: limits)
        }
    }

    // MARK: - HTML / index-of

    private static func resolveHTML(_ base: URL, session: URLSession,
                                    limits: PackageParser.Limits) async throws -> PackageNode {
        func fetchFolder(_ url: URL, depth: Int) async -> [PackageNode] {
            guard depth <= limits.maxDepth else { return [] }
            guard let (data, _) = try? await SiteAdapterHTTP.fetch(url, headers: [:], session: session) else {
                return []
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            var nodes = PackageParser.parseHTML(html, baseURL: url, limits: limits)
            // Recurse into folders one level at a time.
            for i in nodes.indices where nodes[i].isFolder {
                guard let childURL = nodes[i].url else { continue }
                nodes[i].children = await fetchFolder(childURL, depth: depth + 1)
                if nodes[i].children.isEmpty {
                    // A folder we could not list stays selectable as a folder
                    // pointing at nothing; drop it so the tree stays honest.
                    nodes[i].kind = .folder
                }
            }
            return nodes
        }

        let nodes = await fetchFolder(base, depth: 0)
        guard !nodes.isEmpty else { throw ResolveError.empty }
        guard nodes.count <= limits.maxEntries else { throw ResolveError.tooManyEntries }
        var root = PackageNode.folder(name: base.host ?? "page", path: base.absoluteString,
                                      children: nodes)
        root.setSelected(true)
        return root
    }

    // MARK: - FTP

    private static func resolveFTP(_ base: URL,
                                   limits: PackageParser.Limits) async throws -> PackageNode {
        guard let lister = ftpLister else {
            throw ResolveError.unsupported("FTP 列表组件未加载")
        }
        do {
            let entries = try await lister(base)
            let nodes = PackageParser.parseFTP(entries: entries, baseURL: base, limits: limits)
            guard !nodes.isEmpty else { throw ResolveError.empty }
            var root = PackageNode.folder(name: base.host ?? "ftp", path: base.absoluteString,
                                          children: nodes)
            root.setSelected(true)
            return root
        } catch let error as ResolveError {
            throw error
        } catch {
            throw ResolveError.network(error.localizedDescription)
        }
    }

    // MARK: - Hugging Face

    private static func resolveHuggingFace(repo: String, revision: String,
                                           session: URLSession,
                                           limits: PackageParser.Limits) async throws -> PackageNode {
        let encoded = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        guard let api = URL(string: "https://huggingface.co/api/models/\(encoded)/tree/\(revision)?recursive=true") else {
            throw ResolveError.unsupported(repo)
        }
        let (data, _) = try await SiteAdapterHTTP.fetch(api, headers: [:], session: session)
        do {
            return try PackageParser.parseHuggingFaceTree(data, repo: repo, revision: revision,
                                                          limits: limits)
        } catch let error as PackageParser.ParseError {
            throw ResolveError.network(error.localizedDescription)
        }
    }

    // MARK: - GitHub

    private static func resolveGitHub(owner: String, repo: String, tag: String?,
                                      session: URLSession,
                                      limits: PackageParser.Limits) async throws -> PackageNode {
        var headers: [String: String] = ["Accept": "application/vnd.github+json"]
        if let token = Keychain.secret(account: "github-token"), !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        let apiPath = tag == nil
            ? "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
            : "https://api.github.com/repos/\(owner)/\(repo)/releases/tags/\(tag!)"
        guard let api = URL(string: apiPath) else { throw ResolveError.unsupported(apiPath) }
        let (data, _) = try await SiteAdapterHTTP.fetch(api, headers: headers, session: session)
        do {
            let files = try PackageParser.parseGitHubRelease(data, owner: owner, repo: repo,
                                                             tag: tag, limits: limits)
            var root = PackageNode.folder(name: "\(owner)/\(repo)", path: repo,
                                          children: files)
            root.setSelected(true)
            return root
        } catch let error as PackageParser.ParseError {
            throw ResolveError.network(error.localizedDescription)
        }
    }
}