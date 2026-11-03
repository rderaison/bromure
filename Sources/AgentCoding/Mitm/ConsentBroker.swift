import Foundation
import AppKit

/// Per-credential consent gate.
///
/// Every credential surface (AWS server, SSH agent sign, HTTP token
/// swap) calls `consent(...)` before doing the substitution. If the
/// credential's `requireApproval` flag is off, the call site short-
/// circuits without ever reaching the broker. When the flag is on, the
/// broker checks for a live grant; if there isn't one, it pops a
/// non-modal prompt (`ConsentPrompt`, auto-deny on timeout) offering
/// Don't allow / 5 min / 1 hr / Rest of session.
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
        /// Until the session ends (`expiration` is `.distantFuture`). A
        /// prompt's "Don't allow" is capped at `denyTTL`; only a deny set
        /// from the Guardrails pane can be session-scoped.
        public let isSessionScoped: Bool
    }

    /// Internal storage for a remembered deny. We keep the display
    /// name alongside the expiration so the Approvals window can
    /// render denies the same way it renders allows.
    private struct DenyMemory: Sendable {
        let expiration: Date
        let credentialDisplayName: String
        var isSessionScoped = false
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
    /// The open prompt's handle per key (`ConsentPrompt.choose`'s token).
    private var promptTokens: [String: UUID] = [:]
    /// Prompts a Guardrails decision overtook (`grant`, `deny`, session
    /// teardown): withdrawn, their waiters answered with that decision and
    /// their key freed; the prompt's own answer, if one still comes, neither
    /// stores nor allows — a "Don't allow" shrank a session deny to 5
    /// minutes, and an "Allow" (Return) let the in-flight request through a
    /// deny. Left up, the panel held the key: after a revoke, its Allow was
    /// ignored and every new request parked on it and was refused.
    private var superseded: Set<UUID> = []
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
        let checkedAt = Date()

        FileHandle.standardError.write(Data(
            "[consent] check \(credentialID) for profile \(profileID.uuidString.prefix(8))\n".utf8))

        // A live deny short-circuits before the allow check. If the
        // user just said no, we don't quietly undo that decision by
        // honoring an older allow grant (in practice they shouldn't
        // both be live, but defensive ordering matters when the
        // ordering question ever comes up).
        if let mem = denies[key], mem.expiration > checkedAt {
            FileHandle.standardError.write(Data(
                "[consent] live deny for \(credentialID) — auto-deny\n".utf8))
            Self.recordDecision(profileID: profileID, credentialID: credentialID,
                                credential: credentialDisplayName, scope: scopeHint, outcome: .rememberedDeny)
            return false
        } else if denies[key] != nil {
            denies.removeValue(forKey: key)
        }

        if let g = grants[key], g.expiration > checkedAt {
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
        let token = UUID()
        promptTokens[key] = token

        let profileName = profileNames[profileID] ?? "(unknown workspace)"
        // Non-modal, with a deadline (no answer → deny); routed to a fat
        // client or attached terminal when one is watching. This actor waits
        // on a continuation — the main thread and the control socket don't.
        let title = String(format: NSLocalizedString("Allow “%@” to use %@?",
            comment: "Consent prompt: profile name + credential display name"),
            profileName, credentialDisplayName)
        let choices = [NSLocalizedString("Allow for 1 hour", comment: ""),
                       NSLocalizedString("Allow for 5 minutes", comment: ""),
                       NSLocalizedString("Allow for the rest of the session", comment: ""),
                       NSLocalizedString("Don't allow", comment: "")]
        let timeout = ConsentPrompt.defaultTimeout
        let idx = await ConsentPrompt.choose(profileID: profileID, title: title, message: scopeHint,
                                             choices: choices, denyIndex: choices.count - 1,
                                             timeout: timeout, token: token)
        if superseded.remove(token) != nil {
            // Overtaken while it was up: the newer decision stands. Its
            // waiters and its key went with the overtake (the key may be a
            // newer prompt's by now).
            return Self.liveAllow(grant: grants[key], deny: denies[key], at: Date())
        }
        promptTokens.removeValue(forKey: key)
        let decision: Decision
        switch idx {
        case 0:  decision = .allow1hr
        case 1:  decision = .allow5min
        case 2:  decision = .allowSession
        default: decision = .deny   // "Don't allow", timeout, dismissed
        }
        // A grant's lifetime starts at the answer, not when the prompt
        // opened (the user may have taken minutes to answer).
        let now = Date()
        // No answer before the deadline: nobody said no. It denies this
        // request only — remembered, a missed prompt silently refused every
        // retry for five minutes (S3-6); the next request asks again.
        let timedOut = idx == nil && Self.isTimeout(askedAt: checkedAt, answeredAt: now, timeout: timeout)

        let allow: Bool
        switch decision {
        case .deny:
            if !timedOut {
                denies[key] = DenyMemory(
                    expiration: now.addingTimeInterval(Self.denyTTL),
                    credentialDisplayName: credentialDisplayName)
            }
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

        Self.recordDecision(profileID: profileID, credentialID: credentialID,
                            credential: credentialDisplayName, scope: scopeHint,
                            outcome: timedOut ? .timedOut : Outcome(decision))

        let waiters = pending[key] ?? []
        pending.removeValue(forKey: key)
        for w in waiters { w.resume(returning: allow) }
        return allow
    }

    /// What a stored decision says now: a live deny refuses, a live grant
    /// allows, neither refuses (nobody said yes).
    nonisolated static func liveAllow(grant: Grant?, deny: Date?, at now: Date) -> Bool {
        if let deny, deny > now { return false }
        return (grant?.expiration ?? .distantPast) > now
    }

    private static func liveAllow(grant: Grant?, deny: DenyMemory?, at now: Date) -> Bool {
        liveAllow(grant: grant, deny: deny?.expiration, at: now)
    }

    /// A Guardrails decision for `key` while its prompt is up: the requests
    /// waiting on that prompt get it now, and the prompt's answer won't count.
    /// The prompt is withdrawn (its asker returns now) and the key freed: a
    /// later request — after a revoke, say — asks afresh instead of parking
    /// on a panel whose answer no longer counts.
    private func overtakePrompt(_ key: String, allow: Bool) {
        guard let waiters = pending.removeValue(forKey: key) else { return }
        if let token = promptTokens.removeValue(forKey: key) {
            superseded.insert(token)
            RemoteConsent.withdraw(token: token)   // a terminal prompt
            Task { @MainActor in ConsentPanelPresenter.shared.withdraw(token: token) }
        }
        for w in waiters { w.resume(returning: allow) }
    }

    /// What became of one consent request, as the Security Timeline says it.
    enum Outcome: String, Sendable {
        case allow1hr = "allow_1h", allow5min = "allow_5m", allowSession = "allow_session"
        case deny, timedOut = "timeout", rememberedDeny = "deny_remembered"

        init(_ d: Decision) {
            switch d {
            case .deny: self = .deny
            case .allow5min: self = .allow5min
            case .allow1hr: self = .allow1hr
            case .allowSession: self = .allowSession
            }
        }
    }

    /// A deny that came at (or past) the deadline is the prompt timing out,
    /// not the user's answer (every channel resolves a timeout as deny).
    nonisolated static func isTimeout(askedAt: Date, answeredAt: Date, timeout: TimeInterval) -> Bool {
        answeredAt.timeIntervalSince(askedAt) >= max(1, timeout) - 1
    }

    /// One Security Timeline row (and cloud event) per consent decision:
    /// a grant, a deny, a timeout, a remembered deny (coalesced there).
    nonisolated static func recordDecision(profileID: UUID, credentialID: CredentialID, credential: String,
                                           scope: String, outcome: Outcome) {
        BACEventEmitter.shared.emitDetached(
            profileID: profileID, eventType: "credential.consent",
            eventData: ["credential": .string(SecretFingerprint.redactLegacy(credential)),
                        "credential_id": .string(SecretFingerprint.redactLegacy(credentialID)),
                        "scope": .string(SecretFingerprint.redactLegacy(scope)),
                        "decision": .string(outcome.rawValue)])
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
                isSessionScoped: d.isSessionScoped))
        }
        return out.sorted { $0.credentialDisplayName < $1.credentialDisplayName }
    }

    /// Grant (or re-grant) without a prompt — the Guardrails pane's "Allow
    /// for …" menu. A timed grant runs from now, so re-granting a nearly
    /// spent 5 minutes gives a fresh 5. Clears a remembered deny. Keeps the
    /// display name a prompt already gave this credential.
    public func grant(profileID: UUID, credentialID: CredentialID,
                      _ decision: Decision, credentialDisplayName: String) {
        let key = Self.storeKey(profileID: profileID, credentialID: credentialID)
        let name = grants[key]?.credentialDisplayName ?? denies[key]?.credentialDisplayName
            ?? credentialDisplayName
        let now = Date()
        switch decision {
        case .deny:
            return
        case .allow5min:
            grants[key] = Grant(expiration: now.addingTimeInterval(5 * 60),
                                credentialDisplayName: name, isSessionScoped: false)
        case .allow1hr:
            grants[key] = Grant(expiration: now.addingTimeInterval(60 * 60),
                                credentialDisplayName: name, isSessionScoped: false)
        case .allowSession:
            grants[key] = Grant(expiration: .distantFuture,
                                credentialDisplayName: name, isSessionScoped: true)
        }
        denies.removeValue(forKey: key)
        overtakePrompt(key, allow: true)
        Self.recordDecision(profileID: profileID, credentialID: credentialID,
                            credential: name, scope: "granted from the Guardrails pane",
                            outcome: Outcome(decision))
    }

    /// Refuse without a prompt — the Guardrails pane's "Deny for …" menu.
    /// `duration` nil = until the session ends. Replaces a live grant, and
    /// runs from now like `grant`.
    public func deny(profileID: UUID, credentialID: CredentialID,
                     for duration: TimeInterval?, credentialDisplayName: String) {
        let key = Self.storeKey(profileID: profileID, credentialID: credentialID)
        let name = grants[key]?.credentialDisplayName ?? denies[key]?.credentialDisplayName
            ?? credentialDisplayName
        denies[key] = DenyMemory(
            expiration: duration.map { Date().addingTimeInterval($0) } ?? .distantFuture,
            credentialDisplayName: name,
            isSessionScoped: duration == nil)
        grants.removeValue(forKey: key)
        overtakePrompt(key, allow: false)
        Self.recordDecision(profileID: profileID, credentialID: credentialID,
                            credential: name, scope: "denied from the Guardrails pane",
                            outcome: .deny)
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
        // The session is over: a prompt still up for it allows nothing.
        for k in pending.keys where k.hasPrefix(prefix) {
            overtakePrompt(k, allow: false)
        }
    }

    public func revokeEverything() {
        grants.removeAll()
        denies.removeAll()
    }
}

/// Conventions for the synthetic credential identifier strings.
/// Stable across launches so a "Allow for the rest of the session"
/// grant matches the same credential within the same session.
// ConsentCredentialID moved to ConsentCredentialID.swift (shared, Foundation)
// so the iOS fat client can compile SessionTokenPlan/Profile without this
// file's AppKit ConsentBroker.
