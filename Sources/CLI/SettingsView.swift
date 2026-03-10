import SwiftUI
import SandboxEngine

struct SettingsView: View {
    @AppStorage("vm.memoryGB") private var memoryGB = 2
    @AppStorage("vm.cpuCount") private var cpuCount = 0
    @AppStorage("vm.enableAudio") private var enableAudio = true
    @AppStorage("vm.swapCmdCtrl") private var swapCmdCtrl = true
    @AppStorage("vm.appearance") private var appearance = "system"

    var state: AppState?
    @State private var showResetConfirm = false
    @State private var showRebuildConfirm = false
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
                .help("RAM allocated to the VM. 2 GB is recommended for most browsing.")

                Picker("CPU Cores", selection: $cpuCount) {
                    Text("Automatic (\(autoCPU))").tag(0)
                    ForEach(1...ProcessInfo.processInfo.processorCount, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }

                Toggle("Audio", isOn: $enableAudio)
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

                Toggle("Use Command as Control", isOn: $swapCmdCtrl)
                    .help("Swap Command and Control keys so macOS shortcuts work in Chromium.")
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
        .frame(width: 450, height: 480)
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

        .onChange(of: memoryGB) { _, _ in state?.restartPool() }
        .onChange(of: cpuCount) { _, _ in state?.restartPool() }
        .onChange(of: enableAudio) { _, _ in state?.restartPool() }

        Text("Changes restart the pre-warmed VM.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 8)
    }
}
