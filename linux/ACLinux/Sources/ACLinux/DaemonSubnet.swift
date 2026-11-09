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
                    + " set \(useRandom172DefaultsKey) true in the daemon's defaults to move to a private 172.16/12 subnet\n").utf8))
            } else {
                defaults.set(true, forKey: useRandom172DefaultsKey)
            }
        }
        let base: UInt32 = defaults.bool(forKey: useRandom172DefaultsKey)
            ? VMNetSwitch.persistedRandom172Base(hostUsed: hostUsed, defaults: defaults)
            : 0xC0A8_4000
        return VMNetSwitch.ipString(base | 1)
    }

    /// The `/24` a gateway (its .1) is on, as a CIDR.
    // @port-skip linux-only: see chooseWorkspaceGateway
    static func subnetCIDR(gateway: String) -> String {
        let p = gateway.split(separator: ".")
        return p.count == 4 ? p[0..<3].joined(separator: ".") + ".0/24" : "192.168.64.0/24"
    }
}
