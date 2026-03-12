import SwiftUI
import SandboxEngine
import UniformTypeIdentifiers
import Security

private extension UTType {
    static let pem = UTType(filenameExtension: "pem") ?? .data
}

struct ProfileSettingsView: View {
    @State var draft: Profile
    let usedColors: Set<ProfileColor>
    let profileDiskExists: Bool
    var onDeleteProfileDisk: (() -> Void)?
    var onSave: (Profile) -> Void
    var onCancel: () -> Void
    var onShowWarpEULA: ((@escaping () -> Void) -> Void)?

    @State private var isRenaming = false
    @State private var editedName: String = ""
    @State private var showWarpMemoryConfirm = false
    @State private var showEncryptionWarning = false
    @State private var pendingEncryptOnDisk = false
    @State private var showCAPicker = false
    @State private var caImportError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // MARK: - Profile
                Section("Profile") {
                    if isRenaming {
                        HStack {
                            TextField("Name", text: $editedName)
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty {
                                    draft.name = trimmed
                                }
                                isRenaming = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Cancel") {
                                isRenaming = false
                            }
                            .controlSize(.small)
                        }
                    } else {
                        HStack {
                            Text(draft.name)
                                .font(.headline)
                            Spacer()
                            Button("Rename") {
                                editedName = draft.name
                                isRenaming = true
                            }
                            .controlSize(.small)
                        }
                    }

                    Picker("Color", selection: $draft.color) {
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
                    .help("Window border color for this profile. \"None\" removes the border.")

                    Toggle("Retain browsing data", isOn: $draft.settings.persistent)
                        .help("Keep cookies, history, and bookmarks between sessions.")
                        .onChange(of: draft.settings.persistent) { _, newValue in
                            if !newValue {
                                draft.settings.encryptOnDisk = false
                            }
                        }

                    TextField("Home Page", text: $draft.settings.homePage)
                        .help("The page Chromium opens on launch.")
                }

                // MARK: - Browser
                Section("Browser") {
                    Toggle("GPU Acceleration", isOn: $draft.settings.enableGPU)
                        .help("Hardware GPU acceleration. Disable if you experience graphical glitches.")
                    Toggle("WebGL", isOn: $draft.settings.enableWebGL)
                        .help("Enable WebGL and WebGPU for 3D content.")
                }

                // MARK: - Network
                Section("Network") {
                    Toggle("Filter ads (with Pi-hole)", isOn: $draft.settings.enableAdBlocking)
                        .help("Block ads and trackers using Pi-hole DNS filtering.")
                    Toggle("Cloudflare WARP", isOn: $draft.settings.enableWarp)
                        .help("Route VM traffic through Cloudflare\u{2019}s encrypted network.")
                        .onChange(of: draft.settings.enableWarp) { _, newValue in
                            if newValue {
                                if let onShowWarpEULA, !UserDefaults.standard.bool(forKey: "warpEULAAccepted") {
                                    draft.settings.enableWarp = false
                                    onShowWarpEULA {
                                        draft.settings.enableWarp = true
                                    }
                                    return
                                }
                                let memGB = UserDefaults.standard.integer(forKey: "vm.memoryGB")
                                if memGB > 0 && memGB < 2 {
                                    showWarpMemoryConfirm = true
                                }
                            }
                        }
                }

                // MARK: - Security
                Section("Security") {
                    Toggle("Shared Clipboard", isOn: $draft.settings.enableClipboardSharing)
                        .help("Share the clipboard between macOS and the VM browser.")

                    Toggle("File Upload", isOn: $draft.settings.canUpload)
                    Toggle("File Download", isOn: $draft.settings.canDownload)

                    if draft.settings.canDownload {
                        Toggle("Scan with VirusTotal", isOn: $draft.settings.virusTotalEnabled)
                            .padding(.leading, 16)

                        if draft.settings.virusTotalEnabled {
                            SecureField("VirusTotal API Key", text: Binding(
                                get: { draft.settings.virusTotalAPIKey ?? "" },
                                set: { draft.settings.virusTotalAPIKey = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .padding(.leading, 16)
                        }
                    }

                    Toggle("Block Malware Sites", isOn: $draft.settings.blockMalwareSites)
                        .help("Block known malware domains using Cloudflare\u{2019}s security DNS.")
                    Toggle("Phishing Warning", isOn: $draft.settings.phishingWarning)
                        .help("Warn when entering passwords on suspicious sites.")
                    Toggle("Send Link to Other Session", isOn: $draft.settings.enableLinkSender)
                        .help("Adds a right-click menu to send links to another Bromure profile\u{2019}s session.")
                    Toggle("Isolate from Local Network", isOn: $draft.settings.isolateFromLAN)
                        .help("Block the VM from accessing devices on your local network (printers, NAS, etc). Internet access is unaffected.")
                    Toggle("Restrict Outgoing Ports", isOn: $draft.settings.restrictPorts)
                        .help("Only allow outgoing connections on specified ports. DNS (UDP/53) is always allowed.")
                    if draft.settings.restrictPorts {
                        TextField("Allowed Ports", text: $draft.settings.allowedPorts)
                            .textFieldStyle(.roundedBorder)
                            .padding(.leading, 16)
                            .help("Comma-separated ports or ranges, e.g. \"80, 443, 8000-9000\"")
                    }
                }

                // MARK: - Media
                Section("Media") {
                    Toggle("Audio", isOn: $draft.settings.enableAudio)
                        .help("Enable speaker output and audio playback in the VM.")

                    Toggle("Share Webcam", isOn: $draft.settings.enableWebcam)
                        .help("Share your Mac\u{2019}s camera with the browser in the VM.")

                    Toggle("Share Microphone", isOn: $draft.settings.enableMicrophone)
                        .help("Share your Mac\u{2019}s microphone with the browser in the VM.")

                    if draft.settings.enableWebcam || draft.settings.enableMicrophone {
                        MediaPreviewView(
                            webcamDeviceID: $draft.settings.webcamDeviceID,
                            microphoneDeviceID: $draft.settings.microphoneDeviceID,
                            speakerDeviceID: $draft.settings.speakerDeviceID,
                            enableWebcam: draft.settings.enableWebcam,
                            enableMicrophone: draft.settings.enableMicrophone
                        )
                    } else {
                        Picker("Speaker", selection: $draft.settings.speakerDeviceID) {
                            Text("Default").tag(String?.none)
                            ForEach(MediaDevices.speakers()) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                    }
                }

                // MARK: - Root CAs
                Section("Root CAs") {
                    ForEach(draft.settings.rootCAs) { ca in
                        HStack {
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
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button("Add Certificate\u{2026}") {
                        showCAPicker = true
                    }

                    if let err = caImportError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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

                // MARK: - Advanced
                Section("Advanced") {
                    if draft.settings.persistent {
                        Toggle("Encrypt on disk", isOn: Binding(
                            get: { draft.settings.encryptOnDisk },
                            set: { newValue in
                                if profileDiskExists {
                                    pendingEncryptOnDisk = newValue
                                    showEncryptionWarning = true
                                } else {
                                    draft.settings.encryptOnDisk = newValue
                                }
                            }
                        ))
                        .help("Encrypt stored browsing data with LUKS. The key is stored in your macOS Keychain.")
                    } else {
                        Text("Enable \"Retain browsing data\" to access encryption options.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(draft)
                }
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
    }

    /// Colors available for this profile: those not used by other profiles,
    /// plus the profile's own current color (so it remains selectable).
    private var availableColors: [ProfileColor] {
        ProfileColor.allCases.filter { color in
            !usedColors.contains(color) || draft.color == color
        }
    }

    /// Load a certificate file (.pem, .crt, .cer, .der) and return PEM text.
    static func loadCertificateAsPEM(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        // If it already looks like PEM, validate and return it
        if let text = String(data: data, encoding: .utf8),
           text.contains("-----BEGIN CERTIFICATE-----") {
            // Validate by parsing
            guard SecCertificateCreateWithData(nil, Self.pemToDER(text) as CFData) != nil else {
                throw CertError.invalidCertificate
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }

        // Treat as DER — try to parse it
        guard let cert = SecCertificateCreateWithData(nil, data as CFData) else {
            throw CertError.invalidCertificate
        }
        let derData = SecCertificateCopyData(cert) as Data
        let b64 = derData.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
    }

    /// Extract DER bytes from a PEM string.
    private static func pemToDER(_ pem: String) -> Data {
        let lines = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        return Data(base64Encoded: lines.joined()) ?? Data()
    }

    /// Brief summary of a PEM certificate (subject CN or fallback).
    private func caSummary(_ pem: String) -> String {
        let der = Self.pemToDER(pem)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return "Invalid certificate"
        }
        if let summary = SecCertificateCopySubjectSummary(cert) as String? {
            return summary
        }
        return "Certificate"
    }

    private enum CertError: LocalizedError {
        case invalidCertificate
        var errorDescription: String? {
            switch self {
            case .invalidCertificate: return "Not a valid X.509 certificate"
            }
        }
    }

    static func swiftUIColor(for color: ProfileColor) -> Color {
        switch color {
        case .blue: return .blue
        case .red: return .red
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        case .pink: return .pink
        case .teal: return .teal
        case .gray: return .gray
        }
    }
}
