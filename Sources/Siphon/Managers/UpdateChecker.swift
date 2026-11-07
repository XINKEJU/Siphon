import Foundation
import AppKit

/// Self-update framework (ab-download-manager shared/updater model), adapted to
/// Siphon's zero-dependency + unsigned-adoption reality:
///  1. `check()` fetches a user-configured JSON feed and compares versions.
///  2. `downloadAndInstall()` fetches the .app zip, verifies SHA-256, unzips
///     via `/usr/bin/ditto`, atomically swaps the bundle and relaunches.
///
/// The feed is empty by default — the updater stays inert until the user (or a
/// distribution channel) points it at e.g. a GitHub Releases `latest.json`.
@MainActor
public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker()
    static let feedKey = "Siphon.updateFeed"

    public struct UpdateInfo: Codable, Equatable {
        public var version: String
        public var url: String
        public var sha256: String?
        public var notes: String?
    }

    @Published public var status: String = ""
    @Published public var available: UpdateInfo?
    @Published public var checking = false
    @Published public var installing = false

    public var feedURL: String {
        get { UserDefaults.standard.string(forKey: Self.feedKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.feedKey) }
    }

    public init() {}

    /// Current marketing version from the bundle ("1.2.3"); "0" when unbundled.
    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - pure version logic (unit-tested offline)

    /// Compare dotted numeric versions; non-numeric segments compare as strings.
    /// Returns true when `candidate` is strictly newer than `current`.
    nonisolated public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let c = candidate.split(separator: ".").map(String.init)
        let k = current.split(separator: ".").map(String.init)
        for i in 0..<max(c.count, k.count) {
            let a = i < c.count ? c[i] : "0"
            let b = i < k.count ? k[i] : "0"
            if let na = Int(a), let nb = Int(b) {
                if na != nb { return na > nb }
            } else if a != b {
                return a > b
            }
        }
        return false
    }

    /// Parse a feed body: either the update object directly or wrapped as
    /// `{"update": {...}}`. Returns nil when unusable.
    nonisolated public static func parseFeed(_ data: Data) -> UpdateInfo? {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let payload = (obj["update"] as? [String: Any]) ?? obj
        guard let version = payload["version"] as? String, !version.isEmpty,
              let url = payload["url"] as? String, !url.isEmpty else { return nil }
        return UpdateInfo(version: version, url: url,
                          sha256: payload["sha256"] as? String,
                          notes: payload["notes"] as? String)
    }

    // MARK: - check

    public func check() async {
        checking = true
        available = nil
        defer { checking = false }
        let feed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: feed), url.scheme != nil else {
            status = "未配置更新源"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let info = Self.parseFeed(data) else {
                status = "更新源返回了无法识别的内容"
                return
            }
            if Self.isNewer(info.version, than: Self.currentVersion) {
                available = info
                status = "发现新版本 \(info.version)"
            } else {
                status = "已是最新版本（\(Self.currentVersion)）"
            }
        } catch {
            status = "检查更新失败：\(error.localizedDescription)"
        }
    }

    // MARK: - download + install

    /// Download the update, verify it, swap the bundle and relaunch. Only the
    /// last step is destructive and only after every earlier one succeeded.
    public func downloadAndInstall() async {
        guard let info = available else { return }
        installing = true
        defer { installing = false }
        status = "正在下载更新…"
        guard let url = URL(string: info.url) else { status = "更新地址无效"; return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiphonUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zip = tmp.appendingPathComponent("update.zip")
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                status = "下载更新失败：HTTP \(http.statusCode)"
                return
            }
            try data.write(to: zip)
        } catch {
            status = "下载更新失败：\(error.localizedDescription)"
            return
        }
        if let sha = info.sha256?.trimmingCharacters(in: .whitespaces), !sha.isEmpty {
            guard Self.sha256Hex(of: zip) == sha.lowercased() else {
                status = "更新包校验失败（SHA-256 不匹配），已取消"
                return
            }
        }
        status = "正在解压更新…"
        let staging = tmp.appendingPathComponent("staged")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        do { try ditto.run(); ditto.waitUntilExit() } catch {
            status = "解压更新失败：\(error.localizedDescription)"
            return
        }
        guard ditto.terminationStatus == 0 else { status = "解压更新失败（ditto exit=\(ditto.terminationStatus)）"; return }
        // The zip may contain the .app at its root or nested one level down.
        let stagedApp: URL
        if (try? FileManager.default.contentsOfDirectory(at: staging,
                includingPropertiesForKeys: nil))?.first(where: {
                    $0.pathExtension == "app" }) ?? nil != nil {
            stagedApp = (try! FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil))
                .first { $0.pathExtension == "app" }!
        } else {
            status = "更新包内未找到 .app"
            return
        }
        status = "正在替换应用…"
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        let backup = current.appendingPathExtension("old")
        do {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: current, to: backup)
            try FileManager.default.moveItem(at: stagedApp, to: current)
        } catch {
            // Restore the running bundle before giving up.
            try? FileManager.default.moveItem(at: backup, to: current)
            status = "替换应用失败：\(error.localizedDescription)"
            return
        }
        status = "正在重启…"
        Process.runOpenAndTerminate(current)
    }

    nonisolated static func sha256Hex(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit

extension Process {
    /// `open` the (replaced) app bundle, then terminate the current process.
    static func runOpenAndTerminate(_ appURL: URL) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [appURL.path]
        try? open.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}

/// Leftovers from a previous self-update: remove `<App>.old` bundles on launch.
public func cleanupUpdateBackups() {
    let current = URL(fileURLWithPath: Bundle.main.bundlePath)
    let backup = current.appendingPathExtension("old")
    try? FileManager.default.removeItem(at: backup)
}
