import Foundation

// Regression tests for the per-task token-bucket throttler (TaskThrottler) and the
// global SpeedLimitController fold. Verifies: unlimited is a no-op, a cap actually
// delays, and hot-updating the limit mid-flight takes effect.

var failures = 0
func check(_ cond: Bool, _ msg: String, _ detail: String = "") {
    if cond { print("  ok  \(msg)") }
    else { failures += 1; print("  FAIL \(msg)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

@main struct Run {
    static func main() async {
        // 1. Unlimited throttle is a no-op (returns without sleeping).
        let un = TaskThrottler()
        let t0 = Date()
        await un.consume(1_000_000)
        check(Date().timeIntervalSince(t0) < 0.05, "unlimited throttle is a no-op")

        // 2. A 1 MB/s cap delays a 512 KB draw by roughly half a second.
        let capped = TaskThrottler()
        capped.setLimit(1_000_000)
        let t1 = Date()
        await capped.consume(512_000)
        let elapsed = Date().timeIntervalSince(t1)
        check(elapsed >= 0.3 && elapsed < 2.0, "1 MB/s cap delays 512 KB draw ~0.5s",
              "elapsed=\(elapsed)")

        // 3. Hot-update: raising the limit to unlimited stops further delays.
        capped.setLimit(nil)
        let t2 = Date()
        await capped.consume(512_000)
        check(Date().timeIntervalSince(t2) < 0.05, "clearing the limit releases immediately")

        // 4. Global limiter: nil = unlimited, then a cap delays.
        SpeedLimitController.shared.setLimit(nil)
        let t3 = Date()
        await SpeedLimitController.shared.consume(1_000_000)
        check(Date().timeIntervalSince(t3) < 0.05, "global nil is a no-op")

        SpeedLimitController.shared.setLimit(1_000_000)
        // setLimit pre-fills one second's worth of tokens; drain it first so the
        // next draw must actually wait for refill.
        await SpeedLimitController.shared.consume(1_000_000)
        let t4 = Date()
        await SpeedLimitController.shared.consume(512_000)
        let g = Date().timeIntervalSince(t4)
        check(g >= 0.3 && g < 2.0, "global 1 MB/s cap delays 512 KB ~0.5s", "elapsed=\(g)")
        SpeedLimitController.shared.setLimit(nil)

        if failures == 0 { print("THROTTLER TESTS PASSED") }
        else { print("THROTTLER TESTS FAILED: \(failures)"); exit(1) }
    }
}
