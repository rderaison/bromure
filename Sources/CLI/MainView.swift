import SwiftUI
import SandboxEngine

struct MainView: View {
    @Bindable var state: AppState
    var onNewBrowser: @MainActor () -> Void
    var onNewBrowserWithProfile: @MainActor (Profile) -> Void
    var onShowWarpEULA: ((@escaping () -> Void) -> Void)?
    @State private var buttonCooldown = false
    @State private var showNewProfile = false
    @State private var newProfileName = ""
    @State private var newProfileColor: ProfileColor? = .blue
    @State private var editingProfile: Profile?
    @State private var settingsPanel: NSPanel?
    @State private var profileToDelete: Profile?

    /// Colors already used by other profiles.
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
                        Text(step.name)
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

            Text(status)
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
                            Text(profile.name)
                                .font(.body)
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
                            Image(systemName: "gearshape")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Edit profile settings")
                    }
                    .tag(profile.id)
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
                .disabled(state.selectedProfileID == nil)
                .help("Delete selected profile")

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
                            Text(color.label)
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
                        let profile = state.profileManager.createProfile(
                            name: trimmed,
                            color: newProfileColor
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
            if let profile = editingProfile, newID != nil {
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

    // MARK: - Non-modal settings panel

    private func openSettingsPanel(for profile: Profile) {
        // Close existing panel if open
        settingsPanel?.close()

        let settingsView = ProfileSettingsView(
            draft: profile,
            usedColors: usedColors(excluding: profile.id),
            profileDiskExists: ProfileDisk.diskExists(
                at: state.profileManager.profileDiskURL(for: profile.id)
            ),
            onDeleteProfileDisk: {
                let diskURL = state.profileManager.profileDiskURL(for: profile.id)
                try? FileManager.default.removeItem(at: diskURL)
            },
            onSave: { [self] updated in
                state.profileManager.updateProfile(updated)
                state.profileVersion += 1
                editingProfile = nil
                settingsPanel?.close()
                settingsPanel = nil
            },
            onCancel: { [self] in
                editingProfile = nil
                settingsPanel?.close()
                settingsPanel = nil
            },
            onShowWarpEULA: onShowWarpEULA
        )

        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.setFrameSize(NSSize(width: 680, height: 560))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.title = "Profile Settings — \(profile.name)"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.settingsPanel = panel
    }
}
