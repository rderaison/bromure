import Foundation
import AppKit

/// Per-profile, per-scope consent gate for the `.promptOnWrite`
/// guardrail mode. Mirrors `ConsentBroker` in shape (actor, coalescing
/// waiters, in-memory only) but with a different decision set tailored
/// to "ask before allowing a write": Allow once / Allow for 15 minutes
/// / Allow for the rest of the session / Don't allow.
///
/// "Allow once" deliberately does **not** create a grant — the next
/// write triggers a fresh prompt.  This matters when the user wants
/// to inspect each write individually (e.g. they're auditing a chatty
/// agent's behaviour) rather than handing it a 15-minute carte
/// blanche.
///
/// Scoping is by (profileID, scope) where `scope` is a stable string
/// chosen by the caller, e.g. `"kube:api.cluster.example.com"`,
/// `"aws"`, `"github"`, `"clickhouse:host"`. Granting "ClickHouse on
/// host A for 15 min" doesn't auto-grant anything else.
///
/// All grants/denies are in-memory only. The session-scope variant is
/// wiped on `revokeAll(profileID:)` at session teardown; the time-
/// bounded variants expire on the clock.
public actor GuardrailsConsentBroker {
    public enum Decision: Sendable {
        case deny
        /// Allow this one operation only; the next write re-prompts.
        case allowOnce
        case allow15min
        /// Until session teardown (revokeAll).
        case allowSession
    }

    public struct Grant: Sendable {
        public let expiration: Date
        public let scopeDisplayName: String
        public let isSessionScoped: Bool
        public init(expiration: Date,
                    scopeDisplayName: String,
                    isSessionScoped: Bool) {
            self.expiration = expiration
            self.scopeDisplayName = scopeDisplayName
            self.isSessionScoped = isSessionScoped
        }
    }

    public enum DecisionKind: Sendable {
        case allow
        case deny
    }

    /// Row for the Approvals window — covers both live allow grants
    /// and live deny memories.
    public struct LiveEntry: Sendable {
        public let profileID: UUID
        public let scope: String
        public let kind: DecisionKind
        public let expiration: Date
        public let scopeDisplayName: String
        /// Only meaningful when `kind == .allow`. Always false for
        /// denies (deny memory is hard-capped at `denyTTL`).
        public let isSessionScoped: Bool
    }

    private struct DenyMemory: Sendable {
        let expiration: Date
        let scopeDisplayName: String
    }

    private static func storeKey(profileID: UUID, scope: String) -> String {
        return profileID.uuidString + "|" + scope
    }

    private static func splitStoreKey(_ s: String) -> (UUID, String)? {
        guard let pipe = s.firstIndex(of: "|") else { return nil }
        let uuidStr = String(s[..<pipe])
        let scope = String(s[s.index(after: pipe)...])
        guard let uuid = UUID(uuidString: uuidStr) else { return nil }
        return (uuid, scope)
    }

    private var grants: [String: Grant] = [:]
    /// Time-bounded "Don't allow" memory. Same shape + intent as
    /// `ConsentBroker.denies`: silence a chatty agent that retries
    /// the same write dozens of times after a refusal.
    private var denies: [String: DenyMemory] = [:]
    private static let denyTTL: TimeInterval = 60   // 1 minute
    /// Coalesce concurrent calls for the same key onto one dialog.
    private var pending: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var profileNames: [UUID: String] = [:]

    public init() {}

    public func setProfileName(_ name: String, for profileID: UUID) {
        profileNames[profileID] = name
    }

    public func clearProfileName(for profileID: UUID) {
        profileNames.removeValue(forKey: profileID)
    }

    /// Main entry point. Returns true iff the write should proceed.
    ///
    /// - Parameters:
    ///   - profileID: profile owning the request.
    ///   - scope: stable identifier for the grant scope, e.g.
    ///     `"clickhouse:db.example.com"`. A grant on this scope
    ///     covers every subsequent write to the same scope.
    ///   - scopeDisplayName: human-readable scope shown in the
    ///     dialog title (e.g. "ClickHouse db.example.com").
    ///   - operation: exact operation the agent wants to perform —
    ///     for SQL this is the query text, for REST it's
    ///     "DELETE /api/v1/namespaces/default/pods/foo", etc. Shown
    ///     verbatim in the dialog body so the user can decide on
    ///     evidence.
    public func consent(profileID: UUID,
                        scope: String,
                        scopeDisplayName: String,
                        operation: String) async -> Bool {
        let key = Self.storeKey(profileID: profileID, scope: scope)
        let now = Date()

        FileHandle.standardError.write(Data(
            "[guardrails-consent] check \(scope) for profile \(profileID.uuidString.prefix(8))\n".utf8))

        if let mem = denies[key], mem.expiration > now {
            FileHandle.standardError.write(Data(
                "[guardrails-consent] live deny for \(scope) — auto-deny\n".utf8))
            return false
        } else if denies[key] != nil {
            denies.removeValue(forKey: key)
        }

        if let g = grants[key], g.expiration > now {
            FileHandle.standardError.write(Data(
                "[guardrails-consent] live grant for \(scope) — auto-allow\n".utf8))
            return true
        } else if grants[key] != nil {
            grants.removeValue(forKey: key)
        }

        // Coalesce. If a prompt for this key is already on-screen,
        // park a continuation and return when the dialog resolves.
        // The just-resolving call records the grant/deny before
        // waking the waiters, so they pick up the live decision
        // through the same allow/deny checks above on retry. We
        // signal the waiters directly with the boolean result.
        if pending[key] != nil {
            return await withCheckedContinuation { cont in
                pending[key, default: []].append(cont)
            }
        }
        pending[key] = []

        let profileName = profileNames[profileID] ?? "(unknown profile)"
        let decision = await Self.askUser(profileName: profileName,
                                          scopeDisplayName: scopeDisplayName,
                                          operation: operation)

        let allow: Bool
        switch decision {
        case .deny:
            denies[key] = DenyMemory(
                expiration: now.addingTimeInterval(Self.denyTTL),
                scopeDisplayName: scopeDisplayName)
            allow = false
        case .allowOnce:
            // Deliberately no grant — the next write re-prompts.
            allow = true
        case .allow15min:
            grants[key] = Grant(
                expiration: now.addingTimeInterval(15 * 60),
                scopeDisplayName: scopeDisplayName,
                isSessionScoped: false)
            allow = true
        case .allowSession:
            grants[key] = Grant(
                expiration: .distantFuture,
                scopeDisplayName: scopeDisplayName,
                isSessionScoped: true)
            allow = true
        }

        let waiters = pending[key] ?? []
        pending.removeValue(forKey: key)
        for w in waiters { w.resume(returning: allow) }
        return allow
    }

    public func snapshot() -> [LiveEntry] {
        let now = Date()
        var out: [LiveEntry] = []
        for (k, g) in grants where g.expiration > now {
            guard let (pid, scope) = Self.splitStoreKey(k) else { continue }
            out.append(LiveEntry(
                profileID: pid, scope: scope,
                kind: .allow,
                expiration: g.expiration,
                scopeDisplayName: g.scopeDisplayName,
                isSessionScoped: g.isSessionScoped))
        }
        for (k, d) in denies where d.expiration > now {
            guard let (pid, scope) = Self.splitStoreKey(k) else { continue }
            out.append(LiveEntry(
                profileID: pid, scope: scope,
                kind: .deny,
                expiration: d.expiration,
                scopeDisplayName: d.scopeDisplayName,
                isSessionScoped: false))
        }
        return out.sorted { $0.scopeDisplayName < $1.scopeDisplayName }
    }

    public func revoke(profileID: UUID, scope: String) {
        let key = Self.storeKey(profileID: profileID, scope: scope)
        grants.removeValue(forKey: key)
        denies.removeValue(forKey: key)
    }

    /// Wipe every grant + deny for this profile. Session teardown
    /// calls this so session-scope decisions don't survive into
    /// the next launch.
    public func revokeAll(profileID: UUID) {
        let prefix = profileID.uuidString + "|"
        for k in grants.keys where k.hasPrefix(prefix) {
            grants.removeValue(forKey: k)
        }
        for k in denies.keys where k.hasPrefix(prefix) {
            denies.removeValue(forKey: k)
        }
    }

    public func revokeEverything() {
        grants.removeAll()
        denies.removeAll()
    }

    @MainActor
    private static func askUser(profileName: String,
                                scopeDisplayName: String,
                                operation: String) -> Decision {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString(
                "Allow write on “%@” from profile “%@”?",
                comment: "Guardrails write prompt: scope display name + profile name"),
            scopeDisplayName, profileName)
        // The operation goes in the body verbatim so the user sees
        // the exact query / verb / resource that's about to fire.
        // It can be a multi-line SQL statement; NSAlert renders
        // newlines.
        alert.informativeText = operation
        alert.alertStyle = .warning
        // Default action is the safer of the two long grants — 15 min.
        alert.addButton(withTitle: NSLocalizedString("Allow for 15 minutes", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Allow once", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Allow for the rest of the session", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Don't allow", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .allow15min
        case .alertSecondButtonReturn: return .allowOnce
        case .alertThirdButtonReturn:  return .allowSession
        default:                        return .deny
        }
    }
}
