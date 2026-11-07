import Foundation

/// Runs one external transfer process (curl / scp / rsync / mount helpers).
///
/// stdout and stderr are redirected to temporary *files*, not pipes: curl's
/// progress meter can otherwise fill a pipe buffer and deadlock the child while
/// we await its termination. Progress is measured by polling the destination
/// file size, which works uniformly for every tool.
public final class ExternalRunner {
    public struct Outcome: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let wasCancelled: Bool
    }

    private let executable: URL
    private let arguments: [String]
    private let destination: URL?
    private let onBytes: (@Sendable (Int64) -> Void)?
    /// 读取 stdout 的最新尾部内容（yt-dlp 进度行等）；仅在内容变化时回调。
    private let onOutput: (@Sendable (String) -> Void)?
    private var lastOutput = ""
    private let process = Process()
    private let outURL: URL
    private let errURL: URL
    private var cancelled = false
    private var outHandle: FileHandle?
    private var errHandle: FileHandle?

    public init(executable: URL, arguments: [String], destination: URL?,
                onBytes: (@Sendable (Int64) -> Void)? = nil,
                onOutput: (@Sendable (String) -> Void)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.destination = destination
        self.onBytes = onBytes
        self.onOutput = onOutput
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Siphon-External-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.outURL = tmp.appendingPathComponent("stdout.log")
        self.errURL = tmp.appendingPathComponent("stderr.log")
    }

    deinit {
        try? FileManager.default.removeItem(at: outURL.deletingLastPathComponent())
    }

    public func start() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw ExternalRunnerError.binaryNotFound(executable.path)
        }
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        outHandle = try FileHandle(forWritingTo: outURL)
        errHandle = try FileHandle(forWritingTo: errURL)

        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
    }

    /// Wait for exit, reporting destination size every 250 ms. Re-entrant:
    /// resume() reaps the runner itself while the launch-time wait Task also
    /// calls this — the tail (close / read / cleanup) runs exactly once on a
    /// serial queue and the computed outcome is cached.
    public func wait() async -> Outcome {
        while process.isRunning {
            if cancelled { process.terminate(); break }
            reportBytes()
            reportOutput()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return reapQueue.sync { self.reap() }
    }

    private let reapQueue = DispatchQueue(label: "siphon.external.reap")
    private var cachedOutcome: Outcome?

    private func reap() -> Outcome {
        if let cached = cachedOutcome { return cached }
        // Let the kernel flush the child's file descriptors before reading.
        try? outHandle?.synchronize()
        try? errHandle?.synchronize()
        try? outHandle?.close()
        try? errHandle?.close()
        outHandle = nil
        errHandle = nil
        reportBytes()

        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outURL.deletingLastPathComponent())
        let outcome = Outcome(exitCode: process.terminationStatus,
                              stdout: out.trimmingCharacters(in: .whitespacesAndNewlines),
                              stderr: err.trimmingCharacters(in: .whitespacesAndNewlines),
                              wasCancelled: cancelled)
        cachedOutcome = outcome
        return outcome
    }

    public func cancel() {
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    public var isCancelled: Bool { cancelled }

    private func reportOutput() {
        guard let onOutput else { return }
        guard let text = try? String(contentsOf: outURL, encoding: .utf8),
              text != lastOutput else { return }
        // 只需要最新几行进度；避免长任务把整个日志搬进内存。
        lastOutput = text
        onOutput(String(text.suffix(4096)))
    }

    private func reportBytes() {
        guard let destination,
              let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let n = attrs[.size] as? NSNumber else { return }
        onBytes?(n.int64Value)
    }
}

public enum ExternalRunnerError: Error, LocalizedError {
    case binaryNotFound(String)
    case transferFailed(String)
    case invalidURL(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let p): return "未找到系统工具：\(p)"
        case .transferFailed(let m): return "传输失败：\(m)"
        case .invalidURL(let s): return "无效的链接：\(s)"
        case .unsupported(let s): return "当前环境不支持：\(s)"
        }
    }
}
