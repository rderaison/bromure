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

    /// Protocol version advertised in `state` snapshots.
    static let protocolVersion = 1
}
