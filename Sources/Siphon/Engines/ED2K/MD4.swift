import Foundation

/// Pure-Swift MD4 (RFC 1320).
///
/// `CryptoKit` has no MD4, but eD2K/eMule file hashes are defined in terms of MD4,
/// so a self-contained implementation is required. Verified against the RFC test
/// vectors ("" -> 31d6cfe0d16ae931b73c59d7e0c089c0, "abc" -> a448017aaf21d8525fc10ae87aa6729d).
public enum MD4 {
    public static func hash(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8

        // Padding: 0x80, then zeros until length ≡ 56 (mod 64), then 64-bit LE bit length.
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        withUnsafeBytes(of: bitLength.littleEndian) { message.append(contentsOf: $0) }

        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xefcd_ab89
        var h2: UInt32 = 0x98ba_dcfe
        var h3: UInt32 = 0x1032_5476

        let round2Index = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
        let round3Index = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
        let round1Shift: [UInt32] = [3, 7, 11, 19]
        let round2Shift: [UInt32] = [3, 5, 9, 13]
        let round3Shift: [UInt32] = [3, 9, 11, 15]

        for blockStart in stride(from: 0, to: message.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = blockStart + i * 4
                x[i] = UInt32(message[o])
                    | (UInt32(message[o + 1]) << 8)
                    | (UInt32(message[o + 2]) << 16)
                    | (UInt32(message[o + 3]) << 24)
            }

            var a = h0, b = h1, c = h2, d = h3

            // Round 1 — F(X,Y,Z) = (X & Y) | (~X & Z)
            for k in 0..<16 {
                let f = (b & c) | (~b & d)
                a = rotateLeft(a &+ f &+ x[k], round1Shift[k % 4])
                (a, b, c, d) = (d, a, b, c)
            }
            // Round 2 — G(X,Y,Z) = (X&Y)|(X&Z)|(Y&Z), constant 0x5A827999
            for k in 0..<16 {
                let g = (b & c) | (b & d) | (c & d)
                a = rotateLeft(a &+ g &+ x[round2Index[k]] &+ 0x5a82_7999, round2Shift[k % 4])
                (a, b, c, d) = (d, a, b, c)
            }
            // Round 3 — H(X,Y,Z) = X ^ Y ^ Z, constant 0x6ED9EBA1
            for k in 0..<16 {
                let h = b ^ c ^ d
                a = rotateLeft(a &+ h &+ x[round3Index[k]] &+ 0x6ed9_eba1, round3Shift[k % 4])
                (a, b, c, d) = (d, a, b, c)
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
        }

        var out = Data()
        for v in [h0, h1, h2, h3] {
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    @inline(__always)
    private static func rotateLeft(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x &<< n) | (x &>> (32 &- n))
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
