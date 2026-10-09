import Foundation

// MARK: - Fat-client remote-mirroring protocol

/// Shared constants for the "fat client" remote-mirroring feature: a local
/// bromure-ac connects over SSH to a remote bromure-ac and mirrors its full UI
/// 1:1 (grid, workspaces, tabs/worktrees, automations), with bidirectional
/// edits and interactive terminals.
///
/// Transport: we tunnel the remote's owner-only Unix control socket
/// (`control.sock`) over an SSH `exec` channel. The client speaks the EXISTING
/// control-socket HTTP API over the tunnel (state polling, commands, and the
/// hijacked interactive-exec pump for terminals), so almost nothing on the
/// wire is new — the whole control plane is reused. See REMOTE_FAT_CLIENT_PLAN.md.
enum FatClient {
    /// The SSH `exec` command a fat client sends. When the embedded SSH server
    /// (RemoteAccessServer) sees exactly this command on a session channel, it
    /// bridges the channel to the local control socket instead of force-running
    /// the `__remote-menu` TUI. Any other command (or a shell request) keeps the
    /// existing human-facing ForceCommand behaviour, so `ssh host` is unchanged.
    ///
    /// Versioned so the two sides can refuse a major mismatch later.
    static let controlVerb = "bromure-fatclient/1 control"

    /// SSH `exec` verb prefix for a raw TCP tunnel to a guest VM: the full
    /// command is `bromure-fatclient/1 forward <ip> <port>`. The server dials
    /// that guest address (restricted to its vmnet subnet) and splices the SSH
    /// channel to it — this is how a local process / the local browser reaches
    /// the REMOTE 192.168.x.y workspace subnet. See REMOTE_FAT_CLIENT_PLAN.md §4.
    static let forwardVerbPrefix = "bromure-fatclient/1 forward "

    /// Parse `<prefix><ip> <port>` → (ip, port).
    static func parseForward(_ command: String) -> (ip: String, port: Int)? {
        guard command.hasPrefix(forwardVerbPrefix) else { return nil }
        let rest = command.dropFirst(forwardVerbPrefix.count)
        let parts = rest.split(separator: " ")
        guard parts.count == 2, let port = Int(parts[1]), port > 0, port < 65536 else { return nil }
        return (String(parts[0]), port)
    }

    /// SSH `exec` verb for a multiplexed UDP tunnel to a guest: the full command
    /// is `bromure-fatclient/1 forward-udp <ip>`. All UDP to that guest rides one
    /// channel; each datagram is length-prefixed with its return info (see
    /// UtunUDP.swift). The server dials the guest's loopback-relay in UDP mode.
    static let forwardUDPVerbPrefix = "bromure-fatclient/1 forward-udp "

    /// Parse `<prefix><ip>` → ip.
    static func parseForwardUDP(_ command: String) -> String? {
        guard command.hasPrefix(forwardUDPVerbPrefix) else { return nil }
        let ip = command.dropFirst(forwardUDPVerbPrefix.count).trimmingCharacters(in: .whitespaces)
        return ip.isEmpty ? nil : ip
    }

    /// SSH `exec` verb for the browser-MCP relay: `bromure-fatclient/1 browser-mcp
    /// <workspaceID>`. The server splices the workspace agent's vsock-5830 MCP
    /// stream (line-delimited JSON-RPC) to this channel, so the fat client's own
    /// `BrowserMCPServer` — driving the LOCAL browser pane — answers the remote
    /// agent. See REMOTE_FAT_CLIENT_PLAN.md "Browser pane".
    static let browserMCPVerbPrefix = "bromure-fatclient/1 browser-mcp "

    /// Parse `<prefix><workspaceID>` → the workspace id string.
    static func parseBrowserMCP(_ command: String) -> String? {
        guard command.hasPrefix(browserMCPVerbPrefix) else { return nil }
        let rest = command.dropFirst(browserMCPVerbPrefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// SSH `exec` verb for the delegation-MCP relay on a Bromure Agent Host:
    /// the channel waits (parked) until one of the host's agents opens its
    /// `bromure-delegation` MCP stream, then carries it — first line
    /// `bromure-hello w<window>`, then line-delimited JSON-RPC — to the fat
    /// client, whose own DelegationEngine answers. One channel per stream;
    /// the client parks a fresh one as soon as a channel is taken.
    static let delegationMCPVerb = "bromure-fatclient/1 delegation-mcp"

    /// SSH `exec` verbs a Bromure Agent Host attaches (and detaches) itself
    /// with: `…machine-link <machineID> <base64 name>` parks the channel on
    /// the server as one of the machine's links (MachineLinks.swift);
    /// `…machine-detach <machineID>` forgets it. The only verbs a key with the
    /// bromure.io `agent-host` capability may use (see RemoteGrant).
    static let machineLinkVerbPrefix = "bromure-fatclient/1 machine-link "
    static let machineDetachVerbPrefix = "bromure-fatclient/1 machine-detach "

    static func parseMachineLink(_ command: String) -> (id: UUID, name: String)? {
        guard command.hasPrefix(machineLinkVerbPrefix) else { return nil }
        let parts = command.dropFirst(machineLinkVerbPrefix.count).split(separator: " ")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let data = Data(base64Encoded: String(parts[1])),
              let name = String(data: data, encoding: .utf8) else { return nil }
        return (id, name)
    }

    static func parseMachineDetach(_ command: String) -> UUID? {
        guard command.hasPrefix(machineDetachVerbPrefix) else { return nil }
        return UUID(uuidString: command.dropFirst(machineDetachVerbPrefix.count).trimmingCharacters(in: .whitespaces))
    }

    /// Protocol version advertised in `state` snapshots.
    static let protocolVersion = 1

    /// The fat client pins its local browser VMs' switch to this octet so the
    /// gateway (`192.168.<octet>.1`) is a fixed, known address the browser-pane
    /// PAC and the SOCKS forwarder both target *before* the VM boots. 127 sits
    /// above AC's downward (64→2) and Bromure Web's upward (65→126) bands, so it
    /// won't collide with a workspace switch.
    static let browserSwitchOctet: UInt8 = 127
    /// Gateway of the pinned browser switch — where the guest reaches the host
    /// (and thus the SOCKS forwarder).
    static let browserSwitchGateway = "192.168.127.1"
}
