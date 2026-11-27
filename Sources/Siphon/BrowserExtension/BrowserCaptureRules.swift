import Foundation

/// The capture rules the browser extension asks for with `hello` / `rules`.
///
/// MDM's helper answers `{ok, types, capture, excludedSites, excludedAddresses,
/// opened, minKb, captureOff, torrents, videoLookup}` from the app's Options. The
/// extension keeps that answer and decides locally; the app still re-checks every
/// hand-off. Keeping the list in one place means the Settings UI, the REST answer
/// and the extension can never disagree about defaults.
public enum BrowserCaptureRules {
    static let typesKey = "Siphon.captureTypes"
    static let excludedSitesKey = "Siphon.captureExcludedSites"
    static let excludedAddressesKey = "Siphon.captureExcludedAddresses"
    static let openedKey = "Siphon.captureOpenedFiles"
    static let minKbKey = "Siphon.captureMinKB"
    static let torrentsKey = "Siphon.captureTorrents"
    static let browsersKey = "Siphon.captureBrowsersEnabled"
    static let seenKey = "Siphon.extensionSeen"

    /// The usual types, matching MDM's shipped list. Stored as an uppercase,
    /// space-separated string because that is the wire form the extension parses.
    public static let defaultTypes = """
        ZIP RAR 7Z TAR GZ BZ2 XZ TGZ TBZ2 LZ LZMA PDF DOC DOCX XLS XLSX PPT PPTX \
        ODT ODS ODP RTF EPUB MOBI AZW AZW3 DJVU EXE MSI DMG PKG DEB RPM APK IPA \
        APPIMAGE ISO IMG VMDK VDI VHD MP3 M4A AAC FLAC OGG WAV WMA OPUS AIFF APE \
        MP4 M4V MKV WEBM AVI MOV FLV WMV MPG MPEG 3GP 3G2 TS M2TS VOB OGV TORRENT \
        GGUF SAFETENSORS ONNX GLB STL OBJ FBX
        """

    /// Browser names as the extension reports them (derived from the UA and
    /// `navigator.userAgentData` brands, which is how Brave/Opera name themselves).
    public static let browserNames = [
        "Google Chrome", "Microsoft Edge", "Brave", "Opera", "Vivaldi",
        "Chromium", "Firefox", "Safari",
    ]

    // MARK: - stored settings

    public static var types: String {
        get {
            let raw = UserDefaults.standard.string(forKey: typesKey) ?? ""
            return raw.isEmpty ? defaultTypes : raw
        }
        set { UserDefaults.standard.set(newValue, forKey: typesKey) }
    }

    public static var excludedSites: String {
        get { UserDefaults.standard.string(forKey: excludedSitesKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: excludedSitesKey) }
    }

    public static var excludedAddresses: [String] {
        get { UserDefaults.standard.stringArray(forKey: excludedAddressesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: excludedAddressesKey) }
    }

    /// Takes listed types the browser would open itself (a PDF, an MP3).
    public static var takesOpenedFiles: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: openedKey) == nil ? true : d.bool(forKey: openedKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: openedKey) }
    }

    /// Files smaller than this stay with the browser. 0 takes any size.
    public static var minKb: Int {
        get { UserDefaults.standard.integer(forKey: minKbKey) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: minKbKey) }
    }

    public static var takesTorrents: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: torrentsKey) == nil ? true : d.bool(forKey: torrentsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: torrentsKey) }
    }

    /// Browsers the user lets take over downloads. An absent list means all,
    /// so a freshly installed extension works before the user visits Settings.
    public static var enabledBrowsers: [String] {
        get { UserDefaults.standard.stringArray(forKey: browsersKey) ?? browserNames }
        set { UserDefaults.standard.set(newValue, forKey: browsersKey) }
    }

    public static func browserEnabled(_ name: String) -> Bool {
        guard !name.isEmpty else { return true }
        return enabledBrowsers.contains(name)
    }

    public static func setBrowser(_ name: String, enabled: Bool) {
        guard !name.isEmpty else { return }
        var list = enabledBrowsers
        list.removeAll { $0 == name }
        if enabled { list.append(name) }
        // Keep the canonical order so Settings and the stored list stay stable.
        list = browserNames.filter { list.contains($0) } + list.filter { !browserNames.contains($0) }
        enabledBrowsers = list
    }

    // MARK: - wire answer

    public static func answer(browser: String, appVersion: String,
                              integrationOn: Bool) -> [String: Any] {
        let capture = integrationOn && browserEnabled(browser)
        var reply: [String: Any] = [
            "ok": true,
            "version": appVersion,
            "types": types,
            "capture": capture,
            "excludedSites": excludedSites,
            "excludedAddresses": excludedAddresses,
            "opened": takesOpenedFiles,
            "minKb": minKb,
            "torrents": takesTorrents,
            "videoLookup": false,
        ]
        if !capture {
            reply["captureOff"] = integrationOn ? "browser" : "integration-off"
        }
        return reply
    }

    /// Name the browser the way Options lists it. Brave and Opera put their
    /// names only in `userAgentData.brands`, so the UA alone is not enough.
    public static func browserName(userAgent: String?, brands: [String]) -> String {
        let ua = (userAgent ?? "").lowercased()
        let marks = brands.map { $0.lowercased() }
        if marks.contains(where: { $0.contains("brave") }) || ua.contains("brave") {
            return "Brave"
        }
        if ua.contains("edg/") || ua.contains("edga/") || ua.contains("edgios/") {
            return "Microsoft Edge"
        }
        if ua.contains("opr/") || ua.contains("opera") { return "Opera" }
        if ua.contains("vivaldi") { return "Vivaldi" }
        if ua.contains("firefox/") || ua.contains("zen/") || ua.contains("librewolf/") {
            return "Firefox"
        }
        if ua.contains("safari/") && !ua.contains("chrome/") { return "Safari" }
        if ua.contains("chrome/") { return "Google Chrome" }
        if ua.contains("chromium/") { return "Chromium" }
        return ""
    }

    // MARK: - extension seen

    /// `browser -> [version, at]`. Written whenever the extension says `hello`
    /// or asks for `rules`, so Settings can show which browsers really reach us.
    public static func noteSeen(browser: String, version: String) {
        guard !browser.isEmpty else { return }
        var all = seen()
        all[browser] = [
            "version": version.isEmpty ? "?" : version,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: seenKey)
        }
    }

    public static func seen() -> [String: [String: String]] {
        guard let data = UserDefaults.standard.data(forKey: seenKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    public static func seenSummary() -> String {
        let all = seen()
        guard !all.isEmpty else { return "还没有扩展连接过（安装扩展后重新打开浏览器）" }
        return all.sorted { $0.key < $1.key }.map { name, info in
            let version = info["version"] ?? "?"
            let at = info["at"] ?? ""
            return "\(name)：扩展 v\(version)\(at.isEmpty ? "" : "，最近 \(at)")"
        }.joined(separator: "\n")
    }

    public static func resetSeen() {
        UserDefaults.standard.removeObject(forKey: seenKey)
    }
}