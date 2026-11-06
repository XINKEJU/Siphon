import Foundation

/// Global token-bucket rate limiter for the native (HLS/DASH) engines.
///
/// aria2 has its own `--max-overall-download-limit`, so `DownloadStore` forwards the
/// same value to aria2 over JSON-RPC. For native engines the bucket is consulted
/// before each segment request. `nil` / 0 means unlimited.
public final class SpeedLimitController: @unchecked Sendable {
    public static let shared = SpeedLimitController()

    private let lock = NSLock()
    private var limitBytesPerSec: Int64 = 0
    private var tokens: Double = 0
    private var lastRefill = Date()

    private init() {}

    /// Set the global cap. `nil` clears it.
    public func setLimit(_ bytesPerSec: Int64?) {
        lock.lock(); defer { lock.unlock() }
        limitBytesPerSec = max(0, bytesPerSec ?? 0)
        tokens = Double(limitBytesPerSec)
        lastRefill = Date()
    }

    public var currentLimit: Int64 {
        lock.lock(); defer { lock.unlock() }
        return limitBytesPerSec
    }

    /// Sleep until `bytes` worth of tokens are available. No-op when unlimited.
    public func consume(_ bytes: Int) async {
        while true {
            let wait: TimeInterval? = computeWait(bytes: bytes)
            guard let wait else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0.001, wait) * 1_000_000_000))
        }
    }

    private func computeWait(bytes: Int) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard limitBytesPerSec > 0 else { return nil }
        let now = Date()
        let dt = now.timeIntervalSince(lastRefill)
        lastRefill = now
        tokens = min(Double(limitBytesPerSec), tokens + dt * Double(limitBytesPerSec))
        let need = Double(bytes)
        if tokens >= need {
            tokens -= need
            return nil
        }
        return (need - tokens) / Double(limitBytesPerSec)
    }
}
