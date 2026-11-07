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
        guard isValidExtensionID(id) else {
            throw InstallError(message: "扩展 ID 格式无效：应为 32 位、仅含 a–p 的字母")
        }
        guard let gateway = gatewayPath() else {
            throw InstallError(message: "未找到 SiphonNM 网关（请先执行 swift build，或使用打包版 Siphon.app）")
        }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Siphon native messaging gateway",
            "path": gateway.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(id)/"]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        var written: [URL] = []
        for dir in hostDirectories() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(hostName + ".json")
            try data.write(to: file, options: .atomic)
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

    /// Vendor directories Chromium-based browsers read on macOS.
    public static func hostDirectories() -> [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Chromium/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts", isDirectory: true),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts",
                                           isDirectory: true)
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

    static func isValidExtensionID(_ id: String) -> Bool {
        let allowed = Set("abcdefghijklmnop")
        return id.count == 32 && id.allSatisfy { allowed.contains($0) }
    }
}
