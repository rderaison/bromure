import Darwin
import Foundation
import Network

private let hnwDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Watches the host's primary network for changes and notifies registered
/// ``NetworkRefreshBridge`` instances so bridged-mode VMs can renew their
/// DHCP lease and DNS config.
///
/// Uses ``NWPathMonitor`` for change notifications. Each update is reduced to
/// a compact identity (available interface names + types + their IPv4
/// addresses); identity changes are debounced by 500 ms before fanning out.
///
/// The initial path (seen right after ``start()``) is swallowed — sessions
/// boot with the correct network already, so the first update is a no-op
/// establishing the baseline.
@MainActor
public final class HostNetworkWatcher {
    public static let shared = HostNetworkWatcher()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.bromure.networkwatcher")
    private var bridges: [ObjectIdentifier: WeakBridge] = [:]
    private var debounceTask: Task<Void, Never>?
    private var lastIdentity: String?
    private var started = false

    private init() {}

    /// Start the path monitor. Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let identity = Self.identity(of: path)
            Task { @MainActor [weak self] in
                self?.handle(identity: identity)
            }
        }
        monitor.start(queue: monitorQueue)
        if hnwDebug { print("[HostNetworkWatcher] started") }
    }

    /// Register a bridge to receive refresh notifications.
    /// Held weakly — the caller owns the bridge's lifetime.
    public func register(_ bridge: NetworkRefreshBridge) {
        bridges[ObjectIdentifier(bridge)] = WeakBridge(bridge)
        if hnwDebug { print("[HostNetworkWatcher] registered bridge (now \(bridges.count))") }
    }

    public func unregister(_ bridge: NetworkRefreshBridge) {
        bridges.removeValue(forKey: ObjectIdentifier(bridge))
        if hnwDebug { print("[HostNetworkWatcher] unregistered bridge (now \(bridges.count))") }
    }

    // MARK: - Change detection

    private func handle(identity: String) {
        let previous = lastIdentity
        lastIdentity = identity
        guard let previous else {
            // First update establishes the baseline — don't refresh.
            if hnwDebug { print("[HostNetworkWatcher] initial identity: \(identity)") }
            return
        }
        guard identity != previous else { return }
        if hnwDebug { print("[HostNetworkWatcher] identity changed: \(previous) → \(identity)") }

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.fanOut()
        }
    }

    private func fanOut() {
        bridges = bridges.filter { $0.value.value != nil }
        if hnwDebug { print("[HostNetworkWatcher] fanning out refresh to \(bridges.count) bridge(s)") }
        for entry in bridges.values {
            entry.value?.refresh()
        }
    }

    // MARK: - Identity

    /// Compact stable string that changes when the host's reachable network
    /// configuration changes in a way the guest would care about.
    nonisolated private static func identity(of path: NWPath) -> String {
        guard path.status == .satisfied else { return "unsat" }
        let interfaces = path.availableInterfaces.map {
            "\($0.name):\(typeString($0.type))"
        }.joined(separator: ",")
        let addresses = primaryIPv4Addresses()
        return "\(interfaces)|\(addresses)"
    }

    nonisolated private static func typeString(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wifi: return "wifi"
        case .wiredEthernet: return "eth"
        case .cellular: return "cell"
        case .loopback: return "lo"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    /// Snapshot of non-loopback IPv4 addresses keyed by interface name.
    /// Changes when the host roams to a new SSID, reconnects with a new DHCP
    /// lease, or a VPN inserts/removes a utun interface.
    nonisolated private static func primaryIPv4Addresses() -> String {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return "" }
        defer { freeifaddrs(ifap) }

        var result: [(String, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = cursor {
            let entry = cur.pointee
            if let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                let name = String(cString: entry.ifa_name)
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if !ip.hasPrefix("127.") && !name.hasPrefix("lo") {
                    result.append((name, ip))
                }
            }
            cursor = entry.ifa_next
        }
        return result
            .sorted { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: ";")
    }
}

private struct WeakBridge {
    weak var value: NetworkRefreshBridge?
    init(_ v: NetworkRefreshBridge) { self.value = v }
}
