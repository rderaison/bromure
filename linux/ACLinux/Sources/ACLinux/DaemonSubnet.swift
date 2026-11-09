import Foundation
import NIOConcurrencyHelpers
import SandboxEngine

/// The workspaces' subnet, as macOS AC chooses its switch's at launch: a
/// persisted random `/24` in 172.16.0.0/12 (Docker's 172.17–20 and the
/// host's own `/24`s skipped), so a client connected to several servers, or
/// to two users of one server, never sees two remotes on the same subnet;
/// 192.168.64.0/24 (the historical one) when the install opted out.
///
/// The keys are macOS's, in the daemon's own defaults
/// (`$XDG_CONFIG_HOME/bromure-ac.plist`, a multi-user daemon's under its
/// state dir): `vmnet.useRandom172` (Bool) and `vmnet.switch.subnetBase172`
/// (the chosen base). Each user's daemon chooses its own. An install that
/// never chose and already has VMs keeps 192.168.64 (useRandom172 written
/// false once, and said): its VMs, k3s nodes included, keep their addresses.
/// To opt in, set `vmnet.useRandom172` true in that plist and restart.
extension Daemon {
    static let useRandom172DefaultsKey = "vmnet.useRandom172"
    /// The subnet in use, as a CIDR ("172.23.181.0/24"): the guests' NO_PROXY.
    static let workspaceSubnet = NIOLockedValueBox("192.168.64.0/24")

    /// The gateway (the subnet's .1) the daemon's passt and switch take.
    // @port-skip linux-only: the subnet part of ACAppDelegate.applicationDidFinishLaunching (vmnet.useRandom172, setSubnetStrategy(.randomClassB172)): an install that has VMs keeps 192.168.64 (no migration prompt on a server), and the opt-out keeps the fixed 192.168.64
    static func chooseWorkspaceGateway(hasVMs: Bool, defaults: UserDefaults = .standard,
                                       hostUsed: Set<UInt32> = HostNetworkInfo.localPrivate172Slash24s()) -> String {
        if defaults.object(forKey: useRandom172DefaultsKey) == nil {
            if hasVMs {
                defaults.set(false, forKey: useRandom172DefaultsKey)
                FileHandle.standardError.write(Data(("bromure-ac daemon: workspaces stay on 192.168.64.0/24 (this install has VMs);"
                    + " set \(useRandom172DefaultsKey) true in the daemon's defaults to move to a private 172.16/12 subnet."
                    + " A k3s cluster made before keeps its 192.168.64 MetalLB range, node addresses and certificates:"
                    + " recreate it after the move\n").utf8))
            } else {
                defaults.set(true, forKey: useRandom172DefaultsKey)
            }
        }
        let base: UInt32 = defaults.bool(forKey: useRandom172DefaultsKey)
            ? VMNetSwitch.persistedRandom172Base(hostUsed: hostUsed, defaults: defaults)
            : 0xC0A8_4000
        return VMNetSwitch.ipString(base | 1)
    }

    /// The gateway to start on: the one already in use (an adopted passt's,
    /// live records'), else the chosen one. A change (an opt-in, a re-roll
    /// because the host joined the saved /24) waits for a start with nothing
    /// running, and is said (macOS's VMs end at quit; a re-adopted one here
    /// would lose its lease, and an adopted passt keeps its -a/-g).
    // @port-skip linux-only: see chooseWorkspaceGateway
    static func gatewayToUse(chosen: String, inUse: String?, vmsRunning: Bool = true) -> String {
        guard let inUse, inUse != chosen else { return chosen }
        let what = vmsRunning ? "VMs run on it" : "the previous daemon's passt, taken back, is on it"
        FileHandle.standardError.write(Data(("bromure-ac daemon: workspaces stay on \(subnetCIDR(gateway: inUse)) while \(what);"
            + " the move to \(subnetCIDR(gateway: chosen)) waits for a start with none running\n").utf8))
        return inUse
    }

    /// A passt's gateway, from its command line (`-g <gateway>`).
    // @port-skip linux-only: see chooseWorkspaceGateway
    static func passtGateway(argv: [String]) -> String? {
        zip(argv, argv.dropFirst()).first { $0.0 == "-g" || $0.0 == "--gateway" }?.1
    }

    /// Warning, when the daemon has a temporary state dir (a test's, CI's)
    /// but this user's config home: its defaults (the subnet's choice) would
    /// land in the user's ~/.config/bromure-ac.plist. A state dir elsewhere
    /// (a single-user install's own) is no test's.
    // @port-skip linux-only: the daemon's defaults location check
    static func configHomeWarning(stateDir: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard env["XDG_STATE_HOME"].map({ !$0.isEmpty }) == true, env["XDG_CONFIG_HOME"].map({ !$0.isEmpty }) != true else { return nil }
        let home = env["HOME"] ?? NSHomeDirectory()
        let tmpdir = env["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 }
        let temps = ["/tmp/", "/var/tmp/"] + (tmpdir.map { [$0.hasSuffix("/") ? $0 : $0 + "/"] } ?? [])
        guard temps.contains(where: { stateDir.hasPrefix($0) }) else { return nil }
        return "bromure-ac daemon: WARNING: a state dir of its own (\(stateDir)) but this user's config home: its defaults"
            + " (the workspace subnet's choice) go to \(home)/.config/bromure-ac.plist; set XDG_CONFIG_HOME for a test or CI daemon\n"
    }

    /// The `/24` a gateway (its .1) is on, as a CIDR.
    // @port-skip linux-only: see chooseWorkspaceGateway
    static func subnetCIDR(gateway: String) -> String {
        let p = gateway.split(separator: ".")
        return p.count == 4 ? p[0..<3].joined(separator: ".") + ".0/24" : "192.168.64.0/24"
    }
}
