import Foundation

/// Installs the Siphon Native Messaging host manifest for the browsers that
/// support it.
///
/// Chrome reads `~/Library/Application Support/<Vendor>/NativeMessagingHosts/
/// <name>.json` when an extension calls `chrome.runtime.connectNative(name)`.
/// The manifest points at an absolute binary path and whitelists exactly the
/// user's extension ID, so no other extension can talk to Siphon.
///
/// MDM registers the helper at every app start for the browsers installed at
/// that moment; a manifest that leads nowhere (moved gateway, stale copy) is
/// repaired, while one that already works is left alone. `repairIfNeeded()`
/// does the same here and is cheap enough to call on launch.
public enum NativeMessagingHostInstaller {
    public static let hostName = "com.xinkeju.siphon"
    public static let extensionIDKey = "Siphon.extensionID"
    public static let firefoxDefaultID = "siphon-connector@inkeju.com"

    public struct InstallError: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    private struct Vendor {
        let name: String
        /// The browser's profile folder; its existence is our installed check.
        let profile: String
        let hostFolder: String
        let family: Family
    }

    private enum Family { case chromium, firefox }

    public static var extensionID: String {
        UserDefaults.standard.string(forKey: extensionIDKey) ?? ""
    }

    /// Write the manifest into every supported vendor directory. Returns the
    /// paths written so the Settings UI can show them.
    ///
    /// - Parameter onlyInstalled: skip browsers whose profile folder is absent.
    ///   `true` is what launch-time repair uses, matching MDM's behaviour.
    @discardableResult
    public static func install(extensionID rawID: String,
                               onlyInstalled: Bool = false) throws -> [URL] {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isChromeID = isValidExtensionID(id)
        let isFirefoxID = id.contains("@") || id.contains("-")
        guard isChromeID || isFirefoxID else {
            throw InstallError(message: "扩展 ID 格式无效：Chrome 应为 32 位 a-p 字母，Firefox 应为 ID 或邮箱格式")
        }
        guard let gateway = gatewayPath() else {
            throw InstallError(message: "未找到 SiphonNM 网关（请先执行 swift build，或使用打包版 Siphon.app）")
        }
        var written: [URL] = []

        // Chromium-based browsers: chrome-extension://<id>/
        if isChromeID {
            let origin = "chrome-extension://\(id)/"
            let manifest: [String: Any] = [
                "name": hostName,
                "description": "Siphon native messaging gateway",
                "path": gateway.path,
                "type": "stdio",
                "allowed_origins": [origin],
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys])
            for vendor in vendors(onlyInstalled: onlyInstalled) where vendor.family == .chromium {
                let dir = hostDirectory(for: vendor)
                let file = dir.appendingPathComponent(hostName + ".json")
                if manifestIsCurrent(file, gateway: gateway, origin: origin) { continue }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                written.append(file)
            }
        }

        // Firefox and its forks: moz-extension://<id>/
        let firefoxID = isFirefoxID ? id : firefoxDefaultID
        let ffOrigin = "moz-extension://\(firefoxID)/"
        let ffManifest: [String: Any] = [
            "name": hostName,
            "description": "Siphon native messaging gateway",
            "path": gateway.path,
            "type": "stdio",
            "allowed_origins": [ffOrigin],
        ]
        let ffData = try JSONSerialization.data(withJSONObject: ffManifest,
                                                options: [.prettyPrinted, .sortedKeys])
        for vendor in vendors(onlyInstalled: onlyInstalled) where vendor.family == .firefox {
            let dir = hostDirectory(for: vendor)
            let file = dir.appendingPathComponent(hostName + ".json")
            if manifestIsCurrent(file, gateway: gateway, origin: ffOrigin) { continue }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ffData.write(to: file, options: .atomic)
            written.append(file)
        }

        UserDefaults.standard.set(id, forKey: extensionIDKey)
        return written
    }

    /// Launch-time self-heal: re-point manifests at this copy of the gateway for
    /// browsers installed now. Does nothing until the user has told us which
    /// extension ID to whitelist — without it a manifest cannot work at all.
    @discardableResult
    public static func repairIfNeeded() -> [URL] {
        let id = extensionID
        guard !id.isEmpty else { return [] }
        return (try? install(extensionID: id, onlyInstalled: true)) ?? []
    }

    public static func uninstall() {
        for dir in hostDirectories() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(hostName + ".json"))
        }
    }

    public static var isInstalled: Bool {
        !installedManifestURLs().isEmpty
    }

    public static func installedManifestURLs() -> [URL] {
        hostDirectories()
            .map { $0.appendingPathComponent(hostName + ".json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Human-readable view of installed manifests and the origins they whitelist.
    /// A stale Chrome whitelist is the most common reason `connectNative` fails,
    /// so Settings surfaces it instead of leaving users to guess.
    public static func installedManifestSummary() -> String {
        let urls = installedManifestURLs()
        guard !urls.isEmpty else { return "未检测到已安装的原生网关清单" }
        return urls.map { url -> String in
            var origin = "读取失败"
            var path = "读取失败"
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let allowed = json["allowed_origins"] as? [String] {
                    origin = allowed.joined(separator: ", ")
                }
                if let p = json["path"] as? String { path = p }
            }
            let vendor = url.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            return "\(vendor)：\(origin)\n  → \(path)"
        }.joined(separator: "\n")
    }

    /// All vendor directories (Chromium + Firefox + forks).
    public static func hostDirectories() -> [URL] {
        vendors(onlyInstalled: false).map(hostDirectory(for:))
    }

    /// Vendor directories for Chromium-based browsers on macOS.
    public static func chromiumHostDirectories() -> [URL] {
        vendors(onlyInstalled: false).filter { $0.family == .chromium }
            .map(hostDirectory(for:))
    }

    /// Vendor directories for Firefox and its forks on macOS.
    public static func firefoxHostDirectories() -> [URL] {
        vendors(onlyInstalled: false).filter { $0.family == .firefox }
            .map(hostDirectory(for:))
    }

    /// Absolute path of the gateway binary. A shipped app carries it in
    /// `Contents/Resources`; a `swift build` checkout uses `.build/debug`.
    public static func gatewayPath() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "SiphonNM", withExtension: nil) {
            candidates.append(bundled)
        }
        let bundle = Bundle.main.bundleURL
        candidates.append(bundle.appendingPathComponent("Contents/Resources/SiphonNM"))
        candidates.append(bundle.appendingPathComponent("Contents/MacOS/SiphonNM"))
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(dir.appendingPathComponent("SiphonNM"))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(".build/debug/SiphonNM"))
        candidates.append(cwd.appendingPathComponent(".build/release/SiphonNM"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Where the unpacked extension lives (for the "load unpacked" instructions).
    public static func extensionFolderURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) {
            return bundled
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let local = cwd.appendingPathComponent("Resources/BrowserExtension", isDirectory: true)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    public static func isValidExtensionID(_ id: String) -> Bool {
        let allowed = Set("abcdefghijklmnop")
        return id.count == 32 && id.allSatisfy { allowed.contains($0) }
    }

    // MARK: - vendor folders

    private static func vendors(onlyInstalled: Bool) -> [Vendor] {
        let support = "Library/Application Support"
        let list: [Vendor] = [
            Vendor(name: "Google Chrome", profile: "\(support)/Google/Chrome",
                   hostFolder: "\(support)/Google/Chrome/NativeMessagingHosts", family: .chromium),
            Vendor(name: "Google Chrome Beta", profile: "\(support)/Google/Chrome Beta",
                   hostFolder: "\(support)/Google/Chrome Beta/NativeMessagingHosts", family: .chromium),
            Vendor(name: "Google Chrome Canary", profile: "\(support)/Google/Chrome Canary",
                   hostFolder: "\(support)/Google/Chrome Canary/NativeMessagingHosts", family: .chromium),
            Vendor(name: "Chromium", profile: "\(support)/Chromium",
                   hostFolder: "\(support)/Chromium/NativeMessagingHosts", family: .chromium),
            Vendor(name: "Microsoft Edge", profile: "\(support)/Microsoft Edge",
                   hostFolder: "\(support)/Microsoft Edge/NativeMessagingHosts", family: .chromium),
            Vendor(name: "Brave", profile: "\(support)/BraveSoftware/Brave-Browser",
                   hostFolder: "\(support)/BraveSoftware/Brave-Browser/NativeMessagingHosts",
                   family: .chromium),
            Vendor(name: "Opera", profile: "\(support)/com.operasoftware.Opera",
                   hostFolder: "\(support)/com.operasoftware.Opera/NativeMessagingHosts",
                   family: .chromium),
            Vendor(name: "Vivaldi", profile: "\(support)/Vivaldi",
                   hostFolder: "\(support)/Vivaldi/NativeMessagingHosts", family: .chromium),
            Vendor(name: "Firefox", profile: "\(support)/Firefox",
                   hostFolder: "\(support)/Mozilla/NativeMessagingHosts", family: .firefox),
            Vendor(name: "Zen", profile: "\(support)/zen",
                   hostFolder: "\(support)/zen/NativeMessagingHosts", family: .firefox),
            Vendor(name: "LibreWolf", profile: "\(support)/LibreWolf",
                   hostFolder: "\(support)/LibreWolf/NativeMessagingHosts", family: .firefox),
            Vendor(name: "Waterfox", profile: "\(support)/Waterfox",
                   hostFolder: "\(support)/Waterfox/NativeMessagingHosts", family: .firefox),
        ]
        guard onlyInstalled else { return list }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return list.filter {
            FileManager.default.fileExists(atPath: home.appendingPathComponent($0.profile).path)
        }
    }

    private static func hostDirectory(for vendor: Vendor) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(vendor.hostFolder, isDirectory: true)
    }

    /// A manifest left alone in repair mode only when it already names this
    /// gateway and this exact origin — anything else is a stale copy.
    private static func manifestIsCurrent(_ url: URL, gateway: URL, origin: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String,
              let allowed = json["allowed_origins"] as? [String] else { return false }
        return path == gateway.path && allowed == [origin]
    }
}