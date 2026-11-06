import Foundation
import SystemConfiguration
import CoreFoundation

/// Proxy routing bridge (FluxDown PAC / auto-proxy model).
///
/// Reads the system proxy configuration (including PAC / "Auto Proxy Discovery"
/// settings) via `CFNetworkCopySystemProxySettings`, resolves a host's proxy
/// decision through `PACResolver`, and produces a `connectionProxyDictionary`
/// for `URLSessionConfiguration`. Engines apply the result per-host so corporate
/// / school proxy environments are honoured like a browser.
///
/// Loopback hosts (`localhost`, `127.0.0.1`, `::1`) always return `DIRECT` — they
/// never need a proxy, and short-circuiting avoids touching the system proxy
/// store for local traffic.
public final class ProxyRouter: @unchecked Sendable {
    public static let shared = ProxyRouter()

    private static let enabledKey = "Siphon.proxyPACEnabled"

    private let lock = NSLock()
    private var pacResolver: PACResolver?
    private var pacURLString: String?
    private var loadedPacURLString: String?

    private init() {}

    /// Whether PAC / system-proxy routing is enabled. Defaults to off: reading
    /// the system proxy store can block (notably in sandboxed/headless contexts),
    /// so it is opt-in and only touched for non-loopback hosts.
    public var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// Whether `host` is a loopback / local address that must go DIRECT.
    private static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]" {
            return true
        }
        return h.hasSuffix(".local")
    }

    /// The configured PAC URL from system settings, if any.
    public var systemPACURL: URL? {
        guard let dict = Self.copySystemProxies(),
              let s = dict[kSCPropNetProxiesProxyAutoConfigURLString as String] as? String else {
            return nil
        }
        return URL(string: s)
    }

    /// A fixed HTTP/HTTPS/SOCKS proxy from system settings (non-PAC).
    public var systemProxy: (host: String, port: Int, https: Bool)? {
        guard let dict = Self.copySystemProxies() else { return nil }
        if let host = dict[kSCPropNetProxiesHTTPSProxy as String] as? String,
           let port = dict[kSCPropNetProxiesHTTPSPort as String] as? Int, !host.isEmpty {
            return (host, port, true)
        }
        if let host = dict[kSCPropNetProxiesHTTPProxy as String] as? String,
           let port = dict[kSCPropNetProxiesHTTPPort as String] as? Int, !host.isEmpty {
            return (host, port, false)
        }
        return nil
    }

    /// Resolve the proxy dictionary for a URL, honouring a configured PAC script
    /// (system or user-supplied). Returns `nil` for `DIRECT` (no proxy).
    public func proxyDictionary(for url: URL) -> [String: Any]? {
        guard enabled else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        if Self.isLoopback(host) { return nil }

        lock.lock()
        let resolver = ensureResolver()
        lock.unlock()

        // Prefer PAC resolution when a script is available.
        if let resolver {
            for directive in resolver.resolve(url) {
                switch directive {
                case .direct:
                    return nil
                case .proxy(let h, let p), .http(let h, let p), .https(let h, let p):
                    return ["HTTPProxy": h, "HTTPPort": p,
                            "HTTPSProxy": h, "HTTPSPort": p,
                            "HTTPEnable": 1, "HTTPSEnable": 1]
                case .socks(let h, let p, _):
                    return ["SOCKSProxy": h, "SOCKSPort": p, "SOCKSEnable": 1]
                }
            }
        }
        // Fall back to a static system proxy, if any.
        if let sp = systemProxy {
            if sp.https {
                return ["HTTPSProxy": sp.host, "HTTPSPort": sp.port, "HTTPSEnable": 1]
            }
            return ["HTTPProxy": sp.host, "HTTPPort": sp.port, "HTTPEnable": 1]
        }
        return nil
    }

    /// Configure a `URLSessionConfiguration` with the resolved proxy for `url`.
    /// Returns true when a proxy was applied.
    @discardableResult
    public func applyProxy(to config: URLSessionConfiguration, for url: URL) -> Bool {
        guard let dict = proxyDictionary(for: url) else { return false }
        config.connectionProxyDictionary = dict
        return true
    }

    /// (Re)load the PAC script. Reads the system PAC URL unless a custom URL is
    /// supplied (for testing / manual override).
    public func loadPAC(from url: URL? = nil, scriptText: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let scriptText {
            pacResolver = PACResolver(script: scriptText)
            pacURLString = url?.absoluteString
            loadedPacURLString = url?.absoluteString
            return true
        }
        guard let pacURL = url ?? systemPACURL else { return false }
        guard let data = try? Data(contentsOf: pacURL),
              let script = String(data: data, encoding: .utf8) else { return false }
        pacResolver = PACResolver(script: script)
        pacURLString = pacURL.absoluteString
        loadedPacURLString = pacURL.absoluteString
        return true
    }

    private func ensureResolver() -> PACResolver? {
        if pacResolver == nil { _ = loadPAC() }
        return pacResolver
    }

    /// Non-blocking system proxy read via `CFNetworkCopySystemProxySettings`,
    /// which returns the current proxy dictionary without blocking on the
    /// dynamic store (unlike `SCDynamicStoreCopyProxies`).
    private static func copySystemProxies() -> [String: Any]? {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
                as? [String: Any] else { return nil }
        return dict
    }
}
