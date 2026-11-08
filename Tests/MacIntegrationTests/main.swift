import Foundation

// Regression coverage for the macOS integration layer. Everything here is pure
// logic: the Dock tile, menu-bar title, network pause policy, Services link
// extraction and the Finder "Where from" metadata. The AppKit shells around
// them are exercised by `swift build` + the packaged app smoke test.

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(label)")
    if !ok { failures += 1 }
}

func item(_ active: Bool, _ paused: Bool, _ total: Int64, _ done: Int64) -> DockProgressItem {
    DockProgressItem(isActive: active, isPaused: paused, totalBytes: total, downloadedBytes: done)
}

// MARK: - Dock progress

check("empty list → no Dock progress", DockProgressModel.summarize([]) == nil)

let half = DockProgressModel.summarize([item(true, false, 1000, 200),
                                        item(true, false, 1000, 800)])!
check("byte-weighted fraction across two tasks", abs(half.fraction - 0.5) < 0.0001)
check("percent label rounds", half.percentLabel == "50%")
check("active tasks make it determinate", !half.isIndeterminate)
check("active tasks are not paused-only", !half.isPausedOnly)

let unknown = DockProgressModel.summarize([item(true, false, 0, 1234)])!
check("unknown total → indeterminate", unknown.isIndeterminate)
check("unknown total → zero fraction", unknown.fraction == 0)

let clamp = DockProgressModel.summarize([item(true, false, 100, 300)])!
check("downloaded > total is clamped to 1.0", clamp.fraction == 1.0)

let pausedOnly = DockProgressModel.summarize([item(false, true, 1000, 250)])!
check("paused-only shows the paused fraction", abs(pausedOnly.fraction - 0.25) < 0.0001)
check("paused-only has no percent label", pausedOnly.percentLabel == nil)
check("paused-only is flagged", pausedOnly.isPausedOnly)

let mixed = DockProgressModel.summarize([item(true, false, 1000, 100),
                                         item(false, true, 1000, 900)])!
check("paused tasks stay out of the active denominator", abs(mixed.fraction - 0.1) < 0.0001)
check("mixed summary counts active", mixed.activeCount == 1)

let idlePaused = DockProgressModel.summarize([item(false, true, 1000, 0)])
check("paused at 0 bytes → nothing to draw", idlePaused == nil)

// MARK: - Menu bar

check("compact speed: 0", MenuBarTitle.compactSpeed(0) == "0 KB/s")
check("compact speed: 1536 → KB", MenuBarTitle.compactSpeed(1536) == "1.5 KB/s")
check("compact speed: 1 MiB → MB", MenuBarTitle.compactSpeed(1_048_576) == "1.0 MB/s")
check("compact speed: ≥10 drops the decimal",
      MenuBarTitle.compactSpeed(10 * 1_048_576) == "10 MB/s")
check("compact speed: GiB", MenuBarTitle.compactSpeed(1_073_741_824) == "1.0 GB/s")

check("speed style shows throughput",
      MenuBarTitle.text(style: .speed, summary: half, speedBytesPerSec: 1_500_000) == "1.4 MB/s")
check("percent style shows fraction",
      MenuBarTitle.text(style: .percent, summary: half, speedBytesPerSec: 1) == "50%")
check("icon style is empty",
      MenuBarTitle.text(style: .icon, summary: half, speedBytesPerSec: 1).isEmpty)
check("paused-only says so in the menu bar",
      MenuBarTitle.text(style: .speed, summary: pausedOnly, speedBytesPerSec: 0) == "已暂停")
check("no tasks → empty menu bar title",
      MenuBarTitle.text(style: .speed, summary: nil, speedBytesPerSec: 0).isEmpty)

// MARK: - Network policy

let online = NetworkStatus(isOnline: true, isExpensive: false, isConstrained: false,
                           interfaceName: "Wi‑Fi")
let offline = NetworkStatus(isOnline: false, isExpensive: false, isConstrained: false,
                            interfaceName: "")
let metered = NetworkStatus(isOnline: true, isExpensive: true, isConstrained: false,
                            interfaceName: "蜂窝")
let on = NetworkPolicy.Settings(pauseWhenOffline: true, pauseWhenMetered: true)
let off = NetworkPolicy.Settings(pauseWhenOffline: false, pauseWhenMetered: false)

check("offline + pref → pause",
      NetworkPolicy.pauseReason(for: offline, settings: on) == .offline)
check("offline + pref off → keep going",
      NetworkPolicy.pauseReason(for: offline, settings: off) == nil)
check("metered + pref → pause",
      NetworkPolicy.pauseReason(for: metered, settings: on) == .metered)
check("metered + pref off → keep going",
      NetworkPolicy.pauseReason(for: metered, settings: off) == nil)
check("healthy network never pauses",
      NetworkPolicy.pauseReason(for: online, settings: on) == nil)
check("offline wins over metered",
      NetworkPolicy.pauseReason(
        for: NetworkStatus(isOnline: false, isExpensive: true, isConstrained: false,
                           interfaceName: ""), settings: on) == .offline)
check("offline copy", NetworkPauseReason.offline.displayText.contains("网络断开"))
check("metered copy", NetworkPauseReason.metered.displayText.contains("计费"))
check("normal status is silent", online.displayText == nil)
check("offline symbol", offline.symbolName == "wifi.slash")

// MARK: - Services link extraction

let prose = """
看这个：https://example.com/file.zip。
或者 (https://example.org/a.bin)，还有 <ftp://ftp.example.net/pub/x.iso>
magnet:?xt=urn:btih:ABCDEF&dn=hello
重复一次 https://example.com/file.zip
"""
let links = ServiceLinkExtractor.links(in: prose)
check("finds four unique links", links.count == 4)
check("strips trailing full stop", links.first == "https://example.com/file.zip")
check("strips wrapping parentheses", links.contains("https://example.org/a.bin"))
check("strips angle brackets", links.contains("ftp://ftp.example.net/pub/x.iso"))
check("keeps magnet query intact",
      links.contains("magnet:?xt=urn:btih:ABCDEF&dn=hello"))
check("deduplicates", links.filter { $0 == "https://example.com/file.zip" }.count == 1)
check("ignores bare hostnames",
      ServiceLinkExtractor.links(in: "www.example.com 和 example.org").isEmpty)
check("limit is honoured",
      ServiceLinkExtractor.links(in: (0..<5).map { "https://a.test/\($0)" }
        .joined(separator: " "), limit: 2).count == 2)
check("normalizedText joins links",
      ServiceLinkExtractor.normalizedText(in: "https://a.test/1\nhttps://b.test/2")
        == "https://a.test/1\nhttps://b.test/2")
check("normalizedText rejects plain prose",
      ServiceLinkExtractor.normalizedText(in: "没有链接") == nil)

// MARK: - Finder "Where from" metadata

let plist = DownloadOriginMetadata.plist(for: ["https://example.com/f.zip",
                                               "https://example.com/page"])
check("origin plist is binary", plist?.first == 0x62) // "bplist00"
let decoded = plist.flatMap {
    try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
} as? [String]
check("origin plist round-trips", decoded == ["https://example.com/f.zip",
                                              "https://example.com/page"])
check("empty origin list is rejected", DownloadOriginMetadata.plist(for: []) == nil)

// Real xattr write/read on a temp file: the attribute name is what Finder reads.
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("siphon-origin-test-\(UUID().uuidString).bin")
FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8))
check("writes where-from to an existing file",
      DownloadOriginMetadata.write(source: "https://example.com/f.zip",
                                   referrer: "https://example.com/page", to: tmp))
var size = getxattr(tmp.path, DownloadOriginMetadata.attribute, nil, 0, 0, 0)
check("xattr exists after write", size > 0)
var buffer = [UInt8](repeating: 0, count: max(0, size))
size = getxattr(tmp.path, DownloadOriginMetadata.attribute, &buffer, buffer.count, 0, 0)
let readBack = size > 0 ? Data(buffer.prefix(size)) : Data()
let readList = (try? PropertyListSerialization.propertyList(
    from: readBack, options: [], format: nil)) as? [String]
check("xattr holds source + referrer", readList == ["https://example.com/f.zip",
                                                    "https://example.com/page"])

// A non-URL `origin` tag ("rss:标题") is not a referrer and must not be recorded.
check("second write with non-http referrer succeeds",
      DownloadOriginMetadata.write(source: "https://a.test/f", referrer: "rss:标题", to: tmp))
var size2 = getxattr(tmp.path, DownloadOriginMetadata.attribute, nil, 0, 0, 0)
var buffer2 = [UInt8](repeating: 0, count: max(0, size2))
size2 = getxattr(tmp.path, DownloadOriginMetadata.attribute, &buffer2, buffer2.count, 0, 0)
let readList2 = size2 > 0
    ? (try? PropertyListSerialization.propertyList(
        from: Data(buffer2.prefix(size2)), options: [], format: nil)) as? [String]
    : nil
check("non-http referrer is not recorded", readList2 == ["https://a.test/f"])

try? FileManager.default.removeItem(at: tmp)

if failures > 0 {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
print("\nAll macOS integration checks passed.")
