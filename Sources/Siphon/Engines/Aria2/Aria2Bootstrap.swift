import Foundation

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

    public var rpcURL: URL { URL(string: "http://127.0.0.1:\(port)/jsonrpc")! }

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

    public func start() throws {
        guard !isRunning else { return }
        let binary = try locateBinary()
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "--enable-rpc",
            "--rpc-listen-all=false",
            "--rpc-listen-port=\(port)",
            "--rpc-allow-origin-all",
            "--continue=true",
            "--max-concurrent-downloads=8",
            "--max-connection-per-server=8",
            "--split=8",
            "--min-split-size=1M",
            "--dir", NSTemporaryDirectory(),
            "--save-session-interval=30",
            "--auto-save-interval=30"
        ]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        process = proc
        isRunning = true
        Thread.sleep(forTimeInterval: 0.3)
    }

    public func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        isRunning = false
    }
}
