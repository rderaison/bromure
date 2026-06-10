import AppKit
import Foundation
import SandboxEngine
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
        case .grok:   "bolt.fill"
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
    /// Profile IDs flagged compromised by the MITM compromise detector.
    /// Shown with a red exclamation badge; launching one prompts a
    /// disk + home wipe before the VM will boot.
    var compromisedProfiles: Set<Profile.ID>
    @State private var selectedID: Profile.ID?

    let onLaunch: (Profile) -> Void
    let onCreate: () -> Void
    let onEdit: (Profile) -> Void
    let onReset: (Profile) -> Void
    let onDelete: (Profile) -> Void
    let onShowPublicKey: (Profile) -> Void
    let onDuplicate: (Profile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header with the app icon, mirroring the browser's chooser
            // styling.
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: { $0.size = NSSize(width: 40, height: 40); return $0 }(icon))
                        .resizable()
                        .interpolation(.high)
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
                        isCompromised: compromisedProfiles.contains(profile.id),
                        onEdit: { onEdit(profile) }
                    )
                    .tag(profile.id)
                    .contextMenu {
                        Button("Launch") { onLaunch(profile) }
                        Button("Edit…") { onEdit(profile) }
                        Button("Duplicate") { onDuplicate(profile) }
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
    let isCompromised: Bool
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
                    if isCompromised {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .help("Compromised — launching will prompt to wipe disk and home")
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

/// AppleScript bridge: posted by `BromureACSelectEditorCategoryCommand`
/// to switch the open editor's sidebar selection. The view subscribes
/// to this in `body` and updates its @State accordingly. Object is the
/// raw value of `EditorCategory` (so the command doesn't need to know
/// about the Swift type).
public extension Notification.Name {
    static let bromureACSelectEditorCategory =
        Notification.Name("io.bromure.ac.selectEditorCategory")
}

enum EditorCategory: String, CaseIterable, Identifiable {
    case general     = "General"
    case agent       = "Agent"
    case folders     = "Folders"
    case credentials = "Credentials"
    case environment = "Environment"
    case mcp         = "MCP"
    case tracing     = "Tracing"
    case guardrails       = "Guardrails"
    case supplyChain      = "Supply Chain"
    case promptInjection  = "Prompt Injection"
    case appearance  = "Appearance"
    case resources   = "Resources"
    /// App-wide automation toggles. Only shown when the editor is opened
    /// from "Bromure → Preferences" (i.e., `storageContext == nil`); the
    /// settings here are not per-profile.
    case automation  = "Automation"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general:     "person.text.rectangle.fill"
        case .agent:       "sparkles"
        case .folders:     "folder.fill"
        case .credentials: "key.fill"
        case .environment: "terminal.fill"
        case .mcp:         "network"
        case .tracing:     "doc.text.magnifyingglass"
        case .guardrails:       "exclamationmark.shield.fill"
        case .supplyChain:      "shippingbox.fill"
        case .promptInjection:  "exclamationmark.triangle.fill"
        case .appearance:  "paintpalette.fill"
        case .resources:   "memorychip.fill"
        case .automation:  "antenna.radiowaves.left.and.right"
        }
    }

    var color: Color {
        switch self {
        case .general:     .indigo
        case .agent:       .purple
        case .folders:     .orange
        case .credentials: .green
        case .environment: .teal
        case .mcp:         .blue
        case .tracing:     .red
        case .guardrails:       .orange
        case .supplyChain:      .yellow
        case .promptInjection:  .red
        case .appearance:  .pink
        case .resources:   .gray
        case .automation:  .cyan
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
    /// Where the profile's bytes live + how to reset them. Optional
    /// because the Preferences-window flavour of this editor binds to
    /// a template, which has no on-disk session — that flavour passes
    /// nil and the Storage section is hidden.
    private let storageContext: ProfileStorageContext?

    /// "Generate SSH key" toggle is decoupled from the model — only used
    /// to decide whether to call ssh-keygen on save.
    @State private var generateSSH: Bool

    /// Sheet state for the SSH-key import flow.
    @State private var importSheet: ImportSheetState?
    @State private var importError: String?
    /// Keys of the disclosure groups the user has expanded in the
    /// Credentials pane. All sections start collapsed — the user
    /// opens whichever one they need.
    @State private var expandedCredsSections: Set<String> = []
    @State private var discoveredSSOProfiles: [DiscoveredSSOProfile] = []
    @State private var awsFolderGranted: Bool = false

    /// Snapshot of the host's macOS key-repeat values, captured when
    /// the editor opens. Used as the visible default in the Key
    /// repeat fields and as the "treat as auto" sentinel — if the
    /// user leaves the field at the macOS value, we save nil (track
    /// macOS live); if they change it, we save their explicit value.
    @State private var hostKeyRepeat: VMConfig.KeyRepeatSettings = VMConfig.detectKeyRepeat()

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
        isNew: Bool? = nil,
        terminalDefaults: TerminalAppDefaults,
        storageContext: ProfileStorageContext?,
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
        // Caller-supplied isNew lets the picker pre-seed a draft from
        // the user's preferences template while still telling the
        // editor "this is a brand-new profile". Falls back to the
        // legacy `profile == nil` heuristic for back-compat with the
        // simpler "no draft, no template" call site.
        let resolvedIsNew = isNew ?? (profile == nil)
        // Existing keys: don't regen by default. New profile: regen
        // only if there's no key already on the draft (template fork).
        _generateSSH = State(initialValue: resolvedIsNew && p.sshPublicKey == nil)
        self.isNew = resolvedIsNew
        self.terminalDefaults = terminalDefaults
        self.storageContext = storageContext
        self.onSave = onSave
        self.onCancel = onCancel
    }

    /// Which categories show up in the sidebar. The Automation pane
    /// holds app-wide settings (UserDefaults), so it's only relevant
    /// when the editor is opened via Bromure → Preferences (where the
    /// caller doesn't pass a `storageContext`).
    private var visibleCategories: [EditorCategory] {
        EditorCategory.allCases.filter { c in
            c != .automation || storageContext == nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Sidebar
                List(visibleCategories, selection: $selectedCategory) { category in
                    Label {
                        Text(LocalizedStringKey(category.rawValue))
                    } icon: {
                        categoryIcon(category)
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
        // Attach the import sheet at the root of the editor so it stays
        // in the hierarchy regardless of which sidebar category is
        // selected when the user kicks off `presentImportPicker`. When
        // it lived on `credentialsSection`, the switch-based detail
        // view occasionally rebuilt the sheet's host view between the
        // NSOpenPanel modal returning and the state mutation
        // propagating, producing an empty/white sheet.
        .sheet(item: $importSheet) { sheet in
            importSheetView(for: sheet)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .bromureACSelectEditorCategory)) { note in
            // ScriptCommands lower-cases the category name before
            // posting; EditorCategory rawValues are title-cased
            // (e.g. "General", "MCP"). Match case-insensitively, and
            // ignore spaces so a single-word key like "supplychain"
            // resolves to "Supply Chain" — the screenshot script uses
            // space-less keys to keep them out of output filenames.
            if let raw = (note.object as? String)?
                .lowercased()
                .replacingOccurrences(of: " ", with: ""),
               let cat = EditorCategory.allCases.first(where: {
                   $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == raw
               }) {
                selectedCategory = cat
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedCategory {
        case .general:     generalSection
        case .agent:       agentSection
        case .folders:     foldersSection
        case .credentials: credentialsSection
        case .environment: environmentSection
        case .mcp:         mcpSection
        case .tracing:     tracingSection
        case .guardrails:       guardrailsSection
        case .supplyChain:      supplyChainSection
        case .promptInjection:  promptInjectionSection
        case .appearance:  appearanceSection
        case .resources:   resourcesSection
        case .automation:  automationSection
        }
    }

    @ViewBuilder
    private func categoryIcon(_ category: EditorCategory) -> some View {
        if category == .mcp, let url = acResourceBundle.url(forResource: "mcp", withExtension: "svg", subdirectory: "icons"),
           let data = try? Data(contentsOf: url),
           let svgImage = NSImage(data: data) {
            Image(nsImage: svgImage)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(.white)
        } else {
            Image(systemName: category.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        // Every row goes through Form's two-column labeled pattern
        // (Picker(label, ...), LabeledContent, TextField(label, ...)).
        // That's what gives us one right-aligned label column +
        // one left-aligned control column — the System Settings look.
        Form {
            // Preferences (= template) flavour: skip the Name field —
            // the template's name is forced to "Defaults" on save and
            // shouldn't be user-editable here.
            if draft.id != ProfileStore.templateID {
                TextField(NSLocalizedString("Name", comment: "Profile name field label"),
                          text: $draft.name)
            }

            Picker(NSLocalizedString("Color", comment: "Profile color picker label"),
                   selection: $draft.color) {
                ForEach(ProfileColor.allCases, id: \.self) { c in
                    HStack {
                        Circle().fill(c.swiftUIColor.gradient).frame(width: 12, height: 12)
                        Text(c.label)
                    }
                    .tag(c)
                }
            }
            .pickerStyle(.menu)

            keyboardLayoutPicker

            keyRepeatDelayRow
            keyRepeatRateRow

            closeActionPicker

            TextField(NSLocalizedString("Notes (optional)", comment: "Profile notes field label"),
                      text: $draft.comments, axis: .vertical)
                .lineLimit(2...6)
        }
        .formStyle(.grouped)
    }

    /// Choose what happens when the user closes a session window:
    /// suspend (save RAM to disk for instant resume — default), shut down
    /// (clean ACPI poweroff), or ask each time.
    @ViewBuilder
    private var closeActionPicker: some View {
        Picker(NSLocalizedString("When closing the window", comment: ""),
               selection: $draft.closeAction) {
            ForEach(Profile.CloseAction.allCases, id: \.self) { action in
                Text(action.displayName).tag(action)
            }
        }
        .pickerStyle(.radioGroup)
    }

    /// Pre-filled with the host's current macOS value. If the user
    /// types a different number we save it as an explicit override; if
    /// they restore the macOS value we save nil so the profile keeps
    /// tracking macOS live.
    @ViewBuilder
    private var keyRepeatDelayRow: some View {
        LabeledContent(NSLocalizedString("Key repeat delay", comment: "")) {
            HStack(spacing: 6) {
                TextField("",
                          value: Binding(
                            get: { draft.keyRepeatDelayMs ?? hostKeyRepeat.delayMs },
                            set: { draft.keyRepeatDelayMs = ($0 == hostKeyRepeat.delayMs) ? nil : $0 }),
                          format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Text("ms").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var keyRepeatRateRow: some View {
        LabeledContent(NSLocalizedString("Key repeat rate", comment: "")) {
            HStack(spacing: 6) {
                TextField("",
                          value: Binding(
                            get: { draft.keyRepeatRateHz ?? hostKeyRepeat.rateHz },
                            set: { draft.keyRepeatRateHz = ($0 == hostKeyRepeat.rateHz) ? nil : $0 }),
                          format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Text("Hz").foregroundStyle(.secondary)
            }
        }
    }

    /// "Auto" follows the macOS keyboard input source live (the same
    /// dynamic-match behaviour Bromure Web uses); selecting any other
    /// entry pins the VM to that XKB layout regardless of host state.
    @ViewBuilder
    private var keyboardLayoutPicker: some View {
        let autoTag = "__auto__"
        let binding = Binding<String>(
            get: { draft.keyboardLayoutOverride ?? autoTag },
            set: { draft.keyboardLayoutOverride = ($0 == autoTag) ? nil : $0 }
        )
        Picker(NSLocalizedString("Keyboard layout", comment: ""), selection: binding) {
            Text(NSLocalizedString("Auto (match macOS)", comment: ""))
                .tag(autoTag)
            Divider()
            ForEach(VMConfig.commonKeyboardLayouts, id: \.value) { layout in
                Text(layout.label).tag(layout.value)
            }
        }
        .pickerStyle(.menu)
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
                    bedrockModelID: $draft.bedrockModelID,
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
                    return Profile.ToolSpec(
                        tool: t,
                        authMode: self.draft.authMode,
                        apiKey: self.draft.apiKey,
                        requireApproval: self.draft.apiKeyRequiresApproval)
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
                    self.draft.apiKeyRequiresApproval = newValue.requireApproval
                } else if let i = self.draft.additionalTools.firstIndex(where: { $0.tool == t }) {
                    self.draft.additionalTools[i] = newValue
                }
                if newValue.tool == .claude {
                    self.draft.bedrockEnabled = newValue.authMode == .bedrock
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
        VStack(alignment: .leading, spacing: 8) {
            // Git identity (always visible — short, used by ~all
            // profiles, doesn't deserve to hide behind a chevron).
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
            .padding(.bottom, 4)

            credentialsDisclosure(
                key: "ssh",
                title: NSLocalizedString("SSH Keys", comment: ""),
                symbol: "key.fill",
                count: sshKeyCount
            ) {
                sshKeySubsection
            }

            credentialsDisclosure(
                key: "github",
                title: NSLocalizedString("GitHub Tokens", comment: ""),
                symbol: "cat.fill",
                count: gitTokenCount(filter: { isGitHub($0.host) })
            ) {
                gitTokenSubsection(displayName: "GitHub",
                                   defaultHost: "github.com",
                                   filter: { isGitHub($0.host) })
            }

            credentialsDisclosure(
                key: "gitlab",
                title: NSLocalizedString("GitLab Tokens", comment: ""),
                symbol: "testtube.2",
                count: gitTokenCount(filter: { isGitLab($0.host) })
            ) {
                gitTokenSubsection(displayName: "GitLab",
                                   defaultHost: "gitlab.com",
                                   filter: { isGitLab($0.host) })
            }

            credentialsDisclosure(
                key: "bitbucket",
                title: NSLocalizedString("Bitbucket Tokens", comment: ""),
                symbol: "hammer.fill",
                count: gitTokenCount(filter: { isBitbucket($0.host) })
            ) {
                gitTokenSubsection(displayName: "Bitbucket",
                                   defaultHost: "bitbucket.org",
                                   filter: { isBitbucket($0.host) })
            }

            credentialsDisclosure(
                key: "k8s",
                title: NSLocalizedString("Kubernetes", comment: ""),
                symbol: "shippingbox.fill",
                count: draft.kubeconfigs.count
            ) {
                kubernetesSubsection
            }

            credentialsDisclosure(
                key: "do",
                title: NSLocalizedString("DigitalOcean", comment: ""),
                symbol: "cloud.fill",
                count: draft.digitalOceanToken.isEmpty ? 0 : 1
            ) {
                digitalOceanSubsection
            }

            credentialsDisclosure(
                key: "aws",
                title: NSLocalizedString("AWS", comment: ""),
                symbol: "server.rack",
                count: draft.awsCredentials.isUsable ? 1 : 0
            ) {
                awsSubsection
            }

            credentialsDisclosure(
                key: "docker",
                title: NSLocalizedString("Container Registries", comment: ""),
                symbol: "shippingbox.and.arrow.backward.fill",
                count: draft.dockerRegistries.filter { $0.isUsable }.count
            ) {
                dockerRegistriesSubsection
            }

            credentialsDisclosure(
                key: "mongo",
                title: NSLocalizedString("MongoDB", comment: ""),
                symbol: "leaf.fill",
                count: databaseCount(.mongoDataAPI)
            ) {
                databaseSubsection(.mongoDataAPI)
            }

            credentialsDisclosure(
                key: "clickhouse",
                title: NSLocalizedString("ClickHouse", comment: ""),
                symbol: "bolt.horizontal.fill",
                count: databaseCount(.clickHouse)
            ) {
                databaseSubsection(.clickHouse)
            }

            credentialsDisclosure(
                key: "elastic",
                title: NSLocalizedString("Elasticsearch", comment: ""),
                symbol: "magnifyingglass",
                count: databaseCount(.elasticsearch)
            ) {
                databaseSubsection(.elasticsearch)
            }

            credentialsDisclosure(
                key: "other",
                title: NSLocalizedString("Other API keys", comment: ""),
                symbol: "key.horizontal.fill",
                count: draft.manualTokens.count
            ) {
                otherTokensSubsection
            }
        }
    }

    private func databaseCount(_ engine: HTTPDatabaseEndpoint.Engine) -> Int {
        draft.httpDatabases.filter { $0.engine == engine && $0.isUsable }.count
    }

    // MARK: - Disclosure helper

    @ViewBuilder
    private func credentialsDisclosure<Content: View>(
        key: String,
        title: String,
        symbol: String,
        count: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedCredsSections.contains(key) },
            set: { isOpen in
                if isOpen { expandedCredsSections.insert(key) }
                else      { expandedCredsSections.remove(key) }
            })) {
            content()
                .padding(.top, 8)
                .padding(.bottom, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
            }
        }
    }

    // MARK: - Per-provider host predicates

    private func isGitHub(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "github.com" || h.hasSuffix(".github.com")
    }
    private func isGitLab(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "gitlab.com" || h.hasPrefix("gitlab.")
    }
    private func isBitbucket(_ host: String) -> Bool {
        host.lowercased() == "bitbucket.org"
    }
    private var sshKeyCount: Int {
        var n = draft.importedSSHKeys.count
        if draft.sshPublicKey != nil || generateSSH { n += 1 }
        return n
    }
    private func gitTokenCount(filter: (GitHTTPSCredential) -> Bool) -> Int {
        draft.gitHTTPSCredentials.filter(filter).count
    }

    // MARK: - SSH

    @ViewBuilder
    private var sshKeySubsection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ed25519 keypair (auto-generated, lives only on the host)
            VStack(alignment: .leading, spacing: 6) {
                Text("Bromure-generated keypair")
                    .font(.subheadline.weight(.semibold))
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
                if draft.sshPublicKey != nil || generateSSH {
                    requireApprovalToggle(isOn: $draft.sshKeyRequiresApproval)
                }
            }

            Divider()

            importedSSHKeysSubsection
        }
    }

    // MARK: - Git tokens (per provider, sharing one model)

    @ViewBuilder
    private func gitTokenSubsection(displayName: String,
                                    defaultHost: String,
                                    filter: @escaping (GitHTTPSCredential) -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personal access tokens for git over HTTPS. Stored encrypted on the host; the proxy swaps them onto outbound requests so the VM only ever holds the fake. `gh` and `glab` pick up GH_TOKEN / GITLAB_TOKEN env automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let entries = draft.gitHTTPSCredentials.enumerated()
                .filter { filter($0.element) }

            if entries.isEmpty {
                Text("No \(displayName) tokens configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(entries), id: \.element.id) { (idx, _) in
                    HTTPSCredentialRow(
                        credential: $draft.gitHTTPSCredentials[idx],
                        onRemove: { draft.gitHTTPSCredentials.remove(at: idx) },
                        onOpenTokenPage: openTokenPage(for:)
                    )
                }
            }

            HStack {
                Spacer()
                Button {
                    draft.gitHTTPSCredentials.append(
                        GitHTTPSCredential(host: defaultHost,
                                           username: gitUserNameSuggestion(),
                                           token: ""))
                    expandedCredsSections.insert(disclosureKey(for: defaultHost))
                } label: {
                    Label("Add token", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }
    private func disclosureKey(for host: String) -> String {
        if isGitHub(host)    { return "github" }
        if isGitLab(host)    { return "gitlab" }
        if isBitbucket(host) { return "bitbucket" }
        return ""
    }
    private func gitUserNameSuggestion() -> String {
        let n = draft.gitUserName.trimmingCharacters(in: .whitespaces)
        return (!n.isEmpty && !n.contains(" ")) ? n : ""
    }

    // MARK: - Kubernetes

    @ViewBuilder
    private var kubernetesSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Each context produces a synthetic ~/.kube/config in the VM with throwaway client certs / placeholder bearer tokens. Real credentials live on the host; the proxy substitutes them on the wire when the VM talks to the API server. Exec-plugin contexts are polled on the host so kubectl always sees a fresh token.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.kubeconfigs.isEmpty {
                Text("No Kubernetes contexts configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(draft.kubeconfigs.enumerated()), id: \.element.id) { (idx, _) in
                    KubeconfigRow(
                        entry: $draft.kubeconfigs[idx],
                        onRemove: { draft.kubeconfigs.remove(at: idx) }
                    )
                }
            }

            HStack {
                Spacer()
                Button {
                    importKubeconfigFile()
                } label: {
                    Label("Import file…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                Button {
                    draft.kubeconfigs.append(KubeconfigEntry(name: "context-\(draft.kubeconfigs.count + 1)"))
                } label: {
                    Label("Add context", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Open-panel + parse + append. Shows an error sheet if the file
    /// isn't a kubeconfig or YAML parsing failed.
    private func importKubeconfigFile() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Import kubeconfig", comment: "")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []  // anything — kubeconfigs have no canonical UTI
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try KubeconfigImport.parse(text)
            if parsed.isEmpty {
                presentImportError("No contexts were found in this file.")
                return
            }
            draft.kubeconfigs.append(contentsOf: parsed)
        } catch {
            presentImportError(error.localizedDescription)
        }
    }

    private func presentImportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Couldn't import kubeconfig", comment: "")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    // MARK: - DigitalOcean

    @ViewBuilder
    private var digitalOceanSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personal access token from cloud.digitalocean.com → API → Generate New Token. Injected into the VM as `DIGITALOCEAN_ACCESS_TOKEN` env + `~/.config/doctl/config.yaml` — `doctl auth init` is unnecessary, you're already logged in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("dop_v1_…", text: $draft.digitalOceanToken)
                    .textFieldStyle(.roundedBorder)
                Button {
                    if let url = URL(string: "https://cloud.digitalocean.com/account/api/tokens") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open DigitalOcean token page in your browser")
            }
            requireApprovalToggle(isOn: $draft.digitalOceanTokenRequiresApproval)
        }
    }

    // MARK: - "Require approval to use" toggle

    /// Compact checkbox that flips a credential's `requireApproval`
    /// flag. When on, the host pops a consent dialog the first time
    /// any session tries to use the credential; the user picks 5 min /
    /// 1 hr / rest of session / deny. Off by default.
    @ViewBuilder
    private func requireApprovalToggle(isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(NSLocalizedString("Require approval to use", comment: ""))
                .font(.caption)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .help(NSLocalizedString(
            "Pop a confirmation dialog the first time this credential is used in a session. Off by default.",
            comment: ""))
    }

    // MARK: - AWS

    @ViewBuilder
    private var awsSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(NSLocalizedString("Auth method", comment: ""),
                   selection: $draft.awsCredentials.authMode) {
                Text(NSLocalizedString("Static keys", comment: ""))
                    .tag(AWSAuthMode.staticKeys)
                Text(NSLocalizedString("SSO / Identity Center", comment: ""))
                    .tag(AWSAuthMode.ssoProfile)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            switch draft.awsCredentials.authMode {
            case .staticKeys:
                awsStaticKeysFields
            case .ssoProfile:
                awsSSOFields
            }

            requireApprovalToggle(isOn: $draft.awsCredentials.requireApproval)
        }
    }

    @ViewBuilder
    private var awsStaticKeysFields: some View {
        Text("Access key + secret from IAM → Users → Security credentials. The real secret never reaches the VM at all — `~/.aws/config` points at a `credential_process` helper that vends the real access key with a *fake* secret, so the SDK signs a doomed request. The host's MITM proxy strips that signature and re-signs with the real material before the request leaves your Mac. `aws`, terraform, boto3 etc. work out of the box; if anything bypasses the proxy, AWS rejects with InvalidSignatureException — fail-closed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        LabeledContent(NSLocalizedString("Access key ID", comment: "")) {
            TextField("AKIA…", text: $draft.awsCredentials.accessKeyID)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .disableAutocorrection(true)
        }

        LabeledContent(NSLocalizedString("Secret access key", comment: "")) {
            SecureField("•••• ••••", text: $draft.awsCredentials.secretAccessKey)
                .textFieldStyle(.roundedBorder)
        }

        LabeledContent(NSLocalizedString("Session token", comment: "")) {
            SecureField(NSLocalizedString("Optional — STS only", comment: ""),
                        text: $draft.awsCredentials.sessionToken)
                .textFieldStyle(.roundedBorder)
        }

        LabeledContent(NSLocalizedString("Default region", comment: "")) {
            TextField("us-east-1", text: $draft.awsCredentials.region)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
        }

        HStack(spacing: 6) {
            Spacer()
            Button {
                if let url = URL(string: "https://console.aws.amazon.com/iam/home#/security_credentials") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(NSLocalizedString("Open IAM credentials page", comment: ""),
                      systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var awsSSOFields: some View {
        Text("Authenticate via AWS IAM Identity Center (SSO). Grant access to your ~/.aws directory, then select an SSO profile. On session start, if your cached token is expired, your browser will open for login.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if !awsFolderGranted {
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".aws", isDirectory: true)
                panel.message = NSLocalizedString(
                    "Grant Bromure read access to your AWS configuration directory.",
                    comment: "")
                panel.prompt = NSLocalizedString("Grant Access", comment: "")
                if panel.runModal() == .OK, let url = panel.url {
                    awsFolderGranted = true
                    discoveredSSOProfiles = AWSConfigParser.discover(
                        configPath: url.appendingPathComponent("config").path)
                }
            } label: {
                Label(NSLocalizedString("Grant access to ~/.aws", comment: ""),
                      systemImage: "folder.badge.plus")
            }
            .controlSize(.large)
        } else {
            HStack {
                Picker(NSLocalizedString("SSO profile", comment: ""),
                       selection: $draft.awsCredentials.ssoProfileName) {
                    Text("Select a profile…").tag("")
                    ForEach(discoveredSSOProfiles) { profile in
                        Text(profile.name).tag(profile.name)
                    }
                }
                .frame(maxWidth: 240)

                Button {
                    discoveredSSOProfiles = AWSConfigParser.discover()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Refresh profiles", comment: ""))
            }
            .onAppear {
                if discoveredSSOProfiles.isEmpty {
                    let found = AWSConfigParser.discover()
                    if !found.isEmpty {
                        discoveredSSOProfiles = found
                        awsFolderGranted = true
                    }
                }
            }
            .onChange(of: draft.awsCredentials.ssoProfileName) { _, newValue in
                if let match = discoveredSSOProfiles.first(where: { $0.name == newValue }) {
                    draft.awsCredentials.ssoAccountId = match.ssoAccountID
                    draft.awsCredentials.ssoRoleName = match.ssoRoleName
                    if draft.awsCredentials.region.isEmpty {
                        draft.awsCredentials.region = match.region
                    }
                }
            }
        }
    }


    // MARK: - Container Registries (Docker / GHCR / GitLab CR / private)

    @ViewBuilder
    private var dockerRegistriesSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-registry HTTP Basic auth for `docker pull` / `docker push`. The real password is never written into the VM — bromure puts a fake `base64(\"<user>:<derived>\")` in `~/.docker/config.json`, and the proxy substitutes the real value on the wire when the request hits the matching registry host.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.dockerRegistries.isEmpty {
                Text("No registries configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(draft.dockerRegistries.enumerated()), id: \.element.id) { (idx, _) in
                    DockerRegistryRow(
                        cred: $draft.dockerRegistries[idx],
                        onRemove: { draft.dockerRegistries.remove(at: idx) }
                    )
                    Divider()
                }
            }

            HStack {
                Menu {
                    Button("Docker Hub (docker.io)") {
                        addDockerRegistry(host: "docker.io")
                    }
                    Button("GitHub Container Registry (ghcr.io)") {
                        addDockerRegistry(host: "ghcr.io")
                    }
                    Button("GitLab Container Registry (registry.gitlab.com)") {
                        addDockerRegistry(host: "registry.gitlab.com")
                    }
                    Button("Quay (quay.io)") {
                        addDockerRegistry(host: "quay.io")
                    }
                    Divider()
                    Button(NSLocalizedString("Other host…", comment: "")) {
                        addDockerRegistry(host: "")
                    }
                } label: {
                    Label(NSLocalizedString("Add", comment: ""), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    importDockerConfigFile()
                } label: {
                    Label(NSLocalizedString("Import config.json…", comment: ""),
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString(
                    "Pull entries from an existing ~/.docker/config.json. Entries that delegate to credsStore / credHelpers are skipped — those passwords live in the OS keychain, not in the file.",
                    comment: ""))

                Spacer()
            }
        }
    }

    private func addDockerRegistry(host: String) {
        draft.dockerRegistries.append(
            DockerRegistryCredential(host: host, username: "", password: ""))
    }

    // MARK: - HTTPS databases (Mongo Data API / ClickHouse / Elasticsearch)

    private func databaseBlurb(_ engine: HTTPDatabaseEndpoint.Engine) -> String {
        switch engine {
        case .mongoDataAPI:
            return "MongoDB Atlas Data API endpoints. The real API key never enters the VM — bromure injects a fake under your env var(s) and swaps it for the real key on requests to the endpoint host. Set the Guardrails mode under the Guardrails panel: deleteOne/deleteMany are destructive, insert/update are writes, find/aggregate are reads."
        case .clickHouse:
            return "ClickHouse HTTP-interface endpoints (self-hosted or Cloud). The real credential stays on the host; a fake rides in the VM. Guardrails classify the SQL: DROP/TRUNCATE/DELETE (and ALTER…DELETE) are destructive, INSERT/CREATE are writes, SELECT/SHOW are reads."
        case .elasticsearch:
            return "Elasticsearch endpoints. The real credential stays on the host. Guardrails classify by method + path: DELETE and _delete_by_query are destructive, _search/_count/_msearch are reads, _bulk/index/_update are writes."
        }
    }

    @ViewBuilder
    private func databaseSubsection(_ engine: HTTPDatabaseEndpoint.Engine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(databaseBlurb(engine))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let matching = draft.httpDatabases.filter { $0.engine == engine }
            if matching.isEmpty {
                Text("No endpoints configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(matching) { db in
                    if let idx = draft.httpDatabases.firstIndex(where: { $0.id == db.id }) {
                        DatabaseEndpointRow(
                            endpoint: $draft.httpDatabases[idx],
                            onRemove: { draft.httpDatabases.removeAll { $0.id == db.id } }
                        )
                        Divider()
                    }
                }
            }

            HStack {
                Button {
                    addDatabase(engine: engine)
                } label: {
                    Label(NSLocalizedString("Add", comment: ""), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
    }

    private func addDatabase(engine: HTTPDatabaseEndpoint.Engine) {
        // Sensible per-engine defaults for the auth shape.
        let auth: HTTPDatabaseEndpoint.AuthKind
        switch engine {
        case .mongoDataAPI:  auth = .apiKey   // Mongo Data API: `api-key` header
        case .clickHouse:    auth = .basic    // ClickHouse: HTTP Basic (user/pass)
        case .elasticsearch: auth = .basic    // Elastic: Basic or ApiKey
        }
        draft.httpDatabases.append(
            HTTPDatabaseEndpoint(engine: engine, auth: auth))
    }

    /// Open-panel + parse a Docker config.json. For each entry under
    /// `auths`, decode the `auth` field (`base64("user:password")`),
    /// translate the JSON key back to a hostname, and append a new
    /// `DockerRegistryCredential` to the draft. Entries that use
    /// `credsStore` / `credHelpers` are skipped — those passwords live
    /// in the host's OS keychain, not in the file. Always reports a
    /// summary alert so the user knows what landed.
    private func importDockerConfigFile() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Import Docker config.json", comment: "")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".docker", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let parsed: DockerConfigImport.Result
        do {
            let data = try Data(contentsOf: url)
            parsed = try DockerConfigImport.parse(data)
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Couldn't import config.json",
                                                   comment: "")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }

        // Skip duplicates: same (host, username) pair already in the
        // draft is left alone (the user can edit it manually).
        var added = 0
        for entry in parsed.entries {
            let dup = draft.dockerRegistries.contains {
                $0.host.lowercased() == entry.host.lowercased()
                    && $0.username == entry.username
            }
            if dup { continue }
            draft.dockerRegistries.append(DockerRegistryCredential(
                host: entry.host,
                username: entry.username,
                password: entry.password))
            added += 1
        }

        let alert = NSAlert()
        alert.messageText = added == 1
            ? NSLocalizedString("Imported 1 registry", comment: "")
            : String(format: NSLocalizedString("Imported %d registries",
                                                comment: ""), added)
        var info = ""
        if parsed.skippedHelper > 0 {
            info = parsed.skippedHelper == 1
                ? NSLocalizedString(
                    "Skipped 1 entry stored in credsStore / credHelpers (the password lives in the OS keychain, not in the file).",
                    comment: "")
                : String(format: NSLocalizedString(
                    "Skipped %d entries stored in credsStore / credHelpers (passwords live in the OS keychain, not in the file).",
                    comment: ""), parsed.skippedHelper)
        }
        if added == 0 && info.isEmpty {
            info = NSLocalizedString("No usable auth entries found.", comment: "")
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }


    // MARK: - Other API keys (formerly Manual token rules under Advanced)

    @ViewBuilder
    private var otherTokensSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("For any API beyond the auto-handled ones (Anthropic, OpenAI, GitHub, GitLab, DigitalOcean, Kubernetes). Each entry mints a fresh fake (`brm_…`) deterministic in your real value; the fake is exported as the named env var inside the VM, the proxy swaps it back to your real value on the wire.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if draft.manualTokens.isEmpty {
                Text("No other API tokens configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(draft.manualTokens.enumerated()), id: \.element.id) { (idx, _) in
                    ManualTokenRow(
                        token: $draft.manualTokens[idx],
                        onRemove: { draft.manualTokens.remove(at: idx) }
                    )
                }
            }
            HStack {
                Spacer()
                Button {
                    draft.manualTokens.append(ManualToken())
                } label: {
                    Label("Add token", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
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
                ForEach(Array(draft.importedSSHKeys.enumerated()), id: \.element.id) { (idx, key) in
                    VStack(alignment: .leading, spacing: 6) {
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
                        Toggle(isOn: $draft.importedSSHKeys[idx].requireApproval) {
                            Text(NSLocalizedString("Require approval to use", comment: ""))
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        // Disable if the imported key has no public-key
                        // text — the gate looks the key up by wire-format
                        // blob, which we extract from the .pub. Without
                        // it we can't match incoming SIGN_REQUESTs to the
                        // approval entry, and the toggle would silently
                        // do nothing.
                        .disabled(key.publicKeyText.isEmpty)
                        .help(key.publicKeyText.isEmpty
                              ? NSLocalizedString(
                                "Public key text wasn't captured at import time — re-import with the matching .pub file alongside the private key to enable per-key gating.",
                                comment: "")
                              : NSLocalizedString(
                                "Pop a confirmation dialog the first time this credential is used in a session. Off by default.",
                                comment: ""))
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
    private func importSheetView(for sheet: ImportSheetState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import SSH key")
                .font(.title3.bold())
            Text(sheet.sourceURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            TextField("Label", text: Binding(
                get: { importSheet?.label ?? sheet.label },
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
                    completeImport(sheet: importSheet ?? sheet)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(onImportSSHKey == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func presentImportPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Import"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        panel.message = "Pick the private key file (e.g. id_ed25519, id_rsa)."
        if panel.runModal() == .OK, let url = panel.url {
            // Defer the state mutation past the NSOpenPanel modal
            // teardown. Setting `importSheet` synchronously inside the
            // same call frame as `runModal()` returning races with
            // SwiftUI's sheet presentation machinery on macOS — the
            // sheet appears, but its content view is sometimes built
            // against a stale state snapshot, producing an empty/white
            // dialog.
            DispatchQueue.main.async {
                importSheet = ImportSheetState(
                    sourceURL: url,
                    label: url.lastPathComponent,
                    passphrase: ""
                )
            }
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
    private var tracingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            // Private mode: opt-out of bromure.io streaming for this
            // profile. Independent of the local trace level above —
            // the trace inspector keeps recording per the picker;
            // only the upstream metadata feed is suppressed. Hidden
            // entirely on Macs that aren't enrolled with bromure.io
            // because the toggle has no observable effect there: with
            // no workspace to stream to, "private" is the only mode.
            if BACEnrollmentStore.load() != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $draft.privateMode) {
                        Label("Private mode", systemImage: "eye.slash")
                            .font(.subheadline.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    Text("Sessions running under this profile normally stream metadata (tools, files, commands, token usage) to your workspace. Turn this on to keep this profile's activity local — neither the title-bar indicator nor the admin's session list will see anything from this profile. The local trace inspector is unaffected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Subscription-token swap state. The proxy prompts on
            // first detection and persists `.declined` here when the
            // user clicks "Never for this profile" — surface a reset
            // so the user can change their mind without editing JSON.
            // Hide the row when state is `.unset` (default) so we
            // don't add a permanent control for something the user
            // hasn't interacted with yet.
            if draft.subscriptionTokenSwap != .unset {
                subscriptionTokenSwapRow(
                    title: "Claude subscription token swap",
                    state: draft.subscriptionTokenSwap,
                    outboundHost: "anthropic.com",
                    onReset: { draft.subscriptionTokenSwap = .unset })
            }
            if draft.codexTokenSwap != .unset {
                subscriptionTokenSwapRow(
                    title: "Codex subscription token swap",
                    state: draft.codexTokenSwap,
                    outboundHost: "chatgpt.com",
                    onReset: { draft.codexTokenSwap = .unset })
            }

            // Manual tokens moved to Credentials → Other API keys.
        }
    }

    @ViewBuilder
    private func subscriptionTokenSwapRow(title: String,
                                          state: SubscriptionTokenSwapState,
                                          outboundHost: String,
                                          onReset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: "key.viewfinder")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(state == .accepted ? "Active" : "Declined")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(state == .accepted
                 ? "The proxy is keeping the real OAuth tokens on this Mac and serving fakes inside the VM."
                 : "You said \u{201C}Never\u{201D} on the swap prompt for this profile. Reset to be asked again next time the VM sends a real token to \(outboundHost).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(state == .accepted
                   ? "Forget swap (re-prompt next session)"
                   : "Re-enable prompt") {
                onReset()
            }
            .controlSize(.small)
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
                if let storageContext {
                    StorageStackView(
                        isNewProfile: isNew,
                        context: storageContext
                    )
                } else {
                    Text("Storage controls only apply to real profiles. They appear in each profile's editor when you create or edit one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plain `KEY=VALUE` pairs exported into every shell in the VM via `proxy.env` (sourced from `.bashrc`). No proxy substitution — values land on the VM verbatim, so don't put secrets here. Good for log levels, feature flags, build toggles.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if draft.environmentVariables.isEmpty {
                Text("No environment variables configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(draft.environmentVariables.enumerated()), id: \.element.id) { (idx, _) in
                    EnvironmentVariableRow(
                        entry: $draft.environmentVariables[idx],
                        onRemove: { draft.environmentVariables.remove(at: idx) }
                    )
                }
            }
            HStack {
                Spacer()
                Button {
                    draft.environmentVariables.append(EnvironmentVariable())
                } label: {
                    Label("Add variable", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Automation (app-wide, Preferences only)

    /// Hosts the `automation.enabled` / `automation.port` /
    /// `automation.bindAddress` toggles. These drive `ACAutomationServer`,
    /// which in turn powers `Tests/ac-e2e.mjs` (via HTTP) and the
    /// `bromure-ac mcp` stdio subcommand (which wraps the same HTTP API).
    /// Settings are stored in UserDefaults, NOT the profile JSON.
    @ViewBuilder
    private var automationSection: some View {
        let store = AutomationDefaultsStore()
        VStack(alignment: .leading, spacing: 16) {
            Text("Automation API & MCP server")
                .font(.headline)
            Text("Bromure AC exposes an HTTP API on the loopback interface that lets external tools manage profiles and sessions. The bundled `bromure-ac mcp` subcommand wraps the same surface for AI agents (Claude Code, Claude Desktop). These settings apply app-wide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: store.enabledBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable automation server")
                    // Split the ternary — `Text(condition ? "a" : "b")`
                    // resolves to the non-localizing `Text(some String)`
                    // overload when one branch has a String interpolation,
                    // so we end up bypassing the strings table. Two
                    // `Text("literal \(var)")` calls each hit LocalizedStringKey.
                    if store.enabled {
                        Text("Listening on \(store.bindAddress):\(store.port). Toggling this off stops the server immediately; the MCP subcommand will no longer reach the app.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Off — the HTTP API and the MCP subcommand are unavailable.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)

            Divider()

            HStack(spacing: 8) {
                Text("Port")
                    .frame(width: 100, alignment: .trailing)
                TextField("", value: store.portBinding, formatter: Self.portFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("(default: 9223)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Bind address")
                    .frame(width: 100, alignment: .trailing)
                TextField("127.0.0.1", text: store.bindAddressBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                if store.bindAddress != "127.0.0.1" && !store.bindAddress.isEmpty {
                    Label("Non-loopback bind exposes the API to the network. The MCP server has no auth.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            Text("Port and bind address take effect the next time the server starts. Toggling the switch off and on applies them now.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Text("MCP client configuration")
                .font(.headline)
            Text("Add this to `~/.config/claude-code/.mcp.json` (or your MCP client's equivalent):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.mcpConfigSnippet)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))

            Spacer()
        }
        .padding(.top, 4)
    }

    private static let portFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 1
        f.maximum = 65535
        return f
    }()

    private static let mcpConfigSnippet: String =
        #"""
        {
          "mcpServers": {
            "bromure-ac": {
              "command": "/Applications/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac",
              "args": ["mcp"]
            }
          }
        }
        """#

    // MARK: - MCP servers

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP servers give your agent access to external tools and context. Configs are translated into the right format for the active agent (Claude Code or Codex) and injected into the VM at boot.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if draft.mcpServers.isEmpty {
                Text("No MCP servers configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(draft.mcpServers.enumerated()), id: \.element.id) { (idx, _) in
                    MCPServerRow(
                        server: $draft.mcpServers[idx],
                        onRemove: { draft.mcpServers.remove(at: idx) }
                    )
                }
            }
            HStack {
                Spacer()
                Button {
                    draft.mcpServers.append(MCPServer())
                } label: {
                    Label("Add server", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func guardrailRow(_ title: String, systemImage: String,
                              mode: Binding<GuardrailsPolicy.Mode>, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: mode) {
                    ForEach(GuardrailsPolicy.Mode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var guardrailsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Guardrails strips destructive operations from the protocols this agent speaks. It's enforced on the host — inside the proxy — so a misbehaving or compromised agent in the VM can't bypass it. Blocked calls return a hard error the agent sees.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                guardrailRow("Kubernetes", systemImage: "shippingbox.fill",
                             mode: $draft.guardrails.kubernetes,
                             detail: "\(draft.guardrails.kubernetes.detail) \(NSLocalizedString("Applies to the kube API servers from this profile's kubeconfigs (e.g. `kubectl delete` fails cleanly).", comment: ""))")
                if draft.kubeconfigs.isEmpty && draft.guardrails.kubernetes != .off {
                    Label("No kubeconfigs on this profile — add one under Credentials for this to take effect.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                guardrailRow("AWS", systemImage: "cloud.fill", mode: $draft.guardrails.aws,
                             detail: "\(draft.guardrails.aws.detail) \(NSLocalizedString("All *.amazonaws.com APIs; classified by action name (Delete*/Terminate* = destructive, Get*/List*/Describe* = read).", comment: ""))")
                Divider()
                guardrailRow("DigitalOcean", systemImage: "drop.fill", mode: $draft.guardrails.digitalOcean,
                             detail: "\(draft.guardrails.digitalOcean.detail) \(NSLocalizedString("api.digitalocean.com — DELETE = destructive.", comment: ""))")
                Divider()
                guardrailRow(NSLocalizedString("Docker registries", comment: ""), systemImage: "cube.box.fill", mode: $draft.guardrails.docker,
                             detail: "\(draft.guardrails.docker.detail) \(NSLocalizedString("Registries you've added under Credentials — pull = read, push = write, delete = destructive.", comment: ""))")
                if draft.dockerRegistries.isEmpty && draft.guardrails.docker != .off {
                    Label("No registries on this profile — add one under Credentials for this to take effect.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                guardrailRow("GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
                             mode: $draft.guardrails.github,
                             detail: "\(draft.guardrails.github.detail) \(NSLocalizedString("github.com REST API + git over HTTPS; read-only also blocks `git push`.", comment: ""))")
                Divider()
                guardrailRow("GitLab", systemImage: "chevron.left.forwardslash.chevron.right",
                             mode: $draft.guardrails.gitlab,
                             detail: "\(draft.guardrails.gitlab.detail) \(NSLocalizedString("gitlab.com REST API + git over HTTPS.", comment: ""))")
                Divider()
                guardrailRow("Bitbucket", systemImage: "chevron.left.forwardslash.chevron.right",
                             mode: $draft.guardrails.bitbucket,
                             detail: "\(draft.guardrails.bitbucket.detail) \(NSLocalizedString("bitbucket.org REST API + git over HTTPS.", comment: ""))")
                Divider()
                databaseGuardrails
            }
            .padding(.bottom, 8)
        }
    }

    private func databaseEngineSymbol(_ engine: HTTPDatabaseEndpoint.Engine) -> String {
        switch engine {
        case .mongoDataAPI:  return "leaf.fill"
        case .clickHouse:    return "bolt.horizontal.fill"
        case .elasticsearch: return "magnifyingglass"
        }
    }
    private func databaseEngineDetail(_ engine: HTTPDatabaseEndpoint.Engine) -> String {
        switch engine {
        case .mongoDataAPI:
            return NSLocalizedString("deleteOne/deleteMany = destructive; insert/update/replace = write; find/aggregate = read.", comment: "")
        case .clickHouse:
            return NSLocalizedString("DROP/TRUNCATE/DELETE and ALTER…DELETE = destructive; INSERT/CREATE = write; SELECT/SHOW = read.", comment: "")
        case .elasticsearch:
            return NSLocalizedString("DELETE + _delete_by_query = destructive; _search/_count/_msearch = read; _bulk/index/_update = write.", comment: "")
        }
    }

    @ViewBuilder
    private var databaseGuardrails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Databases")
                .font(.subheadline.weight(.semibold))
            if draft.httpDatabases.isEmpty {
                Text("No database endpoints configured. Add MongoDB, ClickHouse, or Elasticsearch endpoints under Credentials to guard them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(draft.httpDatabases) { db in
                    if let idx = draft.httpDatabases.firstIndex(where: { $0.id == db.id }) {
                        let label = db.name.isEmpty
                            ? "\(db.engine.displayName) — \(db.host.isEmpty ? "(no host)" : db.host)"
                            : "\(db.name) (\(db.engine.displayName))"
                        guardrailRow(label,
                                     systemImage: databaseEngineSymbol(db.engine),
                                     mode: $draft.httpDatabases[idx].guardrail,
                                     detail: "\(db.guardrail.detail) \(databaseEngineDetail(db.engine))")
                        if db.host.trimmingCharacters(in: .whitespaces).isEmpty
                            && db.guardrail != .off {
                            Label("Set this endpoint's host under Credentials for the guard to take effect.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Supply Chain section

    @ViewBuilder
    private var promptInjectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("Bromure scans the agent's AI traffic on-device for injected instructions — nothing leaves the Mac. Each detector uses a local model, downloaded from bromure.io the first time you enable it.", comment: ""))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(label: Label(NSLocalizedString("Detectors", comment: ""),
                                  systemImage: "magnifyingglass")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(NSLocalizedString("Detect prompt injection in source code", comment: ""),
                           isOn: $draft.promptInjection.detectSourceInjection)
                    Text(NSLocalizedString("Scores the file contents, web pages, and tool output the agent reads (Prompt Guard). Catches “ignore previous instructions / exfiltrate secrets” hidden in a rogue repository. Downloads ~272 MB on first enable.", comment: ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle(NSLocalizedString("Detect rogue instructions in CLAUDE.md files and similar", comment: ""),
                           isOn: $draft.promptInjection.detectRulesInjection)
                    Text(NSLocalizedString("Scores CLAUDE.md, AGENTS.md, GROK.md, and the other instruction / settings files Claude Code, Codex, and Grok load as authority. Downloads ~571 MB on first enable.", comment: ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            GroupBox(label: Label(NSLocalizedString("When an injection is detected", comment: ""),
                                  systemImage: "exclamationmark.triangle")) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $draft.promptInjection.onDetection) {
                        ForEach(PromptInjectionPolicy.Action.allCases, id: \.self) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(!draft.promptInjection.isActive)
                    Text(NSLocalizedString("“Log but continue” records detections to the Security Log window. “Ask me what to do” pauses the request and shows the flagged text. “Block” fails the request outright.", comment: ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var supplyChainSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("Bromure scans every package fetch (npm, PyPI, Cargo, RubyGems, Maven, NuGet, Go modules, Packagist) through the host MITM and applies these policies before the agent sees the response. The in-VM `.npmrc` / `pip.conf` can only further restrict these settings — they cannot loosen them. Use the per-package allowlists for surgical overrides.", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(label: Label(NSLocalizedString("Age gate", comment: ""),
                                  systemImage: "calendar")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(NSLocalizedString("Refuse packages younger than the cutoff", comment: ""),
                           isOn: $draft.supplyChain.ageGateEnabled)
                    HStack {
                        Text(NSLocalizedString("Minimum age:", comment: ""))
                        Stepper(value: $draft.supplyChain.ageGateDays, in: 0...90) {
                            Text(String(format: NSLocalizedString("%d days", comment: ""),
                                        draft.supplyChain.ageGateDays))
                                .frame(minWidth: 80, alignment: .leading)
                        }
                        .disabled(!draft.supplyChain.ageGateEnabled)
                    }
                    Text(NSLocalizedString("Floating refs (`latest`, semver ranges) silently resolve to the newest version older than the cutoff. Pinned references to too-fresh versions get a 451 with a clear Bromure error.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    allowlistEditor(
                        title: NSLocalizedString("Exempt packages (format: `npm:axios` or just `axios`)", comment: ""),
                        list: $draft.supplyChain.ageGateAllowlist)
                }
                .padding(8)
            }

            GroupBox(label: Label(NSLocalizedString("OSV vulnerability check", comment: ""),
                                  systemImage: "ladybug")) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(NSLocalizedString("Look up packages on api.osv.dev (free, no key required)", comment: ""),
                           isOn: $draft.supplyChain.osvEnabled)
                    Picker(NSLocalizedString("Block at severity:", comment: ""),
                           selection: $draft.supplyChain.osvSeverity) {
                        ForEach(SupplyChainPolicy.Severity.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .disabled(!draft.supplyChain.osvEnabled)
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                    Text(NSLocalizedString("Aggregates GitHub Advisory Database + PyPI advisories + Go's database + RubySec etc. Off by default — a low-severity CVE in a transitive subpackage shouldn't interrupt a workflow.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            GroupBox(label: Label("socket.dev",
                                  systemImage: "checkmark.shield")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(NSLocalizedString("API key:", comment: ""))
                        SecureField("", text: $draft.supplyChain.socketAPIKey)
                            .textFieldStyle(.roundedBorder)
                        Link(destination: URL(string: "https://socket.dev/dashboard/settings/api-tokens")!) {
                            HStack(spacing: 2) {
                                Text(NSLocalizedString("Get an API key", comment: ""))
                                Image(systemName: "arrow.up.forward.square")
                            }
                            .font(.caption)
                        }
                    }
                    Text(NSLocalizedString("The key is stored host-side only — Bromure never exports it into the VM. Calls go directly to api.socket.dev from the host's MITM proxy.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().padding(.vertical, 4)
                    Toggle(NSLocalizedString("Block compromised packages (rogue install scripts, malware-flagged, typosquats, suspicious telemetry)", comment: ""),
                           isOn: $draft.supplyChain.socketBlockCompromised)
                        .disabled(draft.supplyChain.socketAPIKey.isEmpty)
                    Toggle(NSLocalizedString("Block packages with known CVEs", comment: ""),
                           isOn: $draft.supplyChain.socketBlockCVE)
                        .disabled(draft.supplyChain.socketAPIKey.isEmpty)
                    Picker(NSLocalizedString("CVE block threshold:", comment: ""),
                           selection: $draft.supplyChain.socketCVESeverity) {
                        ForEach(SupplyChainPolicy.Severity.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .disabled(!draft.supplyChain.socketBlockCVE || draft.supplyChain.socketAPIKey.isEmpty)
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                }
                .padding(8)
            }

            GroupBox(label: Label(NSLocalizedString("Install scripts", comment: ""),
                                  systemImage: "scroll")) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(NSLocalizedString("Strip preinstall / install / postinstall / prepare from npm tarballs on the fly", comment: ""),
                           isOn: $draft.supplyChain.stripInstallScripts)
                    Text(NSLocalizedString("Bromure rewrites the tarball, removes the script keys from `package.json`, and updates the registry metadata hash so npm's verification still passes for unpinned installs. Some packages (binding compilers — better-sqlite3, node-canvas, …) legitimately need install scripts; add them to the allowlist below.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    allowlistEditor(
                        title: NSLocalizedString("Allow install scripts for (format: `npm:better-sqlite3`)", comment: ""),
                        list: $draft.supplyChain.stripAllowlist)
                }
                .padding(8)
            }

            GroupBox(label: Label(NSLocalizedString("Lockfile-pinned installs", comment: ""),
                                  systemImage: "lock.fill")) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(NSLocalizedString("Prompt before passing lockfile-pinned tarballs through unmodified (`npm ci`, `pip --require-hashes`)", comment: ""),
                           isOn: $draft.supplyChain.lockfilePrompt)
                    Text(NSLocalizedString("These installs use cryptographic integrity hashes baked into a lockfile — Bromure can't rewrite them without breaking verification. When this is on, the first lockfile-pinned fetch in a batch pops a host dialog (Allow once / 15 min / for the session / Don't allow); the entire batch follows the decision.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }
        }
        .padding(16)
    }

    /// Compact list-editor reused for the per-package allowlists.
    /// One entry per row, "+/-" buttons, no header chrome — keeps the
    /// settings panel from drowning in nested groups.
    @ViewBuilder
    private func allowlistEditor(title: String, list: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium))
            ForEach(Array(list.wrappedValue.enumerated()), id: \.offset) { (idx, value) in
                HStack {
                    TextField("", text: Binding(
                        get: { list.wrappedValue[idx] },
                        set: { list.wrappedValue[idx] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button(action: {
                        var copy = list.wrappedValue
                        copy.remove(at: idx)
                        list.wrappedValue = copy
                    }) {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            Button(action: {
                list.wrappedValue.append("")
            }) {
                Label(NSLocalizedString("Add entry", comment: ""),
                      systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

            // Programming ligatures (off by default).
            HStack(spacing: 12) {
                Text("Ligatures").frame(width: 110, alignment: .trailing)
                Toggle("", isOn: $draft.fontLigatures)
                    .labelsHidden()
                Text("Draw \(Text("<=").font(.system(.caption, design: .monospaced))), \(Text("==").font(.system(.caption, design: .monospaced))), \(Text("=>").font(.system(.caption, design: .monospaced))) as combined glyphs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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

    /// Fixed-width font families on this Mac, sorted. A terminal only makes
    /// sense in a monospace font, so we keep just the fixed-pitch families.
    /// We also exclude families whose name starts with `.` — those are
    /// macOS-internal identifiers (`.AppleSystemUIFontMonospaced`, …) that
    /// Linux fontconfig can't resolve, so picking one would silently fall
    /// back in kitty.
    static let allFontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .filter { NSFont(name: $0, size: 12)?.isFixedPitch ?? false }
            .sorted()
    }()

    /// Fonts that always exist in the *guest* image even when the host doesn't
    /// have them registered: JetBrains Mono (installed via apt) and the SF Mono
    /// families copied from Terminal.app at image-build time ("SF Mono" and
    /// "SF Mono Terminal"). `NSFont(name:)` returns nil for these on most Macs,
    /// so they'd never survive the host isFixedPitch filter — add them
    /// explicitly so they're selectable and resolve in the guest's fontconfig.
    static let guestBundledFonts = ["JetBrains Mono", "SF Mono", "SF Mono Terminal"]

    /// The list shown in the Picker — host monospace families plus the
    /// guest-bundled fonts, always including the currently-selected family so
    /// the Picker never shows blank.
    private var fontFamiliesForPicker: [String] {
        var set = Set(Self.allFontFamilies)
        set.formUnion(Self.guestBundledFonts)
        let current = draft.customFontFamily ?? terminalDefaults.fontFamily
        if !current.isEmpty { set.insert(current) }
        return set.sorted()
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
            Toggle(isOn: $token.requireApproval) {
                Text(NSLocalizedString("Require approval to use", comment: ""))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Environment variable row

private struct EnvironmentVariableRow: View {
    @Binding var entry: EnvironmentVariable
    var onRemove: () -> Void

    var body: some View {
        let nameTrim = entry.name.trimmingCharacters(in: .whitespaces)
        let nameInvalid = !nameTrim.isEmpty && !EnvironmentVariable.isValidName(nameTrim)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Name", text: $entry.name, prompt: Text("MY_ENV_VAR"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Text("=")
                    .foregroundStyle(.tertiary)
                TextField("Value", text: $entry.value, prompt: Text("1"))
                    .textFieldStyle(.roundedBorder)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this variable")
            }
            if nameInvalid {
                Text("Name must match `[A-Za-z_][A-Za-z0-9_]*` to be exported.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - MCP server row

private struct MCPServerRow: View {
    @Binding var server: MCPServer
    var onRemove: () -> Void
    @State private var showJSON = false
    @State private var isAuthorizing = false
    @State private var authError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Name", text: $server.name, prompt: Text("my-server"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                if !showJSON {
                    Picker("", selection: $server.transport) {
                        ForEach(MCPServer.Transport.allCases, id: \.self) { t in
                            Text(t.rawValue.uppercased()).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                Toggle("", isOn: $server.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(LocalizedStringKey(server.enabled ? "Enabled" : "Disabled"))
                Spacer()
                Button {
                    if !showJSON && server.rawJSON.isEmpty {
                        server.rawJSON = generateJSON()
                    } else if showJSON {
                        server.rawJSON = ""
                    }
                    showJSON.toggle()
                } label: {
                    Image(systemName: showJSON ? "slider.horizontal.3" : "curlybraces")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(LocalizedStringKey(showJSON ? "Switch to form" : "Edit as JSON"))
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this server")
            }
            if showJSON {
                jsonEditor
            } else {
                formFields
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
        .opacity(server.enabled ? 1.0 : 0.6)
        .onAppear {
            if !server.rawJSON.isEmpty { showJSON = true }
        }
    }

    @ViewBuilder
    private var formFields: some View {
        switch server.transport {
        case .stdio:
            HStack(spacing: 6) {
                TextField("Command", text: $server.command, prompt: Text("npx"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                TextField("Arguments", text: Binding(
                    get: { server.arguments.joined(separator: " ") },
                    set: { server.arguments = $0.components(separatedBy: " ").filter { !$0.isEmpty } }
                ), prompt: Text("-y @upstash/context7-mcp"))
                    .textFieldStyle(.roundedBorder)
            }
        case .http:
            TextField("URL", text: $server.url, prompt: Text("https://mcp.example.com/mcp"))
                .textFieldStyle(.roundedBorder)
            DisclosureGroup("Authentication") {
                VStack(alignment: .leading, spacing: 6) {
                    // OAuth section
                    if !server.url.isEmpty {
                        HStack(spacing: 8) {
                            if server.oauthState != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Authorized")
                                    .font(.caption)
                                if let exp = server.oauthState?.expiresAt {
                                    Text("expires \(exp, style: .relative)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Re-authorize") { authorizeOAuth() }
                                    .font(.caption)
                                    .disabled(isAuthorizing)
                                Button("Revoke") {
                                    server.oauthState = nil
                                    server.bearerToken = ""
                                }
                                .font(.caption)
                                .foregroundStyle(.red)
                            } else {
                                Button(LocalizedStringKey(isAuthorizing ? "Authorizing\u{2026}" : "Authorize with OAuth\u{2026}")) {
                                    authorizeOAuth()
                                }
                                .font(.caption)
                                .disabled(isAuthorizing)
                                if let err = authError {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text(err)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        Divider()
                        Text("Or enter a static token:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // Manual token fields
                    HStack(spacing: 6) {
                        Text("Env var name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        TextField("", text: $server.bearerTokenEnvVar,
                                  prompt: Text("e.g. FIGMA_OAUTH_TOKEN"))
                            .textFieldStyle(.roundedBorder)
                            .disabled(server.oauthState != nil)
                    }
                    if !server.bearerTokenEnvVar.isEmpty {
                        HStack(spacing: 6) {
                            Text("Token")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            if server.oauthState != nil {
                                Text("Managed by OAuth")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                SecureField("", text: $server.bearerToken,
                                            prompt: Text("Never sent to VM — swapped by proxy"))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
            .font(.caption)
        }
    }

    private func authorizeOAuth() {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        authError = nil
        Task { @MainActor in
            defer { isAuthorizing = false }
            do {
                let broker = MCPOAuthBroker()
                let result = try await broker.authorizeServer(url: server.url, existingState: server.oauthState)
                server.oauthState = MCPOAuthState(
                    clientID: result.clientID,
                    clientSecret: result.clientSecret,
                    authorizationEndpoint: result.authorizationEndpoint,
                    tokenEndpoint: result.tokenEndpoint,
                    registrationEndpoint: result.registrationEndpoint,
                    accessToken: result.accessToken,
                    refreshToken: result.refreshToken,
                    expiresAt: result.expiresIn.map {
                        Date().addingTimeInterval(TimeInterval($0))
                    },
                    callbackPort: result.callbackPort
                )
                server.bearerToken = result.accessToken
                if server.bearerTokenEnvVar.isEmpty {
                    let sanitized = server.name
                        .uppercased()
                        .replacingOccurrences(of: " ", with: "_")
                        .replacingOccurrences(of: "-", with: "_")
                    server.bearerTokenEnvVar = "MCP_OAUTH_\(sanitized)"
                }
            } catch MCPOAuthBroker.BrokerError.authorizationCancelled {
                // User cancelled — no error to show.
            } catch {
                authError = error.localizedDescription
            }
        }
    }

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Raw JSON config — passed directly to the agent's MCP config file.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextEditor(text: $server.rawJSON)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(jsonValid ? Color.clear : Color.red.opacity(0.5))
                )
            if !jsonValid {
                Text("Invalid JSON")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var jsonValid: Bool {
        guard !server.rawJSON.isEmpty,
              let data = server.rawJSON.data(using: .utf8) else { return true }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func generateJSON() -> String {
        var obj: [String: Any] = [:]
        switch server.transport {
        case .stdio:
            obj["command"] = server.command
            if !server.arguments.isEmpty { obj["args"] = server.arguments }
        case .http:
            obj["type"] = "http"
            obj["url"] = server.url
            if !server.bearerTokenEnvVar.isEmpty {
                obj["bearerTokenEnvVar"] = server.bearerTokenEnvVar
            }
        }
        let env = server.environment.filter(\.isUsable)
        if !env.isEmpty {
            obj["env"] = env.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
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
    @Binding var bedrockModelID: String
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
                        if m == .bedrock && tool != .claude {
                            EmptyView()
                        } else {
                            Text(m.displayName).tag(m)
                        }
                    }
                }
                .pickerStyle(.radioGroup)

                switch spec.authMode {
                case .token:
                    SecureField(
                        envVarPlaceholder,
                        text: Binding(
                            get: { spec.apiKey ?? "" },
                            set: { spec.apiKey = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    Toggle(isOn: $spec.requireApproval) {
                        Text(NSLocalizedString("Require approval to use", comment: ""))
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                case .subscription:
                    Text("You'll run `\(tool.rawValue) login` once inside the VM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .bedrock:
                    Text("Claude Code will authenticate via AWS Bedrock using the credentials configured in the AWS section below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent(NSLocalizedString("Default Model ID", comment: "")) {
                        TextField("us.anthropic.claude-sonnet-4-6-v1:0",
                                  text: $bedrockModelID)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }
                    Text("Configure AWS credentials (SSO or static keys) in the Credentials → AWS section.")
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
        case .grok:   return "xAI API key"
        }
    }
}

// MARK: - Kubernetes context row

/// One editable row for a KubeconfigEntry. Shows name + server inline;
/// expands to reveal CA, namespace, and the auth-method-specific
/// fields (token / cert+key / exec command + args).
private struct KubeconfigRow: View {
    @Binding var entry: KubeconfigEntry
    var onRemove: () -> Void

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Server").frame(width: 80, alignment: .trailing)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        TextField("https://k8s.example.com:6443",
                                  text: $entry.serverURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Text("CA cert").frame(width: 80, alignment: .trailing)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            TextEditor(text: $entry.caCertPEM)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 60)
                                .border(Color.secondary.opacity(0.25))
                            Text("Optional. Leave blank to trust the Bromure CA only (the proxy still validates the upstream).")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("Namespace").frame(width: 80, alignment: .trailing)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        TextField("default", text: $entry.namespace)
                            .textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    authPicker
                    authFields
                    Toggle(isOn: $entry.requireApproval) {
                        Text(NSLocalizedString("Require approval to use", comment: ""))
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.secondary)
                    TextField("context-name", text: $entry.name)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.semibold))
                    if !entry.serverURL.isEmpty {
                        Text(entry.serverURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    authBadge
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.borderless)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var authBadge: some View {
        Text(authLabel)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(authColor.gradient))
    }
    private var authLabel: String {
        switch entry.auth {
        case .bearerToken:  return NSLocalizedString("token", comment: "")
        case .clientCert:   return NSLocalizedString("cert", comment: "")
        case .execPlugin:   return NSLocalizedString("exec", comment: "")
        }
    }
    private var authColor: Color {
        switch entry.auth {
        case .bearerToken:  return .blue
        case .clientCert:   return .green
        case .execPlugin:   return .purple
        }
    }

    @ViewBuilder
    private var authPicker: some View {
        HStack(spacing: 6) {
            Text("Auth").frame(width: 80, alignment: .trailing)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { authKind },
                set: { switchAuthKind(to: $0) }
            )) {
                Text("Bearer token").tag("token")
                Text("Client certificate").tag("cert")
                Text("Exec plugin").tag("exec")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
    private var authKind: String {
        switch entry.auth {
        case .bearerToken: return "token"
        case .clientCert:  return "cert"
        case .execPlugin:  return "exec"
        }
    }
    private func switchAuthKind(to kind: String) {
        switch kind {
        case "token": entry.auth = .bearerToken("")
        case "cert":  entry.auth = .clientCert(certPEM: "", keyPEM: "")
        case "exec":  entry.auth = .execPlugin(command: "", args: [], refreshSeconds: 600)
        default: break
        }
    }

    @ViewBuilder
    private var authFields: some View {
        switch entry.auth {
        case .bearerToken(let t):
            HStack(spacing: 6) {
                Text("Token").frame(width: 80, alignment: .trailing)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                SecureField("eyJ… or sa-…", text: Binding(
                    get: { t }, set: { entry.auth = .bearerToken($0) }))
                    .textFieldStyle(.roundedBorder)
            }
        case .clientCert(let cert, let key):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text("Cert PEM").frame(width: 80, alignment: .trailing)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { cert },
                        set: { entry.auth = .clientCert(certPEM: $0, keyPEM: key) }))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 60)
                        .border(Color.secondary.opacity(0.25))
                }
                HStack(alignment: .top, spacing: 6) {
                    Text("Key PEM").frame(width: 80, alignment: .trailing)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { key },
                        set: { entry.auth = .clientCert(certPEM: cert, keyPEM: $0) }))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 60)
                        .border(Color.secondary.opacity(0.25))
                }
            }
        case .execPlugin(let cmd, let args, let secs):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Command").frame(width: 80, alignment: .trailing)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    TextField("/usr/local/bin/aws", text: Binding(
                        get: { cmd },
                        set: { entry.auth = .execPlugin(command: $0, args: args, refreshSeconds: secs) }))
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Text("Args").frame(width: 80, alignment: .trailing)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    TextField("eks get-token --cluster-name foo (space-separated)",
                              text: Binding(
                                get: { args.joined(separator: " ") },
                                set: { newVal in
                                    let parts = newVal.split(separator: " ").map(String.init)
                                    entry.auth = .execPlugin(command: cmd, args: parts, refreshSeconds: secs)
                                }))
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Text("Refresh").frame(width: 80, alignment: .trailing)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Stepper(value: Binding(
                        get: { secs },
                        set: { entry.auth = .execPlugin(command: cmd, args: args, refreshSeconds: $0) }),
                            in: 60...3600, step: 60) {
                        Text("\(secs / 60) min")
                            .font(.caption.monospaced())
                    }
                    Spacer()
                }
                Text("Bromure runs this command on the host every refresh interval, parses the kubectl ExecCredential JSON, and feeds the resulting token into the proxy's swap map. The VM's kubectl never executes the plugin.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Toggle(isOn: $credential.requireApproval) {
                Text(NSLocalizedString("Require approval to use", comment: ""))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
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

// MARK: - HTTPS database endpoint row

private struct DatabaseEndpointRow: View {
    @Binding var endpoint: HTTPDatabaseEndpoint
    var onRemove: () -> Void

    @State private var revealSecret: Bool = false

    private var envVarsText: Binding<String> {
        Binding(
            get: { endpoint.envVars.joined(separator: ", ") },
            set: { raw in
                endpoint.envVars = raw
                    .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
                    .map(String.init)
            }
        )
    }

    private var hostPrompt: String {
        switch endpoint.engine {
        case .mongoDataAPI:  return "data.mongodb-api.com"
        case .clickHouse:    return "myhost.clickhouse.cloud:8443 or self-hosted host"
        case .elasticsearch: return "my-deployment.es.io"
        }
    }
    private var secretPrompt: String {
        switch endpoint.auth {
        case .basic:  return "password"
        case .apiKey: return "API key"
        case .bearer: return "bearer token"
        }
    }
    private var envVarPrompt: String {
        switch endpoint.engine {
        case .mongoDataAPI:  return "MONGODB_API_KEY"
        case .clickHouse:    return "CLICKHOUSE_PASSWORD"
        case .elasticsearch: return "ELASTIC_PASSWORD"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Name (optional)", text: $endpoint.name,
                          prompt: Text("Production cluster"))
                    .textFieldStyle(.roundedBorder)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Remove this endpoint", comment: ""))
            }
            TextField("Host", text: $endpoint.host, prompt: Text(hostPrompt))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .help(NSLocalizedString(
                    "The hostname the agent connects to (no scheme). Both the credential swap and Guardrails scope to this host, so self-hosted instances work.",
                    comment: ""))

            Picker("Auth", selection: $endpoint.auth) {
                ForEach(HTTPDatabaseEndpoint.AuthKind.allCases, id: \.self) { a in
                    Text(a.displayName).tag(a)
                }
            }
            .pickerStyle(.segmented)

            if endpoint.auth == .basic {
                TextField("Username", text: $endpoint.username, prompt: Text("default"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            HStack(spacing: 6) {
                ZStack {
                    if revealSecret {
                        TextField("Secret", text: $endpoint.secret, prompt: Text(secretPrompt))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Secret", text: $endpoint.secret, prompt: Text("•••• ••••"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Button {
                    revealSecret.toggle()
                } label: {
                    Image(systemName: revealSecret ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealSecret
                      ? NSLocalizedString("Hide secret", comment: "")
                      : NSLocalizedString("Show secret", comment: ""))
            }

            TextField("Env var(s)", text: envVarsText, prompt: Text(envVarPrompt))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .help(NSLocalizedString(
                    "Environment variable(s) the fake secret is exported under in the VM (comma-separated for more than one). Reference these from your code / connection string.",
                    comment: ""))

            Toggle(isOn: $endpoint.requireApproval) {
                Text(NSLocalizedString("Require approval to use", comment: ""))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Docker registry row

private struct DockerRegistryRow: View {
    @Binding var cred: DockerRegistryCredential
    var onRemove: () -> Void

    @State private var revealPassword: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: hostSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Host", text: $cred.host, prompt: Text("ghcr.io"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Remove this registry", comment: ""))
            }
            HStack(spacing: 6) {
                TextField("Username", text: $cred.username, prompt: Text("octocat"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                ZStack {
                    if revealPassword {
                        TextField("Password / token", text: $cred.password,
                                  prompt: Text("ghp_…"))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Password / token", text: $cred.password,
                                    prompt: Text("•••• ••••"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealPassword
                      ? NSLocalizedString("Hide password", comment: "")
                      : NSLocalizedString("Show password", comment: ""))
            }
            Toggle(isOn: $cred.requireApproval) {
                Text(NSLocalizedString("Require approval to use", comment: ""))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var hostSymbol: String {
        let h = cred.host.lowercased()
        if h == "ghcr.io"                            { return "cat.fill" }
        if h.contains("gitlab")                      { return "fox.fill" }
        if h == "docker.io" || h == "index.docker.io" { return "cube.box.fill" }
        return "shippingbox.fill"
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

// MARK: - Automation defaults bridge

/// Read/write the app-wide automation settings stored in UserDefaults,
/// and live-toggle the HTTP server on the AC delegate when the user flips
/// the switch. Used only by the Preferences "Automation" pane.
@MainActor
private struct AutomationDefaultsStore {
    private let std = UserDefaults.standard

    var enabled: Bool {
        // Defaults to false (opt-in). Matches the delegate's
        // `startAutomationServerIfNeeded` gate.
        std.bool(forKey: "automation.enabled")
    }
    var port: Int {
        let n = std.integer(forKey: "automation.port")
        return n > 0 ? n : 9223
    }
    var bindAddress: String {
        std.string(forKey: "automation.bindAddress") ?? "127.0.0.1"
    }

    var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.enabled },
            set: { on in
                self.std.set(on, forKey: "automation.enabled")
                guard let d = NSApp.delegate as? ACAppDelegate else { return }
                if on {
                    d.startAutomationServerIfNeeded()
                } else {
                    d.stopAutomationServer()
                }
            }
        )
    }

    var portBinding: Binding<Int> {
        Binding(
            get: { self.port },
            set: { v in self.std.set(max(1, min(65535, v)), forKey: "automation.port") }
        )
    }

    var bindAddressBinding: Binding<String> {
        Binding(
            get: { self.bindAddress },
            set: { v in
                self.std.set(v.isEmpty ? "127.0.0.1" : v, forKey: "automation.bindAddress")
            }
        )
    }
}
