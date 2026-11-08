import Foundation

/// Workspaces the agent watchdog quarantined. Their VM's network is cut at
/// the switch, and nothing else may carry the guest's traffic out or act on
/// the network for it until the owner releases it: the proxy over vsock
/// refuses its requests and closes its open connections, the SSH agent
/// signs nothing, the MCP servers and the browser answer nothing, the AWS
/// credential server and the model bridge hand out nothing. What lets the
/// owner look inside (the shell) and what reports on the guest (the
/// attestor, the kernel sentry) stay.
///
/// A host channel asks `contains` before each request, and a long-lived one
/// (an upgraded proxy tunnel, a bridge's open agents) registers a cut with
/// `onQuarantine`: run at every quarantine start (at once if one is on),
/// until the token removes it.
public final class WorkspaceQuarantine: @unchecked Sendable {
    public static let shared = WorkspaceQuarantine()

    /// What a refused request is told.
    public static let refusal = "Bromure: this workspace is quarantined by the agent watchdog; its network access is cut until the owner releases it."

    private let lock = NSLock()
    private var quarantined: Set<UUID> = []
    private var cuts: [UUID: [UUID: @Sendable () -> Void]] = [:]

    public init() {}

    public func contains(_ profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return quarantined.contains(profileID)
    }

    /// Start (running every registered cut) or end a workspace's quarantine.
    public func set(_ on: Bool, for profileID: UUID) {
        lock.lock()
        let run: [@Sendable () -> Void]
        if on {
            quarantined.insert(profileID)
            run = Array((cuts[profileID] ?? [:]).values)
        } else {
            quarantined.remove(profileID)
            run = []
        }
        lock.unlock()
        // Every open proxy connection the firewall tracks goes too.
        if on { EgressConnectionRegistry.shared.cutAll(profileID: profileID) }
        for cut in run { cut() }
    }

    /// `cut` runs at each start of `profileID`'s quarantine (now too, if
    /// one is on and `runNow`: a caller that refuses its requests itself
    /// passes false), until the token removes it (the channel ended).
    @discardableResult
    public func onQuarantine(_ profileID: UUID, runNow: Bool = true, _ cut: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        cuts[profileID, default: [:]][token] = cut
        let now = runNow && quarantined.contains(profileID)
        lock.unlock()
        if now { cut() }
        return token
    }

    public func remove(_ token: UUID, for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        cuts[profileID]?[token] = nil
        if cuts[profileID]?.isEmpty == true { cuts[profileID] = nil }
    }
}

/// An MCP server as a quarantined workspace's guest reaches it: every
/// request answered with an error (a notification with nothing) while the
/// quarantine lasts, the server untouched.
final class QuarantineGatedMCP: MCPLineHandler {
    let inner: any MCPLineHandler
    let profileID: UUID

    init(_ inner: any MCPLineHandler, profileID: UUID) {
        self.inner = inner
        self.profileID = profileID
    }

    func handle(line: String, branch: String?) async -> String? {
        guard WorkspaceQuarantine.shared.contains(profileID) else { return await inner.handle(line: line, branch: branch) }
        return Self.refusal(to: line)
    }

    @MainActor func responseNotWritten(to line: String, branch: String?) {
        inner.responseNotWritten(to: line, branch: branch)
    }

    /// The JSON-RPC error for `line` (nil for a notification: no id).
    static func refusal(to line: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"], !(id is NSNull) else { return nil }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                    "error": ["code": -32001, "message": WorkspaceQuarantine.refusal]]
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
