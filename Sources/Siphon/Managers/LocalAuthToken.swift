import Foundation
// SwiftPM builds SiphonBridge as a separate module; the CLI regression suite
// compiles all sources into one module, where the symbols are already visible.
#if canImport(SiphonBridge)
import SiphonBridge
#endif

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

    /// Test seam: when non-nil it replaces file-backed storage entirely, so
    /// CLI test binaries never touch the login keychain or the real support dir.
    nonisolated(unsafe) public static var testingToken: String?

    /// GUI end-to-end seam: the restart-verification script launches the app with
    /// this environment variable so the app never reads the login keychain (a
    /// freshly ad-hoc-signed build would raise a system permission dialog there,
    /// stalling the test behind a modal prompt).
    private static let environmentOverride =
        ProcessInfo.processInfo.environment["SIPHON_LOCAL_API_TOKEN"]

    /// Loads the token, generating and persisting one on first use.
    ///
    /// Storage is a 0600 file (via `LocalAuthBootstrap`), not the login
    /// keychain: an ad-hoc-signed app gets a new CDHash on every rebuild, and
    /// keychain ACL checks against the old signature raise a modal "wants to
    /// use secret info" prompt on every launch after reinstalling. The
    /// keychain remains only for user-configured secrets (webhook, pairing…)
    /// where a one-time prompt after reinstall is acceptable.
    public static func current() -> String {
        lock.lock(); defer { lock.unlock() }
        if let testingToken { return testingToken }
        if let environmentOverride, !environmentOverride.isEmpty { return environmentOverride }
        if let cached { return cached }
        // One-time migration away from the keychain. Reading an item the
        // current binary does not trust (any reinstall of an ad-hoc-signed
        // build) would raise the modal keychain prompt, so the old value is
        // deliberately NOT read out — the existence probe asks for no secret
        // data and therefore cannot prompt. Losing the old token only means
        // the freshly generated one rotates it, which propagates to the NM
        // gateway through the bootstrap file automatically.
        if Keychain.hasSecret(account: account) {
            Keychain.setSecret("", account: account)
        }
        if let stored = LocalAuthBootstrap.read() {
            cached = stored
            return stored
        }
        let fresh = Keychain.randomToken() ?? UUID().uuidString
        cached = fresh
        LocalAuthBootstrap.publish(fresh)
        return fresh
    }

    /// Ensure the out-of-band bootstrap file exists (e.g. when the control
    /// interface is enabled, or the user deleted the file). Never sends the
    /// token over the loopback socket.
    @discardableResult
    public static func publishBootstrapFile() -> URL? {
        guard testingToken == nil, environmentOverride?.isEmpty ?? true else { return nil }
        return LocalAuthBootstrap.publish(current())
    }

    /// Remove the bootstrap file when the control interface is switched off.
    public static func unpublishBootstrapFile() {
        guard testingToken == nil else { return }
        LocalAuthBootstrap.remove()
    }

    /// Shown in Settings so users can locate the file if the gateway cannot.
    public static var bootstrapFileURL: URL { LocalAuthBootstrap.fileURL() }

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
            LocalAuthBootstrap.publish(fresh)
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
