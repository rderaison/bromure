import SwiftUI
import SandboxEngine

struct SettingsView: View {
    @AppStorage("vm.memoryGB") private var memoryGB = 1
    @AppStorage("vm.cpuCount") private var cpuCount = 0
    @AppStorage("vm.enableNetworking") private var enableNetworking = true
    @AppStorage("vm.enableAudio") private var enableAudio = true
    @AppStorage("vm.enableWarp") private var enableWarp = false
    @AppStorage("vm.enableAdBlocking") private var enableAdBlocking = false
    @AppStorage("vm.appearance") private var appearance = "system"
    @AppStorage("vm.homePage") private var homePage = "https://www.google.com"

    var state: AppState?
    var onShowWarpEULA: ((@escaping () -> Void) -> Void)?
    @State private var showResetConfirm = false
    @State private var showRebuildConfirm = false
    @State private var showWarpMemoryConfirm = false
    @State private var pendingKeyboard: String?
    @State private var pendingScrolling: Bool?
    @State private var pendingDisplayScale: Int?

    @State private var keyboardLayout: String = ""
    @State private var naturalScrolling: Bool = true
    @State private var displayScale: Int = 2

    private var autoCPU: Int {
        max(2, ProcessInfo.processInfo.processorCount / 2)
    }

    static let keyboardLayouts: [(label: String, value: String)] = [
        ("US (QWERTY)", "us"),
        ("US (Dvorak)", "us(dvorak)"),
        ("US (Colemak)", "us(colemak)"),
        ("British", "gb"),
        ("French (AZERTY)", "fr"),
        ("German (QWERTZ)", "de"),
        ("Spanish", "es"),
        ("Italian", "it"),
        ("Portuguese", "pt"),
        ("Brazilian", "br"),
        ("Belgian", "be"),
        ("Dutch", "nl"),
        ("Swedish", "se"),
        ("Norwegian", "no"),
        ("Danish", "dk"),
        ("Finnish", "fi"),
        ("Swiss French", "ch(fr)"),
        ("Swiss German", "ch(de)"),
        ("Canadian French", "ca(fr)"),
        ("Czech", "cz"),
        ("Polish", "pl"),
        ("Russian", "ru"),
        ("Turkish", "tr"),
        ("Japanese", "jp"),
        ("Korean", "kr"),
        ("Arabic", "ara"),
        ("Hebrew", "il"),
        ("Irish", "ie"),
    ]

    var body: some View {
        Form {
            Section("Virtual Machine") {
                Picker("Memory", selection: $memoryGB) {
                    Text("1 GB").tag(1)
                    Text("2 GB").tag(2)
                    Text("4 GB").tag(4)
                    Text("8 GB").tag(8)
                    Text("16 GB").tag(16)
                }
                .help("RAM allocated to the VM. 1 GB is sufficient for most browsing.")

                Picker("CPU Cores", selection: $cpuCount) {
                    Text("Automatic (\(autoCPU))").tag(0)
                    ForEach(1...ProcessInfo.processInfo.processorCount, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
            }

            Section("Input") {
                Picker("Keyboard Layout", selection: $keyboardLayout) {
                    ForEach(Self.keyboardLayouts, id: \.value) { layout in
                        Text(layout.label).tag(layout.value)
                    }
                }
                .onChange(of: keyboardLayout) { _, newValue in
                    let current = state?.currentKeyboardLayout ?? "us"
                    if newValue != current {
                        pendingKeyboard = newValue
                        showRebuildConfirm = true
                    }
                }

                Toggle("Natural Scrolling", isOn: $naturalScrolling)
                    .help("Match macOS trackpad scroll direction.")
                    .onChange(of: naturalScrolling) { _, newValue in
                        let current = state?.currentNaturalScrolling ?? true
                        if newValue != current {
                            pendingScrolling = newValue
                            showRebuildConfirm = true
                        }
                    }
            }

            Section("Display") {
                Picker("Scale Factor", selection: $displayScale) {
                    Text("1x (Standard)").tag(1)
                    Text("2x (Retina)").tag(2)
                }
                .help("Match your Mac's display scaling. Use 2x for Retina displays.")
                .onChange(of: displayScale) { _, newValue in
                    let current = state?.currentDisplayScale ?? 2
                    if newValue != current {
                        pendingDisplayScale = newValue
                        showRebuildConfirm = true
                    }
                }

                Picker("Appearance", selection: $appearance) {
                    Text("Same as System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .help("Controls Chromium's color scheme in the VM.")
            }

            Section("Browser") {
                TextField("Home Page", text: $homePage)
                    .help("The page Chromium opens on launch.")
            }

            Section("Features") {
                Toggle("Networking", isOn: $enableNetworking)
                    .help("Disable for fully isolated browsing with no network access.")
                Toggle("Audio", isOn: $enableAudio)
                Toggle("Filter ads (with Pi-hole)", isOn: $enableAdBlocking)
                    .help("Block ads and trackers using Pi-hole DNS filtering with a local Squid proxy.")
                    .disabled(!enableNetworking)
                Toggle("Cloudflare WARP", isOn: $enableWarp)
                    .help("Route VM traffic through Cloudflare\u{2019}s encrypted network via SOCKS5 proxy.")
                    .disabled(!enableNetworking)
            }

            Section("Storage") {
                LabeledContent("Disk Usage") {
                    Text(state?.diskUsage ?? "\u{2014}")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Location") {
                    Text(VMConfig.defaultStorageDirectory.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Delete Base Image & Reset...", role: .destructive) {
                    showResetConfirm = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 550)
        .onAppear {
            keyboardLayout = state?.currentKeyboardLayout ?? VMConfig.detectKeyboardLayout()
            naturalScrolling = state?.currentNaturalScrolling ?? VMConfig.detectNaturalScrolling()
            displayScale = state?.currentDisplayScale ?? VMConfig.detectDisplayScale()
        }
        .confirmationDialog(
            "Delete the base image?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                state?.resetBaseImage()
            }
        } message: {
            Text("This will delete the Linux base image. You\u{2019}ll need to run setup again.")
        }
        .confirmationDialog(
            "Rebuild required",
            isPresented: $showRebuildConfirm,
            titleVisibility: .visible
        ) {
            Button("Rebuild Image", role: .destructive) {
                if let kb = pendingKeyboard {
                    UserDefaults.standard.set(kb, forKey: "vm.keyboardLayout")
                }
                if let sc = pendingScrolling {
                    UserDefaults.standard.set(sc, forKey: "vm.naturalScrolling")
                }
                if let ds = pendingDisplayScale {
                    UserDefaults.standard.set(ds, forKey: "vm.displayScale")
                }
                pendingKeyboard = nil
                pendingScrolling = nil
                pendingDisplayScale = nil
                state?.regenerateImage()
            }
            Button("Cancel", role: .cancel) {
                // Revert UI to current values
                keyboardLayout = state?.currentKeyboardLayout ?? "us"
                naturalScrolling = state?.currentNaturalScrolling ?? true
                displayScale = state?.currentDisplayScale ?? VMConfig.detectDisplayScale()
                pendingKeyboard = nil
                pendingScrolling = nil
                pendingDisplayScale = nil
            }
        } message: {
            Text("Changing this setting requires rebuilding the base image. All open browser windows will be closed and any unsaved data will be lost.")
        }

        .confirmationDialog(
            "Increase VM memory?",
            isPresented: $showWarpMemoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Increase to 2 GB") {
                memoryGB = 2
            }
            Button("Keep \(memoryGB) GB", role: .cancel) { }
        } message: {
            Text("Cloudflare WARP requires at least 2 GB of RAM to run reliably. Would you like to increase the VM memory?")
        }

        .onChange(of: memoryGB) { _, _ in state?.restartPool() }
        .onChange(of: cpuCount) { _, _ in state?.restartPool() }
        .onChange(of: enableNetworking) { _, _ in state?.restartPool() }
        .onChange(of: enableAudio) { _, _ in state?.restartPool() }
        .onChange(of: enableWarp) { _, _ in state?.restartPool() }
        .onChange(of: enableAdBlocking) { _, _ in state?.restartPool() }
        .onChange(of: appearance) { _, _ in state?.restartPool() }
        .onChange(of: homePage) { _, _ in state?.restartPool() }

        Text("Changes take effect immediately by restarting the pre-warmed VM.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 8)
    }
}
