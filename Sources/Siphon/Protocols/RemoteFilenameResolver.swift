import Foundation

/// Best-effort filename discovery for URLs whose path carries no usable name
/// (`/download?id=123`, `/file/`). Sends HEAD first, then a 1-byte ranged GET
/// for servers that reject HEAD, and reads `Content-Disposition` (RFC 6266).
public enum RemoteFilenameResolver {
    /// Header keys worth forwarding to the probe. Engine options also contain
    /// aria2 keys (`dir`, `out`, …) which are not valid HTTP headers.
    private static let forwardedHeaders: Set<String> = [
        "user-agent", "referer", "cookie", "authorization", "accept", "accept-language"
    ]

    public static func suggestedName(for url: URL,
                                     options: [String: String],
                                     timeout: TimeInterval = 5) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        if let name = await probe(url, options: options, method: "HEAD", timeout: timeout) {
            return name
        }
        return await probe(url, options: options, method: "GET", timeout: timeout)
    }

    private static func probe(_ url: URL, options: [String: String],
                              method: String, timeout: TimeInterval) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
        for (key, value) in options where forwardedHeaders.contains(key.lowercased()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else { return nil }
        return ContentDisposition.filename(from: http.value(forHTTPHeaderField: "Content-Disposition"))
    }
}
