import AppKit
import Foundation
import SwiftUI
@preconcurrency import Virtualization

// MARK: - SwiftUI helpers

extension ProfileColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: .blue
        case .red: .red
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .pink: .pink
        case .teal: .teal
        case .gray: .gray
        }
    }
}

extension Profile.Tool {
    var sfSymbol: String {
        switch self {
        case .claude: "sparkles"
        case .codex:  "terminal.fill"
        }
    }
}

/// A small colored gradient square with an SF symbol — the same idiom
/// the browser's settings sidebar uses to identify sections.
private struct GradientIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Picker (browser-style single pane)

struct ProfilePickerView: View {
    @Binding var profiles: [Profile]
    /// Profile IDs whose VM is currently running — shown as a green dot
    /// next to the row so the user knows which sessions are live.
    var runningProfiles: Set<Profile.ID>
    @State private var selectedID: Profile.ID?

    let onLaunch: (Profile) -> Void
    let onCreate: () -> Void
    let onEdit: (Profile) -> Void
    let onReset: (Profile) -> Void
    let onDelete: (Profile) -> Void
    let onShowPublicKey: (Profile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header with the app icon, mirroring the browser's chooser
            // styling.
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bromure Agentic Coding")
                        .font(.headline)
                    Text("Pick a profile to open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // List of profiles — bordered rows, alternating background.
            List(selection: $selectedID) {
                ForEach(profiles) { profile in
                    ProfileRow(
                        profile: profile,
                        isRunning: runningProfiles.contains(profile.id),
                        onEdit: { onEdit(profile) }
                    )
                    .tag(profile.id)
                    .contextMenu {
                        Button("Launch") { onLaunch(profile) }
                        Button("Edit…") { onEdit(profile) }
                        if profile.sshPublicKey != nil {
                            Button("SSH public key…") { onShowPublicKey(profile) }
                        }
                        Divider()
                        Button("Reset disk", role: .destructive) { onReset(profile) }
                        Button("Delete profile", role: .destructive) { onDelete(profile) }
                    }
                    .help(profile.comments)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 180)

            // + / - toolbar.
            HStack(spacing: 4) {
                Button {
                    onCreate()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Add a new profile")
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    if let id = selectedID,
                       let profile = profiles.first(where: { $0.id == id }) {
                        onDelete(profile)
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selectedProfile == nil)
                .help("Delete selected profile")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            Divider()

            // Launch button + meta line.
            VStack(spacing: 12) {
                Button {
                    if let p = selectedProfile { onLaunch(p) }
                } label: {
                    Label("Open Session", systemImage: "play.fill")
                        .frame(width: 220)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(selectedProfile == nil)
                .tint(selectedProfile?.color.swiftUIColor ?? .accentColor)

                if let profile = selectedProfile {
                    HStack(spacing: 14) {
                        let allTools = profile.allToolSpecs
                        if allTools.count == 1 {
                            Label(allTools[0].tool.displayName, systemImage: allTools[0].tool.sfSymbol)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(allTools.map { $0.tool.displayName }.joined(separator: " + "),
                                  systemImage: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label(profile.authMode.displayName, systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !profile.folderPaths.isEmpty {
                            Label("\(profile.folderPaths.count) folder\(profile.folderPaths.count == 1 ? "" : "s")",
                                  systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if profile.sshPublicKey != nil {
                            Label("SSH key", systemImage: "key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label("\(profile.memoryGB) GB", systemImage: "memorychip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Select a profile, or click + to create one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            if selectedID == nil { selectedID = profiles.first?.id }
        }
        .onChange(of: profiles) { _, new in
            if !new.contains(where: { $0.id == selectedID }) {
                selectedID = new.first?.id
            }
        }
    }

    private var selectedProfile: Profile? {
        profiles.first(where: { $0.id == selectedID })
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isRunning: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(profile.color.swiftUIColor.gradient)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.body)
                    if isRunning {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .help("Session is running")
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: profile.tool.sfSymbol)
                        .font(.caption2)
                    Text(profile.tool.displayName).font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Edit profile settings")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor (create + edit, single form)

// MARK: - Editor categories

enum EditorCategory: String, CaseIterable, Identifiable {
    case general     = "General"
    case agent       = "Agent"
    case folders     = "Folders"
    case credentials = "Credentials"
    case advanced    = "Advanced"
    case appearance  = "Appearance"
    case resources   = "Resources"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general:     "person.text.rectangle.fill"
        case .agent:       "sparkles"
        case .folders:     "folder.fill"
        case .credentials: "key.fill"
        case .advanced:    "shield.lefthalf.filled"
        case .appearance:  "paintpalette.fill"
        case .resources:   "memorychip.fill"
        }
    }

    var color: Color {
        switch self {
        case .general:     .indigo
        case .agent:       .purple
        case .folders:     .orange
        case .credentials: .green
        case .advanced:    .red
        case .appearance:  .pink
        case .resources:   .gray
        }
    }
}

/// Storage paths + state the editor needs to render the layered
/// "Storage" section in the Resources pane. Everything here is
/// optional because a brand-new profile has no on-disk artefacts yet —
/// the editor renders placeholder layers in that case.
struct ProfileStorageContext {
    /// `base.img` — shared across all profiles, immutable at runtime.
    var baseImageURL: URL
    /// Current base-image version stamp ("28"). nil if base hasn't been
    /// built yet (shouldn't happen here — editor only opens post-init —
    /// but defensive).
    var baseImageVersion: String?
    /// Build date of the base image (mtime of the version-stamp file).
    var baseImageBuildDate: Date?
    /// Per-profile system disk; nil for new profiles (created lazily on
    /// first launch).
    var profileDiskURL: URL?
    /// Per-profile home dir; nil for new profiles.
    var profileHomeURL: URL?
    /// True if the profile's VM is currently open in a session window —
    /// reset actions are unsafe in that state.
    var isRunning: Bool
    /// Wired to ACAppDelegate.resetProfile / resetHomeProfile. Both
    /// handle their own confirmation alerts.
    var onResetDisk: () -> Void
    var onResetHome: () -> Void

    static func empty(baseImageURL: URL) -> ProfileStorageContext {
        ProfileStorageContext(
            baseImageURL: baseImageURL,
            baseImageVersion: nil,
            baseImageBuildDate: nil,
            profileDiskURL: nil,
            profileHomeURL: nil,
            isRunning: false,
            onResetDisk: {},
            onResetHome: {}
        )
    }
}

struct ProfileEditorView: View {
    @State private var draft: Profile
    @State private var selectedCategory: EditorCategory = .general
    private let isNew: Bool
    private let terminalDefaults: TerminalAppDefaults
    private let storageContext: ProfileStorageContext

    /// "Generate SSH key" toggle is decoupled from the model — only used
    /// to decide whether to call ssh-keygen on save.
    @State private var generateSSH: Bool

    /// Sheet state for the SSH-key import flow.
    @State private var importSheet: ImportSheetState?
    @State private var importError: String?

    struct ImportSheetState: Identifiable {
        let id = UUID()
        var sourceURL: URL
        var label: String
        var passphrase: String
    }

    let onSave: (Profile, _ generateSSH: Bool) -> Void
    let onCancel: () -> Void

    /// Synchronous import callback: returns the metadata to append on
    /// the draft profile, or throws. Provided by ACAppDelegate so the
    /// view doesn't need filesystem / Keychain access.
    let onImportSSHKey: ((URL, _ passphrase: String?, _ label: String) throws -> ImportedSSHKey)?
    /// Called when the user removes a row — frees the on-disk file +
    /// keychain entry. Provided by ACAppDelegate.
    let onRemoveSSHKey: ((ImportedSSHKey) -> Void)?

    init(
        profile: Profile? = nil,
        terminalDefaults: TerminalAppDefaults,
        storageContext: ProfileStorageContext,
        onSave: @escaping (Profile, _ generateSSH: Bool) -> Void,
        onCancel: @escaping () -> Void,
        onImportSSHKey: ((URL, _ passphrase: String?, _ label: String) throws -> ImportedSSHKey)? = nil,
        onRemoveSSHKey: ((ImportedSSHKey) -> Void)? = nil
    ) {
        self.onImportSSHKey = onImportSSHKey
        self.onRemoveSSHKey = onRemoveSSHKey
        var p = profile ?? Profile(name: "", tool: .claude, authMode: .token)
        // New profiles: pre-fill custom appearance fields with Terminal.app
        // defaults so the editor opens with sensible, editable starting
        // values. We always render the editable fields (no inherit toggle).
        p.seedAppearance(from: terminalDefaults)
        _draft = State(initialValue: p)
        // Existing keys: don't regen by default. New profile: yes.
        _generateSSH = State(initialValue: profile == nil)
        isNew = profile == nil
        self.terminalDefaults = terminalDefaults
        self.storageContext = storageContext
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Sidebar
                List(EditorCategory.allCases, selection: $selectedCategory) { category in
                    Label {
                        Text(category.rawValue)
                    } icon: {
                        Image(systemName: category.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(category.color.gradient,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .tag(category)
                }
                .listStyle(.sidebar)
                .frame(width: 170)

                Divider()

                // Detail
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(isNew ? "New profile" : draft.name.isEmpty ? "Edit profile" : draft.name)
                            .font(.title2.bold())
                        detailContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create" : "Save") {
                    onSave(draft, generateSSH)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedCategory {
        case .general:     generalSection
        case .agent:       agentSection
        case .folders:     foldersSection
        case .credentials: credentialsSection
        case .advanced:    advancedSection
        case .appearance:  appearanceSection
        case .resources:   resourcesSection
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Form {
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Color")
                Picker("", selection: $draft.color) {
                    ForEach(ProfileColor.allCases, id: \.self) { c in
                        HStack {
                            Circle().fill(c.swiftUIColor.gradient).frame(width: 12, height: 12)
                            Text(c.label)
                        }
                        .tag(c)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
            }
            TextField("Notes (optional)", text: $draft.comments, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enable each agent you want available in this profile. The one marked **Primary** auto-launches in the first kitty tab; other enabled agents are installed and authenticated but you run them on demand from a new tab.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Profile.Tool.allCases, id: \.self) { t in
                ToolConfigCard(
                    tool: t,
                    isPrimary: draft.tool == t,
                    isEnabled: isToolEnabled(t),
                    spec: bindingForTool(t),
                    onToggleEnabled: { setToolEnabled(t, enabled: $0) },
                    onMakePrimary: { setPrimary(t) },
                    profileDirHint: profileDirHint
                )
            }
        }
    }

    /// The currently-applied set of enabled tools = primary + additional.
    private func isToolEnabled(_ t: Profile.Tool) -> Bool {
        t == draft.tool || draft.additionalTools.contains(where: { $0.tool == t })
    }

    /// Two-way binding to a tool's ToolSpec slot in `draft`. Reads return
    /// either the primary's spec or the matching additional entry; writes
    /// route to whichever slot the tool currently occupies. If the tool
    /// isn't enabled, reads return defaults and writes are no-ops (the UI
    /// disables editing in that case anyway).
    private func bindingForTool(_ t: Profile.Tool) -> Binding<Profile.ToolSpec> {
        Binding(
            get: {
                if t == self.draft.tool {
                    return Profile.ToolSpec(tool: t, authMode: self.draft.authMode, apiKey: self.draft.apiKey)
                }
                if let s = self.draft.additionalTools.first(where: { $0.tool == t }) {
                    return s
                }
                return Profile.ToolSpec(tool: t)
            },
            set: { newValue in
                if t == self.draft.tool {
                    self.draft.authMode = newValue.authMode
                    self.draft.apiKey   = newValue.apiKey
                } else if let i = self.draft.additionalTools.firstIndex(where: { $0.tool == t }) {
                    self.draft.additionalTools[i] = newValue
                }
            }
        )
    }

    private func setToolEnabled(_ t: Profile.Tool, enabled: Bool) {
        if enabled {
            // Already primary or already in additionals → nothing to do.
            if t == draft.tool { return }
            if !draft.additionalTools.contains(where: { $0.tool == t }) {
                draft.additionalTools.append(Profile.ToolSpec(tool: t))
            }
        } else {
            // Disabling primary: promote some other enabled tool to primary
            // first; if none, we refuse (every profile must have ≥1 tool).
            if t == draft.tool {
                guard let next = draft.additionalTools.first else { return }
                draft.additionalTools.removeAll { $0.tool == next.tool }
                draft.tool     = next.tool
                draft.authMode = next.authMode
                draft.apiKey   = next.apiKey
            } else {
                draft.additionalTools.removeAll { $0.tool == t }
            }
        }
    }

    /// Swap the named tool into the primary slot, demoting the current
    /// primary into additionals (preserving its auth mode + key).
    private func setPrimary(_ t: Profile.Tool) {
        guard t != draft.tool else { return }
        // Snapshot the current primary so we can demote it.
        let oldPrimary = Profile.ToolSpec(
            tool: draft.tool, authMode: draft.authMode, apiKey: draft.apiKey
        )
        // Pull the new primary out of additionals (creating a default
        // entry if the user hadn't enabled it yet — common when they
        // click "Make primary" on a disabled card).
        let newPrimary: Profile.ToolSpec
        if let existing = draft.additionalTools.first(where: { $0.tool == t }) {
            newPrimary = existing
            draft.additionalTools.removeAll { $0.tool == t }
        } else {
            newPrimary = Profile.ToolSpec(tool: t)
        }
        // Promote.
        draft.tool     = newPrimary.tool
        draft.authMode = newPrimary.authMode
        draft.apiKey   = newPrimary.apiKey
        // Demote the old primary into additionals.
        draft.additionalTools.insert(oldPrimary, at: 0)
    }

    @ViewBuilder
    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each folder is mounted into the VM under its real name (e.g. ~/Documents → ~ubuntu/Documents). Capped at 8 folders per profile.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if draft.folderPaths.isEmpty {
                Text("No folders shared.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(Array(draft.folderPaths.enumerated()), id: \.offset) { (idx, path) in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.callout)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            draft.folderPaths.remove(at: idx)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button {
                    addFolder()
                } label: {
                    Label("Add folder…", systemImage: "plus")
                }
                .disabled(draft.folderPaths.count >= 8)
            }
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Git identity
            VStack(alignment: .leading, spacing: 6) {
                Text("Git Identity")
                    .font(.headline)
                TextField("user.name", text: $draft.gitUserName, prompt: Text("Your Name"))
                    .textFieldStyle(.roundedBorder)
                TextField("user.email", text: $draft.gitUserEmail, prompt: Text("you@example.com"))
                    .textFieldStyle(.roundedBorder)
                Text("Written to ~/.gitconfig in the VM. Leave both blank to keep git's defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // SSH
            VStack(alignment: .leading, spacing: 6) {
                Text("SSH key")
                    .font(.headline)
                if isNew {
                    Toggle("Generate an ed25519 keypair", isOn: $generateSSH)
                    Text("The public key will be displayed below after the profile is saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let pub = draft.sshPublicKey {
                    HStack {
                        Text("ed25519 keypair on file.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Regenerate", isOn: $generateSSH)
                    }
                    Text("Public key (paste into github.com/settings/keys):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(pub)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                    }
                    .frame(height: 70)
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pub, forType: .string)
                        }
                        Button("Open GitHub keys page") {
                            if let url = URL(string: "https://github.com/settings/keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Spacer()
                    }
                } else {
                    Toggle("Generate an ed25519 keypair", isOn: $generateSSH)
                }
            }

            Divider()

            // Pre-existing SSH keys the user wants this profile to use.
            importedSSHKeysSubsection

            Divider()

            // HTTPS personal access tokens
            httpsTokensSubsection
        }
        .sheet(item: $importSheet) { _ in
            importSheetView
        }
    }

    @ViewBuilder
    private var importedSSHKeysSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Imported SSH keys")
                    .font(.headline)
                Spacer()
                Button {
                    presentImportPicker()
                } label: {
                    Label("Import…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(onImportSSHKey == nil)
            }
            Text("Point bromure at any existing SSH private key (RSA, ed25519, ecdsa) — encrypted ones included. The key is loaded into the per-profile bromure ssh-agent at every session launch; passphrases are stored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if draft.importedSSHKeys.isEmpty {
                Text("No imported keys.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(draft.importedSSHKeys) { key in
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(key.label).font(.callout)
                                if key.hasPassphrase {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .help("Passphrase is in your macOS Keychain.")
                                }
                            }
                            Text(key.publicKeyText.isEmpty
                                 ? key.filename
                                 : key.publicKeyText.split(separator: " ").prefix(1).joined()
                                   + " " + (key.publicKeyText.split(separator: " ").dropFirst().last.map(String.init) ?? ""))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            onRemoveSSHKey?(key)
                            draft.importedSSHKeys.removeAll { $0.id == key.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if let err = importError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var importSheetView: some View {
        if let sheet = importSheet {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import SSH key")
                    .font(.title3.bold())
                Text(sheet.sourceURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                TextField("Label", text: Binding(
                    get: { importSheet?.label ?? "" },
                    set: { importSheet?.label = $0 }
                ), prompt: Text("personal, work, deploy, …"))
                    .textFieldStyle(.roundedBorder)

                SecureField("Passphrase (leave blank if none)", text: Binding(
                    get: { importSheet?.passphrase ?? "" },
                    set: { importSheet?.passphrase = $0 }
                ))
                    .textFieldStyle(.roundedBorder)

                Text("Passphrases (if any) are stored in the macOS Keychain — bromure-ac fetches via SSH_ASKPASS at session launch and never logs the value.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        importSheet = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Import") {
                        completeImport(sheet: sheet)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(onImportSSHKey == nil)
                }
            }
            .padding(20)
            .frame(width: 480)
        }
    }

    private func presentImportPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        panel.message = "Pick the private key file (e.g. id_ed25519, id_rsa)."
        if panel.runModal() == .OK, let url = panel.url {
            importSheet = ImportSheetState(
                sourceURL: url,
                label: url.lastPathComponent,
                passphrase: ""
            )
        }
    }

    private func completeImport(sheet: ImportSheetState) {
        guard let importer = onImportSSHKey else { return }
        do {
            let imported = try importer(
                sheet.sourceURL,
                sheet.passphrase.isEmpty ? nil : sheet.passphrase,
                sheet.label.trimmingCharacters(in: .whitespaces)
            )
            draft.importedSSHKeys.append(imported)
            importError = nil
            importSheet = nil
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var httpsTokensSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HTTPS tokens")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("GitHub.com")  { addCredential(host: "github.com",  presetName: "GitHub") }
                    Button("GitLab.com")  { addCredential(host: "gitlab.com",  presetName: "GitLab") }
                    Button("Bitbucket.org") { addCredential(host: "bitbucket.org", presetName: "Bitbucket") }
                    Divider()
                    Button("Other host…") { addCredential(host: "", presetName: nil) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text("Personal access tokens for git over HTTPS. Written to ~/.git-credentials in the VM (chmod 600). For github.com / gitlab.com hosts we also seed `gh` and `glab` so their CLIs work without an extra `auth login`.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if draft.gitHTTPSCredentials.isEmpty {
                Text("No HTTPS tokens configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(draft.gitHTTPSCredentials.enumerated()), id: \.element.id) { (idx, _) in
                    HTTPSCredentialRow(
                        credential: $draft.gitHTTPSCredentials[idx],
                        onRemove: { draft.gitHTTPSCredentials.remove(at: idx) },
                        onOpenTokenPage: openTokenPage(for:)
                    )
                }
            }
        }
    }

    private func addCredential(host: String, presetName: String?) {
        // Pre-fill `username` with the git user.name when it looks like a
        // login (no spaces) — saves a step for the common single-account
        // case. Token deliberately left blank.
        let suggestedUser: String = {
            let n = draft.gitUserName.trimmingCharacters(in: .whitespaces)
            return (!n.isEmpty && !n.contains(" ")) ? n : ""
        }()
        draft.gitHTTPSCredentials.append(
            GitHTTPSCredential(host: host, username: suggestedUser, token: "")
        )
        _ = presetName  // reserved for future labelling in the row UI
    }

    private func openTokenPage(for host: String) {
        let h = host.lowercased()
        let urlString: String?
        if h == "github.com" || h.hasSuffix(".github.com") {
            urlString = "https://github.com/settings/tokens"
        } else if h == "gitlab.com" || h.hasPrefix("gitlab.") {
            urlString = "https://gitlab.com/-/user_settings/personal_access_tokens"
        } else if h == "bitbucket.org" {
            urlString = "https://bitbucket.org/account/settings/app-passwords/"
        } else {
            urlString = nil
        }
        if let s = urlString, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("MITM token swap", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Bromure runs an HTTPS proxy on the host that swaps fake tokens for real ones on the wire. Real keys never leave macOS — the VM only ever sees the fakes. Add custom mappings here for any API beyond Claude / Codex / GitHub PAT auth (which are auto-handled).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Trace level for the proxy. Off by default — opt-in
            // because higher levels write encrypted body files to
            // ~/Library/Application Support/BromureAC/traces/.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Session trace", systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("", selection: $draft.traceLevel) {
                        ForEach(TraceLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                Text("Off → nothing recorded. Activity → metadata only (host, status, latency, swap report, leak warnings). AI request details → also captures bodies for known LLM hosts (Anthropic, OpenAI, Google, Cohere, Mistral, Perplexity, x.ai, Groq, Replicate, HuggingFace). Everything → bodies for every host. Bodies are AES-GCM encrypted with the same keychain key as profile secrets. View at App → Trace Inspector (⇧⌘I).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Manual token rules")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    draft.manualTokens.append(ManualToken())
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            if draft.manualTokens.isEmpty {
                Text("No manual tokens configured. Auto-handled APIs (Anthropic, OpenAI, GitHub, GitLab) need no entries here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(draft.manualTokens.enumerated()), id: \.element.id) { (idx, _) in
                    ManualTokenRow(
                        token: $draft.manualTokens[idx],
                        onRemove: { draft.manualTokens.remove(at: idx) }
                    )
                }
            }

            Text("Each entry mints a fresh fake (`brm_…`) on every session launch. The fake is exported as the named env var inside the VM; the proxy on the host swaps it back to your real value when the VM makes the API call.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Storage stack: top of the pane because it's the "loud"
            // visual + the destructive actions live here.
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage")
                    .font(.headline)
                Text("Three layers stack to make this profile's environment. The bottom is shared and immutable; the top two are yours and can be erased independently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StorageStackView(
                    isNewProfile: isNew,
                    context: storageContext
                )
            }

            Divider()

            // Memory
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory")
                    .font(.headline)
                Stepper(value: $draft.memoryGB, in: 2...32, step: 2) {
                    Text("VM RAM: \(draft.memoryGB) GB")
                }
                Text("Bump this if Claude / Codex feels sluggish or rust builds OOM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Network
            VStack(alignment: .leading, spacing: 6) {
                Text("Network")
                    .font(.headline)
                Picker("", selection: $draft.networkMode) {
                    ForEach(Profile.NetworkMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if draft.networkMode == .bridged {
                    let interfaces = VZBridgedNetworkInterface.networkInterfaces
                    if interfaces.isEmpty {
                        Text("No bridged interfaces available. Bromure AC will fall back to NAT at launch.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Picker("Interface", selection: Binding(
                            get: { draft.bridgedInterfaceID ?? interfaces.first?.identifier ?? "" },
                            set: { draft.bridgedInterfaceID = $0 }
                        )) {
                            ForEach(interfaces, id: \.identifier) { iface in
                                Text(iface.localizedDisplayName ?? iface.identifier)
                                    .tag(iface.identifier)
                            }
                        }
                        Text("The VM gets a LAN-routable IP via DHCP on the chosen interface.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("VM sits behind NAT. Egress works; nothing on your LAN can reach it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Font
            HStack(spacing: 12) {
                Text("Font").frame(width: 110, alignment: .trailing)
                Picker("", selection: Binding(
                    get: { draft.customFontFamily ?? terminalDefaults.fontFamily },
                    set: { draft.customFontFamily = $0 }
                )) {
                    ForEach(fontFamiliesForPicker, id: \.self) { fam in
                        Text(fam).tag(fam)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                Stepper(value: Binding(
                    get: { draft.customFontSize ?? terminalDefaults.fontSize },
                    set: { draft.customFontSize = $0 }
                ), in: 8...32) {
                    Text("\(draft.customFontSize ?? terminalDefaults.fontSize) pt")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50)
                }
            }

            // Cursor
            HStack(spacing: 12) {
                Text("Cursor").frame(width: 110, alignment: .trailing)
                Picker("", selection: $draft.cursorShape) {
                    ForEach(Profile.CursorShape.allCases, id: \.self) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer()
            }

            // Colors
            HStack(spacing: 24) {
                Text("Colors").frame(width: 110, alignment: .trailing)
                ColorPicker("Background", selection: Binding(
                    get: { Color(hex: draft.customBackgroundHex ?? terminalDefaults.backgroundHex) },
                    set: { draft.customBackgroundHex = $0.hexString }
                ))
                ColorPicker("Text", selection: Binding(
                    get: { Color(hex: draft.customForegroundHex ?? terminalDefaults.foregroundHex) },
                    set: { draft.customForegroundHex = $0.hexString }
                ))
                Spacer()
            }

            // Opacity
            HStack(spacing: 12) {
                Text("Opacity").frame(width: 110, alignment: .trailing)
                Slider(value: $draft.windowOpacity, in: 0.3...1.0)
                    .frame(maxWidth: 240)
                Text("\(Int(draft.windowOpacity * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 44)
            }

            Divider().padding(.vertical, 4)

            HStack {
                Text("Defaults are seeded from your macOS Terminal.app profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Terminal.app") {
                    draft.customFontFamily = "JetBrains Mono"
                    draft.customFontSize = terminalDefaults.fontSize
                    draft.customBackgroundHex = terminalDefaults.backgroundHex
                    draft.customForegroundHex = terminalDefaults.foregroundHex
                }
            }
        }
    }

    /// All font families on this Mac, sorted. We exclude families whose
    /// name starts with `.` — those are macOS-internal identifiers
    /// (`.AppleSystemUIFont`, `.SFCompactRounded`, …) that Linux
    /// fontconfig can't resolve, so picking one would silently fall back
    /// in kitty.
    static let allFontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }()

    /// The list shown in the Picker — always includes the currently-
    /// selected family (even if it's not in `availableFontFamilies`),
    /// otherwise the Picker shows blank after Reset-to-Terminal sets a
    /// font name that isn't a registered family on this Mac.
    private var fontFamiliesForPicker: [String] {
        let current = draft.customFontFamily ?? terminalDefaults.fontFamily
        var families = Self.allFontFamilies
        if !current.isEmpty && !families.contains(current) {
            families.insert(current, at: 0)
        }
        return families
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !draft.folderPaths.contains(path), draft.folderPaths.count < 8 {
                    draft.folderPaths.append(path)
                }
            }
        }
    }

    private var profileDirHint: String {
        "~/Library/Application Support/BromureAC/profiles/\(draft.id.uuidString.prefix(8))…/"
    }

    private var isValid: Bool {
        // Only the name is required to save. Empty API key is allowed
        // (token mode users may want to paste the key after creation;
        // subscription mode never needs one).
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        systemImage: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GradientIcon(symbol: systemImage, color: color)
                Text(title).font(.headline)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.leading, 30)
        }
    }


}

// MARK: - Manual token row (Advanced)

/// One editable row for the Advanced→Manual tokens list. Pairs a name
/// + env var + real value (masked) + optional host filter.
private struct ManualTokenRow: View {
    @Binding var token: ManualToken
    var onRemove: () -> Void

    @State private var revealReal: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Name", text: $token.name, prompt: Text("Stripe sandbox"))
                    .textFieldStyle(.roundedBorder)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this token rule")
            }
            HStack(spacing: 6) {
                TextField("Env var", text: $token.envVarName, prompt: Text("STRIPE_API_KEY"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                TextField("Host filter (optional)", text: $token.hostFilter,
                          prompt: Text("api.stripe.com"))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                ZStack {
                    if revealReal {
                        TextField("Real value", text: $token.realValue,
                                  prompt: Text("real secret — stays on macOS"))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Real value", text: $token.realValue,
                                    prompt: Text("real secret — stays on macOS"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Button {
                    revealReal.toggle()
                } label: {
                    Image(systemName: revealReal ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealReal ? "Hide value" : "Show value")
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Storage stack

/// Three stacked rows that make explicit the "OS image → per-profile
/// disk → per-profile home" layering. Top of the stack is closest to
/// the user (their home dir); bottom is the shared, immutable base.
/// The two top layers carry destructive "Erase / Reset" actions; the
/// base is documented as rebuild-via-app-menu only.
private struct StorageStackView: View {
    let isNewProfile: Bool
    let context: ProfileStorageContext

    /// Computed asynchronously on view appear so a huge npm-global tree
    /// doesn't block the editor's first paint.
    @State private var diskBytes: Int64?
    @State private var homeBytes: Int64?
    @State private var homeMTime: Date?
    @State private var baseBytes: Int64?

    var body: some View {
        VStack(spacing: 0) {
            // Top — your home dir.
            StorageLayerRow(
                accent: .orange,
                symbol: "house.fill",
                title: "Your home folder",
                subtitle: "Project clones, dotfiles, .ssh keys, npm-global, .cargo, shell history, anything in /home/ubuntu.",
                metadata: homeMetadata,
                size: homeBytes,
                action: isNewProfile
                    ? nil
                    : .init(
                        label: "Erase home…",
                        role: .destructive,
                        enabled: !context.isRunning && context.profileHomeURL != nil,
                        disabledHelp: context.isRunning
                            ? "Close the session window first."
                            : "Created on first launch.",
                        handler: context.onResetHome
                      )
            )

            Divider()

            // Middle — per-profile system disk (CoW clone).
            StorageLayerRow(
                accent: .blue,
                symbol: "internaldrive.fill",
                title: "Profile system disk",
                subtitle: "A read-write copy of the base OS, just for this profile. Holds anything you `sudo apt install`, edits to /etc and /var, system-level config.",
                metadata: diskMetadata,
                size: diskBytes,
                action: isNewProfile
                    ? nil
                    : .init(
                        label: "Reset to base…",
                        role: .destructive,
                        enabled: !context.isRunning && context.profileDiskURL != nil,
                        disabledHelp: context.isRunning
                            ? "Close the session window first."
                            : "Created on first launch.",
                        handler: context.onResetDisk
                      )
            )

            Divider()

            // Bottom — shared base OS image. Read-only, no per-profile
            // action — rebuild lives in the app menu, intentionally
            // distant because it affects every profile.
            StorageLayerRow(
                accent: .gray,
                symbol: "cube.fill",
                title: "Base OS image",
                subtitle: "Ubuntu Noble + Node, Claude Code, Codex, kitty, gh, glab, fonts. Shared by every profile, immutable at runtime.",
                metadata: baseMetadata,
                size: baseBytes,
                action: nil,
                bottomNote: "Rebuild via the app menu (∼5–10 min).",
                noteHelp: "Affects every profile, so it's parked outside this editor."
            )
        }
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        )
        .task {
            await refreshSizes()
        }
    }

    private var homeMetadata: String {
        if isNewProfile { return "Created on first launch." }
        guard context.profileHomeURL != nil else { return "Not yet created." }
        if let mtime = homeMTime {
            return "Active \(relativeAge(of: mtime))."
        }
        return "Quiet — no recent activity."
    }

    private var diskMetadata: String {
        if isNewProfile { return "Created on first launch." }
        guard context.profileDiskURL != nil else { return "Not yet cloned." }
        if let v = context.baseImageVersion {
            return "Cloned from base v\(v)."
        }
        return "Cloned from base."
    }

    private var baseMetadata: String {
        var parts: [String] = []
        if let v = context.baseImageVersion { parts.append("v\(v)") }
        if let d = context.baseImageBuildDate {
            parts.append("built \(Self.dateFormatter.string(from: d))")
        }
        return parts.isEmpty ? "Built once per app version." : parts.joined(separator: " · ")
    }

    @MainActor
    private func refreshSizes() async {
        // Off-main computation, then push back. Keeps the editor
        // interactive even if the home walk takes a beat.
        let baseURL = context.baseImageURL
        let diskURL = context.profileDiskURL
        let homeURL = context.profileHomeURL
        let (b, d, h, m) = await Task.detached(priority: .utility) {
            let base = (try? baseURL.resourceValues(forKeys: [.fileAllocatedSizeKey]))
                .flatMap { $0.fileAllocatedSize }
                .map(Int64.init) ?? 0
            let disk = diskURL.map { Self.allocatedBytes(at: $0) } ?? 0
            let home = homeURL.map { Self.directoryBytes(at: $0) } ?? 0
            let mtime = homeURL.flatMap { url -> Date? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
                return attrs[.modificationDate] as? Date
            }
            return (base, disk, home, mtime)
        }.value
        baseBytes = b
        diskBytes = d
        homeBytes = h
        homeMTime = m
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // `nonisolated` because these are called from a `Task.detached`
    // closure that runs off the main actor. The view itself is
    // MainActor-isolated by virtue of conforming to View, which would
    // otherwise infer these too.
    nonisolated private static func allocatedBytes(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if let n = v?.totalFileAllocatedSize { return Int64(n) }
        if let n = v?.fileAllocatedSize { return Int64(n) }
        return 0
    }

    nonisolated private static func directoryBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let it = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else {
            return 0
        }
        var total: Int64 = 0
        for case let u as URL in it {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true {
                if let n = v?.totalFileAllocatedSize { total &+= Int64(n) }
                else if let n = v?.fileAllocatedSize { total &+= Int64(n) }
            }
        }
        return total
    }

    /// "2 minutes ago", "yesterday", "last week" — short, human.
    private func relativeAge(of date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct StorageLayerRow: View {
    struct Action {
        var label: String
        var role: ButtonRole?
        var enabled: Bool
        var disabledHelp: String?
        var handler: () -> Void
    }

    let accent: Color
    let symbol: String
    let title: String
    let subtitle: String
    let metadata: String
    let size: Int64?
    let action: Action?
    var bottomNote: String? = nil
    var noteHelp: String? = nil

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB, .useKB]
        f.includesUnit = true
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Colored left edge — visually identifies the layer.
            Rectangle()
                .fill(accent.gradient)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: symbol)
                        .foregroundStyle(accent)
                        .font(.body)
                        .frame(width: 18)
                    Text(title)
                        .font(.body.weight(.semibold))
                    Spacer()
                    Text(sizeLabel)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let action {
                        Button(role: action.role) {
                            action.handler()
                        } label: {
                            Text(action.label)
                        }
                        .controlSize(.small)
                        .disabled(!action.enabled)
                        .help(action.enabled ? "" : (action.disabledHelp ?? ""))
                    }
                }

                if let bottomNote {
                    Text(bottomNote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(noteHelp ?? "")
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
        }
    }

    private var sizeLabel: String {
        guard let size else { return "—" }
        if size == 0 { return "—" }
        return Self.byteFormatter.string(fromByteCount: size)
    }
}

// MARK: - Per-tool config card

/// One agent's row in the Agent pane. Header has the tool icon, name,
/// the enable toggle, and a "Primary" pill (radio-style: clicking on a
/// non-primary card promotes it). Body shows auth mode + API key when
/// the tool is enabled.
private struct ToolConfigCard: View {
    let tool: Profile.Tool
    let isPrimary: Bool
    let isEnabled: Bool
    @Binding var spec: Profile.ToolSpec
    let onToggleEnabled: (Bool) -> Void
    let onMakePrimary: () -> Void
    let profileDirHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: tool.sfSymbol)
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.purple.gradient, in: RoundedRectangle(cornerRadius: 5))
                Text(tool.displayName)
                    .font(.body.weight(.medium))
                Spacer()
                if isPrimary {
                    Label("Primary", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.gradient, in: Capsule())
                } else if isEnabled {
                    Button("Make primary") { onMakePrimary() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Toggle("", isOn: Binding(get: { isEnabled }, set: onToggleEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if isEnabled {
                Picker("Auth", selection: $spec.authMode) {
                    ForEach(Profile.AuthMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.radioGroup)

                if spec.authMode == .token {
                    SecureField(
                        envVarPlaceholder,
                        text: Binding(
                            get: { spec.apiKey ?? "" },
                            set: { spec.apiKey = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("Stored under \(profileDirHint). Phase B+ moves this to the keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("You'll run `\(tool.rawValue) login` once inside the VM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: isEnabled ? .textBackgroundColor : .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPrimary ? Color.orange.opacity(0.45) : Color.gray.opacity(0.2),
                        lineWidth: isPrimary ? 1.5 : 1)
        )
        .opacity(isEnabled ? 1.0 : 0.7)
    }

    private var envVarPlaceholder: String {
        switch tool {
        case .claude: return "Anthropic API key"
        case .codex:  return "OpenAI API key"
        }
    }
}

// MARK: - HTTPS credential row

/// One editable row in the HTTPS-tokens list. Host is a free text field
/// (so self-hosted GitLab / Gitea work) but we surface a "create token"
/// link for the well-known forges. Token is masked by default.
private struct HTTPSCredentialRow: View {
    @Binding var credential: GitHTTPSCredential
    var onRemove: () -> Void
    var onOpenTokenPage: (String) -> Void

    @State private var revealToken: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: hostSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Host", text: $credential.host, prompt: Text("github.com"))
                    .textFieldStyle(.roundedBorder)
                Button {
                    onOpenTokenPage(credential.host)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open this host's token-creation page in your browser")
                .disabled(!hasKnownTokenPage)

                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this credential")
            }
            HStack(spacing: 6) {
                TextField("Username", text: $credential.username, prompt: Text("octocat"))
                    .textFieldStyle(.roundedBorder)
                ZStack {
                    if revealToken {
                        TextField("Token", text: $credential.token, prompt: Text("ghp_…"))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Token", text: $credential.token, prompt: Text("ghp_…"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Button {
                    revealToken.toggle()
                } label: {
                    Image(systemName: revealToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealToken ? "Hide token" : "Show token")
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var hostSymbol: String {
        let h = credential.host.lowercased()
        if h == "github.com" || h.hasSuffix(".github.com") { return "cat.fill" }
        if h == "gitlab.com" || h.hasPrefix("gitlab.")     { return "fox.fill" }
        return "globe"
    }

    private var hasKnownTokenPage: Bool {
        let h = credential.host.lowercased()
        return h == "github.com" || h.hasSuffix(".github.com")
            || h == "gitlab.com" || h.hasPrefix("gitlab.")
            || h == "bitbucket.org"
    }
}

// MARK: - SSH-key viewer

struct SSHKeyView: View {
    let profileName: String
    let publicKey: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH public key — \(profileName)")
                .font(.title3.bold())
            Text("Paste this into github.com/settings/keys (or your hosting provider's equivalent). The matching private key lives only inside this profile.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(publicKey)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(height: 80)

            HStack {
                Button("Copy to clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicKey, forType: .string)
                }
                Button("Open GitHub keys page") {
                    if let url = URL(string: "https://github.com/settings/keys") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 540, height: 280)
    }
}
