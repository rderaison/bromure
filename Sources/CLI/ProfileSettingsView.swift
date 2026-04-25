import SwiftUI
import SandboxEngine
import UniformTypeIdentifiers
import Security
import CFNetwork

private extension UTType {
    static let pem = UTType(filenameExtension: "pem") ?? .data
}

// MARK: - Settings Category

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case performance = "Performance"
    case media = "Media"
    case fileTransfer = "File Transfer"
    case hostIsolation = "Host Isolation"
    case network = "Network Isolation"
    case privacy = "Privacy & Safety"
    case vpnAds = "VPN & Ads"
    case enterprise = "Enterprise"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .performance: "bolt.fill"
        case .media: "speaker.wave.2.fill"
        case .fileTransfer: "arrow.up.arrow.down"
        case .hostIsolation: "macwindow.on.rectangle"
        case .privacy: "lock.shield.fill"
        case .network: "network"
        case .vpnAds: "shield.fill"
        case .enterprise: "building.2.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: .gray
        case .performance: .orange
        case .media: .pink
        case .fileTransfer: .cyan
        case .hostIsolation: .teal
        case .privacy: .blue
        case .network: .indigo
        case .vpnAds: .green
        case .enterprise: .purple
        case .advanced: .gray
        }
    }
}

// MARK: - Main View

struct ProfileSettingsView: View {
    @State var draft: Profile
    let usedColors: Set<ProfileColor>
    let profileDiskExists: Bool
    let hasActiveSession: Bool
    /// Managed profiles ship in a signed manifest and can't be modified
    /// locally. The view renders normally but every input is disabled,
    /// Save is hidden, and Cancel reads "Close".
    let isReadOnly: Bool
    var onDeleteProfileDisk: (() -> Void)?
    var onSave: (Profile) -> Void
    var onCancel: () -> Void
    var onShowWarpEULA: ((@escaping () -> Void) -> Void)?
    var onShowPhishingConsent: ((@escaping () -> Void) -> Void)?
    var initialCategory: SettingsCategory = .general

    // Initialized from initialCategory via init
    @State private var selectedCategory: SettingsCategory

    init(draft: Profile, usedColors: Set<ProfileColor>, profileDiskExists: Bool,
         hasActiveSession: Bool = false,
         isReadOnly: Bool = false,
         onDeleteProfileDisk: (() -> Void)? = nil, onSave: @escaping (Profile) -> Void,
         onCancel: @escaping () -> Void, onShowWarpEULA: ((@escaping () -> Void) -> Void)? = nil,
         onShowPhishingConsent: ((@escaping () -> Void) -> Void)? = nil,
         initialCategory: SettingsCategory = .general) {
        self._draft = State(initialValue: draft)
        self.usedColors = usedColors
        self.profileDiskExists = profileDiskExists
        self.hasActiveSession = hasActiveSession
        self.isReadOnly = isReadOnly
        self.onDeleteProfileDisk = onDeleteProfileDisk
        self.onSave = onSave
        self.onCancel = onCancel
        self.onShowWarpEULA = onShowWarpEULA
        self.onShowPhishingConsent = onShowPhishingConsent
        self.initialCategory = initialCategory
        self._selectedCategory = State(initialValue: initialCategory)

        // Load IKEv2 secrets from keychain
        self._ikev2Password = State(initialValue: VPNKeychain.retrieve(profileID: draft.id, key: VPNKeychain.ikev2Password) ?? "")
        self._ikev2PSK = State(initialValue: VPNKeychain.retrieve(profileID: draft.id, key: VPNKeychain.ikev2PSK) ?? "")
        self._ikev2CertData = State(initialValue: VPNKeychain.retrieve(profileID: draft.id, key: VPNKeychain.ikev2Cert) ?? "")
        self._ikev2CertPass = State(initialValue: VPNKeychain.retrieve(profileID: draft.id, key: VPNKeychain.ikev2CertPass) ?? "")
        self._ikev2CertName = State(initialValue: VPNKeychain.retrieve(profileID: draft.id, key: VPNKeychain.ikev2Cert) != nil ? "Imported" : "")
    }
    @State private var showWarpMemoryConfirm = false
    @State private var showEncryptionWarning = false
    @State private var pendingEncryptOnDisk = false
    @State private var showCAPicker = false
    @State private var caImportError: String?
    @State private var showWebcamEffects = false
    @State private var showPhishingPersistenceAlert = false
    @State private var showDeleteDataConfirm = false
    @State private var showVirusTotalKeyError = false
    @State private var vtKeyVerifying = false
    @State private var vtKeyStatus: VTKeyStatus?
    @State private var proxyHostError: String?
    @State private var proxyHostChecking = false

    // IKEv2 keychain-backed secrets (not stored in profile JSON)
    @State private var ikev2Password: String = ""
    @State private var ikev2PSK: String = ""
    @State private var ikev2CertData: String = ""
    @State private var ikev2CertPass: String = ""
    @State private var ikev2CertName: String = ""

    private enum VTKeyStatus {
        case valid
        case invalid(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Sidebar
                List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                    Label {
                        Text(LocalizedStringKey(category.rawValue))
                    } icon: {
                        Image(systemName: category.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(category.iconColor.gradient, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .tag(category)
                }
                .listStyle(.sidebar)
                .frame(width: 170)

                Divider()

                // Detail
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if isReadOnly {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                Text("This profile is managed by your organization. Settings are read-only.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                        detailView
                            .disabled(isReadOnly)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            HStack {
                Button(isReadOnly ? "Close" : "Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !isReadOnly {
                    Button("Save") {
                        if draft.settings.virusTotalEnabled,
                           (draft.settings.virusTotalAPIKey ?? "").isEmpty {
                            showVirusTotalKeyError = true
                        } else {
                            onSave(draft)
                        }
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .confirmationDialog(
            "Increase VM memory?",
            isPresented: $showWarpMemoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Increase to 2 GB") {
                UserDefaults.standard.set(2, forKey: "vm.memoryGB")
            }
            Button("Keep current", role: .cancel) { }
        } message: {
            Text("Cloudflare WARP requires at least 2 GB of RAM to run reliably. Would you like to increase the VM memory?")
        }
        .confirmationDialog(
            pendingEncryptOnDisk ? "Enable encryption?" : "Disable encryption?",
            isPresented: $showEncryptionWarning,
            titleVisibility: .visible
        ) {
            Button("Delete data and continue", role: .destructive) {
                onDeleteProfileDisk?()
                draft.settings.encryptOnDisk = pendingEncryptOnDisk
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Changing the encryption setting will delete all existing browsing data for this profile. This cannot be undone.")
        }
        .confirmationDialog(
            "Enable data persistence?",
            isPresented: $showPhishingPersistenceAlert,
            titleVisibility: .visible
        ) {
            Button("Enable Both") {
                draft.settings.persistent = true
                draft.settings.phishingWarning = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Phishing protection needs to remember which sites you\u{2019}ve visited so it can detect suspicious look-alikes. This requires retaining browsing data between sessions.")
        }
        .alert("VirusTotal API Key Required", isPresented: $showVirusTotalKeyError) {
            Button("OK") {
                selectedCategory = .fileTransfer
            }
        } message: {
            Text("Enter a VirusTotal API key to enable download scanning. You can get a free key at:\nhttps://www.virustotal.com/gui/join-us")
        }
        .sheet(isPresented: $showWebcamEffects) {
            WebcamEffectsView(
                effects: $draft.settings.webcamEffects,
                webcamDeviceID: draft.settings.webcamDeviceID,
                onDismiss: { showWebcamEffects = false }
            )
        }
        .fileImporter(
            isPresented: $showCAPicker,
            allowedContentTypes: [.x509Certificate, .pem, .data],
            allowsMultipleSelection: true
        ) { result in
            caImportError = nil
            switch result {
            case .success(let urls):
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let pem = try Self.loadCertificateAsPEM(from: url)
                        let name = url.deletingPathExtension().lastPathComponent
                        draft.settings.rootCAs.append(CustomRootCA(name: name, pem: pem))
                    } catch {
                        caImportError = "\(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            case .failure(let error):
                caImportError = error.localizedDescription
            }
        }
    }

    // MARK: - Detail Router

    @ViewBuilder
    private var detailView: some View {
        switch selectedCategory {
        case .general: generalView
        case .performance: performanceView
        case .media: mediaView
        case .fileTransfer: fileTransferView
        case .hostIsolation: hostIsolationView
        case .privacy: privacyView
        case .network: networkView
        case .vpnAds: vpnAdsView
        case .enterprise: enterpriseView
        case .advanced: advancedView
        }
    }

    // MARK: - General

    @AppStorage("automation.enabled") private var automationEnabled = false

    private var generalView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("General", subtitle: "Basic profile settings")

            // Name
            VStack(alignment: .leading, spacing: 6) {
                Text("Profile Name").font(.headline)
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            settingsDivider

            // Retain browsing data
            settingToggle(
                "Retain Browsing Data",
                description: "Keep your bookmarks, history, cookies, and passwords between sessions. When turned off, everything is erased each time you close the browser.",
                isOn: $draft.settings.persistent
            )
            .onChange(of: draft.settings.persistent) { _, newValue in
                if !newValue {
                    draft.settings.encryptOnDisk = false
                    draft.settings.phishingWarning = false
                }
            }

            if draft.settings.persistent && profileDiskExists {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteDataConfirm = true
                    } label: {
                        Label("Delete Browsing Data\u{2026}", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(hasActiveSession)
                    .help(hasActiveSession ? "Close the session before deleting browsing data" : "Permanently delete all saved browsing data for this profile")
                    .confirmationDialog(
                        "Delete browsing data?",
                        isPresented: $showDeleteDataConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Delete All Data", role: .destructive) {
                            onDeleteProfileDisk?()
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This will permanently delete all bookmarks, history, cookies, and passwords for this profile. This cannot be undone.")
                    }
                }
                .padding(.top, 2)
            }

            settingsDivider

            // Color
            VStack(alignment: .leading, spacing: 6) {
                Text("Window Color").font(.headline)
                Text("A colored border around the browser window helps you tell profiles apart at a glance.")
                    .settingDescription()
                Picker("", selection: $draft.color) {
                    Text("None").tag(ProfileColor?.none)
                    Divider()
                    ForEach(availableColors, id: \.self) { color in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Self.swiftUIColor(for: color))
                                .frame(width: 12, height: 12)
                            Text(LocalizedStringKey(color.label))
                        }
                        .tag(Optional(color))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            settingsDivider

            // Home Page
            VStack(alignment: .leading, spacing: 6) {
                Text("Home Page").font(.headline)
                Text("The website that opens when you launch this profile.")
                    .settingDescription()
                TextField("https://", text: $draft.settings.homePage)
                    .textFieldStyle(.roundedBorder)
            }

            settingsDivider

            // Language
            VStack(alignment: .leading, spacing: 6) {
                Text("Language").font(.headline)
                Text("The language used by the browser. \u{201C}Same as System\u{201D} follows your Mac\u{2019}s language. Choosing a specific language reduces browser fingerprinting.")
                    .settingDescription()
                Picker("", selection: Binding(
                    get: { draft.settings.locale ?? "" },
                    set: { draft.settings.locale = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Same as System").tag("")
                    Divider()
                    Text("English").tag("en_US")
                    Text("Fran\u{00e7}ais").tag("fr_FR")
                    Text("Deutsch").tag("de_DE")
                    Text("Espa\u{00f1}ol").tag("es_ES")
                    Text("Portugu\u{00ea}s").tag("pt_BR")
                    Text("\u{65e5}\u{672c}\u{8a9e}").tag("ja_JP")
                    Text("\u{4e2d}\u{6587}\u{ff08}\u{7e41}\u{9ad4}\u{ff09}").tag("zh_TW")
                    Text("\u{4e2d}\u{6587}\u{ff08}\u{7b80}\u{4f53}\u{ff09}").tag("zh_CN")
                }
                .labelsHidden()
            }

            settingsDivider

            // Comments (at the bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text("Comments").font(.headline)
                Text("A short note about this profile. Shown when you hover over it in the profile list.")
                    .settingDescription()
                TextEditor(text: $draft.comments)
                    .font(.body)
                    .frame(height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(.quaternary, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Performance

    private var performanceView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Performance", subtitle: "Control how the browser uses your Mac\u{2019}s hardware")

            settingToggle(
                "GPU Acceleration",
                description: "Uses your Mac\u{2019}s graphics chip to make web pages render faster. Turn this off if you notice visual glitches or display problems.",
                isOn: $draft.settings.enableGPU
            )
            .onChange(of: draft.settings.enableGPU) { _, newValue in
                if !newValue {
                    draft.settings.enableWebGL = false
                }
            }

            settingsDivider

            settingToggle(
                "WebGL",
                description: "Lets websites display 3D graphics and interactive content. Required by some games, maps, and data visualizations.",
                isOn: $draft.settings.enableWebGL
            )
            .disabled(!draft.settings.enableGPU)
            .opacity(draft.settings.enableGPU ? 1 : 0.5)

            settingsDivider

            settingToggle(
                "Zero-Copy Rasterization",
                description: "Reduces memory copies during page rendering. Improves performance on most systems.",
                isOn: $draft.settings.enableZeroCopy
            )

            settingsDivider

            settingToggle(
                "Smooth Scrolling",
                description: "Animates scrolling for a smoother feel. Disable for instant, jump-style scrolling.",
                isOn: $draft.settings.enableSmoothScrolling
            )
        }
    }

    // MARK: - Media

    private var mediaView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Media", subtitle: "Audio and device sharing")

            settingToggle(
                "Audio",
                description: "Play sounds, music, and video audio from websites.",
                isOn: $draft.settings.enableAudio
            )

            if draft.settings.enableAudio {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Volume").font(.headline)
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(draft.settings.audioVolume) },
                            set: { draft.settings.audioVolume = Int($0) }
                        ), in: 0...100, step: 5)
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(.secondary)
                        Text("\(draft.settings.audioVolume)%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            settingsDivider

            settingToggle(
                "Share Webcam",
                description: "Let websites in this browser access your Mac\u{2019}s camera for video calls and meetings.",
                isOn: $draft.settings.enableWebcam
            )

            if draft.settings.enableWebcam {
                VStack(alignment: .leading, spacing: 6) {
                    MediaPreviewView(
                        webcamDeviceID: $draft.settings.webcamDeviceID,
                        microphoneDeviceID: .constant(nil),
                        speakerDeviceID: .constant(nil),
                        enableWebcam: !showWebcamEffects,
                        enableMicrophone: false,
                        webcamQuality: draft.settings.webcamQuality,
                        webcamEffects: draft.settings.webcamEffects
                    )

                    HStack(spacing: 12) {
                        let supported = WebcamBridge.supportedQualities(cameraID: draft.settings.webcamDeviceID)
                        Picker("Quality", selection: $draft.settings.webcamQuality) {
                            ForEach(supported, id: \.self) { q in
                                Text(q.label).tag(q)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)

                        Button {
                            showWebcamEffects = true
                        } label: {
                            HStack(spacing: 4) {
                                Label("Effects\u{2026}", systemImage: "sparkles")
                                if draft.settings.webcamEffects.hasAnyEffect {
                                    Circle()
                                        .fill(.blue)
                                        .frame(width: 6, height: 6)
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 20)
            }

            settingsDivider

            settingToggle(
                "Share Microphone",
                description: "Let websites in this browser access your Mac\u{2019}s microphone for calls and voice input.",
                isOn: $draft.settings.enableMicrophone
            )

            if draft.settings.enableMicrophone {
                VStack(alignment: .leading, spacing: 6) {
                    MediaPreviewView(
                        webcamDeviceID: .constant(nil),
                        microphoneDeviceID: $draft.settings.microphoneDeviceID,
                        speakerDeviceID: $draft.settings.speakerDeviceID,
                        enableWebcam: false,
                        enableMicrophone: true
                    )
                }
                .padding(.leading, 20)
            }

            if !draft.settings.enableWebcam && !draft.settings.enableMicrophone {
                settingsDivider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speaker").font(.headline)
                    Text("Choose which speaker to use for audio output.")
                        .settingDescription()
                    Picker("", selection: $draft.settings.speakerDeviceID) {
                        Text("Default").tag(String?.none)
                        ForEach(MediaDevices.speakers()) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
            }
        }
    }

    // MARK: - Host Isolation

    private var hostIsolationView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Host Isolation", subtitle: "Control how this browser interacts with your Mac")

            settingToggle(
                "Native Tabs",
                description: "Hide Chromium\u{2019}s tab strip and address bar, and render them as native macOS toolbar items instead. Tabs, favicons, the URL bar, and a share button appear in the window\u{2019}s titlebar \u{2014} so the page uses the full window and the browser feels like a native Mac app.",
                isOn: $draft.settings.nativeChrome
            )

            settingsDivider

            settingToggle(
                "Shared Clipboard",
                description: "Copy and paste text and images between your Mac and this browser. When turned off, the browser\u{2019}s clipboard is completely isolated.",
                isOn: $draft.settings.enableClipboardSharing
            )

            settingsDivider

            settingToggle(
                "Match Keyboard Layout",
                description: "Automatically switch the browser\u{2019}s keyboard layout when you change it on your Mac. Turn this off to always use the layout set in Bromure \u{2192} Settings \u{2192} Input.",
                isOn: $draft.settings.matchKeyboardLayout
            )

            settingsDivider

            settingToggle(
                "Use macOS Passkeys",
                description: "Sign in to websites using passkeys stored on your Mac. Each request requires Touch ID or password approval.",
                isOn: $draft.settings.keychainPasskeys
            )

            settingsDivider

            settingToggle(
                "Use macOS Passwords",
                description: "Autofill usernames and passwords from your Mac\u{2019}s saved passwords and iCloud Keychain. Disables Chromium\u{2019}s built-in password manager.",
                isOn: $draft.settings.keychainPasswords
            )
        }
    }

    // MARK: - File Transfer

    private var fileTransferView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("File Transfer", subtitle: "Control file uploads and downloads between your Mac and this browser")

            settingToggle(
                "File Upload",
                description: "Allow sending files from your Mac to websites in this browser.",
                isOn: $draft.settings.canUpload
            )

            settingsDivider

            settingToggle(
                "File Download",
                description: "Allow saving files from websites to your Mac.",
                isOn: $draft.settings.canDownload
            )

            if draft.settings.canDownload {
                settingsDivider

                settingToggle(
                    "Scan Downloads with VirusTotal",
                    description: "Automatically check downloaded files for viruses and malware before they reach your Mac.",
                    isOn: $draft.settings.virusTotalEnabled
                )

                if draft.settings.virusTotalEnabled {
                    HStack(spacing: 8) {
                        SecureField("VirusTotal API Key", text: Binding(
                            get: { draft.settings.virusTotalAPIKey ?? "" },
                            set: {
                                draft.settings.virusTotalAPIKey = $0.isEmpty ? nil : $0
                                vtKeyStatus = nil
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)

                        Button {
                            let key = draft.settings.virusTotalAPIKey ?? ""
                            guard !key.isEmpty else {
                                vtKeyStatus = .invalid("Enter an API key first.")
                                return
                            }
                            vtKeyVerifying = true
                            vtKeyStatus = nil
                            Task {
                                do {
                                    try await VirusTotalClient.validateAPIKey(key)
                                    vtKeyVerifying = false
                                    vtKeyStatus = .valid
                                } catch {
                                    vtKeyVerifying = false
                                    vtKeyStatus = .invalid(error.localizedDescription)
                                }
                            }
                        } label: {
                            if vtKeyVerifying {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 50)
                            } else {
                                Text("Verify")
                                    .frame(width: 50)
                            }
                        }
                        .disabled(vtKeyVerifying)

                        if let status = vtKeyStatus {
                            switch status {
                            case .valid:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            case .invalid(let msg):
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .help(msg)
                            }
                        }
                    }
                    .padding(.leading, 20)

                    settingToggle(
                        "Block Threats",
                        description: "Automatically block files that VirusTotal identifies as malicious. Blocked files cannot be saved or dragged to your Mac.",
                        isOn: $draft.settings.blockThreats
                    )
                    .padding(.leading, 20)

                    settingToggle(
                        "Block Unscannable Files",
                        description: "Block files that could not be scanned by VirusTotal (too large, rate-limited, or unknown). When turned off, unscannable files can still be saved manually.",
                        isOn: $draft.settings.blockUnscannable
                    )
                    .padding(.leading, 20)
                }
            }
        }
    }

    // MARK: - Privacy & Safety

    private var privacyView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Privacy & Safety", subtitle: "Control what this browser can access and share")

            settingToggle(
                "Block Malware Sites",
                description: "Blocks access to websites known to distribute viruses or steal information, using Cloudflare\u{2019}s security DNS.",
                isOn: $draft.settings.blockMalwareSites
            )

            settingsDivider

            settingToggle(
                "AI Phishing Detection",
                description: "Analyzes pages with an AI model to catch scams and phishing before you act on them. When enabled, the page\u{2019}s URL, visible text, and form structure are sent to a Bromure analysis server for scoring \u{2014} data leaves the local VM.",
                isOn: $draft.settings.phishingWarning,
                badge: "Beta"
            )
            .onChange(of: draft.settings.phishingWarning) { _, newValue in
                guard newValue else { return }
                if !draft.settings.persistent {
                    draft.settings.phishingWarning = false
                    showPhishingPersistenceAlert = true
                    return
                }
                if let onShowPhishingConsent,
                   !UserDefaults.standard.bool(forKey: "phishingConsentAccepted") {
                    draft.settings.phishingWarning = false
                    onShowPhishingConsent { draft.settings.phishingWarning = true }
                }
            }

            settingsDivider

            settingToggle(
                "Block Screen Capture",
                description: "Hides this browser window from screenshots, screen recordings, and screen sharing apps like Zoom.",
                isOn: $draft.settings.blockScreenCapture
            )

            settingsDivider

            settingToggle(
                "Send Link to Other Session",
                description: "Adds a right-click menu option to send a web page link to another Bromure profile.",
                isOn: $draft.settings.enableLinkSender
            )
        }
    }

    // MARK: - Network Isolation

    private var networkView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Network Isolation", subtitle: "Restrict which networks and ports this browser can reach")

            // Per-profile network interface
            VStack(alignment: .leading, spacing: 6) {
                Text("Network Interface").font(.headline)
                Text("Override the global network setting for this profile. Use this to attach different profiles to different network adapters.")
                    .settingDescription()
                let interfaces = VMConfig.bridgedInterfaces()
                Picker("", selection: $draft.settings.networkInterface) {
                    Text("Default (use global setting)").tag("")
                    Text("NAT").tag("nat")
                    ForEach(interfaces) { iface in
                        Text("Bridge \u{2014} \(iface.displayName)").tag(iface.id)
                    }
                }
                .labelsHidden()
                .frame(width: 300)
            }

            settingsDivider

            settingToggle(
                "Isolate from Local Network",
                description: "Prevents this browser from reaching devices on your home or office network, like printers, NAS drives, or internal servers. Internet access is not affected.",
                isOn: $draft.settings.isolateFromLAN
            )

            settingsDivider

            VStack(alignment: .leading, spacing: 6) {
                settingToggle(
                    "Restrict Outgoing Ports",
                    description: "Only allow the browser to connect on specific network ports. Useful for locking down which services the browser can reach.",
                    isOn: $draft.settings.restrictPorts
                )
                if draft.settings.restrictPorts {
                    TextField("Allowed ports (e.g. 80, 443, 8000-9000)", text: $draft.settings.allowedPorts)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .padding(.leading, 20)
                    Text("DNS (port 53) is always allowed. Separate ports with commas. Use a dash for ranges.")
                        .settingDescription()
                        .padding(.leading, 20)
                }
            }
        }
    }

    // MARK: - VPN & Ads

    private var vpnAdsView: some View {
        let proxyActive = draft.settings.hasProxy

        return VStack(alignment: .leading, spacing: 20) {
            sectionHeader("VPN & Ads", subtitle: "Network privacy and ad blocking")

            if proxyActive {
                Text("A custom proxy is configured in the Enterprise tab. VPN and ad blocking are disabled while a proxy is active.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                // VPN mode picker
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $draft.settings.vpnMode) {
                        Text("No VPN").tag(VPNMode.none)
                        Text("Cloudflare WARP").tag(VPNMode.cloudflareWarp)
                        Text("WireGuard").tag(VPNMode.wireGuard)
                        Text("IKEv2").tag(VPNMode.ikev2)
                    }
                    .pickerStyle(.segmented)
                    .disabled(proxyActive)
                    .onChange(of: draft.settings.vpnMode) { _, newMode in
                        guard newMode == .cloudflareWarp else { return }
                        if let onShowWarpEULA, !UserDefaults.standard.bool(forKey: "warpEULAAccepted") {
                            draft.settings.vpnMode = .none
                            onShowWarpEULA { draft.settings.vpnMode = .cloudflareWarp }
                            return
                        }
                        let memGB = UserDefaults.standard.integer(forKey: "vm.memoryGB")
                        if memGB > 0 && memGB < 2 {
                            showWarpMemoryConfirm = true
                        }
                    }
                    Text("Choose a VPN to route browser traffic through an encrypted tunnel, hiding your IP address from websites.")
                        .settingDescription()
                }

                // WARP options
                if draft.settings.vpnMode == .cloudflareWarp {
                    settingToggle(
                        "Connect on Startup",
                        description: "Automatically connect the VPN when the browser session starts. You can always toggle it from the window\u{2019}s VPN button.",
                        isOn: $draft.settings.warpAutoConnect
                    )
                    .padding(.leading, 20)
                }

                // WireGuard options
                if draft.settings.vpnMode == .wireGuard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WireGuard Configuration")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Paste your WireGuard .conf file below, or use the import button to load it from disk.")
                            .settingDescription()
                        TextEditor(text: $draft.settings.wireGuardConfig)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120, maxHeight: 200)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                            .padding(.top, 2)
                        HStack {
                            Spacer()
                            Button("Import .conf File\u{2026}") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.init(filenameExtension: "conf")!]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url,
                                   let content = try? String(contentsOf: url, encoding: .utf8) {
                                    draft.settings.wireGuardConfig = content
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.blue)
                        }
                    }
                    .padding(.leading, 20)

                    settingToggle(
                        "Connect on Startup",
                        description: "Automatically connect the VPN when the browser session starts. You can always toggle it from the window\u{2019}s VPN button.",
                        isOn: $draft.settings.wireGuardAutoConnect
                    )
                    .padding(.leading, 20)
                }

                // IKEv2 options
                if draft.settings.vpnMode == .ikev2 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("IKEv2 Configuration")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("Server address")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .foregroundStyle(.primary)
                                TextField("", text: $draft.settings.ikev2Server)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Remote ID")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .foregroundStyle(.primary)
                                TextField("Same as server if empty", text: $draft.settings.ikev2RemoteID)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Divider()
                                .gridCellColumns(2)

                            GridRow {
                                Text("Authentication")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .foregroundStyle(.primary)
                                    .fontWeight(.medium)
                                Color.clear.frame(height: 0)
                            }

                            GridRow {
                                Text("User authentication")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .foregroundStyle(.primary)
                                Picker("", selection: $draft.settings.ikev2AuthMethod) {
                                    Text("Username").tag(IKEv2AuthMethod.eap)
                                    Text("Certificate").tag(IKEv2AuthMethod.certificate)
                                    Text("None (PSK)").tag(IKEv2AuthMethod.psk)
                                }
                                .labelsHidden()
                                .frame(maxWidth: 180, alignment: .leading)
                            }

                            if draft.settings.ikev2AuthMethod == .eap {
                                GridRow {
                                    Text("Username")
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .foregroundStyle(.primary)
                                    TextField("", text: $draft.settings.ikev2Username)
                                        .textFieldStyle(.roundedBorder)
                                }
                                GridRow {
                                    Text("Password")
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .foregroundStyle(.primary)
                                    SecureField("", text: ikev2PasswordBinding)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            if draft.settings.ikev2AuthMethod == .psk {
                                GridRow {
                                    Text("Shared secret")
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .foregroundStyle(.primary)
                                    SecureField("", text: ikev2PSKBinding)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            if draft.settings.ikev2AuthMethod == .certificate {
                                GridRow {
                                    Text("Certificate")
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .foregroundStyle(.primary)
                                    HStack {
                                        Text(ikev2CertName.isEmpty ? "None" : ikev2CertName)
                                            .foregroundStyle(ikev2CertName.isEmpty ? .secondary : .primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Button("Select\u{2026}") {
                                            let panel = NSOpenPanel()
                                            panel.allowedContentTypes = [.init(filenameExtension: "p12")!, .init(filenameExtension: "pfx")!]
                                            panel.allowsMultipleSelection = false
                                            if panel.runModal() == .OK, let url = panel.url,
                                               let data = try? Data(contentsOf: url) {
                                                let b64 = data.base64EncodedString()
                                                ikev2CertData = b64
                                                ikev2CertName = url.lastPathComponent
                                                VPNKeychain.store(profileID: draft.id, key: VPNKeychain.ikev2Cert, secret: b64)
                                            }
                                        }
                                    }
                                }
                                GridRow {
                                    Text("Passphrase")
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .foregroundStyle(.primary)
                                    SecureField("", text: ikev2CertPassBinding)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }
                    .padding(.leading, 20)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("VPN Proxy")
                            .font(.subheadline).bold()
                        Text("Route browser traffic through an HTTP proxy reachable inside the VPN tunnel.")
                            .settingDescription()
                        HStack(spacing: 8) {
                            TextField("Hostname", text: $draft.settings.ikev2ProxyHost)
                                .textFieldStyle(.roundedBorder)
                            TextField("Port", value: $draft.settings.ikev2ProxyPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                        if !draft.settings.ikev2ProxyHost.isEmpty {
                            HStack(spacing: 8) {
                                TextField("Username", text: $draft.settings.ikev2ProxyUsername)
                                    .textFieldStyle(.roundedBorder)
                                SecureField("Password", text: $draft.settings.ikev2ProxyPassword)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(.leading, 20)

                    settingToggle(
                        "Use VPN DNS",
                        description: "Use DNS servers pushed by the IKEv2 gateway, preventing DNS leaks outside the tunnel.",
                        isOn: $draft.settings.ikev2UseDNS
                    )
                    .padding(.leading, 20)

                    settingToggle(
                        "Connect on Startup",
                        description: "Automatically connect the VPN when the browser session starts. You can always toggle it from the window\u{2019}s VPN button.",
                        isOn: $draft.settings.ikev2AutoConnect
                    )
                    .padding(.leading, 20)
                }
            }

            settingsDivider

            settingToggle(
                "Block Ads",
                description: "Blocks ads and tracking scripts from loading on websites. This can make pages load faster and protects your privacy.",
                isOn: $draft.settings.enableAdBlocking
            )
            .disabled(proxyActive)
        }
    }

    // MARK: - Enterprise

    private var enterpriseView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Enterprise", subtitle: "Settings for managed environments")

            // Proxy
            VStack(alignment: .leading, spacing: 10) {
                Text("HTTP Proxy").font(.headline)
                Text("Route all browser traffic through a corporate proxy server. When a proxy is configured, VPN and ad blocking are automatically disabled.")
                    .settingDescription()

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Hostname", text: $draft.settings.proxyHost)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { validateProxyHost() }
                            .onChange(of: draft.settings.proxyHost) { _, _ in
                                proxyHostError = nil
                            }
                        if proxyHostChecking {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Resolving\u{2026}")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = proxyHostError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    TextField("Port", value: $draft.settings.proxyPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                if !draft.settings.proxyHost.isEmpty {
                    HStack(spacing: 8) {
                        TextField("Username", text: $draft.settings.proxyUsername)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $draft.settings.proxyPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            settingsDivider

            VStack(alignment: .leading, spacing: 10) {
                Text("Root Certificates").font(.headline)
                Text("Install custom root CA certificates so the browser trusts your organization\u{2019}s internal websites and services. Accepts PEM, DER, CRT, and CER files.")
                    .settingDescription()

                if !draft.settings.rootCAs.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(draft.settings.rootCAs) { ca in
                            HStack {
                                Image(systemName: "lock.doc.fill")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ca.name).lineLimit(1)
                                    Text(caSummary(ca.pem))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    draft.settings.rootCAs.removeAll { $0.id == ca.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            if ca.id != draft.settings.rootCAs.last?.id {
                                Divider()
                            }
                        }
                    }
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button {
                    showCAPicker = true
                } label: {
                    Label("Add Certificate\u{2026}", systemImage: "plus.circle")
                }
                .controlSize(.small)

                if let err = caImportError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Advanced", subtitle: "Additional options for power users")

            // Allow Automation
            VStack(alignment: .leading, spacing: 6) {
                settingToggle(
                    "Allow Automation",
                    description: "Let external tools (Claude Code, Puppeteer, Playwright) create browser sessions and control this profile remotely. When turned off, this profile is hidden from the automation API.",
                    isOn: $draft.settings.allowAutomation
                )

                if draft.settings.allowAutomation && !automationEnabled {
                    Label {
                        Text("The automation server is currently disabled. Enable it in Bromure \u{2192} Settings \u{2192} Automation.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            settingsDivider

            // Session Recording
            VStack(alignment: .leading, spacing: 6) {
                Text("Session Recording").font(.headline)
                Text("Record all HTTP requests made during this browsing session. Useful for analyzing what a suspicious link does behind the scenes. When the session ends, you can save or discard the recording.")
                    .settingDescription()
                Picker("Capture Level", selection: $draft.settings.traceLevel) {
                    Text("Disabled").tag(TraceLevel.disabled)
                    Text("Basic \u{2014} URLs only").tag(TraceLevel.basic)
                    Text("Headers \u{2014} URLs + headers + POST data").tag(TraceLevel.headers)
                    Text("Full \u{2014} URLs + headers + response bodies").tag(TraceLevel.full)
                }
                .labelsHidden()

                if draft.settings.traceLevel == .headers {
                    Label {
                        Text("This level captures POST data which may include passwords, tokens, and form submissions in clear text.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                if draft.settings.traceLevel == .full {
                    Label {
                        Text("Full capture records all request and response bodies including passwords, authentication tokens, personal data, and any sensitive content transmitted over the network. Use only for security analysis of untrusted links.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .padding(10)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                if draft.settings.traceLevel != .disabled {
                    settingsDivider

                    settingToggle(
                        "Start Recording Automatically",
                        description: "Begin capturing requests as soon as the session opens. When off, recording starts only when you click the record button in the titlebar.",
                        isOn: $draft.settings.traceAutoStart
                    )
                }
            }

            settingsDivider

            // Encryption
            if draft.settings.persistent {
                VStack(alignment: .leading, spacing: 6) {
                    settingToggle(
                        "Encrypt Browsing Data",
                        description: "Encrypts all saved browsing data on your Mac\u{2019}s disk using LUKS. The encryption key is stored securely in your macOS Keychain. If you lose the key, your data cannot be recovered.",
                        isOn: Binding(
                            get: { draft.settings.encryptOnDisk },
                            set: { newValue in
                                if profileDiskExists {
                                    pendingEncryptOnDisk = newValue
                                    showEncryptionWarning = true
                                } else {
                                    draft.settings.encryptOnDisk = newValue
                                }
                            }
                        )
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Encryption").font(.headline)
                    Text("Turn on \u{201c}Retain Browsing Data\u{201d} in General to access disk encryption options.")
                        .settingDescription()
                }
            }
        }
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var settingsDivider: some View {
        Divider().padding(.vertical, 2)
    }

    private func settingToggle(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        isOn: Binding<Bool>,
        badge: LocalizedStringKey? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(title, isOn: isOn)
                if let badge {
                    Text(badge)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue, in: Capsule())
                }
            }
            Text(description)
                .settingDescription()
                .padding(.leading, 20)
        }
    }

    // MARK: - Helpers

    private var availableColors: [ProfileColor] {
        ProfileColor.allCases.filter { color in
            !usedColors.contains(color) || draft.color == color
        }
    }

    static func loadCertificateAsPEM(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8),
           text.contains("-----BEGIN CERTIFICATE-----") {
            guard SecCertificateCreateWithData(nil, Self.pemToDER(text) as CFData) != nil else {
                throw CertError.invalidCertificate
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        guard let cert = SecCertificateCreateWithData(nil, data as CFData) else {
            throw CertError.invalidCertificate
        }
        let derData = SecCertificateCopyData(cert) as Data
        let b64 = derData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
    }

    private static func pemToDER(_ pem: String) -> Data {
        let lines = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        return Data(base64Encoded: lines.joined()) ?? Data()
    }

    private func caSummary(_ pem: String) -> String {
        let der = Self.pemToDER(pem)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return "Invalid certificate"
        }
        return (SecCertificateCopySubjectSummary(cert) as String?) ?? "Certificate"
    }

    private enum CertError: LocalizedError {
        case invalidCertificate
        var errorDescription: String? { "Not a valid X.509 certificate" }
    }

    // MARK: - IKEv2 Keychain Bindings

    private var ikev2PasswordBinding: Binding<String> {
        Binding(
            get: { ikev2Password },
            set: { newValue in
                ikev2Password = newValue
                VPNKeychain.store(profileID: draft.id, key: VPNKeychain.ikev2Password, secret: newValue)
            }
        )
    }

    private var ikev2PSKBinding: Binding<String> {
        Binding(
            get: { ikev2PSK },
            set: { newValue in
                ikev2PSK = newValue
                VPNKeychain.store(profileID: draft.id, key: VPNKeychain.ikev2PSK, secret: newValue)
            }
        )
    }

    private var ikev2CertPassBinding: Binding<String> {
        Binding(
            get: { ikev2CertPass },
            set: { newValue in
                ikev2CertPass = newValue
                VPNKeychain.store(profileID: draft.id, key: VPNKeychain.ikev2CertPass, secret: newValue)
            }
        )
    }

    private func validateProxyHost() {
        let host = draft.settings.proxyHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            proxyHostError = nil
            return
        }
        proxyHostChecking = true
        proxyHostError = nil
        Task.detached(priority: .userInitiated) {
            let valid: Bool
            // Accept raw IP addresses without DNS lookup
            var addr = sockaddr_in()
            var addr6 = sockaddr_in6()
            if host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 ||
               host.withCString({ inet_pton(AF_INET6, $0, &addr6.sin6_addr) }) == 1 {
                valid = true
            } else {
                let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
                var resolved = DarwinBoolean(false)
                CFHostStartInfoResolution(hostRef, .addresses, nil)
                CFHostGetAddressing(hostRef, &resolved)
                valid = resolved.boolValue
            }
            await MainActor.run {
                proxyHostChecking = false
                if !valid {
                    proxyHostError = "Cannot resolve \u{201c}\(host)\u{201d} \u{2014} check the hostname"
                }
            }
        }
    }

    static func swiftUIColor(for color: ProfileColor) -> Color {
        switch color {
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

// MARK: - Text Style Extension

private extension Text {
    func settingDescription() -> some View {
        self
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
