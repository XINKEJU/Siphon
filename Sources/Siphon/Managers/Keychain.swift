import Foundation
import Security

/// Generic-password helper shared by every stored secret (S3 key, local API token).
public enum Keychain {
    public static func secret(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setSecret(_ value: String, account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            SecItemDelete(q as CFDictionary)
            return true
        }
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecSuccess
        }
        var add = q
        add.merge(attrs) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// CSPRNG token, 32 bytes, base64.
    public static func randomToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { return nil }
        return Data(bytes).base64EncodedString()
    }

    /// Length-independent comparison so response timing can't leak the secret.
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = a.utf8.map(Int.init), y = b.utf8.map(Int.init)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    private static let service = "com.xinkeju.siphon.macos"
}
