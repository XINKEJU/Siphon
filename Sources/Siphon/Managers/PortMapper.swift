import Foundation

/// NAT traversal: automatic port mapping for inbound peer connections (BitTorrent,
/// eMule, but also any listen server). Mirrors the UPnP / NAT-PMP support found in
/// Transmission / qBittorrent. Two protocols are attempted, best-effort:
///
///   * **NAT-PMP** (RFC 6886) — UDP to the gateway's port 5351.
///   * **UPnP IGD** (SSDP + SOAP) — multicast discovery then `AddPortMapping`.
///
/// Every failure is caught and surfaced through `lastError`; the manager never
/// throws or blocks the UI. If the network has no IGD (or the sandbox blocks
/// multicast), it simply reports `.none` / the error and the app keeps working.
public enum NATType: String, Sendable {
    case unknown = "未知"
    case natPMP = "NAT-PMP"
    case upnp = "UPnP IGD"
    case none = "无（无可用网关）"
    case blocked = "受阻"
}

public final class PortMapper: @unchecked Sendable {
    public static let shared = PortMapper()

    public private(set) var natType: NATType = .unknown
    public private(set) var externalIP: String?
    public private(set) var lastError: String?

    private let lock = NSLock()
    private var mapped: [(proto: String, external: UInt16, `internal`: UInt16)] = []

    private init() {}

    public var mappings: [(proto: String, external: UInt16, `internal`: UInt16)] {
        lock.lock(); defer { lock.unlock() }
        return mapped
    }

    private func setNat(_ t: NATType) {
        lock.lock(); natType = t; lock.unlock()
    }
    private func setError(_ s: String?) {
        lock.lock(); lastError = s; lock.unlock()
    }

    // MARK: - public API

    /// Map `internalPort` → `externalPort` (defaults to the same) for TCP. Tries
    /// NAT-PMP, then UPnP. Returns true if either succeeded.
    @discardableResult
    public func mapPort(internalPort: UInt16, externalPort: UInt16? = nil,
                        description: String = "Siphon") -> Bool {
        let ext = externalPort ?? internalPort
        setError(nil)
        var ok = false
        if let ip = tryNATPMPIGD(internalPort: internalPort, externalPort: ext, desc: description) {
            setNat(.natPMP); externalIP = ip; ok = true
        } else if let ip = tryUPnP(internalPort: internalPort, externalPort: ext, desc: description) {
            setNat(.upnp); externalIP = ip; ok = true
        }
        if ok {
            lock.lock(); mapped.append((proto: "TCP", external: ext, internal: internalPort)); lock.unlock()
        }
        return ok
    }

    /// Async wrapper so the UI can `await` without blocking the main actor.
    public func mapPortAsync(internalPort: UInt16, externalPort: UInt16? = nil,
                             description: String = "Siphon") async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: self.mapPort(internalPort: internalPort,
                                                   externalPort: externalPort, description: description))
            }
        }
    }

    /// Remove every mapping we created. Best-effort; failures are ignored.
    public func unmapAll() {
        let snapshot = mappings
        for m in snapshot {
            _ = tryUPnPUnmap(externalPort: m.external)
            _ = tryNATPMPUnmap(externalPort: m.external)
        }
        lock.lock(); mapped.removeAll(); lock.unlock()
    }

    /// Probe the external address and NAT type without creating a long-lived mapping.
    public func detect() -> NATType {
        if let ip = natPMPExternalAddress() { setNat(.natPMP); externalIP = ip; return .natPMP }
        if let ip = upnpExternalAddress() { setNat(.upnp); externalIP = ip; return .upnp }
        setNat(.none); return .none
    }

    // MARK: - gateway discovery

    private func defaultGateway() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/route")
        proc.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        guard let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return String(t.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - NAT-PMP (RFC 6886)

    private func natPMPExternalAddress() -> String? {
        guard let gw = defaultGateway() else { return nil }
        // A zero-ports request asks the gateway for its public address.
        let req: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let resp = udpExchange(host: gw, port: 5351, payload: req, timeout: 2)
        guard resp.count >= 12, resp[0] == 0, resp[1] == 128 else { return nil }
        let ip = "\(resp[8]).\(resp[9]).\(resp[10]).\(resp[11])"
        return ip
    }

    private func tryNATPMPIGD(internalPort: UInt16, externalPort: UInt16,
                              desc: String) -> String? {
        guard let gw = defaultGateway() else { setError("找不到默认网关"); return nil }
        // version(0) opcode(1) reserved(0) private(2) public(2) ttl(4)
        var req = [UInt8](repeating: 0, count: 12)
        req[1] = 1
        req[4] = UInt8((internalPort >> 8) & 0xFF); req[5] = UInt8(internalPort & 0xFF)
        req[6] = UInt8((externalPort >> 8) & 0xFF); req[7] = UInt8(externalPort & 0xFF)
        let ttl: UInt32 = 7200
        req[8] = UInt8((ttl >> 24) & 0xFF)
        req[9] = UInt8((ttl >> 16) & 0xFF)
        req[10] = UInt8((ttl >> 8) & 0xFF)
        req[11] = UInt8(ttl & 0xFF)
        let resp = udpExchange(host: gw, port: 5351, payload: req, timeout: 2)
        guard resp.count >= 16, resp[0] == 0, resp[1] == 128 else {
            setError("NAT-PMP 网关无响应或拒绝")
            return nil
        }
        let ip = "\(resp[8]).\(resp[9]).\(resp[10]).\(resp[11])"
        return ip
    }

    private func tryNATPMPUnmap(externalPort: UInt16) -> Bool {
        guard let gw = defaultGateway() else { return false }
        var req = [UInt8](repeating: 0, count: 12)
        req[1] = 1
        req[4] = UInt8((externalPort >> 8) & 0xFF); req[5] = UInt8(externalPort & 0xFF)
        // public port 0 + ttl 0 requests deletion
        let resp = udpExchange(host: gw, port: 5351, payload: req, timeout: 2)
        return resp.count >= 16 && resp[1] == 128
    }

    private func udpExchange(host: String, port: UInt16, payload: [UInt8], timeout: Int) -> [UInt8] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [] }
        defer { close(sock) }
        guard let addr = sockaddrIN(host: host, port: port) else { return [] }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var sockAddr = addr
        let sent = withUnsafePointer(to: &sockAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sock, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == payload.count else { return [] }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = recv(sock, &buf, buf.count, 0)
        guard n > 0 else { return [] }
        return Array(buf[0..<Int(n)])
    }

    // MARK: - UPnP IGD (SSDP + SOAP)

    private func tryUPnP(internalPort: UInt16, externalPort: UInt16,
                         desc: String) -> String? {
        guard let ctrl = upnpControlURL() else { setError("未找到 UPnP IGD 设备"); return nil }
        let body = upnpEnvelope(
            service: "urn:schemas-upnp-org:service:WANIPConnection:1",
            action: "AddPortMapping",
            args: [
                ("NewRemoteHost", ""),
                ("NewExternalPort", "\(externalPort)"),
                ("NewProtocol", "TCP"),
                ("NewInternalPort", "\(internalPort)"),
                ("NewInternalClient", localIP() ?? ""),
                ("NewEnabled", "1"),
                ("NewPortMappingDescription", desc),
                ("NewLeaseDuration", "0")
            ])
        guard let xml = soapPost(url: ctrl, body: body),
              !xml.contains("<faultcode>") else {
            setError("UPnP AddPortMapping 失败")
            return nil
        }
        return upnpExternalAddress()
    }

    private func tryUPnPUnmap(externalPort: UInt16) -> Bool {
        guard let ctrl = upnpControlURL() else { return false }
        let body = upnpEnvelope(
            service: "urn:schemas-upnp-org:service:WANIPConnection:1",
            action: "DeletePortMapping",
            args: [("NewRemoteHost", ""), ("NewExternalPort", "\(externalPort)"),
                   ("NewProtocol", "TCP")])
        return soapPost(url: ctrl, body: body) != nil
    }

    private func upnpExternalAddress() -> String? {
        guard let ctrl = upnpControlURL() else { return nil }
        let body = upnpEnvelope(
            service: "urn:schemas-upnp-org:service:WANIPConnection:1",
            action: "GetExternalIPAddress", args: [])
        guard let xml = soapPost(url: ctrl, body: body),
              let m = xml.range(of: "<NewExternalIPAddress>(.*?)</NewExternalIPAddress>",
                               options: .regularExpression) else { return nil }
        let s = String(xml[m])
        return s
            .replacingOccurrences(of: "<NewExternalIPAddress>", with: "")
            .replacingOccurrences(of: "</NewExternalIPAddress>", with: "")
    }

    private func upnpControlURL() -> URL? {
        // SSDP M-SEARCH for IGD root devices.
        let search = [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: 2",
            "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1",
            "",
            ""
        ].joined(separator: "\r\n")
        guard let data = search.data(using: .utf8),
              let (location, _) = ssdpSearch(payload: [UInt8](data), timeout: 3) else { return nil }
        guard let xmlData = try? Data(contentsOf: location),
              let xml = String(data: xmlData, encoding: .utf8) else { return nil }
        // Find the WANIPConnection service control URL, relative to the device URL.
        guard let svc = xml.range(of: "<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>"),
              let urlRange = xml.range(of: "<controlURL>", options: .backwards,
                                       range: xml.startIndex..<svc.lowerBound),
              let end = xml.range(of: "</controlURL>",
                                  range: urlRange.upperBound..<xml.endIndex) else { return nil }
        let path = String(xml[urlRange.upperBound..<end.lowerBound])
        guard let base = URL(string: location.absoluteString) else { return nil }
        return URL(string: path, relativeTo: base) ?? URL(string: path)
    }

    private func ssdpSearch(payload: [UInt8], timeout: Int) -> (URL, String)? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        var addr = sockaddrIN(host: "239.255.255.250", port: 1900)!
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sock, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == payload.count else { return nil }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(sock, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        let text = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
        // Extract LOCATION header.
        for line in text.components(separatedBy: "\r\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.uppercased().hasPrefix("LOCATION:") {
                let url = t.dropFirst("LOCATION:".count).trimmingCharacters(in: .whitespaces)
                if let u = URL(string: url) { return (u, text) }
            }
        }
        return nil
    }

    private func soapPost(url: URL, body: String) -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:WANIPConnection:1#\(soapAction(from: body))\"",
                     forHTTPHeaderField: "SOAPAction")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data, let s = String(data: data, encoding: .utf8) { result = s }
            sem.signal()
        }
        task.resume()
        sem.wait()
        return result
    }

    private func soapAction(from body: String) -> String {
        if body.contains("AddPortMapping") { return "AddPortMapping" }
        if body.contains("DeletePortMapping") { return "DeletePortMapping" }
        if body.contains("GetExternalIPAddress") { return "GetExternalIPAddress" }
        return ""
    }

    private func upnpEnvelope(service: String, action: String,
                              args: [(String, String)]) -> String {
        let inner = args.map { "    <\($0.0)>\($0.1)</\($0.0)>" }.joined(separator: "\n")
        return """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(service)">
        \(inner)
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """
    }

    private func localIP() -> String? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = (53 as UInt16).bigEndian
        addr.sin_addr.s_addr = inet_addr("8.8.8.8")
        var name = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ret = withUnsafePointer(to: &addr) { p in
            _ = UnsafeRawPointer(p).bindMemory(to: sockaddr.self, capacity: 1)
            return withUnsafeMutablePointer(to: &name) { np in
                let npp = UnsafeMutableRawPointer(np).bindMemory(to: sockaddr.self, capacity: 1)
                return getsockname(sock, npp, &len)
            }
        }
        guard ret == 0 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        return withUnsafePointer(to: &name) { np in
            let npp = UnsafeRawPointer(np).bindMemory(to: sockaddr.self, capacity: 1)
            guard getnameinfo(UnsafeMutablePointer(mutating: npp), len, &host,
                              socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: host)
        }
    }
}

// MARK: - socket helpers

private func sockaddrIN(host: String, port: UInt16) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    let ip = inet_addr(host)
    guard ip != INADDR_NONE else { return nil }
    addr.sin_addr.s_addr = ip
    return addr
}
