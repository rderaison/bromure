import Foundation

// Stand-ins for the bits of bromure-ac the shared SSH server sources
// (Shared/RemoteAccessServer.swift, Shared/RemoteSSHHandlers.swift) reach
// for. The agent host has no VMs, no profiles and no MITM log.

/// Where the shared server finds the control socket (and, beside it, its
/// `remote/` key directory).
struct ProfileStore {
    var controlSocketURL: URL { AgentHostPaths.controlSocket }
}

/// The server's audit breadcrumbs go to the app log.
final class SupplyChainLog {
    static let shared = SupplyChainLog()
    func record(_ line: String) { AgentHostLog.log(line) }
}

/// No vmnet here: every `forward` / `forward-udp` request is refused.
enum SandboxEngine {
    struct Subnet {
        var cidrString: String
        func containsGuest(_ ip: String) -> Bool { false }
    }
    final class VMNetSwitch {
        static let shared = VMNetSwitch()
        let subnet: Subnet? = nil
    }
}


/// The P2P identity falls back to bromure-ac's enterprise install token;
/// the agent host has only its own browser-enrolled device record.
struct BACInstall: Codable, Equatable, Identifiable {
    let installId: String
    let orgSlug: String
    let userId: String
    let serverURL: URL
    var id: String { installId }
}

enum BACEnrollmentStore {
    static func load() -> BACInstall? { nil }
    static func loadInstallToken() -> String? { nil }
}
