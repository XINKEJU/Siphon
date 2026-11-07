import Foundation

/// Automatic archive extraction + post-processing (HyperDM / FluxDown model).
///
/// When a download completes and the destination looks like a compressed archive,
/// Siphon can unpack it into a sibling folder and optionally run a user-supplied
/// shell command against the result. Extraction uses only Apple system binaries
/// (`tar`, `unzip`, `gunzip`, and `7z`/`7za` when a p7zip build is on PATH) — no
/// third-party Swift packages, matching the project's zero-dependency rule.
public final class ArchiveManager: @unchecked Sendable {
    public static let shared = ArchiveManager()

    public static let autoExtractKey = "Siphon.autoExtract"
    public static let postProcessKey = "Siphon.postProcessEnabled"
    public static let postProcessCommandKey = "Siphon.postProcessCommand"

    private let queue = DispatchQueue(label: "Siphon.ArchiveManager", qos: .utility)

    private init() {}

    /// Compressed container formats Siphon knows how to unpack natively.
    public enum ArchiveKind {
        case zip, tar, gzip, sevenZip, rar, unknown

        /// Whether this format is something we attempt to expand with a system tool.
        var extractable: Bool { self != .unknown && self != .rar }
    }

    public func kind(of url: URL) -> ArchiveKind {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        if lower.hasSuffix(".7z") { return .sevenZip }
        if lower.hasSuffix(".rar") { return .rar }
        if lower.hasSuffix(".tar") || lower.hasSuffix(".tgz")
            || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.bz2")
            || lower.hasSuffix(".tar.xz") || lower.hasSuffix(".tbz2")
            || lower.hasSuffix(".tbz") || lower.hasSuffix(".txz") { return .tar }
        if lower.hasSuffix(".gz") { return .gzip }
        return .unknown
    }

    public var autoExtractEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoExtractKey)
    }

    public var postProcessEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.postProcessKey)
    }

    public var postProcessCommand: String {
        UserDefaults.standard.string(forKey: Self.postProcessCommandKey) ?? ""
    }

    // MARK: - public entry point

    /// Called on download completion. Extracts the file if it is an archive (when
    /// enabled) and runs the post-process command (when enabled). Best-effort and
    /// fully asynchronous: heavy extraction never blocks the caller (typically the
    /// main actor in `DownloadStore`).
    public func handleCompletion(of file: URL) {
        guard autoExtractEnabled || postProcessEnabled else { return }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var extractDir: URL?
            if self.autoExtractEnabled, self.kind(of: file).extractable {
                extractDir = self.extract(file)
            }
            self.runPostProcess(archive: file, extractDir: extractDir)
        }
    }

    /// Expand `archive` into a sibling folder named after the archive (extensions
    /// stripped). Returns the extraction directory, or `nil` on unsupported format
    /// or failure. Best-effort: the original archive is left untouched on failure.
    public func extract(_ archive: URL) -> URL? {
        let kind = self.kind(of: archive)
        guard kind.extractable else { return nil }
        let dest = archive.deletingLastPathComponent()
            .appendingPathComponent(baseName(of: archive))
        do {
            try FileManager.default.createDirectory(at: dest,
                  withIntermediateDirectories: true, attributes: nil)
        } catch { return nil }
        return runExtractor(kind: kind, archive: archive, dest: dest) ? dest : nil
    }

    // MARK: - extraction

    /// Derive the unpack folder name by stripping every trailing archive extension.
    private func baseName(of url: URL) -> String {
        let compound = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz"]
        let name = url.lastPathComponent
        let lower = name.lowercased()
        if let hit = compound.first(where: { lower.hasSuffix($0) }) {
            let stripped = String(name.dropLast(hit.count))
            return stripped.isEmpty ? "extracted" : stripped
        }
        let single = url.deletingPathExtension().lastPathComponent
        return single.isEmpty ? "extracted" : single
    }

    private func runExtractor(kind: ArchiveKind, archive: URL, dest: URL) -> Bool {
        let file = archive.path
        let dir = dest.path
        let proc = Process()
        switch kind {
        case .zip:
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-q", file, "-d", dir]
        case .tar:
            // `tar` auto-detects gzip/bzip2/xz, so one invocation covers every
            // .tar* variant plus plain .tar.
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xf", file, "-C", dir]
        case .gzip:
            // Single-file .gz: decompress into the destination folder. The output
            // name may collide or the file may not exist yet — create fresh.
            let outName = archive.deletingPathExtension().lastPathComponent
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            proc.arguments = ["-c", file]
            let outURL = dest.appendingPathComponent(outName)
            try? FileManager.default.removeItem(at: outURL)
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            proc.standardOutput = try? FileHandle(forWritingTo: outURL)
        case .sevenZip:
            guard let seven = resolve7z() else { return false }
            proc.executableURL = seven
            proc.arguments = ["x", "-y", file, "-o\(dir)"]
        case .rar, .unknown:
            return false
        }
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Locate a p7zip binary: prefer well-known Homebrew / system paths, otherwise
    /// fall back to PATH resolution via `/usr/bin/env`. Returns `nil` if unavailable.
    private func resolve7z() -> URL? {
        let known = ["/usr/local/bin/7z", "/opt/homebrew/bin/7z",
                     "/opt/homebrew/bin/7za", "/usr/bin/7z", "/usr/bin/7za"]
        if let p = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: p)
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["sh", "-c", "command -v 7z || command -v 7za"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        do {
            try probe.run()
            probe.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        } catch { /* fall through to nil */ }
        return nil
    }

    // MARK: - post-processing

    /// Run the user's post-processing command against a finished download. The
    /// archive path and (when extraction ran) the unpack folder are exported as
    /// environment variables so the script can locate its inputs. Fire-and-forget
    /// on the utility queue; any failure is silently ignored so it can never
    /// disrupt the download lifecycle.
    public func runPostProcess(archive: URL, extractDir: URL?) {
        guard postProcessEnabled,
              !postProcessCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", self.postProcessCommand]
            var env = ProcessInfo.processInfo.environment
            env["SIPHON_FILE"] = archive.path
            env["SIPHON_NAME"] = archive.lastPathComponent
            env["SIPHON_DIR"] = extractDir?.path
                ?? archive.deletingLastPathComponent().path
            proc.environment = env
            proc.currentDirectoryURL = extractDir ?? archive.deletingLastPathComponent()
            do { try proc.run(); proc.waitUntilExit() } catch { /* best-effort */ }
        }
    }
}
