import SwiftUI
import SandboxEngine
import UniformTypeIdentifiers
import Security

private extension UTType {
    static let pem = UTType(filenameExtension: "pem") ?? .data
}

// MARK: - Settings Category

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case performance = "Performance"
    case media = "Media"
    case privacy = "Privacy & Safety"
    case network = "Network Isolation"
    case vpnAds = "VPN & Ads"
    case enterprise = "Enterprise"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .performance: "bolt.fill"
        case .media: "speaker.wave.2.fill"
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
    var onDeleteProfileDisk: (() -> Void)?
    var onSave: (Profile) -> Void
    var onCancel: () -> Void
    var onShowWarpEULA: ((@escaping () -> Void) -> Void)?

    @State private var selectedCategory: SettingsCategory = .general
    @State private var showWarpMemoryConfirm = false
    @State private var showEncryptionWarning = false
    @State private var pendingEncryptOnDisk = false
    @State private var showCAPicker = false
    @State private var caImportError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Sidebar
                List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                    Label {
                        Text(category.rawValue)
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
                    detailView
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
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
        case .privacy: privacyView
        case .network: networkView
        case .vpnAds: vpnAdsView
        case .enterprise: enterpriseView
        case .advanced: advancedView
        }
    }

    // MARK: - General

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
                            Text(color.label)
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

            // Retain browsing data
            settingToggle(
                "Retain Browsing Data",
                description: "Keep your bookmarks, history, cookies, and passwords between sessions. When turned off, everything is erased each time you close the browser.",
                isOn: $draft.settings.persistent
            )
            .onChange(of: draft.settings.persistent) { _, newValue in
                if !newValue { draft.settings.encryptOnDisk = false }
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

            settingsDivider

            settingToggle(
                "WebGL",
                description: "Lets websites display 3D graphics and interactive content. Required by some games, maps, and data visualizations.",
                isOn: $draft.settings.enableWebGL
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

            settingsDivider

            settingToggle(
                "Share Microphone",
                description: "Let websites in this browser access your Mac\u{2019}s microphone for calls and voice input.",
                isOn: $draft.settings.enableMicrophone
            )

            settingsDivider

            // Device selection
            VStack(alignment: .leading, spacing: 6) {
                if draft.settings.enableWebcam || draft.settings.enableMicrophone {
                    Text("Device Selection").font(.headline)
                    Text("Choose which camera, microphone, and speaker to use with this profile.")
                        .settingDescription()
                    MediaPreviewView(
                        webcamDeviceID: $draft.settings.webcamDeviceID,
                        microphoneDeviceID: $draft.settings.microphoneDeviceID,
                        speakerDeviceID: $draft.settings.speakerDeviceID,
                        enableWebcam: draft.settings.enableWebcam,
                        enableMicrophone: draft.settings.enableMicrophone
                    )
                } else {
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

    // MARK: - Privacy & Safety

    private var privacyView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Privacy & Safety", subtitle: "Control what this browser can access and share")

            settingToggle(
                "Shared Clipboard",
                description: "Copy and paste text and images between your Mac and this browser. When turned off, the browser\u{2019}s clipboard is completely isolated.",
                isOn: $draft.settings.enableClipboardSharing
            )

            settingsDivider

            // File transfer group
            VStack(alignment: .leading, spacing: 12) {
                settingToggle(
                    "File Upload",
                    description: "Allow sending files from your Mac to websites in this browser.",
                    isOn: $draft.settings.canUpload
                )

                settingToggle(
                    "File Download",
                    description: "Allow saving files from websites to your Mac.",
                    isOn: $draft.settings.canDownload
                )

                if draft.settings.canDownload {
                    VStack(alignment: .leading, spacing: 6) {
                        settingToggle(
                            "Scan Downloads with VirusTotal",
                            description: "Automatically check downloaded files for viruses and malware before they reach your Mac.",
                            isOn: $draft.settings.virusTotalEnabled
                        )
                        .padding(.leading, 20)

                        if draft.settings.virusTotalEnabled {
                            SecureField("VirusTotal API Key", text: Binding(
                                get: { draft.settings.virusTotalAPIKey ?? "" },
                                set: { draft.settings.virusTotalAPIKey = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
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

            settingsDivider

            settingToggle(
                "Block Malware Sites",
                description: "Blocks access to websites known to distribute viruses or steal information, using Cloudflare\u{2019}s security DNS.",
                isOn: $draft.settings.blockMalwareSites
            )

            settingsDivider

            settingToggle(
                "Phishing Warning",
                description: "Shows a warning when you\u{2019}re about to enter a password on a website that looks suspicious or fake.",
                isOn: $draft.settings.phishingWarning,
                badge: "Beta"
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
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("VPN & Ads", subtitle: "Network privacy and ad blocking")

            VStack(alignment: .leading, spacing: 6) {
                settingToggle(
                    "Cloudflare WARP",
                    description: "Routes all browser traffic through Cloudflare\u{2019}s encrypted network, hiding your IP address from websites. Works like a VPN.",
                    isOn: $draft.settings.enableWarp
                )
                .onChange(of: draft.settings.enableWarp) { _, newValue in
                    if newValue {
                        if let onShowWarpEULA, !UserDefaults.standard.bool(forKey: "warpEULAAccepted") {
                            draft.settings.enableWarp = false
                            onShowWarpEULA { draft.settings.enableWarp = true }
                            return
                        }
                        let memGB = UserDefaults.standard.integer(forKey: "vm.memoryGB")
                        if memGB > 0 && memGB < 2 {
                            showWarpMemoryConfirm = true
                        }
                    }
                }
            }

            settingsDivider

            settingToggle(
                "Block Ads",
                description: "Blocks ads and tracking scripts from loading on websites. This can make pages load faster and protects your privacy.",
                isOn: $draft.settings.enableAdBlocking
            )
        }
    }

    // MARK: - Enterprise

    private var enterpriseView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Enterprise", subtitle: "Settings for managed environments")

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

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
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
        _ title: String,
        description: String,
        isOn: Binding<Bool>,
        badge: String? = nil
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
