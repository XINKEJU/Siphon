import Foundation

/// Out-of-band bootstrap channel for the loopback API token.
///
/// The token must never travel over the loopback HTTP socket. `GET /ping` was
/// unauthenticated by design (extension liveness probe), so returning the token
/// there handed full control of `/tasks`, `/config`, `/add` and `/mdxp` to any
/// local process — and to any extension context able to reach the port. The app
/// now writes the token to a 0600 file inside a 0700 directory; the Native
/// Messaging gateway (a separate process launched by the browser) reads it
/// from there. MV3 extensions cannot read files, so they use the gateway, or
/// the user pastes the token once into the extension's settings.
///
/// Both the app and `SiphonNM` link `SiphonBridge`, so the path is defined once.
/// CLI tests compile the sources as a single module and inject a temporary root.
public enum LocalAuthBootstrap {
    /// Path inside `~/Library/Application Support/Siphon/`. `root` is a test
    /// seam: pass a temporary directory to avoid touching the real Application
    /// Support folder. `fileName` lets other self-generated secrets (aria2 RPC
    /// secret) reuse the same 0600-file channel; caller-supplied names must be
    /// bare file names — no separators, no dot-dot.
    public static func fileURL(for fileName: String = "local-api-token",
                               in root: URL? = nil) -> URL {
        precondition(!fileName.isEmpty && !fileName.contains("/")
                     && !fileName.contains("..") && fileName != ".",
                     "insecure secret file name: \(fileName)")
        let dir = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Siphon", isDirectory: true)
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Write `token` with owner-only permissions, atomically, so a concurrent
    /// reader never sees a partial value. Returns the file URL on success.
    @discardableResult
    public static func publish(_ token: String, fileName: String = "local-api-token",
                               in root: URL? = nil) -> URL? {
        guard !token.isEmpty else { return nil }
        let fm = FileManager.default
        let dir = fileURL(for: fileName, in: root).deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Tighten a directory created with looser permissions by an older build.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let url = fileURL(for: fileName, in: root)
            try Data(token.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// Read the token, refusing files that are group/world accessible, are not
    /// regular files (a planted symlink), or are empty/malformed.
    public static func read(fileName: String = "local-api-token",
                            from root: URL? = nil) -> String? {
        let fm = FileManager.default
        let url = fileURL(for: fileName, in: root)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
              let mode = attrs[.posixPermissions] as? NSNumber,
              mode.uint16Value & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Called when the control interface is switched off, so no stale token
    /// file is left behind for a later, unrelated process to pick up.
    public static func remove(fileName: String = "local-api-token", in root: URL? = nil) {
        try? FileManager.default.removeItem(at: fileURL(for: fileName, in: root))
    }
}
