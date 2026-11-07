import Foundation
import SystemConfiguration
import CoreFoundation

/// Manual proxy configuration (HTTP or SOCKS5).
public struct ManualProxy: Codable, Equatable, Sendable {
    public enum ProxyType: String, Codable, Sendable {
        case http, socks5
    }
    public var type: ProxyType = .http
    public var host: String = ""
    public var port: Int = 0
    public var username: String = ""
    public var password: String = ""

    public init() {}

    public var isValid: Bool {
        !host.isEmpty && port > 0 && port <= 65535
    }

    /// URLSession `connectionProxyDictionary` for this manual proxy.
    public var proxyDictionary: [String: Any] {
        var dict: [String: Any] = [:]
        switch type {
        case .http:
            dict["HTTPProxy"] = host
            dict["HTTPPort"] = port
            dict["HTTPSProxy"] = host
            dict["HTTPSPort"] = port
            dict["HTTPEnable"] = 1
            dict["HTTPSEnable"] = 1
        case .socks5:
            dict["SOCKSProxy"] = host
            dict["SOCKSPort"] = port
            dict["SOCKSEnable"] = 1
        }
        if !username.isEmpty {
            // SOCKS and HTTP proxy auth use the same keys in URLSession.
            dict["SOCKSUsername"] = username
            dict["SOCKSPassword"] = password
            dict["HTTPUsername"] = username
            dict["HTTPPassword"] = password
        }
        return dict
    }
}

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
///
/// Manual proxy (HTTP/SOCKS5) takes priority over system PAC when enabled.
public final class ProxyRouter: @unchecked Sendable {
    public static let shared = ProxyRouter()

    private static let enabledKey = "Siphon.proxyPACEnabled"
    private static let manualEnabledKey = "Siphon.manualProxyEnabled"
    private static let manualProxyKey = "Siphon.manualProxy"

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

    /// Whether a manually configured proxy (HTTP/SOCKS5) is active.
    public var manualEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.manualEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.manualEnabledKey) }
    }

    /// The manually configured proxy, if any.
    public var manualProxy: ManualProxy {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.manualProxyKey),
                  let p = try? JSONDecoder().decode(ManualProxy.self, from: data) else {
                return ManualProxy()
            }
            return p
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.manualProxyKey)
            }
        }
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
    /// Manual proxy (HTTP/SOCKS5) takes priority over system PAC when enabled.
    public func proxyDictionary(for url: URL) -> [String: Any]? {
        guard let host = url.host, !host.isEmpty else { return nil }
        if Self.isLoopback(host) { return nil }

        // Manual proxy has highest priority when enabled and valid.
        if manualEnabled {
            let mp = manualProxy
            if mp.isValid { return mp.proxyDictionary }
        }

        guard enabled else { return nil }

        // loadPAC takes the same lock — release around it (NSLock is not
        // reentrant; calling it while held would deadlock).
        lock.lock()
        if pacResolver == nil {
            lock.unlock()
            _ = loadPAC()
            lock.lock()
        }
        let resolver = pacResolver
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
    /// supplied (for testing / manual override). Remote (http/https) PAC URLs
    /// are fetched off-thread and cached — a synchronous `Data(contentsOf:)`
    /// here used to block engine session setup on a network round-trip.
    @discardableResult
    public func loadPAC(from url: URL? = nil, scriptText: String? = nil) -> Bool {
        if let scriptText {
            lock.lock()
            pacResolver = PACResolver(script: scriptText)
            pacURLString = url?.absoluteString
            loadedPacURLString = url?.absoluteString
            lock.unlock()
            return true
        }
        guard let pacURL = url ?? systemPACURL else { return false }
        switch pacURL.scheme?.lowercased() {
        case "http", "https":
            lock.lock()
            pacURLString = pacURL.absoluteString
            let needsFetch = loadedPacURLString != pacURL.absoluteString
                || Date().timeIntervalSince(lastPACFetch) > Self.pacRefreshInterval
            lock.unlock()
            if needsFetch { Task { await refreshRemotePAC(pacURL) } }
            let haveScript = pacResolver != nil
            lock.unlock()
            return haveScript
        default:
            // file:// and custom schemes: local read, safe inline.
            guard let data = try? Data(contentsOf: pacURL),
                  let script = String(data: data, encoding: .utf8) else { return false }
            lock.lock()
            pacResolver = PACResolver(script: script)
            pacURLString = pacURL.absoluteString
            loadedPacURLString = pacURL.absoluteString
            lock.unlock()
            return true
        }
    }

    private static let pacRefreshInterval: TimeInterval = 300
    private var lastPACFetch = Date.distantPast

    private func refreshRemotePAC(_ url: URL) async {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let script = String(data: data, encoding: .utf8) else { return }
        storeRemotePAC(script, urlString: url.absoluteString)
    }

    /// Lock application lives in a sync method: an async context resuming on an
    /// arbitrary executor may not lock/unlock across threads.
    private func storeRemotePAC(_ script: String, urlString: String) {
        lock.lock()
        pacResolver = PACResolver(script: script)
        loadedPacURLString = urlString
        lastPACFetch = Date()
        lock.unlock()
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
