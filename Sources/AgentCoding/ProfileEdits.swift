import Foundation
#if canImport(SandboxEngine)
import SandboxEngine
#endif

// Saving a created or edited workspace -- the editor's Save, and the
// control socket's create / PUT / PATCH -- on any host: the macOS app
// delegate (ProfileEdits+App.swift) and the Linux daemon.

/// What saving a workspace needs from its host.
@MainActor
protocol ProfileEditHost: AnyObject {
    var profiles: [Profile] { get set }
    var store: ProfileStore { get }
    var terminalDefaults: TerminalAppDefaults { get }
    /// The proxy's per-install salt for stand-in tokens; nil without a proxy.
    var fakeTokenSalt: Data? { get }
    func profileByNameOrID(_ key: String) -> Profile?
    func sessionTokenPlan(for profile: Profile, salt: Data) -> SessionTokenPlan
    /// A fresh ed25519 key in the workspace's host-only agent dir; the
    /// OpenSSH public key.
    func makeSSHKey(in dir: URL) throws -> String
    /// An already-saved edit applied to the workspace's running session.
    func applyLiveEditToRunningSession(_ new: Profile)
    func automationProfileDescribe(_ key: String) -> [String: Any]?
    /// `profiles` was reloaded after a save (`saved`), or after an edit found
    /// its workspace deleted (nil): the host's own surfaces follow.
    func profilesDidChange(saved: Profile?, editing: Profile?)
}

extension ProfileEditHost {
    /// Shared save + app-state reconciliation for a created/edited profile.
    /// Deliberately AppKit-free (no NSAlert, no window ops) so the headless
    /// control-socket path can call it too — the GUI-only bits (folder-discard
    /// alert, SSH-key viewer, live-session restart prompt) stay in the callers.
    /// Mutates `profile` (may set `sshPublicKey`) and refreshes `profiles` +
    /// the sidebar. Throws on disk/keychain failure.
    @MainActor
    func persistEditedProfile(_ profile: inout Profile, editing: Profile?,
                              generateSSH: Bool, policySource: String = "user") throws {
        // The organization boundary is a hard gate on every save, whichever
        // path it came from (the Sandbox drawer's Allow used to skip it).
        if let refusal = OpenShellGovernance.shared.refusal(saving: profile, editing: editing) {
            throw refusal
        }
        // An edit of a workspace the other process deleted meanwhile: don't
        // write it back.
        if editing != nil, !store.exists(profile) {
            profiles = store.loadAll()
            profilesDidChange(saved: nil, editing: editing)
            throw ProfileStore.ProfileGone(name: profile.name)
        }
        // Belt-and-braces: trim every secret before persisting. Pasted tokens
        // routinely come with trailing whitespace; embedding either in an HTTP
        // header value at swap time would corrupt the request and trigger a
        // "401 Invalid API key" upstream.
        let trim = { (s: String?) in s?.trimmingCharacters(in: .whitespacesAndNewlines) }
        profile.apiKey = trim(profile.apiKey)
        profile.additionalTools = profile.additionalTools.map { var s = $0; s.apiKey = trim(s.apiKey); return s }
        profile.gitHTTPSCredentials = profile.gitHTTPSCredentials.map {
            var c = $0; c.token = c.token.trimmingCharacters(in: .whitespacesAndNewlines); return c
        }
        profile.manualTokens = profile.manualTokens.map {
            var t = $0; t.realValue = t.realValue.trimmingCharacters(in: .whitespacesAndNewlines); return t
        }

        // Credentials the VM minted while the editor was open
        // (`saveMintedCredential`): the editor never edits them, so the app's
        // copy -- secrets included -- is the current one.
        if let current = profiles.first(where: { $0.id == profile.id }) {
            profile.mintedCredentials = current.mintedCredentials
            // Fields the app saves while settings is open -- the dashboard's
            // notes, the sidebar's Squelch switch: left as the editor opened
            // them, they're the stored ones (Finding CWE-362, "Saving
            // workspace settings overwrites notes edited on the VM
            // dashboard"). Edited here, the editor's win.
            if let opened = editing { profile.adoptAppEdits(from: current, opened: opened) }
        }
        // The editor's copy is as old as the window: keep what the app
        // updated meanwhile (lastUsedAt went backwards on a save).
        try store.saveEdited(&profile)
        // The OpenShell policy's revision history (identical saves keep the
        // current version).
        if profile.usesOpenShellPolicy || !(PolicyHistory.shared.revisions(in: store.profileDirectory(for: profile)).isEmpty) {
            PolicyHistory.shared.record(policy: profile.networkPolicy, source: policySource,
                                        in: store.profileDirectory(for: profile))
        }
        // Write the managed home with FAKE credentials, not reals. The editor
        // save previously called prepareHomeDirectory with NO token plan, so
        // its git / gh / glab / docker writers fell back to the real secret —
        // and for a virtiofs workspace that home IS the live `/home/ubuntu`,
        // so a cosmetic save (rename, opacity…) left a real token in the
        // guest until a later credential-affecting edit happened to rewrite
        // the fakes. Build the same per-session plan the launch/refresh paths
        // use so the editor can only ever write fakes. (The plan is
        // deterministic in (real value, install salt); a not-yet-running
        // profile gets re-seeded with the same fakes on its next boot.)
        let editSalt = fakeTokenSalt ?? Data(repeating: 0, count: 32)
        let editPlan = sessionTokenPlan(for: profile, salt: editSalt)
        try store.prepareHomeDirectory(for: profile, terminalDefaults: terminalDefaults,
                                       tokenPlan: editPlan)
        let agentDir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent", isDirectory: true)
        if generateSSH {
            // Agent dir is host-only — never mounted into the VM. The private
            // seed lives here; the public key gets a courtesy copy into the
            // VM's ~/.ssh for reference.
            let pub = try makeSSHKey(in: agentDir)
            profile.sshPublicKey = pub
            try store.save(profile)
        } else if editing == nil,
                  profile.sshPublicKey != nil,
                  !FileManager.default.fileExists(atPath:
                    agentDir.appendingPathComponent("id_ed25519.raw").path) {
            // New profile that inherited the default public key from the
            // preferences template — copy the matching private seed in so the
            // in-process ssh-agent has something to load.
            try DefaultSSHKey.copy(to: agentDir)
        }
        profiles = store.loadAll()
        profilesDidChange(saved: profile, editing: editing)
    }

    func automationUpsertProfile(idOrName: String?, doc rawDoc: [String: Any]) -> [String: Any] {
        // Drop transport-only markers before decoding. `generateSSH` is a
        // control flag (not a Profile field): when set, the host mints a fresh
        // ed25519 key in the profile's agent dir — host-side, exactly like the
        // GUI's "Generate SSH key". The private seed never enters the VM.
        var doc = rawDoc
        doc.removeValue(forKey: "_secretsRedacted")
        let generateSSH = (rawDoc["generateSSH"] as? Bool) == true
        doc.removeValue(forKey: "generateSSH")
        // `_commentsIfStill`: the notes an implicit dashboard save started
        // from. Other notes stored since (settings) win: its `comments` is
        // dropped here, where the check and the write are one step.
        let commentsIfStill = rawDoc["_commentsIfStill"] as? String
        doc.removeValue(forKey: "_commentsIfStill")
        var commentsSuperseded = false

        let profile: Profile
        let editing: Profile?

        if let idOrName {
            // ---- Update: full-document replace of a workspace's non-secret
            // fields, preserving stored secrets the caller didn't re-supply.
            guard let existing = profileByNameOrID(idOrName) else {
                return ["ok": false, "error": "Workspace not found: \(idOrName)"]
            }
            commentsSuperseded = ProfileNotes.dropSupersededComments(&doc, stored: existing.comments, ifStill: commentsIfStill)
            // A partial document (only the fields to change) is overlaid on
            // the stored workspace; a full one replaces every field it names.
            var incoming: Profile
            switch ProfileDocument.merge(doc, over: existing) {
            case .success(let p): incoming = p
            case .failure(let e): return ["ok": false, "error": e.message]
            }
            // Server-owned identity — never trust the client's copies.
            incoming.id = existing.id
            incoming.createdAt = existing.createdAt
            incoming.lastUsedAt = existing.lastUsedAt

            // Shared-folder edits are incompatible with a suspended VM (same
            // reasoning as the GUI's discard alert). Headless can't prompt, so
            // refuse rather than silently discard the snapshot.
            if existing.folderPaths != incoming.folderPaths {
                let stateURL = store.profileDirectory(for: existing)
                    .appendingPathComponent("vm.state")
                if FileManager.default.fileExists(atPath: stateURL.path) {
                    return ["ok": false, "error":
                        "Shared folders changed but this workspace has a suspended VM. "
                        + "Stop it first (`vm kill \(existing.name)`), then edit folders."]
                }
            }

            // Secret preservation: a document round-tripped through describe/
            // export comes back with blank secrets. Harvest the existing set +
            // whatever the caller actually typed, overlay the latter on the
            // former, and re-apply — so untouched secrets survive.
            var existingCopy = existing
            let existingSecrets = ProfileSecrets.extract(stripping: &existingCopy)
            var incomingCopy = incoming
            let incomingSecrets = ProfileSecrets.extract(stripping: &incomingCopy)
            var merged = existingSecrets
            merged.overlay(with: incomingSecrets)
            merged.apply(to: &incoming)
            // Minted credentials are the VM's, never the document's: a copy
            // round-tripped while the VM minted one would drop it (and its
            // secret), and the next boot would sign its key as the workspace.
            incoming.mintedCredentials = existing.mintedCredentials

            // Kube contexts are part of this full-document replace: honor the
            // caller's exact set so removing one in the (redacted) editor sticks.
            // overlay/apply above already restored each redacted entry's stored
            // secret and kept existing entries by id; here we drop any context the
            // caller's document omitted. An absent `kubeconfigs` key means "don't
            // touch" (partial callers stay safe) — only an explicitly-sent array
            // is authoritative.
            if let sentKube = rawDoc["kubeconfigs"] as? [[String: Any]] {
                let keep = Set(sentKube.compactMap { ($0["id"] as? String).flatMap { UUID(uuidString: $0) } })
                incoming.kubeconfigs.removeAll { !keep.contains($0.id) }
            }

            profile = incoming
            editing = existing
        } else {
            // ---- Create: seed from the preferences template (so a new
            // workspace inherits the user's defaults + default OAuth tokens),
            // then overlay the caller's fields at the document level so
            // unspecified keys keep their template value.
            let name = (doc["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return ["ok": false, "error": "A workspace name is required."] }
            let minted = store.newProfileFromTemplate(name: name)
            var created: Profile
            switch ProfileDocument.merge(doc, over: minted) {
            case .success(let p): created = p
            case .failure(let e): return ["ok": false, "error": e.message]
            }
            // Force server-owned identity regardless of what the doc carried.
            created.id = minted.id
            created.createdAt = minted.createdAt
            created.lastUsedAt = nil
            profile = created
            editing = nil
        }

        // An OpenShell policy that doesn't validate would fail closed on the
        // next session; refuse it here like the GUI's disabled Save.
        if profile.usesOpenShellPolicy {
            do { _ = try OpenShellPolicy.parse(profile.networkPolicy) } catch {
                return ["ok": false, "error": "Invalid OpenShell policy: \(error)"]
            }
            if let r = OpenShellGovernance.shared.check(policyYAML: profile.networkPolicy,
                                                        providerRules: profile.openShellProviderRules),
               !r.passed {
                return ["ok": false, "error": "OpenShell policy is outside the organization boundary: \(r.summary)"]
            }
        }

        var toSave = profile
        do {
            try persistEditedProfile(&toSave, editing: editing, generateSSH: generateSSH, policySource: "api")
        } catch {
            var r: [String: Any] = ["ok": false, "error": error.localizedDescription]
            // The notes it dropped are still the ones that won: a client that
            // read only "failed" reopened its stale draft.
            if commentsSuperseded, let editing { r["commentsSuperseded"] = true; r["comments"] = editing.comments }
            return r
        }

        // Push host-side cosmetic + live-swap updates into a running session,
        // matching the GUI (minus the restart prompt, which needs a window).
        if editing != nil { applyLiveEditToRunningSession(toSave) }

        var result = automationProfileDescribe(toSave.id.uuidString) ?? ["id": toSave.id.uuidString]
        result["ok"] = true
        if commentsSuperseded { result["commentsSuperseded"] = true }
        // Surface the freshly-minted public key so the caller can show it for
        // pasting into GitHub etc. (public, not a secret).
        if generateSSH, let pub = toSave.sshPublicKey, !pub.isEmpty { result["sshPublicKey"] = pub }
        return result
    }
}

/// A workspace's notes as the dashboard saves them.
enum ProfileNotes {
    /// An implicit notes save over the API (`_commentsIfStill`) whose base
    /// isn't the stored notes any more: its `comments` is dropped (true).
    static func dropSupersededComments(_ doc: inout [String: Any], stored: String,
                                                   ifStill base: String?) -> Bool {
        guard let base, doc["comments"] != nil, !notesStill(stored, base) else { return false }
        doc.removeValue(forKey: "comments")
        return true
    }

    /// Stored notes still the ones an edit started from: trailing blanks
    /// aside, as the dashboard saves them.
    static func notesStill(_ stored: String, _ base: String) -> Bool {
        func trimmed(_ s: String) -> Substring {
            var t = Substring(s)
            while t.last?.isWhitespace == true { t.removeLast() }
            return t
        }
        return trimmed(stored) == trimmed(base)
    }
}
