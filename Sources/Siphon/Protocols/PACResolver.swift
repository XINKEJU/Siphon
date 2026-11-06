import Foundation
import JavaScriptCore

/// PAC (Proxy Auto-Config) resolver — FluxDown `pac_js.rs` model, implemented on
/// macOS's built-in JavaScriptCore instead of a bundled QuickJS runtime.
///
/// A PAC script defines `FindProxyForURL(url, host) -> String`. The returned
/// directive string is a `;`-separated list of fallbacks, e.g.
/// `"PROXY proxy.example:8080; DIRECT"` or `"SOCKS5 127.0.0.1:1080"`.
///
/// We parse it into an ordered list of `ProxyDirective`s; callers walk the list
/// and use the first entry the network stack supports. This lets a download
/// route through a corporate/school proxy exactly like a browser would.
public final class PACResolver {
    /// One parsed directive from a PAC result.
    public enum Directive: Equatable {
        /// `PROXY host:port` — HTTP/HTTPS proxy.
        case proxy(host: String, port: Int)
        /// `SOCKS` / `SOCKS5` / `SOCKS4` — SOCKS proxy.
        case socks(host: String, port: Int, version: Int)
        /// `HTTP host:port` — same as PROXY.
        case http(host: String, port: Int)
        /// `HTTPS host:port` — HTTPS proxy.
        case https(host: String, port: Int)
        /// `DIRECT` — no proxy.
        case direct

        /// Whether the directive is `DIRECT` (the terminal "no proxy" fallback).
        public var isDirect: Bool { self == .direct }
    }

    private let context: JSContext

    /// Load a PAC script from its text content.
    public init(script: String) {
        let ctx = JSContext()!
        // PAC scripts reference a handful of helper functions (dnsDomainIs,
        // isPlainHostName, shExpMatch, …). Define them as plain JavaScript so
        // real-world scripts don't throw on undefined helpers. `shExpMatch`
        // implements shell-style wildcard matching (`*` / `?`).
        ctx.evaluateScript("""
        function isPlainHostName(host) { return host.indexOf('.') < 0; }
        function dnsDomainIs(host, domain) {
            return host === domain || host.lastIndexOf('.' + domain) === host.length - domain.length - 1;
        }
        function localHostOrDomainIs(host, domain) { return dnsDomainIs(host, domain); }
        function isResolvable(host) { return false; }
        function isInNet(host, pattern, mask) { return false; }
        function dnsResolve(host) { return host; }
        function myIpAddress() { return ''; }
        function weekdayRange() { return false; }
        function dateRange() { return false; }
        function timeRange() { return false; }
        function shExpMatch(str, pattern) {
            var re = '^' + pattern.replace(/\\./g, '\\\\.')
                .replace(/\\*/g, '.*').replace(/\\?/g, '.') + '$';
            return new RegExp(re, 'i').test(str);
        }
        """)
        ctx.evaluateScript(script)
        context = ctx
    }

    /// Resolve the proxy decision for a URL. Returns the ordered directive list,
    /// or an empty list if the script errored / returned nothing.
    public func resolve(_ url: URL) -> [Directive] {
        let host = url.host ?? ""
        guard let fn = context.objectForKeyedSubscript("FindProxyForURL"),
              !fn.isUndefined else { return [] }
        let result = fn.call(withArguments: [url.absoluteString, host])
        guard let raw = result?.toString() else { return [] }
        return Self.parse(raw)
    }

    /// Parse a PAC result string into directives. Handles `PROXY`, `HTTP`,
    /// `HTTPS`, `SOCKS`/`SOCKS5`/`SOCKS4` and `DIRECT`, ignoring whitespace and
    /// unknown tokens. Returns `[]` for a pure-`DIRECT` result's only caller
    /// convenience is `isDirect` on the parsed entry.
    public static func parse(_ result: String) -> [Directive] {
        var out: [Directive] = []
        for token in result.split(separator: ";") {
            let parts = token.split(separator: " ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let kind = parts.first?.uppercased() else { continue }
            switch kind {
            case "DIRECT":
                out.append(.direct)
            case "PROXY", "HTTP":
                if parts.count >= 2, let (h, p) = Self.splitHostPort(parts[1]) {
                    out.append(kind == "PROXY" ? .proxy(host: h, port: p) : .http(host: h, port: p))
                }
            case "HTTPS":
                if parts.count >= 2, let (h, p) = Self.splitHostPort(parts[1]) {
                    out.append(.https(host: h, port: p))
                }
            case "SOCKS", "SOCKS4", "SOCKS5":
                let version = kind == "SOCKS4" ? 4 : 5
                if parts.count >= 2, let (h, p) = Self.splitHostPort(parts[1]) {
                    out.append(.socks(host: h, port: p, version: version))
                }
            default:
                break
            }
        }
        return out
    }

    /// Split `host:port` (host may itself be an IPv6 literal `[::1]:8080`).
    private static func splitHostPort(_ s: String) -> (String, Int)? {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":"),
              let port = Int(s[s.index(after: colon)...]) else { return nil }
        let host = String(s[..<colon])
        return (host, port)
    }
}
