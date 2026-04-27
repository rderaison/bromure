import Foundation
import AppKit

/// Per-credential consent gate.
///
/// Every credential surface (AWS server, SSH agent sign, HTTP token
/// swap) calls `consent(...)` before doing the substitution. If the
/// credential's `requireApproval` flag is off, the call site short-
/// circuits without ever reaching the broker. When the flag is on, the
/// broker checks for a live grant; if there isn't one, it pops a
/// modal NSAlert offering Don't allow / 5 min / 1 hr / Rest of session.
///
/// Concurrent calls for the same `(profileID, credentialID)` key
/// coalesce onto the same dialog — a chatty agent firing a dozen
/// parallel requests sees one prompt, not twelve.
///
/// All grants are in-memory only. The session-scope variant is wiped
/// when `revokeAll(profileID:)` runs at session teardown; the time-
/// bounded variants expire on the clock.
public actor ConsentBroker {
    public enum Decision: Sendable {
        case deny
        case allow5min
        case allow1hr
        /// Until the profile's session ends. Bromure-AC clears these
        /// in `unregister(profileID:)` when the user closes the
        /// session window.
        case allowSession
    }

    /// Synthetic credential identifier — collisions across credential
    /// kinds avoided by prefixing with the kind.
    public typealias CredentialID = String

    public struct Grant: Sendable {
        /// Expiration. `.distantFuture` for the session-scope variant
        /// (cleared by `revokeAll` rather than the clock).
        public let expiration: Date
        public let credentialDisplayName: String
        public let isSessionScoped: Bool
        public init(expiration: Date,
                    credentialDisplayName: String,
                    isSessionScoped: Bool) {
            self.expiration = expiration
            self.credentialDisplayName = credentialDisplayName
            self.isSessionScoped = isSessionScoped
        }
    }

    public enum DecisionKind: Sendable {
        case allow
        case deny
    }

    /// Unified row for the Approvals window — covers both live allow
    /// grants and live deny memories. Flat fields so the view doesn't
    /// have to switch on a sum type per cell.
    public struct LiveEntry: Sendable {
        public let profileID: UUID
        public let credentialID: CredentialID
        public let kind: DecisionKind
        public let expiration: Date
        public let credentialDisplayName: String
        /// Only meaningful when `kind == .allow`. Always false for
        /// denies (deny memory is hard-capped at `denyTTL`).
        public let isSessionScoped: Bool
    }

    /// Internal storage for a remembered deny. We keep the display
    /// name alongside the expiration so the Approvals window can
    /// render denies the same way it renders allows.
    private struct DenyMemory: Sendable {
        let expiration: Date
        let credentialDisplayName: String
    }

    private static func storeKey(profileID: UUID, credentialID: CredentialID) -> String {
        return profileID.uuidString + "|" + credentialID
    }

    private static func splitStoreKey(_ s: String) -> (UUID, CredentialID)? {
        guard let pipe = s.firstIndex(of: "|") else { return nil }
        let uuidStr = String(s[..<pipe])
        let credID  = String(s[s.index(after: pipe)...])
        guard let uuid = UUID(uuidString: uuidStr) else { return nil }
        return (uuid, credID)
    }

    private var grants: [String: Grant] = [:]
    /// Time-bounded "Don't allow" memory. When the user clicks
    /// Don't allow, we record `now + 5min` here along with the
    /// credential's display name (so the Approvals window can list
    /// the deny the same way it lists allows). Subsequent calls for
    /// the same key auto-deny without re-prompting until the entry
    /// expires. Same scope semantics as `grants` — cleared on
    /// `revoke*` and on session teardown.
    private var denies: [String: DenyMemory] = [:]
    /// How long a Don't-allow click is remembered. Short enough that
    /// a user who changed their mind isn't held hostage; long enough
    /// to silence a chatty agent that retries the same operation
    /// dozens of times after a refusal.
    private static let denyTTL: TimeInterval = 5 * 60
    /// Coalesced waiters: while a prompt is on-screen for a key, any
    /// other call for the same key parks here and resumes when the
    /// dialog resolves.
    private var pending: [String: [CheckedContinuation<Bool, Never>]] = [:]
    /// profileID → display name. Set by `ACAppDelegate` at session
    /// launch so the dialog can say "Profile <name> wants to…".
    private var profileNames: [UUID: String] = [:]

    public init() {}

    public func setProfileName(_ name: String, for profileID: UUID) {
        profileNames[profileID] = name
    }

    public func clearProfileName(for profileID: UUID) {
        profileNames.removeValue(forKey: profileID)
    }

    /// Main entry point. Returns true iff the caller may proceed with
    /// the substitution / signing / cred vending.
    ///
    /// - Parameters:
    ///   - profileID: the profile owning the credential.
    ///   - credentialID: stable identifier for the credential — see
    ///     `ConsentCredentialID` helpers for the conventions.
    ///   - credentialDisplayName: shown in the dialog title (e.g.
    ///     "AWS access key AKIA…XYZ", "GitHub token (octocat)").
    ///   - scopeHint: shown as informative text in the dialog (e.g.
    ///     "for any *.openai.com request", "to sign with key
    ///     bromure-ac:work").
    public func consent(profileID: UUID,
                        credentialID: CredentialID,
                        credentialDisplayName: String,
                        scopeHint: String) async -> Bool {
        let key = Self.storeKey(profileID: profileID, credentialID: credentialID)
        let now = Date()

        FileHandle.standardError.write(Data(
            "[consent] check \(credentialID) for profile \(profileID.uuidString.prefix(8))\n".utf8))

        // A live deny short-circuits before the allow check. If the
        // user just said no, we don't quietly undo that decision by
        // honoring an older allow grant (in practice they shouldn't
        // both be live, but defensive ordering matters when the
        // ordering question ever comes up).
        if let mem = denies[key], mem.expiration > now {
            FileHandle.standardError.write(Data(
                "[consent] live deny for \(credentialID) — auto-deny\n".utf8))
            return false
        } else if denies[key] != nil {
            denies.removeValue(forKey: key)
        }

        if let g = grants[key], g.expiration > now {
            FileHandle.standardError.write(Data(
                "[consent] live grant for \(credentialID) — auto-allow\n".utf8))
            return true
        } else if grants[key] != nil {
            grants.removeValue(forKey: key)
        }

        // Coalesce. If a prompt for this key is already on-screen,
        // park a continuation and return when the dialog resolves.
        if pending[key] != nil {
            return await withCheckedContinuation { cont in
                pending[key, default: []].append(cont)
            }
        }
        pending[key] = []

        let profileName = profileNames[profileID] ?? "(unknown profile)"
        let decision = await Self.askUser(profileName: profileName,
                                          credentialDisplayName: credentialDisplayName,
                                          scopeHint: scopeHint)

        let allow: Bool
        switch decision {
        case .deny:
            denies[key] = DenyMemory(
                expiration: now.addingTimeInterval(Self.denyTTL),
                credentialDisplayName: credentialDisplayName)
            allow = false
        case .allow5min:
            grants[key] = Grant(expiration: now.addingTimeInterval(5 * 60),
                                credentialDisplayName: credentialDisplayName,
                                isSessionScoped: false)
            allow = true
        case .allow1hr:
            grants[key] = Grant(expiration: now.addingTimeInterval(60 * 60),
                                credentialDisplayName: credentialDisplayName,
                                isSessionScoped: false)
            allow = true
        case .allowSession:
            grants[key] = Grant(expiration: .distantFuture,
                                credentialDisplayName: credentialDisplayName,
                                isSessionScoped: true)
            allow = true
        }

        let waiters = pending[key] ?? []
        pending.removeValue(forKey: key)
        for w in waiters { w.resume(returning: allow) }
        return allow
    }

    /// Snapshot of all live (unexpired) decisions — both allow grants
    /// and remembered denies — for the management UI.
    public func snapshot() -> [LiveEntry] {
        let now = Date()
        var out: [LiveEntry] = []
        for (k, g) in grants where g.expiration > now {
            guard let (pid, cid) = Self.splitStoreKey(k) else { continue }
            out.append(LiveEntry(
                profileID: pid, credentialID: cid,
                kind: .allow,
                expiration: g.expiration,
                credentialDisplayName: g.credentialDisplayName,
                isSessionScoped: g.isSessionScoped))
        }
        for (k, d) in denies where d.expiration > now {
            guard let (pid, cid) = Self.splitStoreKey(k) else { continue }
            out.append(LiveEntry(
                profileID: pid, credentialID: cid,
                kind: .deny,
                expiration: d.expiration,
                credentialDisplayName: d.credentialDisplayName,
                isSessionScoped: false))
        }
        return out.sorted { $0.credentialDisplayName < $1.credentialDisplayName }
    }

    public func revoke(profileID: UUID, credentialID: CredentialID) {
        let key = Self.storeKey(profileID: profileID, credentialID: credentialID)
        grants.removeValue(forKey: key)
        denies.removeValue(forKey: key)
    }

    /// Wipe every grant *and* deny for this profile. Called at
    /// session teardown so session-scope decisions don't survive
    /// into the next launch.
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

    // MARK: - Modal prompt

    @MainActor
    private static func askUser(profileName: String,
                                credentialDisplayName: String,
                                scopeHint: String) -> Decision {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString(
                "Allow “%@” to use %@?",
                comment: "Consent prompt: profile name + credential display name"),
            profileName, credentialDisplayName)
        alert.informativeText = scopeHint
        alert.alertStyle = .informational
        // Order: most-likely choice first (becomes the default action).
        alert.addButton(withTitle: NSLocalizedString("Allow for 1 hour", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Allow for 5 minutes", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Allow for the rest of the session", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Don't allow", comment: ""))
        // Activate the app so the modal grabs focus even when the VM
        // window is the user's foreground context.
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .allow1hr
        case .alertSecondButtonReturn: return .allow5min
        case .alertThirdButtonReturn:  return .allowSession
        default:                        return .deny
        }
    }
}

/// Conventions for the synthetic credential identifier strings.
/// Stable across launches so a "Allow for the rest of the session"
/// grant matches the same credential within the same session.
public enum ConsentCredentialID {
    public static func primaryToolAPIKey(tool: String) -> String { "tool-apikey:" + tool }
    public static func aws() -> String                            { "aws" }
    public static func digitalOcean() -> String                   { "do-pat" }
    public static func sshKey(_ id: String) -> String             { "ssh:" + id }
    public static func bromureSSHKey() -> String                  { "ssh:bromure-auto" }
    public static func gitHTTPS(_ id: UUID) -> String             { "git-https:" + id.uuidString }
    public static func manualToken(_ id: UUID) -> String          { "manual:" + id.uuidString }
    public static func dockerRegistry(_ id: UUID) -> String       { "docker:" + id.uuidString }
    public static func kubeconfig(_ id: UUID) -> String           { "kube:" + id.uuidString }
}
