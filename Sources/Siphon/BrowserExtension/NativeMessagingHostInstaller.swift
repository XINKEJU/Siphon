import Foundation

/// Installs the Siphon Native Messaging host manifest for the Chromium browsers.
///
/// Chrome reads `~/Library/Application Support/<Vendor>/NativeMessagingHosts/
/// <name>.json` when an extension calls `chrome.runtime.connectNative(name)`.
/// The manifest points at an absolute binary path and whitelists exactly the
/// user's extension ID, so no other extension can talk to Siphon.
public enum NativeMessagingHostInstaller {
    public static let hostName = "com.xinkeju.siphon"
    public static let extensionIDKey = "Siphon.extensionID"

    public struct InstallError: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    public static var extensionID: String {
        UserDefaults.standard.string(forKey: extensionIDKey) ?? ""
    }

    /// Write the manifest into every supported vendor directory. Returns the
    /// paths written so the Settings UI can show them.
    @discardableResult
    public static func install(extensionID rawID: String) throws -> [URL] {
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
            let manifest: [String: Any] = [
                "name": hostName,
                "description": "Siphon native messaging gateway",
                "path": gateway.path,
                "type": "stdio",
                "allowed_origins": ["chrome-extension://\(id)/"]
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys])
            for dir in chromiumHostDirectories() {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(hostName + ".json")
                try data.write(to: file, options: .atomic)
                written.append(file)
            }
        }

        // Firefox: moz-extension://<id>/
        let firefoxID = isFirefoxID ? id : "siphon-connector@inkeju.com"
        let ffManifest: [String: Any] = [
            "name": hostName,
            "description": "Siphon native messaging gateway",
            "path": gateway.path,
            "type": "stdio",
            "allowed_origins": ["moz-extension://\(firefoxID)/"]
        ]
        let ffData = try JSONSerialization.data(withJSONObject: ffManifest,
                                                options: [.prettyPrinted, .sortedKeys])
        for dir in firefoxHostDirectories() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(hostName + ".json")
            try ffData.write(to: file, options: .atomic)
            written.append(file)
        }

        UserDefaults.standard.set(id, forKey: extensionIDKey)
        return written
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
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let allowed = json["allowed_origins"] as? [String] {
                origin = allowed.joined(separator: ", ")
            }
            let vendor = url.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            return "\(vendor)：\(origin)"
        }.joined(separator: "\n")
    }

    /// All vendor directories (Chromium + Firefox).
    public static func hostDirectories() -> [URL] {
        chromiumHostDirectories() + firefoxHostDirectories()
    }

    /// Vendor directories for Chromium-based browsers on macOS.
    public static func chromiumHostDirectories() -> [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Chromium/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts",
                                           isDirectory: true),
        ]
    }

    /// Vendor directory for Firefox on macOS.
    public static func firefoxHostDirectories() -> [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            support.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true),
        ]
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
}
