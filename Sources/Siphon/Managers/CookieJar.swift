import Foundation

/// Host-scoped cookie cache fed by the browser extension.
///
/// The extension already attaches `Cookie` for the URL it submits, but a single
/// submission can fan out into several requests (playlist segments, mirrors,
/// redirects) that were never seen by the browser. Keeping the last-known
/// cookie per host lets those follow-up requests stay authenticated without
/// asking the user to export cookies by hand.
///
/// Scope is deliberately narrow:
/// - cookies are stored per **exact host** (no sub-domain wildcard);
/// - values are persisted to Application Support, so they survive a relaunch;
/// - a bounded LRU (200 hosts / 100 cookies per host) keeps the file small;
/// - `path`, `secure` and `expiresAt` are honoured when assembling the header.
public final class CookieJar: @unchecked Sendable {
    public static let shared = CookieJar()

    public struct Cookie: Codable, Sendable {
        public var name: String
        public var value: String
        /// Lowercased request host (no port). Stored without a leading dot so a
        /// host-only cookie can never leak to a sibling sub-domain.
        public var host: String
        public var path: String
        public var secure: Bool
        public var expiresAt: Date?
        public var lastAccess: Date

        public init(name: String, value: String, host: String, path: String = "/",
                    secure: Bool = false, expiresAt: Date? = nil,
                    lastAccess: Date = Date()) {
            self.name = name; self.value = value; self.host = host
            self.path = path; self.secure = secure
            self.expiresAt = expiresAt; self.lastAccess = lastAccess
        }
    }

    private let lock = NSLock()
    private var cookies: [Cookie] = []
    private let fileURL: URL

    static let maxHosts = 200
    static let maxCookiesPerHost = 100

    public init(fileURL: URL = CookieJar.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    public static var defaultFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Siphon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cookies.json")
    }

    public var hostCount: Int {
        lock.lock(); defer { lock.unlock() }
        return Set(cookies.map(\.host)).count
    }

    public var cookieCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cookies.count
    }

    /// Parse a `Cookie` request header (`a=1; b=2`) and merge it into the jar for
    /// `host`. Empty/invalid pairs are ignored; values are sanitised so the jar can
    /// never hand a CRLF-injected header to an engine.
    public func ingest(cookieHeader: String, forHost host: String) {
        let key = Self.hostKey(host)
        guard !key.isEmpty else { return }
        let pairs = CookieJar.parsePairs(cookieHeader)
        guard !pairs.isEmpty else { return }

        lock.lock()
        let now = Date()
        for (name, value) in pairs {
            if let i = cookies.firstIndex(where: {
                $0.host == key && $0.name == name && $0.path == "/"
            }) {
                cookies[i].value = value
                cookies[i].lastAccess = now
                cookies[i].expiresAt = nil
            } else {
                cookies.append(Cookie(name: name, value: value, host: key,
                                      lastAccess: now))
            }
        }
        enforceLimits(forHost: key)
        lock.unlock()
        save()
    }

    /// Assemble the `Cookie` header for a request URL, honouring path, secure
    /// transport and expiry. Returns nil when nothing applies.
    public func cookieHeader(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        let key = Self.hostKey(host)
        let secureTransport = scheme == "https"
        let path = url.path.isEmpty ? "/" : url.path

        lock.lock()
        let now = Date()
        // Drop expired cookies while we are here (cheap, bounded by cookieCount).
        cookies.removeAll { cookie in
            guard let expiry = cookie.expiresAt else { return false }
            return expiry <= now
        }
        var matched: [Cookie] = []
        for i in cookies.indices where cookies[i].host == key
            && cookies[i].pathMatches(path)
            && (secureTransport || !cookies[i].secure) {
            matched.append(cookies[i])
            cookies[i].lastAccess = now
        }
        lock.unlock()

        guard !matched.isEmpty else { return nil }
        // Browsers send more specific paths first.
        matched.sort { $0.path.count > $1.path.count }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public func clear() {
        lock.lock(); cookies.removeAll(); lock.unlock()
        save()
    }

    // MARK: - limits

    private func enforceLimits(forHost host: String) {
        // Per-host cap: evict the least recently used cookies of that host.
        let hostCookies = cookies.filter { $0.host == host }
        if hostCookies.count > Self.maxCookiesPerHost {
            let excess = hostCookies.count - Self.maxCookiesPerHost
            let victims = hostCookies.sorted { $0.lastAccess < $1.lastAccess }.prefix(excess)
            let ids = Set(victims.map { "\($0.host)|\($0.path)|\($0.name)" })
            cookies.removeAll { ids.contains("\($0.host)|\($0.path)|\($0.name)") }
        }
        // Global host cap: evict the least recently used host wholesale.
        let hosts = Set(cookies.map(\.host))
        if hosts.count > Self.maxHosts {
            let ranked = hosts.map { h in
                (h, cookies.filter { $0.host == h }.map(\.lastAccess).max() ?? .distantPast)
            }.sorted { $0.1 < $1.1 }
            let victims = Set(ranked.prefix(hosts.count - Self.maxHosts).map(\.0))
            cookies.removeAll { victims.contains($0.host) }
        }
    }

    // MARK: - parsing

    static func hostKey(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let colon = h.lastIndex(of: ":"), h.contains("]") == false,
           !h.hasPrefix("[") {
            h = String(h[..<colon])
        }
        return h
    }

    static func parsePairs(_ header: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let name = String(piece[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(piece[piece.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else { continue }
            out.append((name, value))
        }
        return out
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Cookie].self, from: data) else { return }
        cookies = decoded
    }

    private func save() {
        lock.lock()
        let snapshot = cookies
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension CookieJar.Cookie {
    /// RFC 6265 path matching (`/` matches everything; otherwise prefix on a
    /// path boundary, so `/api` does not match `/apix`).
    func pathMatches(_ requestPath: String) -> Bool {
        let cookiePath = path.isEmpty ? "/" : path
        if cookiePath == "/" { return true }
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/")
            || requestPath.dropFirst(cookiePath.count).first == "/"
    }
}
