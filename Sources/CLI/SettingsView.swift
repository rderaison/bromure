import SwiftUI
import SandboxEngine

// MARK: - Settings Category

private enum AppSettingsCategory: String, CaseIterable, Identifiable {
    case hardware = "Hardware"
    case input = "Input"
    case display = "Display"
    case network = "Network"
    case storage = "Storage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .hardware: "cpu.fill"
        case .input: "keyboard.fill"
        case .display: "display"
        case .network: "network"
        case .storage: "internaldrive.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .hardware: .orange
        case .input: .blue
        case .display: .purple
        case .network: .green
        case .storage: .gray
        }
    }
}

// MARK: - Main View

struct SettingsView: View {
    @AppStorage("vm.memoryGB") private var memoryGB = 2
    @AppStorage("vm.cpuCount") private var cpuCount = 0
    // Audio moved to per-profile (ProfileSettings.enableAudio)
    @AppStorage("vm.swapCmdCtrl") private var swapCmdCtrl = true
    @AppStorage("vm.appearance") private var appearance = "system"
    @AppStorage("vm.dnsServers") private var dnsServers = ""
    @AppStorage("vm.networkMode") private var networkMode = "nat"
    @AppStorage("vm.bridgedInterface") private var bridgedInterface = ""

    var state: AppState?

    @State private var selectedCategory: AppSettingsCategory = .hardware
    @State private var showResetConfirm = false
    @State private var showRebuildConfirm = false
    @State private var pendingKeyboard: String?
    @State private var pendingScrolling: Bool?
    @State private var pendingDisplayScale: Int?

    @State private var keyboardLayout: String = ""
    @State private var naturalScrolling: Bool = true
    @State private var displayScale: Int = 2

    private var autoCPU: Int {
        let mem = memoryGB > 0 ? memoryGB : 2
        return min(max(2, mem * 2), ProcessInfo.processInfo.processorCount)
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
        HStack(spacing: 0) {
            // Sidebar
            List(AppSettingsCategory.allCases, selection: $selectedCategory) { category in
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
            .frame(width: 160)

            Divider()

            // Detail
            ScrollView {
                detailView
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 620, height: 480)
        .onAppear {
            keyboardLayout = state?.currentKeyboardLayout ?? VMConfig.detectKeyboardLayout()
            naturalScrolling = state?.currentNaturalScrolling ?? VMConfig.detectNaturalScrolling()
            displayScale = state?.currentDisplayScale ?? VMConfig.detectDisplayScale()
        }
        .onChange(of: memoryGB) { _, _ in state?.restartPool() }
        .onChange(of: cpuCount) { _, _ in state?.restartPool() }
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
    }

    // MARK: - Detail Router

    @ViewBuilder
    private var detailView: some View {
        switch selectedCategory {
        case .hardware: hardwareView
        case .input: inputView
        case .display: displayView
        case .network: networkView
        case .storage: storageView
        }
    }

    // MARK: - Hardware

    private var hardwareView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Hardware", subtitle: "Resources allocated to each browser session")

            VStack(alignment: .leading, spacing: 6) {
                Text("Memory").font(.headline)
                Text("How much RAM each browser gets. 2 GB works for most websites. Increase to 4 GB or more for heavy web apps.")
                    .settingDescription()
                Picker("", selection: $memoryGB) {
                    Text("1 GB").tag(1)
                    Text("2 GB").tag(2)
                    Text("3 GB").tag(3)
                    Text("4 GB").tag(4)
                    Text("8 GB").tag(8)
                    Text("16 GB").tag(16)
                }
                .labelsHidden()
                .frame(width: 200)
            }

            settingsDivider

            VStack(alignment: .leading, spacing: 6) {
                Text("CPU Cores").font(.headline)
                Text("Number of processor cores available to the browser. Automatic scales with memory (2 cores per GB), up to the number of cores on this Mac.")
                    .settingDescription()
                Picker("", selection: $cpuCount) {
                    Text("Automatic (\(autoCPU))").tag(0)
                    ForEach(1...ProcessInfo.processInfo.processorCount, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            Spacer()

            Text("Changes take effect when the next browser session starts.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Input

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Input", subtitle: "Keyboard and trackpad settings")

            VStack(alignment: .leading, spacing: 6) {
                Text("Keyboard Layout").font(.headline)
                Text("Match this to your physical keyboard. Changing the layout requires rebuilding the base image.")
                    .settingDescription()
                Picker("", selection: $keyboardLayout) {
                    ForEach(Self.keyboardLayouts, id: \.value) { layout in
                        Text(layout.label).tag(layout.value)
                    }
                }
                .labelsHidden()
                .frame(width: 250)
                .onChange(of: keyboardLayout) { _, newValue in
                    let current = state?.currentKeyboardLayout ?? "us"
                    if newValue != current {
                        pendingKeyboard = newValue
                        showRebuildConfirm = true
                    }
                }
            }

            settingsDivider

            settingToggle(
                "Natural Scrolling",
                description: "Scroll content in the same direction as your finger moves on the trackpad, matching the macOS default.",
                isOn: $naturalScrolling
            )
            .onChange(of: naturalScrolling) { _, newValue in
                let current = state?.currentNaturalScrolling ?? true
                if newValue != current {
                    pendingScrolling = newValue
                    showRebuildConfirm = true
                }
            }

            settingsDivider

            settingToggle(
                "Use Command as Control",
                description: "Makes familiar shortcuts like \u{2318}C, \u{2318}V, and \u{2318}T work inside the browser by swapping the Command and Control keys.",
                isOn: $swapCmdCtrl
            )
        }
    }

    // MARK: - Display

    private var displayView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Display", subtitle: "Screen and appearance settings")

            VStack(alignment: .leading, spacing: 6) {
                Text("Scale Factor").font(.headline)
                Text("Match your Mac\u{2019}s display. Use 2x for Retina screens (most modern Macs). Changing this requires rebuilding the base image.")
                    .settingDescription()
                Picker("", selection: $displayScale) {
                    Text("1x (Standard)").tag(1)
                    Text("2x (Retina)").tag(2)
                }
                .labelsHidden()
                .frame(width: 200)
                .onChange(of: displayScale) { _, newValue in
                    let current = state?.currentDisplayScale ?? 2
                    if newValue != current {
                        pendingDisplayScale = newValue
                        showRebuildConfirm = true
                    }
                }
            }

            settingsDivider

            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance").font(.headline)
                Text("Controls whether the browser uses a light or dark color scheme. \u{201c}Same as System\u{201d} follows your Mac\u{2019}s current setting.")
                    .settingDescription()
                Picker("", selection: $appearance) {
                    Text("Same as System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }

    // MARK: - Network

    private var networkView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Network", subtitle: "Connection mode and DNS settings")

            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You probably don\u{2019}t need to change anything here.")
                        .font(.callout.bold())
                    Text("These settings are only useful if you\u{2019}re having trouble during installation or if a VPN, firewall, or other local software is preventing the browser from connecting to the internet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.yellow.opacity(0.3), lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                Text("Connection Mode").font(.headline)
                Text("NAT (recommended) gives the browser its own private network address. Bridged mode places the browser directly on your network, as if it were a separate device.")
                    .settingDescription()
                Picker("", selection: $networkMode) {
                    Text("NAT (Recommended)").tag("nat")
                    Text("Bridged").tag("bridged")
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .onChange(of: networkMode) { _, _ in state?.restartPool() }
            }

            if networkMode == "bridged" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Network Interface").font(.headline)
                    Text("Choose which network connection the browser should use. Typically this is your Wi-Fi or Ethernet adapter.")
                        .settingDescription()
                    let interfaces = VMConfig.bridgedInterfaces()
                    if interfaces.isEmpty {
                        Text("No network interfaces available.")
                            .font(.callout)
                            .foregroundStyle(.red)
                    } else {
                        Picker("", selection: $bridgedInterface) {
                            Text("Select\u{2026}").tag("")
                            ForEach(interfaces) { iface in
                                Text(iface.displayName).tag(iface.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 300)
                        .onChange(of: bridgedInterface) { _, _ in state?.restartPool() }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("LAN isolation and port restriction are not available in bridged mode.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            settingsDivider

            VStack(alignment: .leading, spacing: 6) {
                Text("DNS Servers").font(.headline)
                Text("Override which DNS servers the browser uses to look up website addresses. Leave empty to use the default. Set this if you\u{2019}re on a VPN or security software that breaks internet access in the browser.")
                    .settingDescription()
                TextField("e.g. 1.1.1.1, 8.8.8.8", text: $dnsServers)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onChange(of: dnsServers) { _, _ in state?.restartPool() }

                if networkMode == "bridged" {
                    Text("DNS override only works in NAT mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Storage

    private var storageView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Storage", subtitle: "Disk usage and base image management")

            VStack(alignment: .leading, spacing: 8) {
                Text("Disk Usage").font(.headline)
                Text("Total disk space used by the base image and all profile data.")
                    .settingDescription()

                HStack {
                    Text(state?.diskUsage ?? "\u{2014}")
                        .font(.system(.title3, design: .rounded).bold())
                }
            }

            settingsDivider

            VStack(alignment: .leading, spacing: 8) {
                Text("Storage Location").font(.headline)
                Text(VMConfig.defaultStorageDirectory.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            settingsDivider

            VStack(alignment: .leading, spacing: 8) {
                Text("Reset").font(.headline)
                Text("Delete the Linux base image. You\u{2019}ll need to run the initial setup again. This does not delete your profile data or settings.")
                    .settingDescription()

                Button("Delete Base Image & Reset\u{2026}", role: .destructive) {
                    showResetConfirm = true
                }
                .controlSize(.small)
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
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            Text(description)
                .settingDescription()
                .padding(.leading, 20)
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
