import Foundation
import AppKit

/// Consent broker for the `lockfilePrompt` supply-chain layer (and
/// any other ask-the-user paths the policy fires). Same shape as
/// `GuardrailsConsentBroker` — actor with coalescing, in-memory
/// grants, profile-name plumbing — kept distinct so the snapshot /
/// approvals UI can list "Supply chain decisions" separately from
/// "Guardrail decisions". They're conceptually different
/// (intercepting versus rejecting agent intent) even when the
/// broker code shape is identical.
public actor SupplyChainConsentBroker {
    public enum Decision: Sendable {
        case deny
        case allowOnce
        case allow15min
        case allowSession
    }

    public struct Grant: Sendable {
        public let expiration: Date
        public let scopeDisplayName: String
        public let isSessionScoped: Bool
    }

    public enum DecisionKind: Sendable {
        case allow
        case deny
    }

    public struct LiveEntry: Sendable {
        public let profileID: UUID
        public let scope: String
        public let kind: DecisionKind
        public let expiration: Date
        public let scopeDisplayName: String
        public let isSessionScoped: Bool
    }

    private struct DenyMemory: Sendable {
        let expiration: Date
        let scopeDisplayName: String
    }

    private static func storeKey(profileID: UUID, scope: String) -> String {
        profileID.uuidString + "|" + scope
    }

    private static func splitStoreKey(_ s: String) -> (UUID, String)? {
        guard let pipe = s.firstIndex(of: "|") else { return nil }
        let uuidStr = String(s[..<pipe])
        let scope = String(s[s.index(after: pipe)...])
        guard let uuid = UUID(uuidString: uuidStr) else { return nil }
        return (uuid, scope)
    }

    private var grants: [String: Grant] = [:]
    private var denies: [String: DenyMemory] = [:]
    private static let denyTTL: TimeInterval = 60
    private var pending: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var profileNames: [UUID: String] = [:]

    public init() {}

    public func setProfileName(_ name: String, for profileID: UUID) {
        profileNames[profileID] = name
    }
    public func clearProfileName(for profileID: UUID) {
        profileNames.removeValue(forKey: profileID)
    }

    /// Returns true iff the supply-chain action should proceed.
    ///
    /// - Parameters:
    ///   - profileID: profile owning the request.
    ///   - scope: stable identifier for the grant scope. Convention:
    ///     `"lockfile:<ecosystem>"` for the npm-ci-style bypass,
    ///     `"override:<ecosystem>:<pkg>:<version>"` if we ever ask
    ///     the user to override a specific block.
    ///   - scopeDisplayName: shown in the dialog title.
    ///   - detail: shown verbatim in the dialog body — exact
    ///     description of what's about to happen ("npm ci will fetch
    ///     187 packages pinned by package-lock.json…").
    public func consent(profileID: UUID,
                        scope: String,
                        scopeDisplayName: String,
                        detail: String) async -> Bool {
        let key = Self.storeKey(profileID: profileID, scope: scope)
        let now = Date()

        FileHandle.standardError.write(Data(
            "[supply-chain-consent] check \(scope) for profile \(profileID.uuidString.prefix(8))\n".utf8))

        if let mem = denies[key], mem.expiration > now {
            FileHandle.standardError.write(Data(
                "[supply-chain-consent] live deny for \(scope) — auto-deny\n".utf8))
            return false
        } else if denies[key] != nil {
            denies.removeValue(forKey: key)
        }

        if let g = grants[key], g.expiration > now {
            FileHandle.standardError.write(Data(
                "[supply-chain-consent] live grant for \(scope) — auto-allow\n".utf8))
            return true
        } else if grants[key] != nil {
            grants.removeValue(forKey: key)
        }

        if pending[key] != nil {
            return await withCheckedContinuation { cont in
                pending[key, default: []].append(cont)
            }
        }
        pending[key] = []

        let profileName = profileNames[profileID] ?? "(unknown profile)"
        let decision: Decision
        if RemoteConsent.isActive(for: profileID) {
            // No GUI (SSH/CLI): prompt in the workspace's tmux. nil → deny.
            let title = String(format: NSLocalizedString(
                "Pass through %@ from workspace “%@”?",
                comment: "Supply-chain bypass prompt"), scopeDisplayName, profileName)
            let choices = ["Allow for 15 minutes", "Allow once",
                           "Allow for the rest of the session", "Don't allow"]
            let idx = await Task.detached {
                RemoteConsent.choose(profileID: profileID, title: title,
                                     message: detail, choices: choices)
            }.value
            switch idx {
            case 0:  decision = .allow15min
            case 1:  decision = .allowOnce
            case 2:  decision = .allowSession
            default: decision = .deny
            }
        } else {
            decision = await Self.askUser(profileName: profileName,
                                          scopeDisplayName: scopeDisplayName,
                                          detail: detail)
        }

        let allow: Bool
        switch decision {
        case .deny:
            denies[key] = DenyMemory(
                expiration: now.addingTimeInterval(Self.denyTTL),
                scopeDisplayName: scopeDisplayName)
            allow = false
        case .allowOnce:
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
                                detail: String) -> Decision {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString(
                "Pass through %@ from workspace “%@”?",
                comment: "Supply-chain bypass prompt"),
            scopeDisplayName, profileName)
        alert.informativeText = detail
        alert.alertStyle = .warning
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
