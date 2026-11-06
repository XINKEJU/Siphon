import Foundation

/// Lists an FTP directory so a directory URL (`ftp://host/path/`) can be expanded
/// into one download task per file — a capability aria2 itself lacks (it only fetches
/// single files; there is no MLSD recursion).
///
/// We delegate the wire work to the system `/usr/bin/curl`, whose FTP backend already
/// implements the hard parts: EPSV-first data connections, `MLSD` with automatic
/// `LIST` fallback, and `NLST` for the directory listing. `--list-only` asks curl for
/// exactly that listing instead of downloading the directory as a file.
///
/// The parser accepts three shapes curl may emit:
///  1. Machine-list format (`type=...;sizd=...;modify=...; name`), produced by MLSD.
///  2. `ls -l`-style long listing, produced by the LIST fallback.
///  3. Bare names, produced by NLST (no metadata; size 0, type unknown).
public enum FTPDirectoryLister {

    /// One discovered entry. `isDirectory` is only authoritative when MLSD was used;
    /// LIST/NLST listings are treated as files (subdirectories are skipped rather
    /// than risk recursing into the wrong path).
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let size: Int64
        public let isDirectory: Bool
    }

    public enum ListerError: Error, LocalizedError {
        case notFTP
        case missingCurl
        case listFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notFTP: return "不是 FTP 链接"
            case .missingCurl: return "未找到系统 curl"
            case .listFailed(let s): return "列出 FTP 目录失败：\(s)"
            }
        }
    }

    private static var curlPath: String {
        let configured = ProtocolSettings.load().curlPath.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return "/usr/bin/curl"
    }

    /// True when a URL looks like an FTP directory rather than a concrete file.
    /// A trailing "/" (or an empty path) is the signal: `ftp://host/` and
    /// `ftp://host/dir/` are directories; `ftp://host/file.bin` is a file.
    ///
    /// Note: `URL.path` *strips* a trailing slash (`/pub/` → `/pub`), so we consult
    /// the raw string's path portion instead — the only reliable way to detect the
    /// trailing `/` that marks a directory.
    public static func looksLikeDirectory(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "ftp" else { return false }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        guard let s = comps?.string, let sep = s.range(of: "://") else {
            return url.path.isEmpty || url.path == "/"
        }
        let after = s[sep.upperBound...]
        guard let slash = after.firstIndex(of: "/") else { return true } // no path at all
        let path = after[slash...]
        return path.isEmpty || path.hasSuffix("/")
    }

    /// Fetch the directory listing and return parsed entries (excluding `.` / `..`).
    public static func list(_ url: URL, options: [String: String] = [:]) async throws -> [Entry] {
        guard url.scheme?.lowercased() == "ftp" else { throw ListerError.notFTP }
        let curl = curlPath
        guard FileManager.default.isExecutableFile(atPath: curl) else {
            throw ListerError.missingCurl
        }
        let dirURL = url.path.hasSuffix("/")
            ? url
            : URL(string: url.absoluteString + (url.absoluteString.hasSuffix("/") ? "" : "/"))!
        var args = ["--globoff", "--silent", "--show-error", "--list-only", "--connect-timeout", "20"]
        // Forward any user-supplied FTP credentials/headers the same way the
        // single-file path does. Only meaningful for keys curl treats as FTP options;
        // harmless otherwise.
        for (k, v) in options where !["dir", "out"].contains(k.lowercased()) {
            args += ["--header", "\(k): \(v)"]
        }
        args.append(dirURL.absoluteString)

        let runner = ExternalRunner(executable: URL(fileURLWithPath: curl),
                                    arguments: args, destination: nil)
        do {
            try runner.start()
            let outcome = await runner.wait()
            guard outcome.exitCode == 0 else {
                throw ListerError.listFailed(outcome.stderr.isEmpty
                    ? "exit=\(outcome.exitCode)" : outcome.stderr)
            }
            return parse(outcome.stdout)
        } catch {
            throw ListerError.listFailed(error.localizedDescription)
        }
    }

    // MARK: - parsing

    /// Parse a raw listing blob into entries, in stable order.
    public static func parse(_ raw: String) -> [Entry] {
        var out: [Entry] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // MLSD machine-list rows carry `key=value;` facts. Recognise them by a
            // `; ` separator and a leading `name=`-style fact, then let the MLSD
            // parser own the row (it drops `.`/`..` itself — never fall through).
            if trimmed.contains("; "),
               let firstSemi = trimmed.firstIndex(of: ";"),
               trimmed[trimmed.startIndex..<firstSemi].contains("=") {
                if let e = parseMLSD(trimmed) { out.append(e) }
                continue
            }

            // `ls -l` long listing rows start with a permission/type char.
            if let c = trimmed.first, c == "d" || c == "-" || c == "l" {
                if let e = parseLongListing(trimmed) { out.append(e) }
                continue
            }

            // `total N` summary line from LIST — not an entry.
            if trimmed.hasPrefix("total ") { continue }

            // NLST: a bare file name with no metadata.
            if trimmed != "." && trimmed != ".." {
                out.append(Entry(name: trimmed, size: 0, isDirectory: false))
            }
        }
        return out
    }

    /// MLSD machine list: `type=dir;modify=...;perm=...; name`.
    ///
    /// Facts are `key=value` pairs separated by `;`; the final fact and the file name
    /// are separated by `; ` (semicolon + space) per RFC 3659. We split on the *last*
    /// `; ` so a name containing spaces is preserved intact.
    private static func parseMLSD(_ line: String) -> Entry? {
        guard let sep = line.range(of: "; ", options: .backwards) else { return nil }
        let facts = String(line[line.startIndex..<sep.lowerBound])
        let name = String(line[sep.upperBound..<line.endIndex])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var isDir = false
        var size: Int64 = 0
        for fact in facts.components(separatedBy: ";") {
            let f = fact.trimmingCharacters(in: .whitespaces)
            if f == "type=dir" { isDir = true }
            else if f.hasPrefix("sizd="), let v = Int64(f.dropFirst(5)) { size = v }
            else if f.hasPrefix("size="), let v = Int64(f.dropFirst(5)) { size = v }
        }
        return Entry(name: name, size: size, isDirectory: isDir)
    }

    /// `ls -l` long listing: `drwxr-xr-x   ... name`. The first char (d/l/-) marks a
    /// directory; the name is the token before a symlink arrow (`link -> target`) or,
    /// absent one, the final whitespace-delimited token. Symlinks (`l`) are treated
    /// as files to avoid recursing into a loop.
    private static func parseLongListing(_ line: String) -> Entry? {
        let fields = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard fields.count >= 2 else { return nil }
        let perms = fields[0]
        guard perms.count >= 1 else { return nil }
        let c = perms.first!
        guard c == "d" || c == "-" || c == "l" else { return nil }
        // Symlink rows end with `name -> target`; the link name is the token before "->".
        let name: String
        if let arrow = fields.firstIndex(of: "->"), arrow > 0 {
            name = fields[arrow - 1]
        } else {
            name = fields.last!
        }
        guard name != "." && name != ".." else { return nil }
        var size: Int64 = 0
        if fields.count >= 5 { size = Int64(fields[4]) ?? 0 }
        return Entry(name: name, size: size, isDirectory: (c == "d"))
    }
}
