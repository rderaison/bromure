import SwiftUI
import SandboxEngine

// MARK: - Settings Category

private enum AppSettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case hardware = "Hardware"
    case input = "Input"
    case display = "Display"
    case network = "Network"
    case automation = "Automation"
    case storage = "Storage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .hardware: "cpu.fill"
        case .input: "keyboard.fill"
        case .display: "display"
        case .network: "network"
        case .automation: "terminal.fill"
        case .storage: "internaldrive.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: .gray
        case .hardware: .orange
        case .input: .blue
        case .display: .purple
        case .network: .green
        case .automation: .indigo
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
    @AppStorage("vm.extraKernelOptions") private var extraKernelOptions = VMConfig.defaultExtraKernelOptions
    @AppStorage("vm.energyMode") private var energyMode = EnergyMode.default.rawValue
    @AppStorage("automation.enabled") private var automationEnabled = false
    @AppStorage("automation.port") private var automationPort = 9222
    @AppStorage("automation.bindAddress") private var automationBindAddress = "127.0.0.1"
    @AppStorage("links.defaultProfileID") private var defaultProfileID = ""

    var state: AppState?

    @State private var selectedCategory: AppSettingsCategory = .general
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
        .onChange(of: extraKernelOptions) { _, _ in state?.restartPool() }
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
        case .general: generalView
        case .hardware: hardwareView
        case .input: inputView
        case .display: displayView
        case .network: networkView
        case .automation: automationView
        case .storage: storageView
        }
    }

    // MARK: - General

    private var generalView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("General", subtitle: "App-wide preferences")

            VStack(alignment: .leading, spacing: 6) {
                Text("Default Profile for Links").font(.headline)
                Text("When Bromure is your default browser, links clicked in other apps open with this profile. Choose \u{201C}Ask Every Time\u{201D} to pick a profile on each click.")
                    .settingDescription()
                Picker("", selection: $defaultProfileID) {
                    Text("Ask Every Time").tag("")
                    ForEach(state?.profileManager.allProfiles ?? []) { profile in
                        Text(profile.name).tag(profile.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }
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

            settingsDivider

            VStack(alignment: .leading, spacing: 6) {
                Text("Energy Mode").font(.headline)
                Text("Controls when idle browser sessions pause to save battery. Automatic follows your Mac\u{2019}s Low Power Mode. Low Power pauses after 3 minutes of inactivity regardless. High Power never pauses.")
                    .settingDescription()
                Picker("", selection: $energyMode) {
                    Text("High Power").tag(EnergyMode.highPower.rawValue)
                    Text("Automatic").tag(EnergyMode.automatic.rawValue)
                    Text("Low Power").tag(EnergyMode.lowPower.rawValue)
                }
                .labelsHidden()
                .frame(width: 200)
            }

            settingsDivider

            kernelOptionsView

            Spacer()

            Text("Changes take effect when the next browser session starts.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var kernelOptionsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kernel Boot Options").font(.headline)
            Text("Additional Linux kernel command-line parameters appended to the virtual machine boot command. The default disables SME to work around a crash on Apple M4 processors.")
                .settingDescription()
            TextField("", text: $extraKernelOptions)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity)

            if extraKernelOptions != VMConfig.defaultExtraKernelOptions {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Incorrect kernel options will prevent the browser from booting.")
                            .font(.callout.bold())
                        Text("Only change this if you know what you are doing. Removing arm64.nosme may cause crashes on M4 Macs. Invalid options may prevent the browser from booting.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.3), lineWidth: 1))

                Button("Reset to Default") {
                    extraKernelOptions = VMConfig.defaultExtraKernelOptions
                }
                .controlSize(.small)
            }
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
                Text("Match your Mac\u{2019}s display. Use 2x for Retina screens (most modern Macs).")
                    .settingDescription()
                Picker("", selection: $displayScale) {
                    Text("1x (Standard)").tag(1)
                    Text("2x (Retina)").tag(2)
                }
                .labelsHidden()
                .frame(width: 200)
                .onChange(of: displayScale) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "vm.displayScale")
                    state?.restartPool()
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

    // MARK: - Automation

    private var automationView: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Automation", subtitle: "Remote browser control via HTTP API, CDP, and MCP")

            settingToggle(
                "Enable Automation",
                description: "Start an HTTP server that lets external tools (Puppeteer, Playwright, Claude Code, Codex) create browser sessions and control them via CDP.",
                isOn: $automationEnabled
            )

            if automationEnabled {
                settingsDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Port").font(.headline)
                    Text("The port for the automation API server. Tools connect here to list profiles, create sessions, and get CDP endpoints.")
                        .settingDescription()
                    TextField("Port", text: Binding(
                        get: { String(automationPort) },
                        set: { automationPort = Int($0) ?? automationPort }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                settingsDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Bind Address").font(.headline)
                    Text("Use 127.0.0.1 to only allow connections from this Mac. Use 0.0.0.0 to allow connections from other machines on the network.")
                        .settingDescription()
                    Picker("", selection: $automationBindAddress) {
                        Text("127.0.0.1 (localhost only)").tag("127.0.0.1")
                        Text("0.0.0.0 (all interfaces)").tag("0.0.0.0")
                    }
                    .labelsHidden()
                    .frame(width: 280)

                    if automationBindAddress == "0.0.0.0" {
                        Label {
                            Text("Binding to all interfaces exposes the automation API to your entire network. Anyone on your LAN can create browser sessions, execute JavaScript, and take screenshots. Only use this on trusted networks.")
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage").font(.headline)
                    Text("Once enabled, external tools can connect to the API:")
                        .settingDescription()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("List profiles:").font(.callout.bold())
                        Text(verbatim: "curl http://127.0.0.1:\(automationPort)/profiles")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Text("Create session:").font(.callout.bold()).padding(.top, 4)
                        Text(verbatim: "curl -X POST http://127.0.0.1:\(automationPort)/sessions -d '{\"profile\":\"Private Browsing\"}'")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Text("List sessions:").font(.callout.bold()).padding(.top, 4)
                        Text(verbatim: "curl http://127.0.0.1:\(automationPort)/sessions")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Text("Close session:").font(.callout.bold()).padding(.top, 4)
                        Text(verbatim: "curl -X DELETE http://127.0.0.1:\(automationPort)/sessions/<id>")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }

                settingsDivider

                apiReferenceView

                settingsDivider

                VStack(alignment: .leading, spacing: 8) {
                    Text("MCP Server").font(.headline)
                    Text("Bromure includes a built-in MCP server for Claude Code, Openclaws, and other MCP-compatible AI tools. Add this to your MCP configuration:")
                        .settingDescription()

                    let bromurePath = Bundle.main.executablePath ?? "/Applications/Bromure.app/Contents/MacOS/bromure"

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(".mcp.json").font(.callout.bold())
                            Spacer()
                            copyButton(text: """
                            {
                              "mcpServers": {
                                "bromure": {
                                  "command": "\(bromurePath)",
                                  "args": ["mcp"]
                                }
                              }
                            }
                            """, id: "mcp")
                        }
                        Text("""
                        {
                          "mcpServers": {
                            "bromure": {
                              "command": "\(bromurePath)",
                              "args": ["mcp"]
                            }
                          }
                        }
                        """)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                    Text("Add --debug to the args to include VM shell access and app state tools.")
                        .settingDescription()
                }
            }
        }
    }

    @State private var copiedID: String?

    private func copyButton(text: String, id: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedID = nil }
        } label: {
            Image(systemName: copiedID == id ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    private func apiRow(_ method: String, _ path: String, _ description: LocalizedStringKey, example: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(method)
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(method == "GET" ? Color.green : method == "POST" ? Color.blue : method == "DELETE" ? Color.red : Color.purple, in: RoundedRectangle(cornerRadius: 3))
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                Spacer()
                if let cmd = example {
                    copyButton(text: cmd, id: path)
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var apiReferenceView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Reference").font(.headline)
            Text("HTTP endpoints available when automation is enabled:")
                .settingDescription()

            let base = "http://\(automationBindAddress):\(automationPort)"

            VStack(alignment: .leading, spacing: 6) {
                apiRow("GET", "/health", "Health check",
                       example: "curl \(base)/health")
                Divider()
                apiRow("GET", "/profiles", "List available profiles",
                       example: "curl \(base)/profiles")
                Divider()
                apiRow("GET", "/sessions", "List active sessions",
                       example: "curl \(base)/sessions")
                Divider()
                apiRow("POST", "/sessions", "Create a new browser session",
                       example: "curl -X POST \(base)/sessions -d '{\"profile\":\"Work\"}'")
                Divider()
                apiRow("GET", "/sessions/:id", "Get session info",
                       example: "curl \(base)/sessions/<id>")
                Divider()
                apiRow("DELETE", "/sessions/:id", "Close a session",
                       example: "curl -X DELETE \(base)/sessions/<id>")
                Divider()
                apiRow("GET", "/sessions/:id/trace", "Get session trace events",
                       example: "curl \(base)/sessions/<id>/trace")
                Divider()
                apiRow("WS", "/cdp/:id/...", "Chrome DevTools Protocol WebSocket proxy")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
