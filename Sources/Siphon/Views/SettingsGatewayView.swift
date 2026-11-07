import SwiftUI

/// 协议网关 tab（系统代理 PAC / IPFS 网关 / S3 兼容存储 / libcurl 路径）。
struct GatewaySettingsView: View {
    @State private var ipfsGateway = ""
    @State private var s3Endpoint = ""
    @State private var s3Region = ""
    @State private var s3AccessKey = ""
    @State private var s3SecretKey = ""
    @State private var s3UseHTTPS = true
    @State private var curlPath = ""
    @State private var settingsSaved = false

    var body: some View {
        Form {
            Section("系统代理（PAC）") {
                Toggle("自动使用系统代理 / PAC 脚本", isOn: Binding(
                    get: { ProxyRouter.shared.enabled },
                    set: { ProxyRouter.shared.enabled = $0 }))
                Text("开启后，下载按系统代理设置（含 PAC 自动配置）走代理；本地回环地址始终直连。默认关闭以避免阻塞。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("IPFS / IPNS 网关") {
                TextField("网关地址", text: $ipfsGateway,
                          prompt: Text("https://ipfs.io 或 http://127.0.0.1:8080"))
                    .textFieldStyle(.roundedBorder)
                Text("ipfs:// 与 ipns:// 会重写为 <网关>/ipfs/<CID> 后交给原生 HTTP 引擎拉取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("S3 兼容对象存储") {
                TextField("Endpoint（仅主机名）", text: $s3Endpoint,
                          prompt: Text("s3.amazonaws.com / localhost:9000"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Region", text: $s3Region, prompt: Text("us-east-1"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Access Key", text: $s3AccessKey)
                        .textFieldStyle(.roundedBorder)
                }
                SecureField("Secret Key（存入钥匙串）", text: $s3SecretKey)
                    .textFieldStyle(.roundedBorder)
                Toggle("使用 HTTPS", isOn: $s3UseHTTPS)
                Text("s3://bucket/key 会生成 AWS SigV4 预签名 URL。兼容 AWS S3、MinIO、Cloudflare R2、Wasabi、Backblaze B2。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("libcurl") {
                TextField("curl 可执行文件", text: $curlPath)
                    .textFieldStyle(.roundedBorder)
                Text("用于 FTPS / SMB / TFTP / Gopher / RTSP 等协议。留空则使用 /usr/bin/curl。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(settingsSaved ? "已保存" : "保存设置") { saveGatewaySettings() }
                        .glassButton(prominent: true)
                    if settingsSaved {
                        Text("已生效").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadGatewaySettings() }
    }

    private func loadGatewaySettings() {
        let s = ProtocolSettings.load()
        ipfsGateway = s.ipfsGateway
        s3Endpoint = s.s3.endpoint
        s3Region = s.s3.region
        s3AccessKey = s.s3.accessKey
        s3SecretKey = s.s3.secretKey
        s3UseHTTPS = s.s3.useHTTPS
        curlPath = s.curlPath
    }

    private func saveGatewaySettings() {
        var cfg = S3Signer.Config()
        cfg.endpoint = s3Endpoint.trimmingCharacters(in: .whitespaces)
        cfg.region = s3Region.trimmingCharacters(in: .whitespaces)
        cfg.accessKey = s3AccessKey.trimmingCharacters(in: .whitespaces)
        cfg.secretKey = s3SecretKey
        cfg.useHTTPS = s3UseHTTPS
        if cfg.endpoint.isEmpty { cfg.endpoint = "s3.amazonaws.com" }
        if cfg.region.isEmpty { cfg.region = "us-east-1" }
        let gateway = ipfsGateway.trimmingCharacters(in: .whitespaces)
        ProtocolSettings(
            ipfsGateway: gateway.isEmpty ? "https://ipfs.io" : gateway,
            s3: cfg,
            curlPath: curlPath.trimmingCharacters(in: .whitespaces).isEmpty
                ? "/usr/bin/curl" : curlPath.trimmingCharacters(in: .whitespaces)
        ).save()
        settingsSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settingsSaved = false }
    }
}
