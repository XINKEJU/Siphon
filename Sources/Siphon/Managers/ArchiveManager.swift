import Foundation
import OSLog

private let archiveLog = Logger(subsystem: "com.xinkeju.siphon.macos", category: "archive")

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
    /// Copy of the command the user explicitly confirmed in Settings. A command
    /// written only to `postProcessCommandKey` (e.g. by `defaults write` or by
    /// another local process) must not silently become executable code.
    public static let postProcessConfirmedKey = "Siphon.postProcessConfirmedCommand"
    public static let maxPostProcessCommandBytes = 4_096

    private let queue = DispatchQueue(label: "Siphon.ArchiveManager", qos: .utility)
    private let stateLock = NSLock()
    private var _lastError: String?

    /// Last extraction / post-processing failure, surfaced in Settings instead
    /// of being swallowed by an empty `catch`.
    public var lastError: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastError
    }

    private func setLastError(_ message: String) {
        stateLock.lock(); _lastError = message; stateLock.unlock()
    }

    private func clearLastError() {
        stateLock.lock(); _lastError = nil; stateLock.unlock()
    }

    private init() {}

    /// True only when the configured command matches what the user confirmed.
    public var isPostProcessConfirmed: Bool {
        let command = postProcessCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty,
              command.utf8.count <= Self.maxPostProcessCommandBytes,
              !command.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        return command == (UserDefaults.standard.string(forKey: Self.postProcessConfirmedKey) ?? "")
    }

    /// Called by Settings when the user presses "确认并启用命令".
    public func confirmPostProcessCommand(_ command: String) {
        UserDefaults.standard.set(
            command.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.postProcessConfirmedKey)
    }

    /// Compressed container formats Siphon knows how to unpack natively.
    public enum ArchiveKind {
        case zip, tar, gzip, sevenZip, rar, unknown

        /// Whether this format is something we attempt to expand with a system tool.
        var extractable: Bool { self != .unknown && self != .rar }
    }

    /// Bounds for archive expansion. A hostile archive can otherwise write
    /// outside the download folder (Zip Slip) or fill the disk (zip bomb).
    public static let maxEntryCount = 20_000
    public static let maxExpandedBytes: UInt64 = 2 << 30

    /// Validate archive entry **names** before handing the archive to a system
    /// extractor. Rejects absolute paths, `..` traversal, Windows drive paths,
    /// backslashes, control characters and absurd entry counts. Pure function
    /// so the regression suite can exercise it without creating archives.
    public static func validateEntryNames(_ names: [String]) -> String? {
        guard names.count <= maxEntryCount else {
            return "归档条目数超过 \(maxEntryCount) 上限"
        }
        for raw in names {
            let name = raw.replacingOccurrences(of: "\\", with: "/")
            guard !name.isEmpty, !name.hasPrefix("/") else {
                return "归档包含绝对路径条目：\(raw.prefix(80))"
            }
            guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return "归档条目包含控制字符"
            }
            guard !name.split(separator: "/", omittingEmptySubsequences: false)
                    .contains("..") else {
                return "归档包含路径穿越条目：\(raw.prefix(80))"
            }
            // "C:/…" and "C:…" are absolute on Windows extractors.
            if name.count >= 2, name[name.index(name.startIndex, offsetBy: 1)] == ":" {
                return "归档包含盘符路径：\(raw.prefix(80))"
            }
        }
        return nil
    }

    /// gzip stores the uncompressed size (mod 2^32) in its last 4 bytes.
    /// Used to reject decompression bombs before writing anything.
    public static func gzipExpandedSize(_ data: Data) -> UInt64? {
        guard data.count >= 4 else { return nil }
        let tail = data.suffix(4)
        var value: UInt32 = 0
        for (i, byte) in tail.enumerated() {
            value |= UInt32(byte) << (8 * UInt32(i))
        }
        return UInt64(value)
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
        // Inspect *before* unpacking. The old code passed the archive straight
        // to unzip/tar, so a `../` entry or a symlink entry could write outside
        // the destination folder, and a zip bomb could fill the disk.
        guard let inspection = inspect(kind: kind, archive: archive) else {
            setLastError("无法读取归档目录（文件损坏或格式不受支持）")
            return nil
        }
        if let reason = Self.validateEntryNames(inspection.names) {
            setLastError("已拒绝解压：\(reason)")
            return nil
        }
        if inspection.special {
            setLastError("已拒绝解压：归档包含符号链接或特殊文件条目")
            return nil
        }
        if inspection.expandedBytes > Self.maxExpandedBytes {
            setLastError("已拒绝解压：展开体积超过 \(Self.maxExpandedBytes / (1 << 20)) MiB 上限")
            return nil
        }
        let dest = archive.deletingLastPathComponent()
            .appendingPathComponent(baseName(of: archive))
        let fm = FileManager.default
        // Never unpack into a pre-existing folder: on failure we remove `dest`,
        // which must be a directory we created in this call only.
        guard !fm.fileExists(atPath: dest.path) else {
            setLastError("解压目标文件夹已存在，为保护已有文件已跳过：\(dest.lastPathComponent)")
            return nil
        }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false,
                                   attributes: nil)
        } catch {
            setLastError("创建解压目录失败：\(error.localizedDescription)")
            return nil
        }
        guard runExtractor(kind: kind, archive: archive, dest: dest),
              postValidate(dest) else {
            try? fm.removeItem(at: dest)
            setLastError("解压失败或内容超出安全上限，已清理：\(dest.lastPathComponent)")
            return nil
        }
        clearLastError()
        return dest
    }

    // MARK: - archive inspection (runs before any byte is written)

    private struct Inspection {
        var names: [String]
        var expandedBytes: UInt64
        var special: Bool
    }

    private func inspect(kind: ArchiveKind, archive: URL) -> Inspection? {
        switch kind {
        case .zip:
            guard let names = capture("/usr/bin/unzip", ["-Z1", archive.path]) else { return nil }
            let detail = capture("/usr/bin/unzip", ["-Z", "-l", archive.path]) ?? []
            return Inspection(names: names,
                              expandedBytes: Self.zipExpandedBytes(detail) ?? Self.maxExpandedBytes + 1,
                              special: detail.contains { Self.isSpecialListingLine($0) })
        case .tar:
            guard let names = capture("/usr/bin/tar", ["-tf", archive.path]) else { return nil }
            let detail = capture("/usr/bin/tar", ["-tvf", archive.path]) ?? []
            return Inspection(names: names,
                              expandedBytes: Self.tarExpandedBytes(detail),
                              special: detail.contains { Self.isSpecialListingLine($0) })
        case .sevenZip:
            guard let seven = resolve7z(),
                  let lines = capture(seven.path, ["l", "-slt", "-y", archive.path]) else { return nil }
            let names = lines.compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("Path = ") ? String(t.dropFirst(7)) : nil
            }
            var bytes: UInt64 = 0
            var special = false
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Size = "),
                   let n = UInt64(t.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    bytes += n
                }
                if t.hasPrefix("Attributes = ") {
                    let v = t.dropFirst(13).trimmingCharacters(in: .whitespaces)
                    if v.hasPrefix("l") || v.contains("Symbolic") { special = true }
                }
                if t.contains("Symbolic Link") { special = true }
            }
            return Inspection(names: names, expandedBytes: bytes, special: special)
        case .gzip:
            guard let handle = try? FileHandle(forReadingFrom: archive),
                  let end = try? handle.seekToEnd(), end >= 4 else { return nil }
            try? handle.seek(toOffset: end - 4)
            let tailData = (try? handle.read(upToCount: 4)) ?? Data()
            try? handle.close()
            guard let size = Self.gzipExpandedSize(tailData) else { return nil }
            let outName = ContentDisposition.safeName(
                archive.deletingPathExtension().lastPathComponent) ?? "extracted"
            return Inspection(names: [outName], expandedBytes: size, special: false)
        case .rar, .unknown:
            return nil
        }
    }

    /// Capture a listing tool's stdout. stderr goes to /dev/null so a chatty
    /// extractor cannot fill a pipe and deadlock the child process.
    private func capture(_ executable: String, _ arguments: [String]) -> [String]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            archiveLog.error("archive listing tool failed to launch: \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// `zipinfo -l` / `tar -tvf` start each entry with a type character.
    /// Symlinks (`l`), devices (`b`/`c`), FIFOs (`p`) and sockets (`s`) are
    /// refused: a symlink entry can redirect later entries outside `dest`.
    public static func isSpecialListingLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 10, let first = t.first else { return false }
        return ["l", "b", "c", "p", "s"].contains(first) && t.contains(" ")
    }

    public static func zipExpandedBytes(_ lines: [String]) -> UInt64? {
        guard let line = lines.first(where: { $0.contains("bytes uncompressed") }),
              let segment = line.split(separator: ",")
                .first(where: { $0.contains("bytes uncompressed") }) else { return nil }
        return segment.split(separator: " ").compactMap { UInt64($0) }.first
    }

    /// BSD `tar -tvf` prints `mode links owner group SIZE Mon DD HH:MM name`.
    /// Locate SIZE by the month token that follows it.
    public static func tarExpandedBytes(_ lines: [String]) -> UInt64 {
        var total: UInt64 = 0
        for line in lines {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count > 3 else { continue }
            for i in 0..<(parts.count - 2) {
                if let n = UInt64(parts[i]), parts[i + 1].count == 3,
                   Int(parts[i + 2]) != nil {
                    total += n
                    break
                }
            }
        }
        return total
    }

    /// Second line of defence after extraction: drop any special entry left by
    /// the tool and enforce the same byte ceiling on what actually landed.
    private func postValidate(_ dest: URL) -> Bool {
        let fm = FileManager.default
        guard let subs = try? fm.subpathsOfDirectory(atPath: dest.path),
              subs.count <= Self.maxEntryCount else { return false }
        var total: UInt64 = 0
        for sub in subs {
            let url = dest.appendingPathComponent(sub)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let type = attrs[.type] as? FileAttributeType else { continue }
            if type != .typeRegular && type != .typeDirectory {
                try? fm.removeItem(at: url)
                continue
            }
            if type == .typeRegular {
                total += (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                if total > Self.maxExpandedBytes { return false }
            }
        }
        return true
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
    /// command must have been explicitly confirmed in Settings; it has a hard
    /// timeout and its exit code / stderr are recorded rather than discarded.
    public func runPostProcess(archive: URL, extractDir: URL?) {
        guard postProcessEnabled,
              !postProcessCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard isPostProcessConfirmed else {
            setLastError("后处理命令尚未在设置页确认，已拒绝执行")
            return
        }
        let command = postProcessCommand
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            // Redirect both streams to a file: piping a chatty script into an
            // unread Pipe deadlocks the child once the buffer fills.
            let logURL = fm.temporaryDirectory
                .appendingPathComponent("siphon-postprocess-\(UUID().uuidString).log")
            fm.createFile(atPath: logURL.path, contents: nil)
            defer { try? fm.removeItem(at: logURL) }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["SIPHON_FILE"] = archive.path
            env["SIPHON_NAME"] = archive.lastPathComponent
            env["SIPHON_DIR"] = extractDir?.path
                ?? archive.deletingLastPathComponent().path
            proc.environment = env
            proc.currentDirectoryURL = extractDir ?? archive.deletingLastPathComponent()
            proc.standardOutput = try? FileHandle(forWritingTo: logURL)
            proc.standardError = try? FileHandle(forWritingTo: logURL)
            do {
                try proc.run()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    proc.waitUntilExit()
                    done.signal()
                }
                if done.wait(timeout: .now() + 60) == .timedOut {
                    proc.terminate()
                    self.setLastError("后处理命令超时（60 秒），已终止")
                    return
                }
                if proc.terminationStatus != 0 {
                    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                    self.setLastError("后处理命令退出码 \(proc.terminationStatus)：\(log.suffix(500))")
                } else {
                    self.clearLastError()
                }
            } catch {
                self.setLastError("后处理命令启动失败：\(error.localizedDescription)")
            }
        }
    }
}
