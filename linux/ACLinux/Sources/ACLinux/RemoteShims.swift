import Foundation
import NIOConcurrencyHelpers

// Stand-ins for the bits of bromure-ac the shared SSH server sources
// (_shared/RemoteAccessServer.swift, _shared/RemoteSSHHandlers.swift) reach
// for, as Sources/AgentHost/Shims.swift provides them for the agent host.

/// Where the shared server finds the control socket (and, beside it, its
/// `remote/` key directory). The daemon sets it before starting the server.
// @port-skip linux-only: stand-in for the macOS ProfileStore's control socket path
struct ProfileStore {
    static let controlSocket = NIOLockedValueBox<URL?>(nil)
    // @port-skip linux-only: stand-in
    var controlSocketURL: URL {
        Self.controlSocket.withLockedValue { $0 }
            ?? URL(fileURLWithPath: (ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory())
                + "/bromure-ac/control.sock")
    }
}

/// The server's audit breadcrumbs go to the daemon's log.
// @port-skip linux-only: stand-in for the macOS MITM supply-chain log
final class SupplyChainLog: Sendable {
    static let shared = SupplyChainLog()
    // @port-skip linux-only: stand-in
    func record(_ line: String) { FileHandle.standardError.write(Data("bromure-ac daemon: \(line)\n".utf8)) }
}

/// The guest subnet `forward` / `forward-udp` may reach: the interim
/// switch's (InterimSwitch's DHCP range), set by the daemon.
// @port-skip linux-only: stand-in for SandboxEngine's vmnet switch
enum SandboxEngine {
    // @port-skip linux-only: stand-in
    struct Subnet: Sendable {
        var network: UInt32
        var prefix: Int
        var gateway: UInt32
        // @port-skip linux-only: stand-in
        var cidrString: String { "\(Self.dotted(network))/\(prefix)" }
        /// In the subnet, and neither its network, broadcast nor gateway address.
        // @port-skip linux-only: stand-in
        func containsGuest(_ ip: String) -> Bool {
            guard let a = Self.parse(ip) else { return false }
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
            return a & mask == network & mask && a != network && a != network | ~mask && a != gateway
        }
        // @port-skip linux-only: stand-in
        static func parse(_ s: String) -> UInt32? {
            let p = s.split(separator: ".").compactMap { UInt32($0) }
            guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
            return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
        }
        // @port-skip linux-only: stand-in
        static func dotted(_ a: UInt32) -> String { "\(a >> 24).\(a >> 16 & 255).\(a >> 8 & 255).\(a & 255)" }
    }
    // @port-skip linux-only: stand-in
    final class VMNetSwitch: Sendable {
        static let shared = VMNetSwitch()
        private let box = NIOLockedValueBox<Subnet?>(nil)
        // @port-skip linux-only: stand-in
        var subnet: Subnet? {
            get { box.withLockedValue { $0 } }
            set { box.withLockedValue { $0 = newValue } }
        }
    }
}
