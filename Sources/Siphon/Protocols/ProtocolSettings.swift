import Foundation
import Security

/// User-configurable protocol gateways. Strings live in UserDefaults; the S3 secret
/// is stored in the login Keychain rather than plaintext preferences.
public struct ProtocolSettings: Sendable {
    public var ipfsGateway: String
    public var s3: S3Signer.Config
    public var curlPath: String

    public static let `default` = ProtocolSettings(
        ipfsGateway: "https://ipfs.io",
        s3: S3Signer.Config(),
        curlPath: "/usr/bin/curl"
    )

    public init(ipfsGateway: String, s3: S3Signer.Config, curlPath: String) {
        self.ipfsGateway = ipfsGateway; self.s3 = s3; self.curlPath = curlPath
    }

    private enum Key {
        static let ipfs = "Siphon.ipfsGateway"
        static let endpoint = "Siphon.s3Endpoint"
        static let region = "Siphon.s3Region"
        static let access = "Siphon.s3AccessKey"
        static let https = "Siphon.s3UseHTTPS"
        static let curl = "Siphon.curlPath"
        static let secretAccount = "s3-secret-key"
    }

    public static func load() -> ProtocolSettings {
        let d = UserDefaults.standard
        var cfg = S3Signer.Config()
        cfg.endpoint = d.string(forKey: Key.endpoint) ?? cfg.endpoint
        cfg.region = d.string(forKey: Key.region) ?? cfg.region
        cfg.accessKey = d.string(forKey: Key.access) ?? ""
        cfg.secretKey = Keychain.secret(account: Key.secretAccount) ?? ""
        if d.object(forKey: Key.https) != nil { cfg.useHTTPS = d.bool(forKey: Key.https) }
        return ProtocolSettings(
            ipfsGateway: d.string(forKey: Key.ipfs) ?? "https://ipfs.io",
            s3: cfg,
            curlPath: d.string(forKey: Key.curl) ?? "/usr/bin/curl"
        )
    }

    public func save() {
        let d = UserDefaults.standard
        d.set(ipfsGateway, forKey: Key.ipfs)
        d.set(s3.endpoint, forKey: Key.endpoint)
        d.set(s3.region, forKey: Key.region)
        d.set(s3.accessKey, forKey: Key.access)
        d.set(s3.useHTTPS, forKey: Key.https)
        d.set(curlPath, forKey: Key.curl)
        Keychain.setSecret(s3.secretKey, account: Key.secretAccount)
    }
}
