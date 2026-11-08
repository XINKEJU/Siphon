import Foundation
import AppKit
import Observation
import OSLog

private let updaterLog = Logger(subsystem: "com.xinkeju.siphon.macos", category: "updater")

/// Self-update framework (ab-download-manager shared/updater model), adapted to
/// Siphon's zero-dependency + unsigned-adoption reality:
///  1. `check()` fetches a user-configured **HTTPS** JSON feed and compares versions.
///  2. `downloadAndInstall()` fetches the .app zip over **HTTPS**, requires a
///     valid SHA-256 from the feed, verifies the staged bundle's identity and
///     code signature, asks the user to confirm, then swaps and relaunches.
///
/// Threat model: the feed URL lives in UserDefaults (any local process can
/// rewrite it) and the feed used to allow `http://` / `file://` URLs with an
/// optional hash from that same feed. That was a full supply-chain RCE: a MITM
/// or a local process could point the updater at any `.app` and have it run.
/// Now the transport is TLS, the hash is mandatory, and the replacement bundle
/// must have the same bundle ID and the same signing identity as the running
/// app before anything is moved. For an adhoc-signed build the HTTPS feed hash
/// remains the only trust root; a distributed build must use a Developer ID
/// signature + notarization (see `scripts/build-app.sh`).
///
/// The feed is empty by default — the updater stays inert until the user points
/// it at e.g. a GitHub Releases `latest.json`.
@MainActor
@Observable
public final class UpdateChecker {
    public static let shared = UpdateChecker()
    static let feedKey = "Siphon.updateFeed"

    public struct UpdateInfo: Codable, Equatable {
        public var version: String
        public var url: String
        public var sha256: String?
        public var notes: String?
    }

    public var status: String = ""
    public var available: UpdateInfo?
    public var checking = false
    public var installing = false

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

    /// A digest is only usable if it is exactly 64 hex characters. Feeds that
    /// omit it (or ship a placeholder) must never reach the install path.
    nonisolated public static func isValidSHA256(_ value: String?) -> Bool {
        guard let value else { return false }
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = Set("0123456789abcdef")
        return s.count == 64 && s.allSatisfy { hex.contains($0) }
    }

    /// Update source policy: HTTPS only, no embedded credentials, no loopback
    /// or private/link-literal hosts. `http://` + `file://` were accepted before,
    /// which let a local process or a network MITM choose the executable.
    nonisolated public static func trustedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.port == nil || url.port == 443 else { return nil }
        if host == "localhost" || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host == "::1"
            || host.hasPrefix("fd") || host.hasPrefix("fe80") { return nil }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            if [0, 10, 127].contains(octets[0]) { return nil }
            if octets[0] == 169 && octets[1] == 254 { return nil }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return nil }
            if octets[0] == 192 && octets[1] == 168 { return nil }
            if octets[0] == 100 && (64...127).contains(octets[1]) { return nil }
        }
        return url
    }

    // MARK: - check

    public func check() async {
        checking = true
        available = nil
        defer { checking = false }
        let feed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feed.isEmpty, let url = Self.trustedURL(feed) else {
            status = feed.isEmpty ? "未配置更新源" : "更新源必须是 HTTPS 地址（不接受本地/内网地址）"
            available = nil
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let info = Self.parseFeed(data) else {
                status = "更新源返回了无法识别的内容"
                return
            }
            guard Self.isValidSHA256(info.sha256) else {
                status = "更新源缺少有效的 SHA-256 校验值，已拒绝更新"
                return
            }
            guard Self.trustedURL(info.url) != nil else {
                status = "更新包地址必须是 HTTPS 地址（不接受本地/内网地址）"
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
        guard let url = Self.trustedURL(info.url) else {
            status = "更新包地址无效（要求 HTTPS）"
            return
        }
        guard let expectedSHA = info.sha256?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(), Self.isValidSHA256(expectedSHA) else {
            status = "更新源缺少有效的 SHA-256 校验值，已取消"
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiphonUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zip = tmp.appendingPathComponent("update.zip")
        do {
            // URLSession.download streams to a temp file on disk — update
            // packages are tens of MB and must not be buffered in memory.
            let (tmpFile, resp) = try await URLSession.shared.download(from: url)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                status = "下载更新失败：HTTP \(http.statusCode)"
                return
            }
            try FileManager.default.moveItem(at: tmpFile, to: zip)
        } catch {
            status = "下载更新失败：\(error.localizedDescription)"
            return
        }
        guard Self.sha256Hex(of: zip) == expectedSHA else {
            status = "更新包校验失败（SHA-256 不匹配），已取消"
            return
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
        let stagedContents = (try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil)) ?? []
        if let app = stagedContents.first(where: { $0.pathExtension == "app" }) {
            stagedApp = app
        } else {
            status = "更新包内未找到 .app"
            return
        }
        // Never swap in an arbitrary bundle: it must still be Siphon, signed by
        // the same identity, and pass `codesign --verify`. Without this the
        // feed's hash is the only gate and a rewritten feed installs any app.
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        let verdict = Self.verifyStagedBundle(stagedApp, against: current)
        guard verdict.ok else {
            status = "更新包校验失败：\(verdict.reason)，已取消"
            return
        }
        guard await confirmInstall(version: info.version,
                                   host: url.host ?? "未知来源",
                                   digest: expectedSHA) else {
            status = "已取消更新"
            return
        }
        status = "正在替换应用…"
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

    // MARK: - staged bundle verification

    /// Developer ID team when present, otherwise the literal `adhoc`.
    /// `nil` means unsigned, unreadable, or `codesign` could not run.
    nonisolated static func signingIdentity(of app: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", "--verbose=4", app.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            updaterLog.error("codesign -dv failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        for line in output.split(separator: "\n") {
            guard let r = line.range(of: "TeamIdentifier=") else { continue }
            let team = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !team.isEmpty, team != "not set" { return "team:" + team }
        }
        return output.contains("Signature=adhoc") ? "adhoc" : nil
    }

    /// A feed-controlled zip must not be able to substitute a different app.
    nonisolated static func verifyStagedBundle(_ app: URL, against current: URL)
        -> (ok: Bool, reason: String) {
        let fm = FileManager.default
        // `attributesOfItem` describes the link itself, so a symlink planted in
        // the archive cannot point the swap outside the staging directory.
        guard let attrs = try? fm.attributesOfItem(atPath: app.standardizedFileURL.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeDirectory else {
            return (false, "更新包内的 .app 不是普通目录")
        }
        guard let plist = NSDictionary(contentsOf:
                app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let incomingID = plist["CFBundleIdentifier"] as? String,
              let installedID = Bundle.main.bundleIdentifier,
              incomingID == installedID else {
            return (false, "应用标识与当前应用不一致")
        }
        guard let incomingExe = plist["CFBundleExecutable"] as? String,
              let installedExe = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String,
              incomingExe == installedExe,
              fm.isExecutableFile(atPath:
                app.appendingPathComponent("Contents/MacOS/\(incomingExe)").path) else {
            return (false, "可执行文件缺失或与当前应用不一致")
        }
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", "--verbose=1", app.path]
        let err = Pipe()
        verify.standardError = err
        verify.standardOutput = err
        do { try verify.run() } catch {
            updaterLog.error("staged bundle codesign verification failed to launch: \(error.localizedDescription, privacy: .public)")
            return (false, "无法执行签名校验")
        }
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            return (false, "代码签名无效（\(log.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))）")
        }
        guard let incoming = signingIdentity(of: app),
              let installed = signingIdentity(of: current),
              incoming == installed else {
            return (false, "签名身份与当前应用不一致")
        }
        return (true, "")
    }

    /// Explicit consent before the one destructive step.
    @MainActor
    private func confirmInstall(version: String, host: String, digest: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "安装 Siphon \(version)？"
            alert.informativeText = "来源：\(host)\nSHA-256：\(digest.prefix(16))…\n\n"
                + "更新包已通过哈希与代码签名校验。替换当前应用后将自动重启。"
            alert.addButton(withTitle: "安装并重启")
            alert.addButton(withTitle: "取消")
            continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
        }
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
