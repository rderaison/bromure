import SwiftUI
import SandboxEngine

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
