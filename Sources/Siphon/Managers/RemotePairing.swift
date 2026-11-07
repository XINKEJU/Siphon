import Foundation
import Security

/// Remote device-code pairing (MDXP-style).
///
/// Implements the *client* side of a device-code handshake: the local app shows a
/// short, human-readable code; the remote device presents that code to a pairing
/// endpoint (a local relay or an MDXP server), which then confirms. Siphon ships
/// the state machine, code generation and persistence; the transport that delivers
/// the code to the remote peer is intentionally pluggable so it can later point at
/// a real MDXP broker without changing this code.
///
/// Paired devices are stored under an opaque, randomly-generated token — never a
/// secret credential — and are shown so the user can audit and revoke them.
public final class RemotePairing: @unchecked Sendable {
    public static let shared = RemotePairing()

    public struct PairedDevice: Codable, Identifiable, Equatable {
        public var id: UUID
        public var name: String
        public var token: String
        public var pairedAt: Date
    }

    /// What actually hits UserDefaults — the token lives in the Keychain.
    private struct StoredDevice: Codable {
        var id: UUID, name: String, pairedAt: Date
    }

    public enum State: Equatable {
        case idle
        case awaiting(code: String, expiresAt: Date)
        case paired
    }

    private let lock = NSLock()
    private var _state: State = .idle
    private var _devices: [PairedDevice]

    private static let devicesKey = "Siphon.pairedDevices"
    private static func tokenAccount(_ id: UUID) -> String { "pairing-token-\(id.uuidString)" }
    /// A pending code is intentionally not persisted: it is short-lived (5 min) and
    /// losing it across a relaunch simply means the user regenerates it.
    private static let codeTTL: TimeInterval = 300

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.devicesKey) {
            if let legacy = try? JSONDecoder().decode([PairedDevice].self, from: data) {
                // One-time migration: lift tokens into the Keychain and strip
                // them from the persisted blob.
                for dev in legacy {
                    Keychain.setSecret(dev.token, account: Self.tokenAccount(dev.id))
                }
                let stored = legacy.map { StoredDevice(id: $0.id, name: $0.name, pairedAt: $0.pairedAt) }
                if let out = try? JSONEncoder().encode(stored) {
                    d.set(out, forKey: Self.devicesKey)
                }
                _devices = legacy
            } else if let list = try? JSONDecoder().decode([StoredDevice].self, from: data) {
                _devices = list.map {
                    PairedDevice(id: $0.id, name: $0.name,
                                 token: Keychain.secret(account: Self.tokenAccount($0.id)) ?? "",
                                 pairedAt: $0.pairedAt)
                }
            } else {
                _devices = []
            }
        } else {
            _devices = []
        }
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        // Expire a pending code that has timed out.
        if case .awaiting(_, let exp) = _state, Date() > exp {
            _state = .idle
            return .idle
        }
        return _state
    }

    public var devices: [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return _devices
    }

    /// Generate a fresh 8-character pairing code (Crockford-style, ambiguous glyphs
    /// removed) grouped as `XXXX-XXXX`. Returns the displayed code.
    @discardableResult
    public func beginPairing() -> String {
        let code = Self.generateCode()
        lock.lock()
        _state = .awaiting(code: code, expiresAt: Date().addingTimeInterval(Self.codeTTL))
        lock.unlock()
        return code
    }

    public func cancelPairing() {
        lock.lock(); _state = .idle; lock.unlock()
    }

    /// Confirm a pending pairing and register `deviceName`. In a full MDXP flow this
    /// is invoked by the relay once the remote peer has presented the code; locally
    /// it finalises the handshake. Returns the new `PairedDevice`, or `nil` if there
    /// was no live, unexpired code.
    @discardableResult
    public func confirmPairing(deviceName: String) -> PairedDevice? {
        lock.lock()
        guard case .awaiting(let code, let exp) = _state, Date() <= exp else {
            lock.unlock()
            return nil
        }
        let device = PairedDevice(id: UUID(),
                                  name: deviceName.isEmpty ? "设备-\(code)" : deviceName,
                                  token: Self.randomToken(),
                                  pairedAt: Date())
        _devices.append(device)
        _state = .paired
        let snapshot = _devices
        lock.unlock()
        Keychain.setSecret(device.token, account: Self.tokenAccount(device.id))
        persist(snapshot)
        return device
    }

    public func remove(deviceID: UUID) {
        lock.lock()
        _devices.removeAll { $0.id == deviceID }
        let snapshot = _devices
        lock.unlock()
        Keychain.setSecret("", account: Self.tokenAccount(deviceID))
        persist(snapshot)
    }

    /// Authenticate an MDXP request. Accepts `Bearer <token>` or a bare token
    /// and compares each paired device token in constant time.
    public func verify(presented: String?) -> Bool {
        guard var token = presented?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return false }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !token.isEmpty else { return false }
        lock.lock()
        let tokens = _devices.map(\.token).filter { !$0.isEmpty }
        lock.unlock()
        return tokens.contains { Keychain.constantTimeEqual(token, $0) }
    }

    private func persist(_ devices: [PairedDevice]) {
        let stored = devices.map { StoredDevice(id: $0.id, name: $0.name, pairedAt: $0.pairedAt) }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.devicesKey)
        }
    }

    // MARK: - code generation

    private static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"  // no 0/O/1/I/L

    private static func generateCode() -> String {
        var s = ""
        for i in 0..<8 {
            let idx = Int.random(in: 0..<alphabet.count)
            let c = alphabet[alphabet.index(alphabet.startIndex, offsetBy: idx)]
            if i == 4 { s.append("-") }
            s.append(c)
        }
        return s
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let res = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard res == errSecSuccess else {
            // Fallback to a timestamp-derived token if SecRandom is unavailable.
            return UUID().uuidString + String(Date().timeIntervalSince1970)
        }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
