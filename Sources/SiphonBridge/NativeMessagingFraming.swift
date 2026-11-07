import Foundation

/// Chrome Native Messaging wire format: one message is a 4-byte little-endian
/// length followed by a UTF-8 JSON object. Shared by the `SiphonNM` gateway and
/// its tests so the framing is defined exactly once.
public enum NativeMessagingFraming {
    public static let maxInboundBytes = 4 * 1024 * 1024
    public static let maxOutboundBytes = 1 * 1024 * 1024

    public static func encode(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              let json = try? JSONSerialization.data(withJSONObject: object),
              json.count <= maxOutboundBytes else { return nil }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    public static func decode(_ frame: Data) -> [String: Any]? {
        guard frame.count >= 4 else { return nil }
        let lengthBytes = frame.prefix(4)
        let length = lengthBytes.withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { dst in
                dst.copyBytes(from: raw)
            }
            return UInt32(littleEndian: value)
        }
        guard Int(length) <= maxInboundBytes else { return nil }
        let body = frame.dropFirst(4)
        guard body.count == Int(length),
              let json = try? JSONSerialization.jsonObject(with: Data(body)) else { return nil }
        return json as? [String: Any]
    }

    /// Read one complete message from stdin. Returns nil on EOF, malformed frame
    /// or an over-long length (the caller exits, which Chrome treats as normal).
    public static func readMessage(from handle: FileHandle = .standardInput) -> [String: Any]? {
        let header = handle.readData(ofLength: 4)
        guard header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { dst in
                dst.copyBytes(from: raw)
            }
            return UInt32(littleEndian: value)
        }
        guard Int(length) <= maxInboundBytes else { return nil }
        let body = handle.readData(ofLength: Int(length))
        guard body.count == Int(length),
              let json = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return json as? [String: Any]
    }

    @discardableResult
    public static func writeMessage(_ object: [String: Any],
                                    to handle: FileHandle = .standardOutput) -> Bool {
        guard let frame = encode(object) else { return false }
        handle.write(frame)
        return true
    }
}
