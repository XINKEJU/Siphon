import Foundation
import Darwin

public enum Aria2Error: Error, LocalizedError {
    case binaryNotFound
    case rpcFailure(String)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "未找到 aria2c 二进制文件。请将 aria2c 放入 App 包或 Application Support/Siphon/ 目录。"
        case .rpcFailure(let m): return "aria2 RPC 错误：\(m)"
        case .notRunning: return "aria2 尚未启动。"
        }
    }
}

/// Launches and supervises the bundled `aria2c` subprocess and exposes its JSON-RPC endpoint.
/// Running aria2 as a separate process (rather than linking libaria2) keeps the app clear of
/// GPLv2 linking obligations and lets aria2 handle its own protocol maturity.
public final class Aria2Bootstrap {
    public static let shared = Aria2Bootstrap()

    /// Overridable so tests / secondary instances never collide with a running app.
    public var port: UInt16 = 6800
    private var process: Process?
    public private(set) var isRunning = false

    /// Secret passed as `--rpc-secret` and prepended as `token:` by `Aria2RPC`.
    /// Generated once per install; aria2 binds loopback only, but without the
    /// secret any local process (or any web page, when CORS is open) could drive
    /// aria2. Stored in UserDefaults rather than the Keychain: the threat is a
    /// remote page, and Keychain ACL entries created by helper processes would
    /// prompt on every access.
    public private(set) var rpcSecret = ""

    /// Session file handed to `--save-session` / `--input-file`: aria2 writes the
    /// GIDs of incomplete downloads here on graceful shutdown (and every 30 s), and
    /// reloads them on the next launch. Settable so tests never touch the real one.
    public var sessionFile: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("Siphon/aria2-session.a2")
    }()

    public var rpcURL: URL { URL(string: "http://127.0.0.1:\(port)/jsonrpc")! }

    /// aria2 also serves JSON-RPC over WebSocket on the same port and *pushes* event
    /// notifications (onDownloadComplete / onDownloadError / …) to connected clients.
    /// Siphon uses it for instant state changes without waiting for the next poll tick.
    public var wsURL: URL { URL(string: "ws://127.0.0.1:\(port)/jsonrpc")! }

    private init() {}

    /// Locate aria2c: (1) inside the .app bundle, (2) Application Support,
    /// (3) any directory on PATH (Homebrew is /opt/homebrew/bin on Apple Silicon,
    /// /usr/local/bin on Intel), (4) common absolute fallbacks.
    private func locateBinary() throws -> URL {
        let fm = FileManager.default
        if let b = Bundle.main.url(forResource: "aria2c", withExtension: nil) { return b }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Siphon/aria2c")
        if fm.isExecutableFile(atPath: support.path) { return support }

        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":")
        var candidates = pathDirs.map { $0 + "/aria2c" }
        candidates.append(contentsOf: ["/opt/homebrew/bin/aria2c",
                                       "/usr/local/bin/aria2c",
                                       "/usr/bin/aria2c"])
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw Aria2Error.binaryNotFound
    }

    /// Launches aria2c (async). The caller thread is **not** blocked: the old
    /// `Thread.sleep(0.3)` is gone, replaced by an `await`-ed loopback port probe
    /// that only suspends the async task until aria2 binds the RPC port (or fails).
    public func start() async throws {
        guard !isRunning else { return }
        let binary = try locateBinary()
        let secret = loadOrCreateSecret()
        rpcSecret = secret
        try? FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var args = [
            "--enable-rpc",
            "--rpc-listen-all=false",
            "--rpc-listen-port=\(port)",
            "--rpc-secret=\(secret)",
            // Motrix hardening: RPC bodies with huge magnet links need headroom.
            "--rpc-max-request-size=50M",
            "--continue=true",
            "--max-concurrent-downloads=8",
            "--max-connection-per-server=8",
            "--split=8",
            "--min-split-size=1M",
            // Don't pre-allocate the full file for small files (less space churn),
            // keep preallocation only where it helps contiguous writes.
            "--no-file-allocation-limit=64M",
            // Give up after repeated "not found" instead of retrying forever.
            "--max-file-not-found=10",
            // Die with Siphon (own pid, NOT ppid: bundled apps parent to launchd,
            // and checking a launchd pid would make aria2 exit immediately).
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
            // BT hygiene: never linger as a seeder for tasks the user added as
            // downloads, and drop unselected pieces' files.
            "--bt-detach-seed-only=true",
            "--bt-remove-unselected-file=true",
            // Transmission-flavoured peer identity: trackers and peers handle a
            // mainstream BT client better than an unknown "aria2" agent.
            "--peer-agent=Transmission/3.00",
            "--peer-id-prefix=-TR3000-",
            "--dht-entry-point=dht.transmissionbt.com:6881",
            "--dir", NSTemporaryDirectory(),
            "--save-session=\(sessionFile.path)",
            "--save-session-interval=30",
            "--auto-save-interval=30"
        ]
        // Reload the previous session's incomplete downloads. They would auto-start,
        // so `Aria2Engine.adoptPersistedSessions` force-pauses everything right after
        // startup and re-binds the GIDs to the restored Siphon tasks.
        if FileManager.default.fileExists(atPath: sessionFile.path) {
            args.append(contentsOf: ["--input-file=\(sessionFile.path)",
                                     "--deferred-input=true"])
        }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        process = proc
        // Poll the real loopback port until it answers, or give up on crash/timeout.
        // `await` keeps the caller thread free instead of blocking it like the old probe.
        guard await waitUntilReady(process: proc, port: port, timeout: 5) else {
            proc.terminate()
            process = nil
            throw Aria2Error.notRunning
        }
        isRunning = true
    }

    /// Poll the loopback RPC port until it accepts a connection, or the process died
    /// / timed out. Returns false if aria2 never came up, so we never lie about isRunning.
    /// Async so the wait suspends the task instead of blocking the caller's thread.
    private func waitUntilReady(process proc: Process, port: UInt16, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !proc.isRunning { return false }
            if portOpen(port) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Synchronous loopback TCP connect probe (best-effort readiness check).
    private func portOpen(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func loadOrCreateSecret() -> String {
        let account = "aria2-rpc-secret"
        // Migrate the legacy plaintext UserDefaults blob, then keep the secret
        // in the Keychain only.
        let d = UserDefaults.standard
        if let legacy = d.string(forKey: "Siphon.aria2RpcSecret"), !legacy.isEmpty {
            Keychain.setSecret(legacy, account: account)
            d.removeObject(forKey: "Siphon.aria2RpcSecret")
            return legacy
        }
        if let s = Keychain.secret(account: account), !s.isEmpty { return s }
        let fresh = Keychain.randomToken()
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        Keychain.setSecret(fresh, account: account)
        return fresh
    }

    public func stop() {
        if let p = process, p.isRunning {
            // SIGTERM → aria2 shuts down gracefully and writes the session file;
            // wait so callers that inspect the file right after stop() see it.
            p.terminate()
            p.waitUntilExit()
        }
        process = nil
        isRunning = false
    }
}
