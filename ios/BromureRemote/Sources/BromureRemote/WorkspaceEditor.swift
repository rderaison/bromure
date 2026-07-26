import SwiftUI

// MARK: - Workspace editor (iOS)
//
// The SAME `ProfileEditorView` the desktop opens, presented as a sheet and
// backed by the remote document round-trip the macOS fat client uses:
// GET /profiles/{id}?full=1 (secrets blanked) → edit → secret-preserving PUT,
// or a blank draft → POST /profiles for "New Workspace". Host-side-only
// affordances (SSH-key import, subscription registration) stay hidden — their
// callbacks are nil, exactly like the macOS remote editor.

/// What the editor sheet is on: a fresh workspace or an existing profile id.
enum WorkspaceEdit: Identifiable, Hashable {
    case new
    case existing(Profile.ID)
    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let u): return u.uuidString
        }
    }
    var editingID: Profile.ID? {
        switch self {
        case .new: return nil
        case .existing(let u): return u
        }
    }
}

struct WorkspaceEditorSheet: View {
    let controller: RemoteHostController
    let editing: Profile.ID?
    let onClose: () -> Void

    /// Loaded profile (edit) or draft (new); nil while the fetch is in flight.
    @State private var loaded: LoadedEditor?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saving = false
    /// Server-generated public key to surface after a save asked for one.
    @State private var generatedKey: String?
    /// Save touched a boot-baked field on a running workspace — offer restart.
    @State private var offerRestart: Profile.ID?

    struct LoadedEditor {
        var profile: Profile
        var isNew: Bool
        var credentialRefs: [CredentialRef]?
        /// Baseline for the restart-requiring diff (edit flavour only).
        var original: Profile?
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loaded {
                    editor(loaded)
                } else if let loadError {
                    errorAndProgress(loadError)
                } else {
                    ProgressView("Loading workspace settings…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(editing == nil ? "New Workspace" : "Workspace Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The editor carries its own Cancel/Save bar (same as macOS);
                // the nav bar just needs an escape hatch while loading/erroring.
                if loaded == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onClose)
                    }
                }
            }
        }
        // The default iPad form sheet is cramped in portrait — the editor is a
        // full sidebar-plus-detail surface, so take the page-sized sheet where
        // the OS offers it (iOS 17 keeps the stock size).
        .editorSheetSizing()
        .interactiveDismissDisabled()   // an half-edited draft shouldn't swipe away
        .task { await load() }
        .alert("New SSH key generated", isPresented: Binding(
            get: { generatedKey != nil },
            set: { if !$0 { generatedKey = nil; finishAfterKeyAlert() } })) {
            Button("Copy Key") {
                if let generatedKey { platformCopyToPasteboard(generatedKey) }
            }
            Button("OK") {}
        } message: {
            Text("Add this public key to your Git host:\n\n\(generatedKey ?? "")")
        }
        .alert("Restart to apply these changes?", isPresented: Binding(
            get: { offerRestart != nil },
            set: { if !$0 { offerRestart = nil; onClose() } })) {
            Button("Restart Now") {
                if let id = offerRestart { controller.restartWorkspace(id) }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Some settings you changed (like networking, memory, or shared folders) are baked into the VM at boot, so the running workspace won't pick them up until it restarts.")
        }
        .alert("Couldn't save the workspace", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private func errorAndProgress(_ loadError: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load the workspace", systemImage: "exclamationmark.triangle")
        } description: {
            Text(loadError)
        } actions: {
            Button("Retry") { self.loadError = nil; Task { await load() } }
            Button("Close", role: .cancel, action: onClose)
        }
    }

    @ViewBuilder
    private func editor(_ state: LoadedEditor) -> some View {
        ProfileEditorView(
            profile: state.profile,
            isNew: state.isNew,
            terminalDefaults: TerminalAppDefaults.load(),
            storageContext: nil,
            remoteCredentialRefs: state.credentialRefs,
            onSave: { edited, generateSSH in save(edited, generateSSH: generateSSH) },
            onCancel: onClose)
            .disabled(saving)
            .overlay {
                if saving { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
    }

    // MARK: Load

    private func load() async {
        guard loaded == nil else { return }
        guard let id = editing else {
            // New workspace: a numbered placeholder name so the user can save
            // immediately — same seeding as the desktop's "+".
            let taken = Set(controller.profiles.map { $0.name })
            var n = controller.profiles.count + 1
            var name = "Workspace \(n)"
            while taken.contains(name) { n += 1; name = "Workspace \(n)" }
            loaded = LoadedEditor(
                profile: Profile(name: name, tool: .claude, authMode: .subscription),
                isNew: true, credentialRefs: nil, original: nil)
            return
        }
        do {
            let doc = try await controller.fetchProfileDoc(id)
            let data = try JSONSerialization.data(withJSONObject: doc)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let profile = try dec.decode(Profile.self, from: data)
            // The remote profile's secrets are blanked, so use the
            // server-computed ref list to populate Credentials/Guardrails.
            let refs = (doc["configuredCredentialRefs"] as? [String])?
                .compactMap { CredentialRef(wireID: $0) }
            loaded = LoadedEditor(profile: profile, isNew: false,
                                  credentialRefs: refs, original: profile)
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Save

    private func save(_ edited: Profile, generateSSH: Bool) {
        guard var doc = ACAppDelegate.codableToDict(edited), !saving else { return }
        // The Profile encoder omits an empty kubeconfigs array; send it
        // explicitly so removing the last kube context is honored server-side.
        if edited.kubeconfigs.isEmpty { doc["kubeconfigs"] = [[String: Any]]() }
        if generateSSH { doc["generateSSH"] = true }
        saving = true
        let original = loaded?.original
        Task { @MainActor in
            defer { saving = false }
            do {
                let resp: [String: Any]
                if let id = editing {
                    resp = try await controller.saveProfileDoc(id, doc)
                } else {
                    resp = try await controller.createProfileDoc(doc)
                }
                // Some settings only apply on a fresh boot — offer the restart
                // now, exactly like the desktop editors.
                if let id = editing, let original,
                   RemoteHostController.restartRequiringChanges(from: original, to: edited),
                   controller.runState(for: id) == .running || controller.runState(for: id) == .booting {
                    offerRestart = id
                }
                if generateSSH, let pub = resp["sshPublicKey"] as? String, !pub.isEmpty {
                    generatedKey = pub   // onClose runs when the alert dismisses
                } else if offerRestart == nil {
                    onClose()
                }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// The key alert is the last thing standing between a successful save and
    /// dismissal — unless the restart offer is also queued, which then owns
    /// the dismissal.
    private func finishAfterKeyAlert() {
        if offerRestart == nil { onClose() }
    }
}

extension View {
    /// iPad's default form sheet is cramped for the editor, especially in
    /// portrait. Page sizing hands it a near-full-height sheet on iOS 18+;
    /// iOS 17 keeps the stock form sheet (no smaller than before).
    @ViewBuilder func editorSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.page)
        } else {
            self
        }
    }
}
