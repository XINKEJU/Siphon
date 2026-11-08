import Foundation
import Network
import Observation

/// 系统网络状态（`NWPathMonitor`）。
///
/// 下载器对网络变化的反应应当是「先暂停、后恢复」，而不是让每个连接各自
/// 超时重试：断网瞬间几十个 segment 同时报错，用户看到的是满屏失败，恢复后
/// 也不会自动继续。这里只做状态源，暂停/恢复策略由 `NetworkPolicy` +
/// `DownloadStore` 决定。
@MainActor
@Observable
public final class NetworkMonitor {
    public static let shared = NetworkMonitor()

    public private(set) var status = NetworkStatus(
        isOnline: true, isExpensive: false, isConstrained: false, interfaceName: "")

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.xinkeju.siphon.network-path")
    @ObservationIgnored private var started = false
    @ObservationIgnored public var onChange: ((NetworkStatus) -> Void)?

    private init() {}

    public func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let interface: String
            if path.usesInterfaceType(.wifi) { interface = "Wi‑Fi" }
            else if path.usesInterfaceType(.wiredEthernet) { interface = "有线" }
            else if path.usesInterfaceType(.cellular) { interface = "蜂窝" }
            else if path.usesInterfaceType(.loopback) { interface = "本机" }
            else { interface = "" }
            let next = NetworkStatus(
                isOnline: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                interfaceName: interface)
            Task { @MainActor in self?.apply(next) }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
        started = false
    }

    private func apply(_ next: NetworkStatus) {
        guard next != status else { return }
        status = next
        onChange?(next)
    }
}
