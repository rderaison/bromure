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
    /// Debug/screenshot hook: present a Credentials-pane sheet (object is a
    /// spec string: "picker", "editor:<type>", or "envimport").
    static let bromureACPresentCredentialSheet =
        Notification.Name("io.bromure.ac.presentCredentialSheet")
}

enum EditorCategory: String, CaseIterable, Identifiable {
    case general     = "General"
    case models      = "Agents"
    case localModels = "Local Models"
    case fusion      = "Fusion"
    case folders     = "Folders"
    case credentials = "Credentials"
    case environment = "Environment"
    case mcp         = "MCP"
    case tracing     = "Tracing"
    case guardrails       = "Guardrails"
    case supplyChain      = "Supply Chain"
    case promptInjection  = "Prompt Injection"
    case appearance  = "Appearance"
    case browser     = "Browser"
    case resources   = "Resources"
    /// App-wide automation toggles. Only shown when the editor is opened
    /// from "Bromure → Preferences" (i.e., `storageContext == nil`); the
    /// settings here are not per-profile.
    case automation  = "Automation"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general:     "person.text.rectangle.fill"
        case .models:      "sparkles"
        case .localModels: "cpu.fill"
        case .fusion:      "bolt.fill"
        case .folders:     "folder.fill"
        case .credentials: "key.fill"
        case .environment: "terminal.fill"
        case .mcp:         "network"
        case .tracing:     "doc.text.magnifyingglass"
        case .guardrails:       "exclamationmark.shield.fill"
        case .supplyChain:      "shippingbox.fill"
        case .promptInjection:  "exclamationmark.triangle.fill"
        case .appearance:  "paintpalette.fill"
        case .browser:     "globe"
        case .resources:   "memorychip.fill"
        case .automation:  "antenna.radiowaves.left.and.right"
        }
    }

    var color: Color {
        switch self {
        case .general:     .indigo
        case .models:      .purple
        case .localModels: .mint
        case .fusion:      .yellow
        case .folders:     .orange
        case .credentials: .green
        case .environment: .teal
        case .mcp:         .blue
        case .tracing:     .red
        case .guardrails:       .orange
        case .supplyChain:      .yellow
        case .promptInjection:  .red
        case .appearance:  .pink
        case .browser:     .blue
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
    /// Per-profile home *image* (ext4 model); nil for virtiofs-model and
    /// new profiles. When set, the home row sizes/labels against the
    /// image instead of walking the directory.
    var profileHomeImageURL: URL?
    /// True if the profile's VM is currently open in a session window —
    /// reset actions are unsafe in that state.
    var isRunning: Bool
    /// Wired to ACAppDelegate.resetProfile / resetHomeProfile. Both
    /// handle their own confirmation alerts.
    var onResetDisk: () -> Void
    var onResetHome: () -> Void
    /// Non-nil only for saved legacy (virtiofs-home) profiles: re-arms the
    /// home-storage upgrade offer for the next launch.
    var onUpgradeHome: (() -> Void)?
    /// Non-nil only for saved ext4-home profiles: roll the home back to one
    /// of its per-boot checkpoints (ACAppDelegate.restoreHomeStorage — owns
    /// its own picker + confirmation).
    var onRestoreHome: (() -> Void)?

    static func empty(baseImageURL: URL) -> ProfileStorageContext {
        ProfileStorageContext(
            baseImageURL: baseImageURL,
            baseImageVersion: nil,
            baseImageBuildDate: nil,
            profileDiskURL: nil,
            profileHomeURL: nil,
            profileHomeImageURL: nil,
            isRunning: false,
            onResetDisk: {},
            onResetHome: {},
            onUpgradeHome: nil,
            onRestoreHome: nil
        )
    }
}

// MARK: - Env-file import model + review sheet

struct EnvImportState: Identifiable {
    let id = UUID()
    var fileName: String
    var recognized: [EnvRecognizedRow]
    var unrecognized: [EnvUnrecognizedRow]
    var importCount: Int {
        recognized.filter { $0.include }.count + unrecognized.filter { $0.include }.count
    }
    static let blank = EnvImportState(fileName: "", recognized: [], unrecognized: [])
}
struct EnvRecognizedRow: Identifiable {
    let id = UUID()
    let slot: EnvFileImport.Slot
    let name: String
    let value: String
    var include: Bool
    var note: String
    var gitUsername: String = ""
    var needsGitUsername: Bool { if case .gitToken = slot { return true } ; return false }
}
struct EnvUnrecognizedRow: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    var include: Bool = true
    var hostsText: String = ""
}

/// The env-import review sheet, bound to the live `EnvImportState`. A separate
/// view (rather than an inline sheet closure) so its bindings always resolve to
/// the current state — an inline closure reading the parent's optional @State
/// captures a stale value and renders empty.
struct EnvImportReviewView: View {
    @Binding var state: EnvImportState
    var onCancel: () -> Void
    var onImport: () -> Void

    private static func masked(_ v: String) -> String {
        if v.count <= 8 { return String(repeating: "•", count: max(v.count, 1)) }
        return v.prefix(4) + "…" + v.suffix(4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.down").foregroundStyle(.tint)
                Text("Import from \(state.fileName)").font(.headline)
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !state.recognized.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RECOGNIZED").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach($state.recognized) { $row in recognizedRow($row) }
                        }
                    }
                    if !state.unrecognized.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("UNRECOGNIZED").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Text("Import these as generic tokens. Set the host(s) each one authenticates to so the fake is only swapped for the real value on those hosts. Leave blank to allow any host.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach($state.unrecognized) { $row in unrecognizedRow($row) }
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Import \(state.importCount) credential\(state.importCount == 1 ? "" : "s")") {
                    onImport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.importCount == 0)
            }
            .padding()
        }
        .frame(width: 580, height: 560)
    }

    @ViewBuilder
    private func recognizedRow(_ row: Binding<EnvRecognizedRow>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: row.include).labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text(EnvFileImport.displayName(for: row.wrappedValue.slot))
                        .font(.subheadline.weight(.medium))
                    Text("\(row.wrappedValue.name) = \(Self.masked(row.wrappedValue.value))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !row.wrappedValue.note.isEmpty {
                        Text(row.wrappedValue.note).font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            if row.wrappedValue.needsGitUsername {
                HStack(spacing: 6) {
                    Text("Git username").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: row.gitUsername, prompt: Text("you"))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func unrecognizedRow(_ row: Binding<EnvUnrecognizedRow>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: row.include).labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.wrappedValue.name).font(.subheadline.weight(.medium).monospaced())
                    Text(Self.masked(row.wrappedValue.value)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Host(s)").font(.caption).foregroundStyle(.secondary)
                TextField("", text: row.hostsText,
                          prompt: Text("api.example.com, example.dev  (blank = any host)"))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 4)
    }
}

struct ProfileEditorView: View {
    @State private var draft: Profile
    @State private var selectedCategory: EditorCategory = .general
    /// Each agent's auth before local mode pinned it to `.local` (Bug#6), so
    /// turning local mode back off restores it instead of clobbering it.
    @State private var preLocalAuthModes: [Profile.Tool: Profile.AuthMode] = [:]
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
    /// Bumped on `.bromureSubscriptionStoresChanged` to re-read per-tool
    /// registration status after a register/forget (runs in another window).
    @State private var subscriptionRefreshTick = 0
    /// Live model list for the Fusion judge picker (fetched per provider).
    @State private var fusionJudgeModels: [String] = []
    @State private var fusionJudgeModelsLoading = false

    /// Sheet state for the SSH-key import flow.
    @State private var importSheet: ImportSheetState?
    @State private var importError: String?
    @State private var confirmBrowserRedownload = false
    /// Keys of the disclosure groups the user has expanded in the
    /// Credentials pane. All sections start collapsed — the user
    /// opens whichever one they need.
    @State private var expandedCredsSections: Set<String> = []
    @State private var discoveredSSOProfiles: [DiscoveredSSOProfile] = []
    @State private var awsFolderGranted: Bool = false

    /// The Credentials pane's add/edit sheet — either the type picker or one
    /// type's editor. Nil when nothing is presented.
    @State private var credSheet: CredentialSheet?
    /// The env-file import review flow. Nil when not importing.
    @State private var envImport = EnvImportState.blank
    @State private var showEnvImport = false
    @State private var showEnvFileImporter = false

    enum CredentialSheet: Identifiable {
        case picker
        case editor(CredentialEditorType)
        var id: String {
            switch self {
            case .picker:          return "picker"
            case .editor(let t):   return "editor:\(t.rawValue)"
            }
        }
    }

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
    /// Returns the date this profile/preferences' Claude subscription was
    /// captured (nil = not registered). A closure (not a value) so it's
    /// re-read live after a register/forget. nil = no proxy engine → hide.
    let claudeAccountSavedAt: (() -> Date?)?
    /// Launch the "Register with Claude" flow (scope baked in by the caller).
    let onRegisterClaude: (() -> Void)?
    /// Forget the stored Claude credential for this scope.
    let onForgetClaude: (() -> Void)?
    /// ChatGPT / Codex counterparts of the three above.
    let codexAccountSavedAt: (() -> Date?)?
    let onRegisterCodex: (() -> Void)?
    let onForgetCodex: (() -> Void)?
    /// Fetch the available model ids for a provider (for the judge picker).
    /// `(provider, authMode, apiKey?, completion)` — host resolves the cred
    /// (API key here, or its subscription store) and calls back on the main
    /// actor with the model ids (empty on failure).
    let onFetchFusionModels: ((Profile.Tool, Profile.AuthMode, String?, @escaping ([String]) -> Void) -> Void)?
    /// Grok (xAI) counterparts.
    let grokAccountSavedAt: (() -> Date?)?
    let onRegisterGrok: (() -> Void)?
    let onForgetGrok: (() -> Void)?

    init(
        profile: Profile? = nil,
        isNew: Bool? = nil,
        terminalDefaults: TerminalAppDefaults,
        storageContext: ProfileStorageContext?,
        onSave: @escaping (Profile, _ generateSSH: Bool) -> Void,
        onCancel: @escaping () -> Void,
        onImportSSHKey: ((URL, _ passphrase: String?, _ label: String) throws -> ImportedSSHKey)? = nil,
        onRemoveSSHKey: ((ImportedSSHKey) -> Void)? = nil,
        claudeAccountSavedAt: (() -> Date?)? = nil,
        onRegisterClaude: (() -> Void)? = nil,
        onForgetClaude: (() -> Void)? = nil,
        codexAccountSavedAt: (() -> Date?)? = nil,
        onRegisterCodex: (() -> Void)? = nil,
        onForgetCodex: (() -> Void)? = nil,
        grokAccountSavedAt: (() -> Date?)? = nil,
        onRegisterGrok: (() -> Void)? = nil,
        onForgetGrok: (() -> Void)? = nil,
        onFetchFusionModels: ((Profile.Tool, Profile.AuthMode, String?, @escaping ([String]) -> Void) -> Void)? = nil
    ) {
        self.onImportSSHKey = onImportSSHKey
        self.onRemoveSSHKey = onRemoveSSHKey
        self.claudeAccountSavedAt = claudeAccountSavedAt
        self.onRegisterClaude = onRegisterClaude
        self.onForgetClaude = onForgetClaude
        self.codexAccountSavedAt = codexAccountSavedAt
        self.onRegisterCodex = onRegisterCodex
        self.onForgetCodex = onForgetCodex
        self.grokAccountSavedAt = grokAccountSavedAt
        self.onRegisterGrok = onRegisterGrok
        self.onForgetGrok = onForgetGrok
        self.onFetchFusionModels = onFetchFusionModels
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
                        Text(isNew ? "New workspace" : draft.name.isEmpty ? "Edit workspace" : draft.name)
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
        .sheet(item: $credSheet) { sheet in
            credentialSheetView(sheet)
        }
        .sheet(isPresented: $showEnvImport) {
            EnvImportReviewView(
                state: $envImport,
                onCancel: { showEnvImport = false },
                onImport: { applyEnvImport() })
        }
        .fileImporter(isPresented: $showEnvFileImporter,
                      allowedContentTypes: [.data, .text, .plainText, .item],
                      allowsMultipleSelection: false) { result in
            handleEnvFilePicked(result)
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
        .onReceive(NotificationCenter.default.publisher(
            for: .bromureACPresentCredentialSheet)) { note in
            presentDebugCredentialSheet(note.object as? String ?? "")
        }
        // Bug#6: enabling local mode + choosing a model also configures the
        // workspace's agents to use it (auth → "Local model"), so it's not a
        // two-step "Local Models, then Agents" dance. Watches the two controls
        // the Local Models pane drives.
        .onChange(of: draft.modelRouting) { _, _ in syncAgentsForLocalModels() }
        .onChange(of: draft.activeModelID) { _, _ in syncAgentsForLocalModels() }
    }

    /// Keep agent auth in step with the Local Models pane (Bug#6). In local mode
    /// with a model chosen, every agent is pinned to the on-host engine; leaving
    /// local mode restores each agent's prior cloud auth.
    private func syncAgentsForLocalModels() {
        if draft.modelRouting == .local, draft.activeModelID != nil {
            if draft.authMode != .local { preLocalAuthModes[draft.tool] = draft.authMode }
            for s in draft.additionalTools where s.authMode != .local {
                preLocalAuthModes[s.tool] = s.authMode
            }
            draft.setAllAgentsLocal()
        } else {
            draft.clearAgentsLocal(restoring: preLocalAuthModes)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedCategory {
        case .general:     generalSection
        case .models:      modelsSection
        case .localModels: localModelsSection
        case .fusion:      fusionSection
        case .folders:     foldersSection
        case .credentials: credentialsSection
        case .environment: environmentSection
        case .mcp:         mcpSection
        case .tracing:     tracingSection
        case .guardrails:       guardrailsSection
        case .supplyChain:      supplyChainSection
        case .promptInjection:  promptInjectionSection
        case .appearance:  appearanceSection
        case .browser:     browserSection
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
    private var localModelsSection: some View {
        LocalModelsSettingsView(routing: $draft.modelRouting,
                                activeModelID: $draft.activeModelID,
                                selectedModelIDs: draft.distinctLocalModelIDs)
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

            // (Keyboard layout / key-repeat rows removed with the
            // framebuffer: the native terminal path uses macOS input
            // directly, so there is no guest X keymap to configure.)

            closeActionPicker

            Toggle(NSLocalizedString("Start this VM at login", comment: ""),
                   isOn: $draft.bootAtStartup)

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
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enable each agent you want available in this workspace. The one marked **Primary** auto-launches in the first tab; other enabled agents are installed and authenticated but you run them on demand from a new tab.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Local models the user can pin a tool to — the installed ones
            // (download more in the Local Models section). Empty → the
            // "Local model" auth option is greyed out.
            let localModels = CatalogStore.shared.effective().models
                .filter { CatalogStore.shared.isInstalled(repo: $0.repo) }
            // The single model every "Local model" agent uses — the one
            // selected in the Local Models pane. Agents no longer pick
            // their own; this is shown read-only on each card.
            let activeLocalModelName = localModels
                .first(where: { $0.id == draft.activeModelID })?.displayName

            ForEach(Profile.Tool.allCases, id: \.self) { t in
                let sub = subscriptionInfo(for: t)
                ToolConfigCard(
                    tool: t,
                    isPrimary: draft.tool == t,
                    isEnabled: isToolEnabled(t),
                    spec: bindingForTool(t),
                    localModels: localModels,
                    activeLocalModelName: activeLocalModelName,
                    bedrockModelID: $draft.bedrockModelID,
                    onToggleEnabled: { setToolEnabled(t, enabled: $0) },
                    onMakePrimary: { setPrimary(t) },
                    profileDirHint: profileDirHint,
                    subscriptionRegisteredAt: sub.savedAt,
                    onRegisterSubscription: sub.onRegister,
                    onForgetSubscription: sub.onForget
                )
            }
        }
        // Re-read registration status when a register/forget completes (it runs
        // in a separate window), so the inline controls flip without reopening.
        .onReceive(NotificationCenter.default.publisher(
            for: .bromureSubscriptionStoresChanged)) { _ in
            subscriptionRefreshTick &+= 1
        }
    }

    /// Per-tool subscription registration status + actions, routed to the
    /// matching account closures supplied by the host. The savedAt closures are
    /// re-read on every render (bumped by `subscriptionRefreshTick`).
    private func subscriptionInfo(for tool: Profile.Tool)
        -> (savedAt: Date?, onRegister: (() -> Void)?, onForget: (() -> Void)?) {
        _ = subscriptionRefreshTick   // tie re-render to the refresh counter
        switch tool {
        case .claude: return (claudeAccountSavedAt?(), onRegisterClaude, onForgetClaude)
        case .codex:  return (codexAccountSavedAt?(), onRegisterCodex, onForgetCodex)
        case .grok:   return (grokAccountSavedAt?(), onRegisterGrok, onForgetGrok)
        }
    }

    // MARK: - Fusion pane

    @ViewBuilder
    private var fusionSection: some View {
        let usable = draft.fusionUsableProviders
        // Installed local models, available as a fuse leg / judge backend.
        let localModels = CatalogStore.shared.effective().models
            .filter { CatalogStore.shared.isInstalled(repo: $0.repo) }
        VStack(alignment: .leading, spacing: 12) {
            // Blurb.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                    Text("Fusion").font(.body.weight(.semibold))
                    Text("BETA").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                }
                Text("When engaged, Fusion answers each prompt with **multiple** models at once, has a judge model map where they agree, conflict, and each shine, then synthesizes a single best reply — delivered to Claude Code as if one model wrote it. Engage it per session from the ⚡ in the title bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Fusion runs on the **Claude Code** session (it intercepts Claude's API). It needs at least two configured agents below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // Models to fuse.
            Text("Models to fuse").font(.subheadline.weight(.medium))
            Text("Your Claude Code session is always one of the fused models; pick the others.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Profile.Tool.allCases, id: \.self) { t in
                let ok = draft.hasUsableCredential(for: t)
                Toggle(isOn: Binding(
                    get: { draft.fusionLegs.contains(t) && ok },
                    set: { on in
                        if on { draft.fusionLegs.insert(t) } else { draft.fusionLegs.remove(t) }
                    })) {
                    HStack(spacing: 6) {
                        Image(systemName: t.sfSymbol).foregroundStyle(ok ? .primary : .secondary)
                        Text(fusionBackendLabel(t))
                        if !ok {
                            Text("— no cloud credential (configure it in Agents)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!ok)
            }
            // Local model leg.
            fusionLocalLegRow(localModels: localModels)

            if !draft.fusionConfigurable {
                Text("Pick at least two models to fuse — your Claude Code session counts as one, so add one more (a cloud agent or a local model).")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            // Judge.
            Text("Judge").font(.subheadline.weight(.medium))
            Text("The model that weighs the drafts and writes the final answer.")
                .font(.caption).foregroundStyle(.secondary)
            fusionJudgePickers(usable: usable, localModels: localModels)
        }
        .onAppear { ensureFusionJudgeDefaults(usable: usable) }
    }

    /// Backend-flavoured label for a cloud leg.
    private func fusionBackendLabel(_ t: Profile.Tool) -> String {
        switch t {
        case .claude: return NSLocalizedString("Claude Code (Anthropic) — your session", comment: "Fusion cloud leg label for the primary Claude session")
        case .codex:  return NSLocalizedString("Codex (OpenAI)", comment: "Fusion cloud leg label")
        case .grok:   return NSLocalizedString("Grok (xAI)", comment: "Fusion cloud leg label")
        }
    }

    /// The "Local model" fuse-leg row: a checkbox + model picker. Greyed out
    /// when no local model is installed.
    @ViewBuilder
    private func fusionLocalLegRow(localModels: [CatalogModel]) -> some View {
        if localModels.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text("Local model").foregroundStyle(.secondary)
                Text("— download one in Local Models")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(0.6)
        } else {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { (draft.fusionLocalLeg?.isEmpty == false) },
                    set: { on in
                        draft.fusionLocalLeg = on ? (draft.fusionLocalLeg ?? localModels.first?.id) : nil
                    })) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu").foregroundStyle(.mint)
                        Text("Local model")
                    }
                }
                .toggleStyle(.checkbox)
                if draft.fusionLocalLeg?.isEmpty == false {
                    Picker("", selection: Binding(
                        get: { draft.fusionLocalLeg ?? localModels.first?.id ?? "" },
                        set: { draft.fusionLocalLeg = $0 })) {
                        ForEach(localModels) { Text($0.displayName).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: 220)
                }
            }
        }
    }

    /// Provider + model pickers for the judge. Backends are the usable cloud
    /// providers plus "Local" (when a local model is installed); cloud model
    /// lists are fetched live, local lists come from the installed catalog.
    @ViewBuilder
    private func fusionJudgePickers(usable: [Profile.Tool], localModels: [CatalogModel]) -> some View {
        HStack(spacing: 8) {
            Picker("Provider", selection: Binding(
                get: { draft.fusionJudgeLocal ? "local"
                        : (draft.fusionJudgeProvider?.rawValue ?? usable.first?.rawValue ?? "") },
                set: { tag in
                    if tag == "local" {
                        draft.fusionJudgeLocal = true
                        if draft.fusionJudgeModel == nil {
                            draft.fusionJudgeModel = draft.fusionLocalLeg ?? localModels.first?.id
                        }
                    } else {
                        draft.fusionJudgeLocal = false
                        draft.fusionJudgeProvider = Profile.Tool(rawValue: tag)
                        draft.fusionJudgeModel = nil
                        fusionJudgeModels = []
                        loadFusionJudgeModels()
                    }
                })) {
                ForEach(usable, id: \.self) { Text(fusionBackendLabel($0)).tag($0.rawValue) }
                if !localModels.isEmpty { Text("Local").tag("local") }
            }
            .frame(maxWidth: 200)

            if draft.fusionJudgeLocal {
                Picker("Model", selection: Binding(
                    get: { draft.fusionJudgeModel ?? localModels.first?.id ?? "" },
                    set: { draft.fusionJudgeModel = $0 })) {
                    ForEach(localModels) { Text($0.name).tag($0.id) }
                }
            } else {
                if fusionJudgeModelsLoading { ProgressView().controlSize(.small) }
                Picker("Model", selection: Binding(
                    get: { draft.fusionJudgeModel ?? "" },
                    set: { draft.fusionJudgeModel = $0.isEmpty ? nil : $0 })) {
                    Text("(default)").tag("")
                    ForEach(fusionJudgeModels, id: \.self) { Text($0).tag($0) }
                    if let m = draft.fusionJudgeModel, !fusionJudgeModels.contains(m) {
                        Text(m).tag(m)
                    }
                }
            }
        }
        .disabled(usable.isEmpty && localModels.isEmpty)
    }

    private func ensureFusionJudgeDefaults(usable: [Profile.Tool]) {
        if !draft.fusionJudgeLocal && draft.fusionJudgeProvider == nil {
            draft.fusionJudgeProvider = usable.first
        }
        if !draft.fusionJudgeLocal && fusionJudgeModels.isEmpty { loadFusionJudgeModels() }
    }

    /// Fetch the cloud model list for the current judge provider via the host.
    /// (A local judge picks from the installed catalog, no fetch needed.)
    private func loadFusionJudgeModels() {
        guard !draft.fusionJudgeLocal,
              let provider = draft.fusionJudgeProvider ?? draft.fusionUsableProviders.first,
              let fetch = onFetchFusionModels else { return }
        let spec = draft.allToolSpecs.first { $0.tool == provider }
        fusionJudgeModelsLoading = true
        fetch(provider, spec?.authMode ?? .token, spec?.apiKey) { models in
            fusionJudgeModels = models
            fusionJudgeModelsLoading = false
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
                        localModelID: self.draft.activeModelID,
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
                    self.draft.activeModelID = newValue.localModelID
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
            Text("Each folder is mounted into the VM under its real name (e.g. ~/Documents → ~ubuntu/Documents). Capped at 8 folders per workspace.")
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
        VStack(alignment: .leading, spacing: 12) {
            // Git identity (always visible — short, used by ~all profiles, and
            // carries no secret so it isn't a "credential" in the list below).
            VStack(alignment: .leading, spacing: 6) {
                Text("Git Identity").font(.headline)
                TextField("user.name", text: $draft.gitUserName, prompt: Text("Your Name"))
                    .textFieldStyle(.roundedBorder)
                TextField("user.email", text: $draft.gitUserEmail, prompt: Text("you@example.com"))
                    .textFieldStyle(.roundedBorder)
                Text("Written to ~/.gitconfig in the VM. Leave both blank to keep git's defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // Only what's configured — grouped by category. Real values stay on
            // the host; the "ask before use" control lives in the Guardrails pane.
            let groups = draft.configuredCredentialsByCategory()
            if groups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "key.slash").font(.title2).foregroundStyle(.secondary)
                    Text("No credentials yet").font(.subheadline.weight(.medium))
                    Text("Add an API key, token, or SSH key — or import an env file. Real values stay on your Mac; the VM only ever holds a fake.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.0.title.uppercased())
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(group.1) { ref in configuredCredentialRow(ref) }
                    }
                }
            }

            HStack {
                Button { credSheet = .picker } label: {
                    Label("Add credential", systemImage: "plus")
                }
                Button { beginEnvImport() } label: {
                    Label("Import env file…", systemImage: "square.and.arrow.down")
                }
                Spacer()
            }
            .buttonStyle(.bordered).controlSize(.small).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One configured-credential summary row: icon, title, host(s), and an
    /// edit/remove menu. Tapping opens the type's editor (or the Agents pane
    /// for agent API keys, which are configured there).
    @ViewBuilder
    private func configuredCredentialRow(_ ref: CredentialRef) -> some View {
        let hosts = draft.credentialHosts(ref)
        HStack(spacing: 8) {
            Image(systemName: ref.symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.credentialTitle(ref)).font(.subheadline)
                if !hosts.isEmpty {
                    Text(hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button(ref.editorType == .agents ? "Edit in Agents…" : "Edit…") {
                    openCredentialEditor(ref)
                }
                if ref.editorType != .agents {
                    Button("Remove", role: .destructive) { removeCredential(ref) }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 18).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { openCredentialEditor(ref) }
    }

    private func openCredentialEditor(_ ref: CredentialRef) {
        if ref.editorType == .agents {
            NotificationCenter.default.post(name: .bromureACSelectEditorCategory, object: "agents")
        } else {
            credSheet = .editor(ref.editorType)
        }
    }

    private func removeCredential(_ ref: CredentialRef) {
        switch ref {
        case .git(let u):          draft.gitHTTPSCredentials.removeAll { $0.id == u }
        case .manual(let u):       draft.manualTokens.removeAll { $0.id == u }
        case .docker(let u):       draft.dockerRegistries.removeAll { $0.id == u }
        case .database(let u):     draft.httpDatabases.removeAll { $0.id == u }
        case .kube(let u):         draft.kubeconfigs.removeAll { $0.id == u }
        case .importedSSHKey(let u): draft.importedSSHKeys.removeAll { $0.id == u }
        case .aws:                 draft.awsCredentials = AWSCredentials()
        case .digitalOcean:        draft.digitalOceanToken = ""
        case .linear:              draft.linearToken = ""
        case .managedSSHKey:       draft.sshPublicKey = nil; generateSSH = false
        case .primaryToolKey, .additionalTool: break   // configured in the Agents pane
        }
    }


    private func databaseCount(_ engine: HTTPDatabaseEndpoint.Engine) -> Int {
        draft.httpDatabases.filter { $0.engine == engine && $0.isUsable }.count
    }

    // MARK: - Add / edit credential sheet

    @ViewBuilder
    private func credentialSheetView(_ sheet: CredentialSheet) -> some View {
        switch sheet {
        case .picker:          addCredentialPicker
        case .editor(let type): credentialEditorSheet(type)
        }
    }

    private var addCredentialPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add credential").font(.headline)
                Spacer()
                Button("Cancel") { credSheet = nil }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    // Agent API keys are configured in the Agents pane, so the
                    // picker offers everything else.
                    ForEach(CredentialEditorType.allCases.filter { $0 != .agents }) { type in
                        Button { credSheet = .editor(type) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: type.symbol)
                                    .foregroundStyle(.tint).frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(type.title).font(.subheadline.weight(.medium))
                                    Text(type.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 9).padding(.horizontal, 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            Text("Agent API keys (Anthropic, OpenAI, xAI) are configured in the Agents pane.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(width: 460, height: 520)
    }

    @ViewBuilder
    private func credentialEditorSheet(_ type: CredentialEditorType) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: type.symbol).foregroundStyle(.tint)
                Text(type.title).font(.headline)
                Spacer()
                Button("Done") { credSheet = nil }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    credentialEditorBody(type)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 560)
    }

    @ViewBuilder
    private func credentialEditorBody(_ type: CredentialEditorType) -> some View {
        switch type {
        case .agents:
            EmptyView()
        case .git:
            VStack(alignment: .leading, spacing: 16) {
                gitProviderEditor("GitHub", "github.com", { isGitHub($0.host) })
                gitProviderEditor("GitLab", "gitlab.com", { isGitLab($0.host) })
                gitProviderEditor("Bitbucket", "bitbucket.org", { isBitbucket($0.host) })
            }
        case .ssh:          sshKeySubsection
        case .aws:          awsSubsection
        case .digitalOcean: digitalOceanSubsection
        case .linear:       linearSubsection
        case .kubernetes:   kubernetesSubsection
        case .docker:       dockerRegistriesSubsection
        case .database:
            VStack(alignment: .leading, spacing: 18) {
                databaseGroupEditor(.mongoDataAPI)
                databaseGroupEditor(.clickHouse)
                databaseGroupEditor(.elasticsearch)
            }
        case .manual:       otherTokensSubsection
        }
    }

    @ViewBuilder
    private func gitProviderEditor(_ name: String, _ host: String,
                                   _ filter: @escaping (GitHTTPSCredential) -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline.weight(.semibold))
            gitTokenSubsection(displayName: name, defaultHost: host, filter: filter)
        }
    }

    @ViewBuilder
    private func databaseGroupEditor(_ engine: HTTPDatabaseEndpoint.Engine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(engine.displayName).font(.subheadline.weight(.semibold))
            databaseSubsection(engine)
        }
    }

    // MARK: - Import env file

    private func beginEnvImport() { showEnvFileImporter = true }

    /// Debug/screenshot hook: present a Credentials-pane sheet without a click.
    /// "picker", "editor:<type>", or "envimport" (with synthesized demo rows).
    private func presentDebugCredentialSheet(_ spec: String) {
        switch spec {
        case "picker":
            credSheet = .picker
        case "envimport":
            // Drive the REAL parse→classify→populate path with a sample file.
            // Deferred off the notification tick so the state set lands in a
            // clean update cycle (the file-picker flow already does this).
            let sample = """
                export OPENAI_API_KEY=sk-proj-abcdef1234567890
                export GH_TOKEN='ghp_wxyz9876543210'
                AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
                GRRR_ANOTHER_KEY=s3cret-value-abcdef   # unknown service
                WIDGET_TOKEN="wgt_0123456789"
                """
            importEnvText(sample, fileName: "sample.env")
        default:
            if spec.hasPrefix("editor:"),
               let t = CredentialEditorType(rawValue: String(spec.dropFirst("editor:".count))) {
                credSheet = .editor(t)
            }
        }
    }

    private func handleEnvFilePicked(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "Couldn't read \(url.lastPathComponent) as text."
            return
        }
        importEnvText(text, fileName: url.lastPathComponent)
    }

    /// Parse env text, classify against known credentials, and present the
    /// review sheet. Shared by the file picker and the debug hook.
    private func importEnvText(_ text: String, fileName: String) {
        let cls = EnvFileImport.classify(EnvFileImport.parse(text))
        let recognized: [EnvRecognizedRow] = cls.recognized.map { pair in
            let already = isSlotConfigured(pair.slot)
            return EnvRecognizedRow(
                slot: pair.slot, name: pair.variable.name, value: pair.variable.value,
                include: !already,
                note: already ? "Already configured — check to overwrite." : "",
                gitUsername: draft.gitUserName)
        }
        let unrecognized = cls.unrecognized.map { EnvUnrecognizedRow(name: $0.name, value: $0.value) }
        if recognized.isEmpty && unrecognized.isEmpty {
            importError = "No importable variables found in \(fileName)."
            return
        }
        envImport = EnvImportState(fileName: fileName,
                                   recognized: recognized, unrecognized: unrecognized)
        showEnvImport = true
    }

    private func isSlotConfigured(_ slot: EnvFileImport.Slot) -> Bool {
        switch slot {
        case .toolKey(let t):
            if draft.tool == t { return !(draft.apiKey ?? "").isEmpty }
            return draft.additionalTools.contains { $0.tool == t && !($0.apiKey ?? "").isEmpty }
        case .gitToken(let host):
            return draft.gitHTTPSCredentials.contains { $0.host == host && $0.isUsable }
        case .digitalOcean: return !draft.digitalOceanToken.isEmpty
        case .linear:       return !draft.linearToken.isEmpty
        case .awsAccessKeyID, .awsSecretAccessKey, .awsSessionToken:
            return draft.awsCredentials.isUsable
        }
    }



    private func applyEnvImport() {
        let state = envImport
        var awsAccess = "", awsSecret = "", awsSession = "", awsAny = false
        for row in state.recognized where row.include {
            switch row.slot {
            case .toolKey(let t):
                if draft.tool == t {
                    draft.apiKey = row.value; draft.authMode = .token
                } else if let i = draft.additionalTools.firstIndex(where: { $0.tool == t }) {
                    draft.additionalTools[i].apiKey = row.value
                    draft.additionalTools[i].authMode = .token
                } else {
                    draft.additionalTools.append(.init(tool: t, authMode: .token, apiKey: row.value))
                }
            case .gitToken(let host):
                let user = row.gitUsername.trimmingCharacters(in: .whitespaces)
                if let i = draft.gitHTTPSCredentials.firstIndex(where: { $0.host == host }) {
                    draft.gitHTTPSCredentials[i].token = row.value
                    if !user.isEmpty { draft.gitHTTPSCredentials[i].username = user }
                } else {
                    draft.gitHTTPSCredentials.append(.init(host: host, username: user, token: row.value))
                }
            case .digitalOcean: draft.digitalOceanToken = row.value
            case .linear:       draft.linearToken = row.value
            case .awsAccessKeyID:    awsAccess = row.value; awsAny = true
            case .awsSecretAccessKey: awsSecret = row.value; awsAny = true
            case .awsSessionToken:   awsSession = row.value; awsAny = true
            }
        }
        if awsAny {
            draft.awsCredentials.authMode = .staticKeys
            if !awsAccess.isEmpty { draft.awsCredentials.accessKeyID = awsAccess }
            if !awsSecret.isEmpty { draft.awsCredentials.secretAccessKey = awsSecret }
            if !awsSession.isEmpty { draft.awsCredentials.sessionToken = awsSession }
        }
        for row in state.unrecognized where row.include {
            let hosts = row.hostsText
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            draft.manualTokens.append(.init(
                name: row.name, realValue: row.value, envVarName: row.name, hostFilters: hosts))
        }
        showEnvImport = false
    }

    // MARK: - Disclosure helper


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
                    Text("The public key will be displayed below after the workspace is saved.")
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
        }
    }

    // MARK: - Linear

    @ViewBuilder
    private var linearSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personal API key from linear.app → Settings → API. Injected into the VM as `LINEAR_API_KEY` env — the Linear SDK, MCP servers and CLI tools pick it up automatically. Swapped fake→real only on requests to linear.app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("lin_api_…", text: $draft.linearToken)
                    .textFieldStyle(.roundedBorder)
                Button {
                    if let url = URL(string: "https://linear.app/settings/api") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open Linear API settings in your browser")
            }
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
            Text(NSLocalizedString("Add credentials for any API that Bromure doesn't handle automatically (Anthropic, OpenAI, GitHub, GitLab, DigitalOcean and Kubernetes already are). The agent inside the VM only ever sees a fake token (`brm_…`); when a request leaves the VM, Bromure swaps the fake back to your real key on the way out — so your real secret never enters the sandbox.", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if draft.manualTokens.isEmpty {
                Text(NSLocalizedString("No extra credentials yet.", comment: ""))
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
                    Label(NSLocalizedString("Add credential", comment: ""), systemImage: "plus")
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
            Text("Point bromure at any existing SSH private key (RSA, ed25519, ecdsa) — encrypted ones included. The key is loaded into the per-workspace bromure ssh-agent at every session launch; passphrases are stored in the macOS Keychain.")
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
    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This workspace has an embedded Chromium browser its agents can drive (navigate, click, type, screenshot, read the network log and console) through the built-in `browser` MCP server. The browser runs in its own disposable VM.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $draft.browserPersistent) {
                    Label("Stay signed in to websites", systemImage: "person.badge.key.fill")
                        .font(.subheadline.weight(.semibold))
                }
                Text("Off (default) → the browser starts from a clean profile every time and forgets everything when the window closes — fully ephemeral. On → cookies, logins, and history are kept on an encrypted per-workspace disk (~/Library/Application Support/BromureAC/browser-profiles/), so the agent stays signed in to sites between sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("PERMISSIONS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Toggle(isOn: $draft.browserAllowUploads) {
                    Label("Allow file uploads", systemImage: "arrow.up.doc.fill")
                        .font(.subheadline.weight(.semibold))
                }
                Toggle(isOn: $draft.browserAllowDownloads) {
                    Label("Allow file downloads", systemImage: "arrow.down.doc.fill")
                        .font(.subheadline.weight(.semibold))
                }
                Toggle(isOn: $draft.browserWebcam) {
                    Label("Allow camera", systemImage: "video.fill")
                        .font(.subheadline.weight(.semibold))
                }
                Toggle(isOn: $draft.browserMicrophone) {
                    Label("Allow microphone", systemImage: "mic.fill")
                        .font(.subheadline.weight(.semibold))
                }
                Text("Uploads and downloads are on by default. The camera and microphone are off by default — turning one on exposes that host device to pages the browser (and the agent) opens, and keeps WebRTC enabled. Changes take effect the next time the browser opens; an open browser is restarted to apply them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            browserImageSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Browser base image (app-wide): status + a (Re)download button
    /// driving the shared BrowserImageInstaller — the same install the
    /// browser pane triggers on first open, so progress started in one
    /// place is visible in the other.
    @ViewBuilder
    private var browserImageSection: some View {
        let installer = BrowserImageInstaller.shared
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label("Browser image", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                switch installer.phase {
                case .running:
                    EmptyView()
                case .idle, .failed:
                    switch installer.installedSource {
                    case .sharedWithBromureWeb:
                        EmptyView()   // Bromure Web owns it — nothing to manage here
                    case .downloadedByAC:
                        Button("Re-download") { confirmBrowserRedownload = true }
                            .confirmationDialog(
                                "Re-download the browser image?",
                                isPresented: $confirmBrowserRedownload
                            ) {
                                Button("Re-download") {
                                    Task { await BrowserImageInstaller.shared.install() }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Downloads a fresh copy (a few GB) and replaces the current image. Open browser sessions keep running and pick up the new image next time they start.")
                            }
                    case nil:
                        Button("Download Now") {
                            Task { await BrowserImageInstaller.shared.install() }
                        }
                    }
                }
            }

            if installer.phase == .running {
                HStack(spacing: 8) {
                    Text(installer.progress.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(String(format: "%.0f%%", installer.progress.progress * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: installer.progress.progress, total: 1.0)
                    .progressViewStyle(.linear)
            } else {
                Text(browserImageCaption(installer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = installer.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func browserImageCaption(_ installer: BrowserImageInstaller) -> String {
        let size = installer.installedDiskSize.map { " (\($0))" } ?? ""
        switch installer.installedSource {
        case .sharedWithBromureWeb:
            return String(localized: "Installed by Bromure Web\(size) — shared with Agentic Coding, managed by the Bromure app.")
        case .downloadedByAC:
            return String(localized: "Installed\(size) — downloaded from dl.bromure.io into ~/Library/Application Support/BromureAC/browser.")
        case nil:
            return String(localized: "Not installed. Downloaded automatically the first time a workspace opens the browser, or download it now.")
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
                Text("Off → nothing recorded. Activity → metadata only (host, status, latency, swap report, leak warnings). AI request details → also captures bodies for known LLM hosts (Anthropic, OpenAI, Google, Cohere, Mistral, Perplexity, x.ai, Groq, Replicate, HuggingFace). Everything → bodies for every host. Bodies are AES-GCM encrypted with the same keychain key as workspace secrets. View at App → Trace Inspector (⇧⌘I).")
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
                    Text("Sessions running under this workspace normally stream metadata (tools, files, commands, token usage) to your workspace. Turn this on to keep this workspace's activity local — neither the title-bar indicator nor the admin's session list will see anything from this workspace. The local trace inspector is unaffected.")
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
                 : "You said \u{201C}Never\u{201D} on the swap prompt for this workspace. Reset to be asked again next time the VM sends a real token to \(outboundHost).")
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
                Text("Three layers stack to make this workspace's environment. The bottom is shared and immutable; the top two are yours and can be erased independently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let storageContext {
                    StorageStackView(
                        isNewProfile: isNew,
                        context: storageContext
                    )
                } else {
                    Text("Storage controls only apply to real workspaces. They appear in each workspace's editor when you create or edit one.")
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
            Text("Bromure AC exposes an HTTP API on the loopback interface that lets external tools manage workspaces and sessions. The bundled `bromure-ac mcp` subcommand wraps the same surface for AI agents (Claude Code, Claude Desktop). These settings apply app-wide.")
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
    private var guardrailsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Guardrails govern how this workspace's configured credentials are used. **Ask before use** pops a host-side confirmation the first time a credential is used in a session. A **write policy** strips or blocks destructive operations on the wire — enforced in the proxy, so a compromised agent can't bypass it. Only credentials you've configured appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                let refs = draft.configuredCredentials()
                if refs.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "shield.slash").font(.title2).foregroundStyle(.secondary)
                        Text("No credentials to guard").font(.subheadline.weight(.medium))
                        Text("Add credentials in the Credentials pane. Each one appears here with an “ask before use” toggle and, where it applies, a write policy.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                } else {
                    ForEach(refs) { ref in
                        guardrailCredentialRow(ref)
                        Divider()
                    }
                    Text("A write policy is per service, so two credentials for the same service (e.g. two GitHub tokens) share one policy.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// One configured credential in the Guardrails pane: ask-before-use, plus a
    /// write-policy picker where the credential's service has one.
    @ViewBuilder
    private func guardrailCredentialRow(_ ref: CredentialRef) -> some View {
        let hosts = draft.credentialHosts(ref)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ref.symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.credentialTitle(ref)).font(.subheadline.weight(.medium))
                    if !hosts.isEmpty {
                        Text(hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let mode = guardrailModeBinding(for: ref) {
                    Picker("", selection: mode) {
                        ForEach(GuardrailsPolicy.Mode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 176)
                }
            }
            requireApprovalToggle(isOn: approvalBinding(for: ref))
                .padding(.leading, 26)
        }
        .padding(.vertical, 3)
    }

    /// A `Binding<Bool>` into a configured credential's `requireApproval` flag,
    /// hiding the per-struct vs. profile-scalar asymmetry.
    private func approvalBinding(for ref: CredentialRef) -> Binding<Bool> {
        switch ref {
        case .primaryToolKey:        return $draft.apiKeyRequiresApproval
        case .additionalTool(let t): return approvalArray(\.additionalTools, id: t, flag: \.requireApproval)
        case .git(let u):            return approvalArray(\.gitHTTPSCredentials, id: u, flag: \.requireApproval)
        case .manual(let u):         return approvalArray(\.manualTokens, id: u, flag: \.requireApproval)
        case .docker(let u):         return approvalArray(\.dockerRegistries, id: u, flag: \.requireApproval)
        case .database(let u):       return approvalArray(\.httpDatabases, id: u, flag: \.requireApproval)
        case .kube(let u):           return approvalArray(\.kubeconfigs, id: u, flag: \.requireApproval)
        case .importedSSHKey(let u): return approvalArray(\.importedSSHKeys, id: u, flag: \.requireApproval)
        case .aws:                   return $draft.awsCredentials.requireApproval
        case .digitalOcean:          return $draft.digitalOceanTokenRequiresApproval
        case .linear:                return $draft.linearTokenRequiresApproval
        case .managedSSHKey:         return $draft.sshKeyRequiresApproval
        }
    }

    private func approvalArray<T: Identifiable>(
        _ path: WritableKeyPath<Profile, [T]>, id: T.ID,
        flag: WritableKeyPath<T, Bool>) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: path].first { $0.id == id }?[keyPath: flag] ?? false },
            set: { v in
                if let i = draft[keyPath: path].firstIndex(where: { $0.id == id }) {
                    draft[keyPath: path][i][keyPath: flag] = v
                }
            })
    }

    /// The write-policy `Mode` binding for a credential whose service has one
    /// (git forge, AWS, DigitalOcean, Docker, Kubernetes, databases); nil for
    /// plain API keys / SSH keys / manual tokens.
    private func guardrailModeBinding(for ref: CredentialRef) -> Binding<GuardrailsPolicy.Mode>? {
        switch ref {
        case .git(let u):
            guard let host = draft.gitHTTPSCredentials.first(where: { $0.id == u })?.host.lowercased()
            else { return nil }
            if host == "github.com" || host.hasSuffix(".github.com") { return $draft.guardrails.github }
            if host == "gitlab.com" || host.hasPrefix("gitlab.")     { return $draft.guardrails.gitlab }
            if host == "bitbucket.org"                               { return $draft.guardrails.bitbucket }
            return nil
        case .aws:          return $draft.guardrails.aws
        case .digitalOcean: return $draft.guardrails.digitalOcean
        case .docker:       return $draft.guardrails.docker
        case .kube:         return $draft.guardrails.kubernetes
        case .database(let u):
            return Binding(
                get: { draft.httpDatabases.first { $0.id == u }?.guardrail ?? .off },
                set: { v in
                    if let i = draft.httpDatabases.firstIndex(where: { $0.id == u }) {
                        draft.httpDatabases[i].guardrail = v
                    }
                })
        default: return nil
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
                        // Checking the box asks the user to confirm the
                        // download (and its disk cost), then downloads with a
                        // progress panel — right away, so the model is ready by
                        // the time a VM runs. Declining/failing reverts the box,
                        // since the detector is a no-op without its model.
                        .onChange(of: draft.promptInjection.detectSourceInjection) { _, isOn in
                            guard isOn else { return }
                            PromptInjectionModelDownloader.start(.promptGuard) { ok in
                                if !ok { draft.promptInjection.detectSourceInjection = false }
                            }
                        }
                    Text(NSLocalizedString("Scores the file contents, web pages, and tool output the agent reads (Prompt Guard). Catches “ignore previous instructions / exfiltrate secrets” hidden in a rogue repository. Downloads ~272 MB on first enable.", comment: ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle(NSLocalizedString("Detect rogue instructions in CLAUDE.md files and similar", comment: ""),
                           isOn: $draft.promptInjection.detectRulesInjection)
                        .onChange(of: draft.promptInjection.detectRulesInjection) { _, isOn in
                            guard isOn else { return }
                            PromptInjectionModelDownloader.start(.claudeMdGuard) { ok in
                                if !ok { draft.promptInjection.detectRulesInjection = false }
                            }
                        }
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

            GroupBox(label: Label(NSLocalizedString("Package filtering", comment: ""),
                                  systemImage: "checkmark.shield")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $draft.supplyChain.packageFilter) {
                        ForEach(SupplyChainPolicy.PackageFilter.allCases, id: \.self) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(NSLocalizedString("One provider at a time: socket.dev vets each package against its reputation database before Bromure lets the fetch through; Delpi replaces the npm registry outright — every npm fetch is re-routed to its filtering registry.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if draft.supplyChain.packageFilter == .socketDev {
                        Divider().padding(.vertical, 4)
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

                    if draft.supplyChain.packageFilter == .delpi {
                        Divider().padding(.vertical, 4)
                        HStack {
                            Text(NSLocalizedString("API key:", comment: ""))
                            SecureField("", text: $draft.supplyChain.delpiAPIKey)
                                .textFieldStyle(.roundedBorder)
                            Link(destination: URL(string: "https://www.landh.tech/")!) {
                                HStack(spacing: 2) {
                                    Text(NSLocalizedString("Get an API key", comment: ""))
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .font(.caption)
                            }
                        }
                        Text(NSLocalizedString("Every npm registry request from the VM is re-routed to Delpi's secure registry (depi-npm-proxy.landh.tech), authenticated host-side with this key — Bromure never exports it into the VM. If Delpi rejects the key, the install fails with a clear error and Bromure alerts you.", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if draft.supplyChain.delpiAPIKey.isEmpty {
                            Label(NSLocalizedString("Enter an API key — Delpi stays off without one.", comment: ""),
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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
                Toggle("Blinking", isOn: $draft.cursorBlink)
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

    /// Fixed-width font families on this Mac, sorted. A terminal only makes
    /// sense in a monospace font, so we keep just the fixed-pitch families.
    /// We also exclude families whose name starts with `.` — those are
    /// macOS-internal identifiers (`.AppleSystemUIFontMonospaced`, …) that
    /// Linux fontconfig can't resolve, so picking one would silently fall
    /// back in the terminal.
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

// MARK: - Local Models (vLLM.md)

/// The "Local Models" settings pane: an "Enable local models" master
/// toggle, a Local/Hybrid mode picker, and the curated MLX catalog with
/// RAM-fit gating — models that won't fit this Mac are greyed out and
/// unselectable (§5.3). The inference engine is bundled (in-process MLX),
/// so there's nothing to install. Downloads are immediate side effects
/// (global, not per-profile); the routing mode + active-model selection
/// persist on Save.
struct LocalModelsSettingsView: View {
    @Binding var routing: Profile.Routing
    @Binding var activeModelID: String?
    /// Every distinct local model this profile would load at once — for the
    /// combined-memory warning (the engine can serve several in parallel).
    var selectedModelIDs: [String] = []

    private let hostGB = HostMemory.unifiedMemoryGB()
    private let catalog = CatalogStore.shared.effective()

    /// Combined memory of all distinct local models that would load at once.
    private var combinedMemGB: Int {
        selectedModelIDs.reduce(0) { $0 + (CatalogStore.shared.resolve($1)?.minUnifiedMemGB ?? 0) }
    }

    // Download progress lives in the shared manager so it survives leaving
    // and re-entering this pane (and so the VM-launch path can see it).
    private let downloads = ModelDownloadManager.shared

    /// Bumped when a model is removed to force the rows to re-read
    /// `CatalogStore.isInstalled` — that lookup hits disk and isn't observable,
    /// so without this the row keeps showing "Installed" after a Remove and the
    /// button appears to do nothing.
    @State private var refreshTick = 0

    /// "Enable local models" ↔ routing ≠ cloud. Turning it on defaults to Local.
    private var enableLocal: Binding<Bool> {
        Binding(
            get: { routing != .cloud },
            set: { on in
                if on {
                    if routing == .cloud { routing = .local }
                } else {
                    routing = .cloud
                }
            })
    }

    private var modeSelection: Binding<Profile.Routing> {
        Binding(get: { routing == .cloud ? .local : routing },
                set: { routing = $0 })
    }

    var body: some View {
        // Establish a dependency on refreshTick so a Remove re-runs the rows'
        // `installed` lookup (CatalogStore.isInstalled is a non-observable disk read).
        let _ = refreshTick
        return Form {
            Section {
                Toggle(isOn: enableLocal) {
                    Text("Enable local models")
                    Text("Run a coding model on this Mac instead of the cloud.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if routing != .cloud {
                Section {
                    Picker("Mode", selection: modeSelection) {
                        Text("Local — always on-device").tag(Profile.Routing.local)
                        Text("Hybrid — cloud, fall back to local").tag(Profile.Routing.hybrid)
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("**Local** keeps every request on this Mac — nothing leaves the machine. Replies are private but slower, and bounded by the model you can fit in memory.")
                        Text("**Hybrid** sends requests to the cloud as usual, falling back to the on-device model only when the cloud is unreachable — cloud speed and quality, with a local safety net.")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                if combinedMemGB > 0, combinedMemGB > Int(Double(hostGB) * 0.85) {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                // Ternary Text(cond ? a : b) with interpolation resolves to
                                // the non-localizing Text(String) overload, so format explicitly.
                                Text(combinedMemGB > hostGB
                                     ? String(format: NSLocalizedString("Selected local models need ~%d GB together — more than this Mac's %d GB.", comment: "combined-memory warning, over budget"), combinedMemGB, hostGB)
                                     : String(format: NSLocalizedString("Selected local models need ~%d GB together, close to this Mac's %d GB.", comment: "combined-memory warning, near budget"), combinedMemGB, hostGB))
                                Text("They run in parallel (one engine, several models), so their memory adds up. Drop one, or pick smaller models.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(combinedMemGB > hostGB ? .red : .orange)
                        }
                    }
                }

                Section {
                    ForEach(catalog.sortedForDisplay) { model in
                        modelRow(model)
                    }
                } header: {
                    Text("Models  ·  \(hostGB) GB unified memory")
                } footer: {
                    Text("Greyed-out models need more memory than this Mac has.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Model row

    @ViewBuilder private func modelRow(_ model: CatalogModel) -> some View {
        let fit = RAMFitGate.fit(model: model, hostUnifiedMemGB: hostGB)
        let wontFit = (fit == .wontFit)
        let isActive = (activeModelID == model.id)
        let state = downloads.state(repo: model.repo)
        // "Installed" only when fully downloaded — never while a pull is
        // still running (CatalogStore.isInstalled checks completeness).
        let installed = (state == nil) && CatalogStore.shared.isInstalled(repo: model.repo)

        HStack(spacing: 10) {
            // Active-model radio (only meaningful when it fits).
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .onTapGesture { if !wontFit { activeModelID = model.id } }

            tierBadge(ModelCatalog.tier(forMinMemGB: model.minUnifiedMemGB))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.callout)
                HStack(spacing: 6) {
                    Text(fit.badge)
                        .foregroundStyle(fit == .fits ? .green : (fit == .tight ? .orange : .secondary))
                    Text("· \(Int(model.downloadGB)) GB")
                    if model.toolCalling == .verified {
                        Label("tools", systemImage: "checkmark.seal.fill").labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            modelAction(model: model, state: state, installed: installed, wontFit: wontFit)
        }
        .opacity(wontFit ? 0.45 : 1)
        .disabled(wontFit)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func modelAction(model: CatalogModel,
                                          state: ModelDownloadManager.State?,
                                          installed: Bool, wontFit: Bool) -> some View {
        switch state {
        case .downloading(let frac, let label):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: frac).progressViewStyle(.linear).frame(width: 110)
                    Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button {
                    downloads.cancel(repo: model.repo)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop download")
            }
        case .interrupted(let onDisk, let total):
            // A pull the app didn't finish (crash/kill). Offer to resume it
            // (HubDownloader skips files already on disk) or discard the
            // partial. (Bug#2.)
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Interrupted").font(.caption2).foregroundStyle(.orange)
                    Text(total > 0 ? ProgressBar.bytesLabel(onDisk, total)
                                   : ByteCountFormatter.string(fromByteCount: onDisk, countStyle: .file))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Resume") { startDownload(model) }.controlSize(.small)
                Button {
                    downloads.discard(repo: model.repo)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Discard the partial download")
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Button("Retry") { startDownload(model) }.controlSize(.small)
            }
            .help(msg)
        case nil:
            if installed {
                Menu {
                    Button("Remove", role: .destructive) { removeModel(model) }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .menuStyle(.borderlessButton).fixedSize()
            } else {
                Button("Download") { startDownload(model) }
                    .controlSize(.small)
                    .disabled(wontFit)
            }
        }
    }

    @ViewBuilder private func tierBadge(_ tier: String) -> some View {
        Text(tier)
            .font(.caption2.bold().monospaced())
            .frame(width: 26, height: 18)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Actions (immediate side effects)

    private func startDownload(_ model: CatalogModel) {
        downloads.start(repo: model.repo,
                        totalBytes: Int64(model.downloadGB * 1_000_000_000))
        if activeModelID == nil { activeModelID = model.id }
    }

    private func removeModel(_ model: CatalogModel) {
        do {
            try CatalogStore.shared.removeInstalled(repo: model.repo)
        } catch {
            FileHandle.standardError.write(Data(
                "[models] remove \(model.repo) failed: \(error)\n".utf8))
        }
        if activeModelID == model.id { activeModelID = nil }
        refreshTick += 1   // force the row to re-read isInstalled (see refreshTick)
    }
}

// MARK: - Credential field label helpers

/// Bold caption that sits above a credential input, naming the field.
/// Shared by every credential row so the labelling stays consistent.
/// The passed string is localized here, so call sites pass plain English.
private func credFieldLabel(_ text: String) -> some View {
    Text(NSLocalizedString(text, comment: "credential field label"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
}

/// Small tertiary line under a credential input explaining what to type.
/// The passed string is localized here, so call sites pass plain English.
private func credFieldHint(_ text: String) -> some View {
    Text(NSLocalizedString(text, comment: "credential field hint"))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Manual token row (Advanced)

/// One editable row for the Advanced→Manual tokens list. Pairs a name
/// + env var + real value (masked) + optional host filter.
private struct ManualTokenRow: View {
    @Binding var token: ManualToken
    var onRemove: () -> Void

    @State private var revealReal: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Name — the display label for this entry, plus the remove button.
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    credFieldLabel("Name")
                    Spacer()
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("Remove this credential", comment: ""))
                }
                TextField("", text: $token.name,
                          prompt: Text(NSLocalizedString("e.g. Stripe (sandbox)", comment: "")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                credFieldHint("A name for you to recognise this entry. Shown here only — never sent anywhere.")
            }

            // Real secret — the actual key, masked by default.
            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("Real secret")
                HStack(spacing: 6) {
                    ZStack {
                        if revealReal {
                            TextField("", text: $token.realValue, prompt: Text("sk_live_…"))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("", text: $token.realValue, prompt: Text("sk_live_…"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .labelsHidden()
                    Button {
                        revealReal.toggle()
                    } label: {
                        Image(systemName: revealReal ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealReal
                          ? NSLocalizedString("Hide value", comment: "")
                          : NSLocalizedString("Show value", comment: ""))
                }
                credFieldHint("Your real API key. Stays on macOS — the VM only ever sees a fake stand-in.")
            }

            // Env var — the variable the fake is exported under inside the VM.
            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("Environment variable")
                TextField("", text: $token.envVarName, prompt: Text("STRIPE_API_KEY"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                credFieldHint("The agent reads the fake token from this variable inside the VM. Leave blank to inject nothing and copy it in yourself.")
            }

            // Hosts — restrict where the fake is swapped back to the real key.
            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("API host(s) (optional)")
                TextField("", text: Binding(
                    get: { token.hostFilters.joined(separator: ", ") },
                    set: { token.hostFilters = $0
                        .split(whereSeparator: { $0 == "," || $0 == " " })
                        .map { String($0) }
                        .filter { !$0.isEmpty } }),
                    prompt: Text("api.stripe.com, api.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                credFieldHint("Hostnames only, comma-separated, no https:// or path. The real key is substituted only on requests to these hosts and their subdomains. Leave blank to allow any host.")
            }

        }
        .padding(10)
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
                title: NSLocalizedString("Your home folder", comment: ""),
                subtitle: context.profileHomeImageURL != nil
                    ? NSLocalizedString("Project clones, dotfiles, .ssh keys, npm-global, .cargo, shell history — on a private ext4 disk image that shrinks as files are deleted.", comment: "")
                    : NSLocalizedString("Project clones, dotfiles, .ssh keys, npm-global, .cargo, shell history, anything in /home/ubuntu.", comment: ""),
                metadata: homeMetadata,
                size: homeBytes,
                action: isNewProfile
                    ? nil
                    : .init(
                        label: NSLocalizedString("Erase home…", comment: ""),
                        role: .destructive,
                        enabled: !context.isRunning
                            && (context.profileHomeURL != nil
                                || context.profileHomeImageURL != nil),
                        disabledHelp: context.isRunning
                            ? NSLocalizedString("Close the session window first.", comment: "")
                            : NSLocalizedString("Created on first launch.", comment: ""),
                        handler: context.onResetHome
                      ),
                // One slot, model-exclusive: legacy homes offer the upgrade,
                // ext4 homes offer the checkpoint rollback.
                secondaryAction: {
                    if isNewProfile { return nil }
                    if context.onUpgradeHome != nil {
                        return .init(
                            label: NSLocalizedString("Upgrade storage…", comment: ""),
                            role: nil,
                            enabled: !context.isRunning,
                            disabledHelp: NSLocalizedString("Close the session window first.", comment: ""),
                            handler: { context.onUpgradeHome?() })
                    }
                    if context.onRestoreHome != nil {
                        return .init(
                            label: NSLocalizedString("Restore home…", comment: ""),
                            role: nil,
                            enabled: !context.isRunning,
                            disabledHelp: NSLocalizedString("Close the session window first.", comment: ""),
                            handler: { context.onRestoreHome?() })
                    }
                    return nil
                }()
            )

            Divider()

            // Middle — per-profile system disk (CoW clone).
            StorageLayerRow(
                accent: .blue,
                symbol: "internaldrive.fill",
                title: NSLocalizedString("Workspace system disk", comment: ""),
                subtitle: NSLocalizedString("A read-write copy of the base OS, just for this workspace. Holds anything you `sudo apt install`, edits to /etc and /var, system-level config.", comment: "Storage layer subtitle — per-workspace system disk"),
                metadata: diskMetadata,
                size: diskBytes,
                action: isNewProfile
                    ? nil
                    : .init(
                        label: NSLocalizedString("Reset to base…", comment: ""),
                        role: .destructive,
                        enabled: !context.isRunning && context.profileDiskURL != nil,
                        disabledHelp: context.isRunning
                            ? NSLocalizedString("Close the session window first.", comment: "")
                            : NSLocalizedString("Created on first launch.", comment: ""),
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
                title: NSLocalizedString("Base OS image", comment: ""),
                subtitle: NSLocalizedString("Ubuntu Noble + Node, Claude Code, Codex, gh, glab, fonts. Shared by every workspace, immutable at runtime.", comment: "Storage layer subtitle — shared base OS image"),
                metadata: baseMetadata,
                size: baseBytes,
                action: nil,
                bottomNote: NSLocalizedString("Rebuild via the app menu (∼5–10 min).", comment: "Base OS image rebuild note"),
                noteHelp: NSLocalizedString("Affects every workspace, so it's parked outside this editor.", comment: "Base OS image rebuild help")
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
        if isNewProfile { return NSLocalizedString("Created on first launch.", comment: "") }
        guard context.profileHomeURL != nil || context.profileHomeImageURL != nil else {
            return NSLocalizedString("Not yet created.", comment: "Storage layer status — home not created yet")
        }
        if let mtime = homeMTime {
            return String(format: NSLocalizedString("Active %@.", comment: "Storage layer status — recently active, arg is a relative age"), relativeAge(of: mtime))
        }
        return NSLocalizedString("Quiet — no recent activity.", comment: "Storage layer status — home idle")
    }

    private var diskMetadata: String {
        if isNewProfile { return NSLocalizedString("Created on first launch.", comment: "") }
        guard context.profileDiskURL != nil else { return NSLocalizedString("Not yet cloned.", comment: "Storage layer status — disk not cloned yet") }
        if let v = context.baseImageVersion {
            return String(format: NSLocalizedString("Cloned from base v%@.", comment: "Storage layer status — disk cloned from base version, arg is version stamp"), v)
        }
        return NSLocalizedString("Cloned from base.", comment: "Storage layer status — disk cloned from base")
    }

    private var baseMetadata: String {
        var parts: [String] = []
        if let v = context.baseImageVersion { parts.append("v\(v)") }
        if let d = context.baseImageBuildDate {
            parts.append(String(format: NSLocalizedString("built %@", comment: "Storage layer status — base image build date, arg is a date"), Self.dateFormatter.string(from: d)))
        }
        return parts.isEmpty ? NSLocalizedString("Built once per app version.", comment: "Storage layer status — base image build cadence") : parts.joined(separator: " · ")
    }

    @MainActor
    private func refreshSizes() async {
        // Off-main computation, then push back. Keeps the editor
        // interactive even if the home walk takes a beat.
        let baseURL = context.baseImageURL
        let diskURL = context.profileDiskURL
        let homeURL = context.profileHomeURL
        let homeImageURL = context.profileHomeImageURL
        let (b, d, h, m) = await Task.detached(priority: .utility) {
            let base = (try? baseURL.resourceValues(forKeys: [.fileAllocatedSizeKey]))
                .flatMap { $0.fileAllocatedSize }
                .map(Int64.init) ?? 0
            let disk = diskURL.map { Self.allocatedBytes(at: $0) } ?? 0
            // ext4 home: the image's allocated (sparse-aware) size — O(1),
            // and it's the real cost on the Mac. virtiofs home: the walk.
            let home = homeImageURL.map { Self.allocatedBytes(at: $0) }
                ?? homeURL.map { Self.directoryBytes(at: $0) } ?? 0
            let mURL = homeImageURL ?? homeURL
            let mtime = mURL.flatMap { url -> Date? in
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
    /// Optional non-destructive action rendered left of `action` (e.g. the
    /// home row's "Upgrade storage…").
    var secondaryAction: Action? = nil
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
                    if let secondaryAction {
                        Button(role: secondaryAction.role) {
                            secondaryAction.handler()
                        } label: {
                            Text(secondaryAction.label)
                        }
                        .controlSize(.small)
                        .disabled(!secondaryAction.enabled)
                        .help(secondaryAction.enabled ? "" : (secondaryAction.disabledHelp ?? ""))
                    }
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
    /// Installed local models. Empty → the "Local model" option is greyed
    /// out. Used only to gate the radio; agents don't pick from this list.
    let localModels: [CatalogModel]
    /// Display name of the profile's active local model (chosen in the
    /// Local Models pane). Every agent in `.local` mode runs on it.
    let activeLocalModelName: String?
    @Binding var bedrockModelID: String
    let onToggleEnabled: (Bool) -> Void
    let onMakePrimary: () -> Void
    let profileDirHint: String
    /// Date this tool's subscription was registered host-side (nil = not yet).
    /// Drives the inline Register / Re-register+Forget controls on the
    /// Subscription radio row. `onRegisterSubscription == nil` hides them.
    let subscriptionRegisteredAt: Date?
    let onRegisterSubscription: (() -> Void)?
    let onForgetSubscription: (() -> Void)?

    /// The base-URL env var this tool reads, for the explanatory caption.
    private var localBaseURLEnvName: String {
        switch tool {
        case .claude: return "ANTHROPIC_BASE_URL"
        case .codex:  return "OPENAI_BASE_URL"
        case .grok:   return "XAI_BASE_URL"
        }
    }

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
                // Custom radio group so the Subscription row can carry an inline
                // Register / Re-register+Forget control.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Profile.AuthMode.allCases, id: \.self) { m in
                        if m == .bedrock && tool != .claude {
                            EmptyView()
                        } else {
                            let localDisabled = (m == .local && localModels.isEmpty)
                            HStack(spacing: 8) {
                                Button { spec.authMode = m } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: spec.authMode == m
                                              ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(spec.authMode == m
                                                             ? Color.accentColor : Color.secondary)
                                        Text(m.displayName).foregroundStyle(.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(localDisabled)
                                .opacity(localDisabled ? 0.45 : 1)

                                if localDisabled {
                                    Text("— download a model in Local Models")
                                        .font(.caption).foregroundStyle(.secondary)
                                }

                                if m == .subscription, let onRegister = onRegisterSubscription {
                                    if subscriptionRegisteredAt != nil {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green).controlSize(.small)
                                        Button(NSLocalizedString("Re-register…", comment: "")) { onRegister() }
                                            .buttonStyle(.borderless).controlSize(.small)
                                        if let onForget = onForgetSubscription {
                                            Button(NSLocalizedString("Forget", comment: ""),
                                                   role: .destructive) { onForget() }
                                                .buttonStyle(.borderless).controlSize(.small)
                                        }
                                    } else {
                                        Button(NSLocalizedString("Register…", comment: "")) { onRegister() }
                                            .buttonStyle(.borderless).controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                }

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
                case .subscription:
                    EmptyView()
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
                case .local:
                    if localModels.isEmpty {
                        Text("No local models installed yet. Enable and download one in the Local Models section.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Runs on this Mac via the local engine — \(tool.displayName) is pointed at it through \(localBaseURLEnvName). The model is the one selected in **Local Models**\(activeLocalModelName.map { ": \($0)" } ?? ".")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("Host")
                HStack(spacing: 6) {
                    Image(systemName: hostSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    TextField("", text: $credential.host, prompt: Text("github.com"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Button {
                        onOpenTokenPage(credential.host)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("Open this host's token-creation page in your browser", comment: ""))
                    .disabled(!hasKnownTokenPage)

                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("Remove this credential", comment: ""))
                }
                credFieldHint("The git host these credentials sign in to. Works with self-hosted GitLab / Gitea too.")
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    credFieldLabel("Username")
                    TextField("", text: $credential.username, prompt: Text("octocat"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 3) {
                    credFieldLabel("Personal access token")
                    HStack(spacing: 6) {
                        ZStack {
                            if revealToken {
                                TextField("", text: $credential.token, prompt: Text("ghp_…"))
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("", text: $credential.token, prompt: Text("ghp_…"))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .labelsHidden()
                        Button {
                            revealToken.toggle()
                        } label: {
                            Image(systemName: revealToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealToken
                              ? NSLocalizedString("Hide token", comment: "")
                              : NSLocalizedString("Show token", comment: ""))
                    }
                }
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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    credFieldLabel("Name (optional)")
                    Spacer()
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("Remove this endpoint", comment: ""))
                }
                TextField("", text: $endpoint.name,
                          prompt: Text(NSLocalizedString("e.g. Production cluster", comment: "")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                credFieldHint("A name for you to recognise this endpoint. Shown here only.")
            }

            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("Host")
                TextField("", text: $endpoint.host, prompt: Text(hostPrompt))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .labelsHidden()
                credFieldHint("The hostname the agent connects to — no https:// or path. Both the credential swap and Guardrails scope to this host, so self-hosted instances work.")
            }

            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("Authentication")
                Picker("", selection: $endpoint.auth) {
                    ForEach(HTTPDatabaseEndpoint.AuthKind.allCases, id: \.self) { a in
                        Text(a.displayName).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if endpoint.auth == .basic {
                VStack(alignment: .leading, spacing: 3) {
                    credFieldLabel("Username")
                    TextField("", text: $endpoint.username, prompt: Text("default"))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("Secret")
                HStack(spacing: 6) {
                    ZStack {
                        if revealSecret {
                            TextField("", text: $endpoint.secret, prompt: Text(secretPrompt))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("", text: $endpoint.secret, prompt: Text("•••• ••••"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .labelsHidden()
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
                credFieldHint("Your real secret. Stays on macOS — the VM only ever sees a fake stand-in.")
            }

            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("Environment variable(s)")
                TextField("", text: envVarsText, prompt: Text(envVarPrompt))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .labelsHidden()
                credFieldHint("Variable(s) the fake secret is exported under in the VM — comma-separated for more than one. Reference these from your code / connection string.")
            }

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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                credFieldLabel("Registry host")
                HStack(spacing: 6) {
                    Image(systemName: hostSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    TextField("", text: $cred.host, prompt: Text("ghcr.io"))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .labelsHidden()
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("Remove this registry", comment: ""))
                }
                credFieldHint("The registry you docker pull / push to, e.g. ghcr.io or a private registry host.")
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    credFieldLabel("Username")
                    TextField("", text: $cred.username, prompt: Text("octocat"))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 3) {
                    credFieldLabel("Password or token")
                    HStack(spacing: 6) {
                        ZStack {
                            if revealPassword {
                                TextField("", text: $cred.password,
                                          prompt: Text("ghp_…"))
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("", text: $cred.password,
                                            prompt: Text("•••• ••••"))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .labelsHidden()
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
                }
            }
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
            Text("Paste this into github.com/settings/keys (or your hosting provider's equivalent). The matching private key lives only inside this workspace.")
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
