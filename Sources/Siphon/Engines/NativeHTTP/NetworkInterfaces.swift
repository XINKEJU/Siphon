import Foundation
import Darwin

/// Physical-path enumeration for multi-NIC aggregation (FluxDown multi_nic
/// model). Returns distinct usable interface names (up + running, IPv4, not
/// loopback). The primary connection always rides the default route; a second
/// interface is used to pin an additional curl worker via `--interface`.
///
/// Note: source-interface binding steers egress only when the system routing
/// table has a usable path for that interface (e.g. Ethernet + Wi-Fi both
/// configured). Forcing routes would require root and is deliberately not done.
enum NetworkInterfaces {

    /// Distinct usable interface names in enumeration order (typically the
    /// primary/default-route interface first).
    static func usableIPv4() -> [String] {
        var out: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return out }
        defer { freeifaddrs(ifaddrPtr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            cursor = p.pointee.ifa_next
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = p.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            if !out.contains(name) { out.append(name) }
        }
        return out
    }
}
