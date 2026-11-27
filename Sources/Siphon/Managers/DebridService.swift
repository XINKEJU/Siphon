import Foundation
import Observation

public struct DebridLink: Sendable, Equatable {
    public var url: URL
    public var fileName: String?
    public var size: Int64?
    public var expires: Date?

    public init(url: URL, fileName: String? = nil, size: Int64? = nil, expires: Date? = nil) {
        self.url = url
        self.fileName = fileName
        self.size = size
        self.expires = expires
    }
}

public struct DebridAccount: Sendable, Equatable {
    public var username: String
    public var isPremium: Bool
    public var expires: Date?

    public init(username: String, isPremium: Bool, expires: Date? = nil) {
        self.username = username
        self.isPremium = isPremium
        self.expires = expires
    }
}

public enum DebridError: Error, LocalizedError, Equatable {
    case missingToken
    case unauthorized
    case premiumRequired
    case quotaExceeded
    case unsupportedLink(String)
    case upstream(String)
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: return "尚未填写该网盘服务的 Token"
        case .unauthorized: return "Token 无效或已过期"
        case .premiumRequired: return "该链接需要高级账户"
        case .quotaExceeded: return "流量额度已用尽"
        case .unsupportedLink(let s): return "不支持的链接：\(s)"
        case .upstream(let s): return "服务返回错误：\(s)"
        case .parse(let s): return "响应无法解析：\(s)"
        }
    }
}

/// One premium-link resolver. Implementations are stateless structs; the token
/// always arrives from the Keychain, never from disk preferences.
public protocol DebridProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var signupURL: URL { get }
    /// Build the network request for unrestricting `link`; exposed for tests.
    func unrestrictRequest(link: URL, token: String) throws -> URLRequest
    func parseUnrestrict(_ data: Data) throws -> DebridLink
    func accountRequest(token: String) -> URLRequest
    func parseAccount(_ data: Data) throws -> DebridAccount
}

public extension DebridProvider {
    func unrestrict(_ link: URL, token: String, session: URLSession = .shared) async throws -> DebridLink {
        guard !token.isEmpty else { throw DebridError.missingToken }
        let request = try unrestrictRequest(link: link, token: token)
        let (data, response) = try await send(request, session: session)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw DebridError.unauthorized
            case 429: throw DebridError.quotaExceeded
            default: throw DebridError.upstream("HTTP \(http.statusCode)")
            }
        }
        return try parseUnrestrict(data)
    }

    func account(token: String, session: URLSession = .shared) async throws -> DebridAccount {
        guard !token.isEmpty else { throw DebridError.missingToken }
        let (data, response) = try await send(accountRequest(token: token), session: session)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw DebridError.unauthorized }
            throw DebridError.upstream("HTTP \(http.statusCode)")
        }
        return try parseAccount(data)
    }

    func send(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw DebridError.upstream(error.localizedDescription)
        }
    }
}

// MARK: - JSON helpers

enum DebridJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DebridError.parse("不是 JSON 对象")
        }
        return obj
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: s)
        }
        if let n = int64(value), n > 0 {
            return Date(timeIntervalSince1970: TimeInterval(n))
        }
        return nil
    }
}

// MARK: - Real-Debrid

public struct RealDebridProvider: DebridProvider {
    public let id = "real-debrid"
    public let displayName = "Real-Debrid"
    public let signupURL = URL(string: "https://real-debrid.com")!

    public init() {}

    public func unrestrictRequest(link: URL, token: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/unrestrict/link")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "link=\(Self.encode(link.absoluteString))".data(using: .utf8)
        return req
    }

    public func parseUnrestrict(_ data: Data) throws -> DebridLink {
        let obj = try DebridJSON.object(data)
        guard let download = obj["download"] as? String, let url = URL(string: download) else {
            throw DebridError.unsupportedLink(obj["error"] as? String ?? "no download field")
        }
        return DebridLink(url: url,
                          fileName: obj["filename"] as? String,
                          size: DebridJSON.int64(obj["filesize"]))
    }

    public func accountRequest(token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    public func parseAccount(_ data: Data) throws -> DebridAccount {
        let obj = try DebridJSON.object(data)
        return DebridAccount(username: obj["username"] as? String ?? "Real-Debrid",
                             isPremium: (obj["type"] as? String) == "premium",
                             expires: DebridJSON.date(obj["expiration"]))
    }

    static func encode(_ s: String) -> String {
        // `URL.absoluteString` is already percent-encoded; decode first so the
        // form body carries a single, unambiguous encoding layer. Keep the
        // unreserved set (`-._~`) literal so URLs stay readable.
        let decoded = s.removingPercentEncoding ?? s
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return decoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? decoded
    }
}

// MARK: - AllDebrid

public struct AllDebridProvider: DebridProvider {
    public let id = "alldebrid"
    public let displayName = "AllDebrid"
    public let signupURL = URL(string: "https://alldebrid.com")!
    private let agent = "siphon"

    public init() {}

    public func unrestrictRequest(link: URL, token: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.alldebrid.com/v4/link/unlock?agent=\(agent)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "link=\(RealDebridProvider.encode(link.absoluteString))".data(using: .utf8)
        return req
    }

    public func parseUnrestrict(_ data: Data) throws -> DebridLink {
        let obj = try DebridJSON.object(data)
        if (obj["status"] as? String) != "success" {
            let error = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
            throw DebridError.unsupportedLink(error)
        }
        guard let body = obj["data"] as? [String: Any],
              let linkText = body["link"] as? String,
              let url = URL(string: linkText) else {
            throw DebridError.parse("missing data.link")
        }
        return DebridLink(url: url,
                          fileName: body["filename"] as? String,
                          size: DebridJSON.int64(body["size"]))
    }

    public func accountRequest(token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.alldebrid.com/v4/user?agent=\(agent)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    public func parseAccount(_ data: Data) throws -> DebridAccount {
        let obj = try DebridJSON.object(data)
        let body = obj["data"] as? [String: Any] ?? [:]
        let user = body["user"] as? [String: Any] ?? [:]
        return DebridAccount(username: user["username"] as? String ?? "AllDebrid",
                             isPremium: (user["isPremium"] as? Bool) ?? false,
                             expires: DebridJSON.date(user["premiumUntil"]))
    }
}

// MARK: - Premiumize

public struct PremiumizeProvider: DebridProvider {
    public let id = "premiumize"
    public let displayName = "Premiumize"
    public let signupURL = URL(string: "https://premiumize.me")!

    public init() {}

    public func unrestrictRequest(link: URL, token: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://www.premiumize.me/api/transfer/directdl")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "src=\(RealDebridProvider.encode(link.absoluteString))".data(using: .utf8)
        return req
    }

    public func parseUnrestrict(_ data: Data) throws -> DebridLink {
        let obj = try DebridJSON.object(data)
        guard (obj["status"] as? String) == "success",
              let content = obj["content"] as? [[String: Any]],
              let first = content.first,
              let linkText = first["link"] as? String,
              let url = URL(string: linkText) else {
            throw DebridError.unsupportedLink(obj["message"] as? String ?? "no content")
        }
        let path = first["path"] as? String
        return DebridLink(url: url,
                          fileName: path.map { ($0 as NSString).lastPathComponent },
                          size: DebridJSON.int64(first["size"]))
    }

    public func accountRequest(token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://www.premiumize.me/api/account/info")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    public func parseAccount(_ data: Data) throws -> DebridAccount {
        let obj = try DebridJSON.object(data)
        let until = DebridJSON.int64(obj["premium_until"])
        return DebridAccount(username: (obj["customer_id"] as? String) ?? "Premiumize",
                             isPremium: (until ?? 0) > Int64(Date().timeIntervalSince1970),
                             expires: until.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

// MARK: - TorBox

public struct TorBoxProvider: DebridProvider {
    public let id = "torbox"
    public let displayName = "TorBox"
    public let signupURL = URL(string: "https://torbox.app")!

    public init() {}

    public func unrestrictRequest(link: URL, token: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.torbox.app/v1/api/webdl/createwebdownload")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "url=\(RealDebridProvider.encode(link.absoluteString))".data(using: .utf8)
        return req
    }

    public func parseUnrestrict(_ data: Data) throws -> DebridLink {
        let obj = try DebridJSON.object(data)
        guard (obj["success"] as? Bool) == true,
              let body = obj["data"] as? [String: Any],
              let linkText = body["download_url"] as? String,
              let url = URL(string: linkText) else {
            throw DebridError.unsupportedLink(obj["detail"] as? String ?? "no download_url")
        }
        return DebridLink(url: url,
                          fileName: body["name"] as? String,
                          size: DebridJSON.int64(body["size"]))
    }

    public func accountRequest(token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.torbox.app/v1/api/user/me")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    public func parseAccount(_ data: Data) throws -> DebridAccount {
        let obj = try DebridJSON.object(data)
        let body = obj["data"] as? [String: Any] ?? [:]
        let plan = DebridJSON.int64(body["plan"]) ?? 0
        return DebridAccount(username: body["email"] as? String ?? "TorBox",
                             isPremium: plan > 0,
                             expires: DebridJSON.date(body["premium_expires_at"]))
    }
}

// MARK: - Mega-Debrid

public struct MegaDebridProvider: DebridProvider {
    public let id = "mega-debrid"
    public let displayName = "Mega-Debrid"
    public let signupURL = URL(string: "https://www.mega-debrid.eu")!

    public init() {}

    public func unrestrictRequest(link: URL, token: String) throws -> URLRequest {
        var comps = URLComponents(string: "https://www.mega-debrid.eu/api.php")!
        comps.queryItems = [
            URLQueryItem(name: "action", value: "getLink"),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "link", value: link.absoluteString),
        ]
        return URLRequest(url: comps.url!)
    }

    public func parseUnrestrict(_ data: Data) throws -> DebridLink {
        let obj = try DebridJSON.object(data)
        guard (DebridJSON.int64(obj["response_code"]) ?? 0) == 200,
              let linkText = obj["link"] as? String,
              let url = URL(string: linkText) else {
            throw DebridError.unsupportedLink(obj["error"] as? String ?? "no link")
        }
        return DebridLink(url: url,
                          fileName: obj["filename"] as? String,
                          size: DebridJSON.int64(obj["size"]))
    }

    public func accountRequest(token: String) -> URLRequest {
        var comps = URLComponents(string: "https://www.mega-debrid.eu/api.php")!
        comps.queryItems = [
            URLQueryItem(name: "action", value: "getHostersList"),
            URLQueryItem(name: "token", value: token),
        ]
        return URLRequest(url: comps.url!)
    }

    public func parseAccount(_ data: Data) throws -> DebridAccount {
        let obj = try DebridJSON.object(data)
        let ok = (DebridJSON.int64(obj["response_code"]) ?? 0) == 200
        guard ok else { throw DebridError.unauthorized }
        return DebridAccount(username: "Mega-Debrid", isPremium: true)
    }
}

// MARK: - Service

/// Holds the enabled state, the preferred provider and the Keychain tokens, and
/// keeps a per-host online/offline cache so the UI can show live availability.
@MainActor
@Observable
public final class DebridService {
    public static let shared = DebridService()

    public let providers: [any DebridProvider] = [
        RealDebridProvider(), AllDebridProvider(), PremiumizeProvider(),
        TorBoxProvider(), MegaDebridProvider(),
    ]

    public enum HostStatus: String, Sendable {
        case unknown, online, offline
    }

    public private(set) var hostStatus: [String: HostStatus] = [:]
    public private(set) var lastError: String?

    public var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "Siphon.debrid.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "Siphon.debrid.enabled") }
    }

    public var preferredProviderID: String? {
        get { UserDefaults.standard.string(forKey: "Siphon.debrid.provider") }
        set { UserDefaults.standard.set(newValue, forKey: "Siphon.debrid.provider") }
    }

    private init() {}

    public func provider(id: String) -> (any DebridProvider)? {
        providers.first { $0.id == id }
    }

    public var preferredProvider: (any DebridProvider)? {
        preferredProviderID.flatMap(provider(id:))
    }

    // MARK: Credentials

    public func token(for providerID: String) -> String {
        Keychain.secret(account: "debrid.\(providerID)") ?? ""
    }

    public func setToken(_ token: String, for providerID: String) -> Bool {
        Keychain.setSecret(token.trimmingCharacters(in: .whitespacesAndNewlines),
                           account: "debrid.\(providerID)")
    }

    public func hasToken(for providerID: String) -> Bool { !token(for: providerID).isEmpty }

    // MARK: Resolution

    public func unrestrict(_ link: URL, providerID: String? = nil,
                           session: URLSession = .shared) async throws -> DebridLink {
        guard let provider = providerID.flatMap(provider(id:)) ?? preferredProvider else {
            throw DebridError.missingToken
        }
        let token = token(for: provider.id)
        do {
            let resolved = try await provider.unrestrict(link, token: token, session: session)
            hostStatus[link.host ?? ""] = .online
            return resolved
        } catch {
            lastError = error.localizedDescription
            if case DebridError.upstream = error {
                hostStatus[link.host ?? ""] = .offline
            }
            throw error
        }
    }

    public func testAccount(providerID: String, session: URLSession = .shared) async throws -> DebridAccount {
        guard let provider = provider(id: providerID) else {
            throw DebridError.missingToken
        }
        return try await provider.account(token: token(for: providerID), session: session)
    }

    /// Probe a host with a short HEAD to refresh its online/offline badge.
    public func refreshHostStatus(_ host: String, session: URLSession = .shared) async {
        guard !host.isEmpty, let url = URL(string: "https://\(host)/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        do {
            _ = try await session.data(for: request)
            hostStatus[host] = .online
        } catch {
            hostStatus[host] = .offline
        }
    }

    public func status(for host: String) -> HostStatus {
        hostStatus[host] ?? .unknown
    }
}