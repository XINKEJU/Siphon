import Foundation

/// Bearer token guarding the loopback control surfaces (REST :17801, MCP :17802).
///
/// Loopback-only binding stops remote hosts, but any web page in any browser can
/// still *send* cross-origin POSTs to 127.0.0.1 (a "simple request" needs no
/// preflight), and with the old `Access-Control-Allow-Origin: *` it could also
/// read the task list back — including task URLs that embed credentials. A
/// per-install bearer token closes both: pages cannot attach an Authorization
/// header without a preflight (which now fails), and cannot read responses
/// without a CORS grant.
public enum LocalAuthToken {
    private static let account = "local-api-token"
    private static let lock = NSLock()
    private static var cached: String?

    /// Test seam: when non-nil it replaces Keychain-backed storage entirely, so
    /// CLI test binaries never touch the login keychain.
    nonisolated(unsafe) public static var testingToken: String?

    /// GUI end-to-end seam: the restart-verification script launches the app with
    /// this environment variable so the app never reads the login keychain (a
    /// freshly ad-hoc-signed build would raise a system permission dialog there,
    /// stalling the test behind a modal prompt).
    private static let environmentOverride =
        ProcessInfo.processInfo.environment["SIPHON_LOCAL_API_TOKEN"]

    /// Loads the token, generating and persisting one on first use.
    public static func current() -> String {
        lock.lock(); defer { lock.unlock() }
        if let testingToken { return testingToken }
        if let environmentOverride, !environmentOverride.isEmpty { return environmentOverride }
        if let cached { return cached }
        if let stored = Keychain.secret(account: account), !stored.isEmpty {
            cached = stored
            return stored
        }
        let fresh = Keychain.randomToken() ?? UUID().uuidString
        cached = fresh
        Keychain.setSecret(fresh, account: account)
        return fresh
    }

    /// Replaces the token (Settings "rotate"). Callers must re-read `current()`.
    @discardableResult
    public static func rotate() -> String {
        lock.lock(); defer { lock.unlock() }
        if let environmentOverride, !environmentOverride.isEmpty {
            cached = environmentOverride
            return environmentOverride
        }
        let fresh = Keychain.randomToken() ?? UUID().uuidString
        if testingToken == nil {
            Keychain.setSecret(fresh, account: account)
        } else {
            testingToken = fresh
        }
        cached = fresh
        return fresh
    }

    /// Accepts both `Authorization: Bearer <token>` and the bare token.
    public static func verify(_ presented: String?) -> Bool {
        guard let presented, !presented.isEmpty else { return false }
        let candidate = presented.hasPrefix("Bearer ")
            ? String(presented.dropFirst(7)) : presented
        return Keychain.constantTimeEqual(candidate, current())
    }
}
