import Foundation

/// The ports a workspace's guest and host meet on: the guest's HTTP proxy
/// and the host vsock ports the in-VM shims dial (host CID 2). SessionDisk
/// carries them under the same names (its comments say more); here they
/// build without the rest of SessionDisk (Linux).
public enum GuestPorts {
    /// The guest's cooperative HTTP proxy (bromure-agentd's vm-bridge listener).
    public static let guestProxyPort: Int = 65534
    /// What daemons before 65534 listened on.
    public static let legacyGuestProxyPort: Int = 8080
    /// The browser MCP (BrowserMCPServer), dialed by the guest's stdio shim.
    public static let browserMCPVsockPort: UInt32 = 5830
    /// The coding-board MCP (TaskBoardMCPServer).
    public static let taskBoardMCPVsockPort: UInt32 = 5831
    /// The plan-stream channel (plan-stream protocol v1).
    public static let planStreamVsockPort: UInt32 = 5832
    /// The automations MCP (AutomationMCPServer).
    public static let automationMCPVsockPort: UInt32 = 5833
    /// The infrastructure MCP (KubeMCPServer).
    public static let kubeMCPVsockPort: UInt32 = 5834
    /// The delegation MCP (DelegationMCPServer).
    public static let delegationMCPVsockPort: UInt32 = 5835
    /// The Switchboard's MCP (SwitchboardMCPServer).
    public static let switchboardMCPVsockPort: UInt32 = 5836
}

/// Guest paths in the meta share (/mnt/bromure-meta) that launch commands
/// name; SessionDisk stages the files and carries the same names.
public enum GuestMetaPaths {
    /// The Switchboard's MCP shim.
    public static let switchboardMCPShimGuestPath = "/mnt/bromure-meta/bromure-switchboard-mcp.py"
    /// The Switchboard's MCP config, for Claude's --mcp-config.
    public static let switchboardMCPConfigGuestPath = "/mnt/bromure-meta/bromure-switchboard-mcp.json"
}

/// Folders of the outbox share (/mnt/bromure-outbox) the host makes for
/// what may write there under an OpenShell sandbox; SessionDisk carries the
/// same names (its comments say more).
public enum GuestOutboxPaths {
    /// The URL relay's requests (`urls/url-*.txt`).
    public static let urlRelayFolder = "urls"
    /// The agents' hooks' reports (tab status, tool calls).
    public static let agentFolder = "agent"
}
