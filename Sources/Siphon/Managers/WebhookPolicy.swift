import Foundation

/// URL and payload policy for task-event webhooks.
///
/// A webhook endpoint used to be any string with `scheme != nil`: `file://`,
/// `http://169.254.169.254/…` and private-network URLs were all accepted, and
/// `URLSession.shared` silently followed redirects into those networks. The
/// payload also carried the raw task URL, which can embed Basic credentials or
/// an S3 presigned URL. This centralises the allow-list, redirect policy and
/// redaction so the same rules apply to direct posts and to every redirect hop.
public enum WebhookPolicy {
    public static let allowPrivateKey = "Siphon.webhooksAllowPrivate"

    /// Accept only HTTP(S) URLs with no embedded credentials. Private, loopback
    /// and link-local hosts are refused unless the user explicitly opts in
    /// (Settings → 集成 → Webhook), which is needed for local relay scripts.
    public static func isAllowed(_ raw: String, allowPrivate: Bool = false) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        if !allowPrivate && isPrivateHost(host) { return nil }
        return url
    }

    public static func isAllowed(_ url: URL, allowPrivate: Bool = false) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return allowPrivate || !isPrivateHost(host)
    }

    /// Literal loopback / private / link-local / metadata hosts and names.
    public static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost")
            || h.hasSuffix(".local") || h.hasSuffix(".internal")
            || h == "metadata.google.internal" || h == "::1"
            || h.hasPrefix("fd") || h.hasPrefix("fe80") { return true }
        let octets = h.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        if [0, 10, 127].contains(octets[0]) { return true }
        if octets[0] == 169 && octets[1] == 254 { return true }  // cloud metadata
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 100 && (64...127).contains(octets[1]) { return true }
        return false
    }

    /// Strip credentials and sensitive query parameters before the task URL is
    /// put in an outbound JSON payload.
    public static func redact(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw) else { return raw }
        comps.user = nil
        comps.password = nil
        if let items = comps.queryItems, !items.isEmpty {
            let sensitive: Set<String> = [
                "token", "sig", "signature", "key", "api_key", "access_key",
                "auth", "authorization", "password", "credential",
                "x-amz-signature", "x-amz-credential", "x-amz-security-token",
            ]
            comps.queryItems = items.map { item in
                sensitive.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: "REDACTED") : item
            }
        }
        return comps.string ?? raw
    }
}
