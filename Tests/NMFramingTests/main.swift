import Foundation

// Native Messaging framing: 4-byte little-endian length + JSON, with caps on
// both directions.

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
}

let sample: [String: Any] = [
    "type": "add",
    "url": "https://example.com/video.mp4",
    "headers": ["Cookie": "a=1", "Referer": "https://example.com/"]
]

let frame = NativeMessagingFraming.encode(sample)
check(frame != nil, "encode produces a frame")
check(frame?.count == 4 + (try! JSONSerialization.data(withJSONObject: sample).count),
      "frame = 4-byte length + JSON payload")

// Length bytes must be little-endian: the first byte is the low byte of the
// JSON size, so a small payload has a non-zero first byte and zero high bytes.
if let frame {
    let payloadSize = frame.count - 4
    let headerBytes = [UInt8](frame.prefix(4))
    check(Int(headerBytes[0]) == payloadSize % 256, "first length byte is payload low byte")
    check(headerBytes[3] == 0, "high length byte is zero for small payloads")
}

let decoded = frame.flatMap { NativeMessagingFraming.decode($0) }
check(decoded?["type"] as? String == "add", "round-trip type")
check(decoded?["url"] as? String == "https://example.com/video.mp4", "round-trip url")
check((decoded?["headers"] as? [String: String])?["Cookie"] == "a=1", "round-trip headers")

// Outbound cap.
let oversized = ["blob": String(repeating: "x", count: NativeMessagingFraming.maxOutboundBytes + 16)]
check(NativeMessagingFraming.encode(oversized) == nil, "oversized outbound message rejected")

// Inbound cap (0xFFFFFFFF length) and short frames.
check(NativeMessagingFraming.decode(Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil,
      "oversized inbound length rejected")
check(NativeMessagingFraming.decode(Data([0x03, 0x00, 0x00, 0x00])) == nil,
      "truncated inbound frame rejected")
check(NativeMessagingFraming.decode(Data()) == nil, "empty frame rejected")

if failures > 0 {
    print("NATIVE MESSAGING FRAMING TESTS FAILED (\(failures))")
    exit(1)
}
print("NATIVE MESSAGING FRAMING TESTS PASSED")
