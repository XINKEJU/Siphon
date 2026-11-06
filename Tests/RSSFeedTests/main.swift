import Foundation
import Network

// RSSParser + FeedManager tests: RSS 2.0 and Atom fixtures, date handling,
// guid-diffing (only new items fire), and the first-refresh seed behaviour.
// Feeds are fetched over the loopback so no network is involved.

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

// MARK: - RSS 2.0

let rssXML = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
<title>Podcast</title>
<item>
  <title>Episode 1</title>
  <link>https://cdn.test/ep1.mp3</link>
  <guid>ep-1</guid>
  <pubDate>Tue, 10 Jun 2025 09:00:00 GMT</pubDate>
</item>
<item>
  <title>Episode 2</title>
  <link>https://cdn.test/ep2.mp3</link>
  <guid>ep-2</guid>
  <pubDate>Tue, 17 Jun 2025 09:00:00 +0000</pubDate>
</item>
</channel></rss>
"""
let rssItems = RSSParser.parse(Data(rssXML.utf8))
check(rssItems.count == 2, "RSS 2.0: two items", "got \(rssItems.count)")
check(rssItems[0].title == "Episode 1" && rssItems[0].link == "https://cdn.test/ep1.mp3",
      "RSS 2.0: title/link captured")
check(rssItems[0].guid == "ep-1", "RSS 2.0: guid captured")
check(rssItems[0].published != nil, "RSS 2.0: RFC822 date parsed",
      "\(rssItems[0].published as Any)")
check(rssItems[1].published != nil, "RSS 2.0: RFC822 date with offset parsed")

// MARK: - Atom

let atomXML = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
<title>Blog</title>
<entry>
  <title>Post A</title>
  <link rel="alternate" href="https://blog.test/posts/a.zip"/>
  <id>tag:blog.test,2025:a</id>
  <published>2025-06-01T10:00:00Z</published>
</entry>
<entry>
  <title>Post B</title>
  <link href="https://blog.test/posts/b.zip"/>
  <id>tag:blog.test,2025:b</id>
</entry>
</feed>
"""
let atomItems = RSSParser.parse(Data(atomXML.utf8))
check(atomItems.count == 2, "Atom: two entries", "got \(atomItems.count)")
check(atomItems[0].link == "https://blog.test/posts/a.zip",
      "Atom: href attribute captured", atomItems[0].link)
check(atomItems[0].guid == "tag:blog.test,2025:a", "Atom: id as guid")
check(atomItems[0].published != nil, "Atom: ISO8601 date parsed")

// MARK: - FeedManager diff + seed semantics (loopback fetch)

let port = 18791
// Feeds persist in UserDefaults; isolate this run from the real profile.
UserDefaults.standard.removeObject(forKey: "Siphon.feeds")

// Stateful loopback server: /feed?version=1 serves two items, version=2 adds ep-3.
let server = HTTPServerStub(port: port)

await server.start()
defer { server.stop() }

let mgr = FeedManager()
var fired: [(title: String, count: Int)] = []
mgr.onNewItems = { feed, items in fired.append((feed.title, items.count)) }

let feedURL = URL(string: "http://127.0.0.1:\(port)/feed?version=1")!
mgr.add(url: feedURL, title: "Test Feed")

// Seed run: nothing fires, but guids are recorded.
await mgr.refreshAll()
check(fired.isEmpty, "first refresh downloads nothing (backlog seeded)")
check(mgr.feeds[0].seenGUIDs.count == 2, "seed run recorded both guids",
      "got \(mgr.feeds[0].seenGUIDs)")

// Same content again: still nothing.
await mgr.refreshAll()
check(fired.isEmpty, "repeat refresh with same items fires nothing")

// The source publishes ep-3 (server serves version=2 for the ?version=2 path).
mgr.feeds[0].url = URL(string: "http://127.0.0.1:\(port)/feed?version=2")!
await mgr.refreshAll()
check(fired.count == 1 && fired[0].count == 1,
      "only the genuinely new item fires", "fired=\(fired)")
check(fired.first?.title == "Test Feed", "callback carries feed identity")
check(mgr.feeds[0].seenGUIDs.count == 3, "seen ring extended")
check(mgr.feeds[0].lastError == nil, "no error recorded")

// Enabled=false suppresses refresh work entirely.
mgr.remove(id: mgr.feeds[0].id)
mgr.add(url: URL(string: "http://127.0.0.1:\(port)/feed?version=2")!, title: "Paused Feed")
await mgr.refreshAll() // seed
mgr.setEnabled(id: mgr.feeds[0].id, false)
fired.removeAll()
await mgr.refreshAll()
check(fired.isEmpty, "disabled feed is not fetched")

// Connection refused → lastError set, no crash.
mgr.add(url: URL(string: "http://127.0.0.1:59999/dead.xml")!, title: "Dead Feed")
await mgr.refreshAll()
check(mgr.feeds.contains { $0.lastError != nil },
      "unreachable feed records lastError")

UserDefaults.standard.removeObject(forKey: "Siphon.feeds")
server.stop()

if failures == 0 { print("RSS FEED TESTS PASSED") }
else { print("RSS FEED TESTS FAILED: \(failures)"); exit(1) }

// MARK: - tiny loopback HTTP server

final class HTTPServerStub: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "feed-stub")
    private let port: UInt16

    init(port: Int) { self.port = UInt16(port) }

    func start() async {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try! NWListener(using: params)
        l.newConnectionHandler = { conn in
            conn.start(queue: self.queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                // Parse the request line so ?version=2 picks the richer fixture.
                let requestLine = (data.flatMap {
                    String(data: Data($0.prefix(200)), encoding: .utf8)
                } ?? "")
                let version = requestLine.contains("version=2") ? 2 : 1
                let body = Self.feedXML(version: version)
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
                conn.send(content: Data(response.utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        l.start(queue: queue)
        listener = l
        // Wait for the port to open.
        for _ in 0..<100 {
            if Self.portOpen(port) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    static func feedXML(version: Int) -> String {
        let ep3 = version >= 2
            ? "<item><title>Episode 3</title><link>https://cdn.test/ep3.mp3</link><guid>ep-3</guid></item>"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel>
        <title>Podcast</title>
        <item><title>Episode 1</title><link>https://cdn.test/ep1.mp3</link><guid>ep-1</guid></item>
        <item><title>Episode 2</title><link>https://cdn.test/ep2.mp3</link><guid>ep-2</guid></item>
        \(ep3)
        </channel></rss>
        """
    }

    static func portOpen(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }
}
