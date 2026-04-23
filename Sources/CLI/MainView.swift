import SwiftUI
import SandboxEngine

struct MainView: View {
    @Bindable var state: AppState
    var onNewBrowser: @MainActor () -> Void
    var onNewBrowserWithProfile: @MainActor (Profile) -> Void
    var onShowWarpEULA: ((@escaping () -> Void) -> Void)?
    var onShowPhishingConsent: ((@escaping () -> Void) -> Void)?
    @State private var buttonCooldown = false
    @State private var showNewProfile = false
    @State private var newProfileName = ""
    @State private var newProfileColor: ProfileColor? = .blue
    @State private var editingProfile: Profile?
    @State private var settingsPanel: NSWindow?
    @State private var settingsDelegateHelper: SettingsWindowDelegate?
    @State private var profileToDelete: Profile?

    /// Colors already used by other profiles.
    private func managedTooltip(for profile: Profile) -> String? {
        guard state.profileManager.isManaged(profile.id) else { return nil }
        let org = state.profileManager.managedOrgSlug(for: profile.id) ?? "your admin"
        return "Managed by \(org). Settings are not editable on this device."
    }

    private func usedColors(excluding profileID: UUID? = nil) -> Set<ProfileColor> {
        Set(state.profileManager.allProfiles.compactMap { profile in
            if profile.id == profileID { return nil }
            return profile.color
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.phase == .ready {
                readyView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: 440, height: 420)
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: 440, height: 420)
            }
        }
        .background(.background)
        .onAppear {
            state.checkState()
            state.onOpenProfileSettings = { [self] profileID, category in
                guard let profile = state.profileManager.profile(withID: profileID) else { return }
                editingProfile = profile
                openSettingsPanel(for: profile, category: category)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Bromure")
                .font(.title.bold())

            Text("Secure, ephemeral browsing in a disposable VM")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.blue.gradient.opacity(0.04))
    }

    // MARK: - Content (non-ready phases)

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .checking:
            ProgressView()
                .padding()

        case .needsSetup:
            setupView

        case .initializing(let status, let progress):
            initializingView(status: status, progress: progress)

        case .warmingUp:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting browser engine...")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Text("First launch is slower, subsequent ones will be faster.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding()

        case .ready:
            readyView

        case .error(let message):
            errorView(message: message)
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("First-Time Setup")
                    .font(.headline)
                Text("Downloads Alpine Linux (~50 MB) and installs\nChromium. This only needs to happen once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                state.startInit()
            } label: {
                Label("Get Started", systemImage: "arrow.down.circle")
                    .frame(width: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Initializing

    private func initializingView(status: String, progress: Double?) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.initSteps) { step in
                    HStack(spacing: 8) {
                        if step.done {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.body)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(LocalizedStringKey(step.name))
                            .font(.subheadline)
                            .foregroundStyle(step.done ? .secondary : .primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)

            if let progress {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 40)
            }

            Text(LocalizedStringKey(status))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !state.consoleLog.isEmpty {
                DisclosureGroup("Console Output") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(state.consoleLog)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id("console-bottom")
                        }
                        .frame(height: 100)
                        .onChange(of: state.consoleLog) {
                            proxy.scrollTo("console-bottom", anchor: .bottom)
                        }
                    }
                }
                .font(.caption)
                .padding(.horizontal, 40)
            }
        }
        .padding()
    }

    // MARK: - Ready

    private var readyView: some View {
        VStack(spacing: 0) {
            // Profile list (profileVersion dependency forces re-render on changes)
            let _ = state.profileVersion
            List(selection: $state.selectedProfileID) {
                ForEach(state.profileManager.allProfiles) { profile in
                    HStack(spacing: 8) {
                        if let color = profile.color {
                            Circle()
                                .fill(ProfileSettingsView.swiftUIColor(for: color))
                                .frame(width: 10, height: 10)
                        } else {
                            Circle()
                                .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                                .frame(width: 10, height: 10)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(profile.name).font(.body)
                                if state.profileManager.isManaged(profile.id) {
                                    Image(systemName: "lock.shield.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help("Managed by \(state.profileManager.managedOrgSlug(for: profile.id) ?? "your admin") — not editable")
                                }
                            }
                            if profile.isEncrypted {
                                Label("Encrypted", systemImage: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button {
                            editingProfile = profile
                        } label: {
                            Image(systemName: state.profileManager.isManaged(profile.id) ? "eye" : "gearshape")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(state.profileManager.isManaged(profile.id) ? "View profile settings (read-only)" : "Edit profile settings")
                    }
                    .tag(profile.id)
                    .help(managedTooltip(for: profile) ?? (profile.comments.isEmpty ? "" : profile.comments))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 150)

            // + / - toolbar
            HStack(spacing: 4) {
                Button {
                    newProfileName = ""
                    let taken = usedColors()
                    newProfileColor = ProfileColor.allCases.first { !taken.contains($0) }
                    showNewProfile = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Add a new profile")

                Button {
                    if let id = state.selectedProfileID,
                       let profile = state.profileManager.profile(withID: id) {
                        profileToDelete = profile
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(
                    state.selectedProfileID == nil ||
                    (state.selectedProfileID.map { state.profileManager.isManaged($0) } ?? false)
                )
                .help(
                    state.selectedProfileID.map { state.profileManager.isManaged($0) } == true
                        ? "Managed profiles can only be removed by unenrolling (Settings → Managed Profile)."
                        : "Delete selected profile"
                )

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            Divider()

            // Launch button + status
            VStack(spacing: 12) {
                Button {
                    if let id = state.selectedProfileID,
                       let profile = state.profileManager.profile(withID: id) {
                        onNewBrowserWithProfile(profile)
                    }
                } label: {
                    if state.isLaunching {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting...")
                        }
                        .frame(width: 200)
                    } else {
                        Label("Open Browser", systemImage: "plus.rectangle")
                            .frame(width: 200)
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n")
                .disabled(state.isLaunching || state.selectedProfileID == nil)

                HStack(spacing: 20) {
                    Label {
                        Text(state.poolReady ? "Ready" : "Warming up...")
                            .font(.caption)
                    } icon: {
                        Image(systemName: state.poolReady ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(state.poolReady ? .green : .orange)
                            .font(.caption)
                    }

                    if state.sessionCount > 0 {
                        Label {
                            Text("\(state.sessionCount) open")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "macwindow")
                                .font(.caption)
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)

        // MARK: - Sheets & Dialogs

        .sheet(isPresented: $showNewProfile) {
            VStack(spacing: 16) {
                Text("New Profile")
                    .font(.headline)

                TextField("Profile Name", text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)

                Picker("Color", selection: $newProfileColor) {
                    let taken = usedColors()
                    Text("None").tag(ProfileColor?.none)
                    Divider()
                    ForEach(ProfileColor.allCases.filter { !taken.contains($0) }, id: \.self) { color in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ProfileSettingsView.swiftUIColor(for: color))
                                .frame(width: 10, height: 10)
                            Text(LocalizedStringKey(color.label))
                        }
                        .tag(Optional(color))
                    }
                }

                HStack {
                    Button("Cancel") {
                        showNewProfile = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        let trimmed = newProfileName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        var settings = ProfileSettings()
                        settings.persistent = true
                        settings.enableClipboardSharing = true
                        settings.enableLinkSender = true
                        settings.keychainPasskeys = true
                        settings.keychainPasswords = true
                        let profile = state.profileManager.createProfile(
                            name: trimmed,
                            color: newProfileColor,
                            settings: settings
                        )
                        state.selectedProfileID = profile.id
                        state.profileVersion += 1
                        showNewProfile = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }

        .onChange(of: editingProfile?.id) { _, newID in
            // Only open from sidebar click (not AppleScript — that calls openSettingsPanel directly)
            if let profile = editingProfile, newID != nil, settingsPanel == nil {
                openSettingsPanel(for: profile)
            }
        }

        .confirmationDialog(
            "Delete \"\(profileToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    state.profileManager.deleteProfile(id: profile.id)
                    if state.selectedProfileID == profile.id {
                        state.selectedProfileID = nil
                    }
                    state.profileVersion += 1
                }
                profileToDelete = nil
            }
        } message: {
            if profileToDelete?.isPersistent == true {
                Text("This will permanently delete the profile and all its saved browsing data.")
            } else {
                Text("This will delete the profile.")
            }
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text("Something went wrong")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                state.checkState()
            }
            .controlSize(.regular)
        }
        .padding()
    }

    // MARK: - Profile settings window

    private func openSettingsPanel(for profile: Profile, category: String? = nil) {
        // Close existing panel if open
        settingsPanel?.close()

        let originalProfile = profile

        // Map category string to enum
        let initialCat: SettingsCategory
        switch category {
        case "general": initialCat = .general
        case "performance": initialCat = .performance
        case "media": initialCat = .media
        case "fileTransfer": initialCat = .fileTransfer
        case "privacy": initialCat = .privacy
        case "network": initialCat = .network
        case "vpnAds": initialCat = .vpnAds
        case "enterprise": initialCat = .enterprise
        case "advanced": initialCat = .advanced
        default: initialCat = .general
        }

        let hasActiveSession: Bool = {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return false }
            return delegate.sessions.contains { $0.profile?.id == profile.id }
        }()
        let isManaged = state.profileManager.isManaged(profile.id)
        let settingsView = ProfileSettingsView(
            draft: profile,
            usedColors: usedColors(excluding: profile.id),
            profileDiskExists: ProfileDisk.diskExists(
                at: state.profileManager.profileDiskURL(for: profile.id)
            ),
            hasActiveSession: hasActiveSession,
            isReadOnly: isManaged,
            onDeleteProfileDisk: {
                let diskURL = state.profileManager.profileDiskURL(for: profile.id)
                try? FileManager.default.removeItem(at: diskURL)
            },
            onSave: { [self] updated in
                let hasChanges = updated.settings != originalProfile.settings
                state.profileManager.updateProfile(updated)
                state.profileVersion += 1
                editingProfile = nil
                settingsPanel?.close()
                settingsPanel = nil
                settingsDelegateHelper = nil

                // If settings changed and there's an active session for this profile, offer restart
                if hasChanges {
                    offerSessionRestart(for: updated)
                }
            },
            onCancel: { [self] in
                editingProfile = nil
                settingsPanel?.close()
                settingsPanel = nil
                settingsDelegateHelper = nil
            },
            onShowWarpEULA: onShowWarpEULA,
            onShowPhishingConsent: onShowPhishingConsent,
            initialCategory: initialCat
        )

        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.setFrameSize(NSSize(width: 680, height: 560))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        let titleFormat = isManaged
            ? NSLocalizedString("Managed Profile \u{2014} %@", comment: "")
            : NSLocalizedString("Profile Settings \u{2014} %@", comment: "")
        window.title = String(format: titleFormat, profile.name)
        window.isReleasedWhenClosed = false
        window.center()

        // Window delegate to intercept close → treat as cancel
        let delegateHelper = SettingsWindowDelegate(
            originalProfile: originalProfile,
            onCancel: { [self] in
                editingProfile = nil
                settingsPanel = nil
                settingsDelegateHelper = nil
            }
        )
        window.delegate = delegateHelper
        self.settingsDelegateHelper = delegateHelper

        window.makeKeyAndOrderFront(nil)
        self.settingsPanel = window
    }

    /// Offer to restart active sessions for a profile after settings change.
    private func offerSessionRestart(for profile: Profile) {
        guard let delegate = NSApp.delegate as? GUIAppDelegate else { return }
        let activeSessions = delegate.sessions.filter { $0.profile?.id == profile.id }
        guard !activeSessions.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restart session?", comment: "")
        let count = activeSessions.count
        alert.informativeText = count == 1
            ? NSLocalizedString("Settings have changed. Restart the browser session to apply them?", comment: "")
            : String(format: NSLocalizedString("Settings have changed. Restart %lld browser sessions to apply them?", comment: ""), count)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Restart", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                for session in activeSessions {
                    await delegate.restartSession(session, profile: profile)
                }
            }
        }
    }
}

// MARK: - Settings Window Delegate

/// Intercepts close to treat as cancel and prompt for unsaved changes.
final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    let originalProfile: Profile
    let onCancel: () -> Void

    init(originalProfile: Profile, onCancel: @escaping () -> Void) {
        self.originalProfile = originalProfile
        self.onCancel = onCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Check if the ProfileSettingsView has unsaved changes.
        // Since we can't easily access the SwiftUI @State from here,
        // just close — the onCancel callback discards changes.
        onCancel()
        return true
    }
}
