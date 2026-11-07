import Foundation

// MARK: - RSS/Atom parsing (persepolis/Fluxdown's subscription pattern)

/// Minimal RSS 2.0 + Atom feed parser. Enough surface for download
/// subscriptions: per-entry title / link / guid / date. Pure Foundation
/// XMLParser — no third-party dependency.
public struct FeedItem: Codable, Equatable {
    public let guid: String
    public let title: String
    public let link: String
    public let published: Date?
}

public final class RSSParser: NSObject, XMLParserDelegate {

    // RSS 2.0 state
    private var items: [FeedItem] = []
    private var inItem = false
    private var currentTitle = ""
    private var currentLink = ""
    private var currentGuid = ""
    private var currentPubDate: Date?
    private var buf = ""
    private var element = ""
    // Atom links carry the URL in an attribute.
    private var isAtom = false
    private var atomLinkHref = ""

    public static func parse(_ data: Data) -> [FeedItem] {
        let parser = RSSParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items
    }

    public func parser(_ parser: XMLParser, didStartElement name: String,
                       namespaceURI: String?, qualifiedName: String?,
                       attributes: [String: String]) {
        element = name.lowercased()
        buf = ""
        switch element {
        case "item":
            inItem = true; isAtom = false
            currentTitle = ""; currentLink = ""; currentGuid = ""; currentPubDate = nil
        case "entry":
            inItem = true; isAtom = true
            currentTitle = ""; currentLink = ""; currentGuid = ""; currentPubDate = nil
        case "link" where isAtom:
            // <link rel="alternate" href="…"/> — prefer non-alternate-free rels.
            let rel = attributes["rel"] ?? "alternate"
            if let href = attributes["href"], rel == "alternate" || atomLinkHref.isEmpty {
                atomLinkHref = href
            }
        default: break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        buf += string
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { buf += s }
    }

    public func parser(_ parser: XMLParser, didEndElement name: String,
                       namespaceURI: String?, qualifiedName: String?) {
        let tag = name.lowercased()
        switch tag {
        case "title" where inItem:
            currentTitle = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        case "link" where inItem && isAtom:
            currentLink = atomLinkHref
        case "link" where inItem:
            currentLink = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        case "guid" where inItem, "id" where inItem:
            currentGuid = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        case "pubdate" where inItem, "published" where inItem, "updated" where inItem:
            currentPubDate = Self.parseDate(buf.trimmingCharacters(in: .whitespacesAndNewlines))
        case "item", "entry":
            let link = currentLink.isEmpty ? currentGuid : currentLink
            if !link.isEmpty {
                let guid = currentGuid.isEmpty ? link : currentGuid
                items.append(FeedItem(guid: guid, title: currentTitle,
                                      link: link, published: currentPubDate))
            }
            inItem = false
            atomLinkHref = ""
        default: break
        }
        buf = ""
        element = ""
    }

    /// RFC 822 (RSS) and RFC 3339 (Atom) dates, best-effort. Formatters are
    /// static: creating a DateFormatter per call is notoriously expensive.
    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        if let d = rfc822.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        return iso.date(from: s)
    }
}

// MARK: - feed manager

/// Subscription store: feeds persist in UserDefaults; `refreshAll` fetches and
/// diffs by guid, so only genuinely new episodes/entries trigger downloads.
public final class FeedManager: ObservableObject, @unchecked Sendable {

    public struct Feed: Codable, Identifiable, Equatable {
        public var id: UUID
        public var title: String
        public var url: URL
        public var enabled: Bool
        public var seenGUIDs: [String]   // capped ring of processed ids
        public var lastFetched: Date?
        public var lastError: String?

        init(url: URL, title: String? = nil) {
            self.id = UUID()
            self.title = title ?? url.host ?? url.absoluteString
            self.url = url
            self.enabled = true
            self.seenGUIDs = []
            self.lastFetched = nil
            self.lastError = nil
        }
    }

    public static let maxSeenGUIDs = 200

    /// Settable so integrations (and tests) can update a feed in place; mutators
    /// call save() themselves — a direct external mutation needs a refreshAll()
    /// or explicit save to persist.
    @Published public var feeds: [Feed] = []
    private let defaultsKey = "Siphon.feeds"
    /// Fired for every genuinely-new item discovered during a refresh.
    /// Wired to DownloadStore so new entries become download tasks.
    public var onNewItems: ((Feed, [FeedItem]) -> Void)?

    public init() {
        if let d = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([Feed].self, from: d) {
            feeds = saved
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(feeds) {
            UserDefaults.standard.set(d, forKey: defaultsKey)
        }
    }

    public func add(url: URL, title: String? = nil) {
        guard !feeds.contains(where: { $0.url == url }) else { return }
        feeds.append(Feed(url: url, title: title))
        save()
    }

    public func remove(id: UUID) {
        feeds.removeAll { $0.id == id }
        save()
    }

    public func setEnabled(id: UUID, _ enabled: Bool) {
        if let i = feeds.firstIndex(where: { $0.id == id }) {
            feeds[i].enabled = enabled
            save()
        }
    }

    /// Fetch every enabled feed, diff, and dispatch new items. First refresh of
    /// a feed seeds seen-GUIDs WITHOUT downloading the whole backlog (the user
    /// presumably already has what they want; new episodes arrive afterwards).
    public func refreshAll() async {
        for index in feeds.indices where feeds[index].enabled {
            let feed = feeds[index]
            do {
                let (data, response) = try await URLSession.shared.data(from: feed.url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let items = RSSParser.parse(data)
                let seen = Set(feed.seenGUIDs)
                var updated = feeds[index]
                if updated.lastFetched == nil {
                    // Seed run: mark everything seen, download nothing.
                    updated.seenGUIDs = items.map { $0.guid }
                    updated.lastError = nil
                } else {
                    let fresh = items.filter { !seen.contains($0.guid) }
                    if !fresh.isEmpty {
                        let cap = Self.maxSeenGUIDs
                        updated.seenGUIDs = (updated.seenGUIDs + fresh.map { $0.guid })
                            .suffix(cap).map { $0 }
                        onNewItems?(updated, fresh)
                    }
                    updated.lastError = nil
                }
                updated.lastFetched = Date()
                feeds[index] = updated
            } catch {
                if let i = feeds.firstIndex(where: { $0.id == feed.id }) {
                    feeds[i].lastError = error.localizedDescription
                }
            }
        }
        save()
    }
}
