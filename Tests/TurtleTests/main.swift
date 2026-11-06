import Foundation

// Pure-logic tests for the turtle three-tier limiter and per-task folding.

var failures = 0
func check(_ cond: Bool, _ msg: String, _ detail: String = "") {
    if cond { print("  ok  \(msg)") }
    else { failures += 1; print("  FAIL \(msg)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

// A fixed calendar for deterministic "now".
func date(_ h: Int, _ m: Int) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 1; c.day = 1; c.hour = h; c.minute = m
    return Calendar(identifier: .gregorian).date(from: c)!
}

// MARK: - off: always unlimited
let off = TurtleConfig(mode: .off, limitBytesPerSec: 1024 * 1024)
check(off.effectiveLimit(at: date(12, 0)) == nil, "off → unlimited at noon")
check(off.effectiveLimit(at: date(23, 0)) == nil, "off → unlimited at night")

// MARK: - on: always capped
let on = TurtleConfig(mode: .on, limitBytesPerSec: 2048)
check(on.effectiveLimit(at: date(3, 0)) == 2048, "on → always capped")
check(on.effectiveLimit(at: date(15, 0)) == 2048, "on → capped at any hour")

// MARK: - auto: capped only inside window (cross-midnight 22:00–07:00)
let auto = TurtleConfig(mode: .auto, limitBytesPerSec: 4096,
                        autoStartMinutes: 22 * 60, autoEndMinutes: 7 * 60)
check(auto.effectiveLimit(at: date(23, 0)) == 4096, "auto → capped at 23:00 (inside)")
check(auto.effectiveLimit(at: date(2, 0)) == 4096, "auto → capped at 02:00 (cross-midnight)")
check(auto.effectiveLimit(at: date(7, 0)) == nil, "auto → unlimited at 07:00 (boundary)")
check(auto.effectiveLimit(at: date(12, 0)) == nil, "auto → unlimited at noon (outside)")
check(auto.effectiveLimit(at: date(21, 59)) == nil, "auto → unlimited just before window")

// MARK: - auto: non-wrapping window (01:00–05:00)
let autoDay = TurtleConfig(mode: .auto, limitBytesPerSec: 1000,
                           autoStartMinutes: 60, autoEndMinutes: 5 * 60)
check(autoDay.effectiveLimit(at: date(3, 0)) == 1000, "auto day → capped at 03:00")
check(autoDay.effectiveLimit(at: date(6, 0)) == nil, "auto day → unlimited at 06:00")
check(autoDay.effectiveLimit(at: date(0, 30)) == nil, "auto day → unlimited before 01:00")

// MARK: - Codable round-trip (persistence)
let encoded = try! JSONEncoder().encode(auto)
let decoded = try! JSONDecoder().decode(TurtleConfig.self, from: encoded)
check(decoded == auto, "TurtleConfig Codable round-trip")

if failures == 0 { print("TURTLE TESTS PASSED") }
else { print("TURTLE TESTS FAILED: \(failures)"); exit(1) }
