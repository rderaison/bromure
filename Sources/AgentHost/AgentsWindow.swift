import AppKit
import SwiftUI

/// "Coding Agents": pick the agents this Mac runs and install or update them
/// with each maker's own installer. Shown once at first launch, then from
/// the menu's "Manage Agents…".
@MainActor
final class AgentsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AgentsWindowController()
    static let introShownKey = "agents.intro.shown"
    /// Run as `__agents`: closing the window quits.
    static var standalone = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 740),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Coding Agents"
        window.contentView = NSHostingView(rootView: AgentsView(installer: .shared) { window.performClose(nil) })
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        AgentInstaller.shared.scan()
        NSApp.setActivationPolicy(.regular)   // a real window: Dock icon, ⌘-Tab
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // `__agents` with BROMURE_AGENTS_SHOT=<png>: the window drawn to a
        // file once the scan settles (design checks without screen access).
        if Self.standalone, let out = ProcessInfo.processInfo.environment["BROMURE_AGENTS_SHOT"],
           let view = window?.contentView {
            let env = ProcessInfo.processInfo.environment
            if let ids = env["BROMURE_AGENTS_INSTALL"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    AgentInstaller.shared.install(ids.split(separator: ",").map(String.init))
                }
            }
            let delay = Double(env["BROMURE_AGENTS_SHOT_DELAY"] ?? "") ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        }
    }

    /// First launch only; later, from the menu.
    func showIntroIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.introShownKey) else {
            AgentInstaller.shared.scan()   // the session guard's knowledge
            return
        }
        UserDefaults.standard.set(true, forKey: Self.introShownKey)
        show()
    }

    func windowWillClose(_ notification: Notification) {
        if Self.standalone { NSApp.terminate(nil) }
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Views

/// Snapshots can't draw Liquid Glass: BROMURE_AGENTS_SHOT draws the material fallback.
private let agentsNoGlass = ProcessInfo.processInfo.environment["BROMURE_AGENTS_SHOT"] != nil

private struct AgentsView: View {
    @ObservedObject var installer: AgentInstaller
    let close: () -> Void
    @State private var selected: Set<String> = []
    @State private var seeded = false
    @State private var logFor: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 34)
                .padding(.bottom, 20)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(AgentSpec.all) { spec in
                        AgentCard(spec: spec, phase: installer.phase(spec.id),
                                  selected: selected.contains(spec.id),
                                  locked: installer.busy,
                                  log: installer.logs[spec.id] ?? "",
                                  showLog: logFor == spec.id,
                                  toggle: { toggle(spec.id) },
                                  toggleLog: { logFor = logFor == spec.id ? nil : spec.id })
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(.bar)
        }
        .frame(minWidth: 660, minHeight: 740)
        .background(VisualEffect().ignoresSafeArea())
        .onChange(of: installer.scanning) { _, scanning in
            // Once we know what's here: Claude is preselected when it's missing.
            guard !scanning, !seeded else { return }
            seeded = true
            if installer.phase("claude") == .missing { selected.insert("claude") }
        }
        .onChange(of: installer.busy) { _, busy in
            if !busy { selected.removeAll() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.98),
                                                  Color(red: 0.62, green: 0.33, blue: 0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: .purple.opacity(0.3), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Coding Agents")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Choose the agents this Mac runs. Each one is downloaded from its maker with their own installer, into your account. Bromure doesn't bundle or host any of them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if installer.scanning {
                ProgressView().controlSize(.small).padding(.top, 8)
            } else {
                Button { installer.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Check again")
                    .padding(.top, 8)
                    .disabled(installer.busy)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("Installers run as you, with no administrator rights. Most agents update themselves after that.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(installer.busy ? "Hide" : "Done", action: close)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            primaryButton
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let button = Button(action: { installer.install(order(selected)) }) {
            HStack(spacing: 6) {
                if installer.busy { ProgressView().controlSize(.small) }
                Text(primaryTitle).fontWeight(.semibold)
            }
            .padding(.horizontal, 6)
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
        .disabled(selected.isEmpty || installer.busy)
        if #available(macOS 26.0, *), !agentsNoGlass {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var primaryTitle: String {
        if installer.busy { return "Installing…" }
        let updates = selected.filter { if case .installed = installer.phase($0) { return true }; return false }.count
        let installs = selected.count - updates
        switch (installs, updates) {
        case (0, 0): return "Install"
        case (let n, 0): return n == 1 ? "Install 1 Agent" : "Install \(n) Agents"
        case (0, let n): return n == 1 ? "Update 1 Agent" : "Update \(n) Agents"
        default: return "Install & Update \(selected.count)"
        }
    }

    private func toggle(_ id: String) {
        guard !installer.busy else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func order(_ ids: Set<String>) -> [String] {
        AgentSpec.all.map(\.id).filter(ids.contains)
    }
}

private struct AgentCard: View {
    let spec: AgentSpec
    let phase: AgentInstaller.Phase
    let selected: Bool
    let locked: Bool
    let log: String
    let showLog: Bool
    let toggle: () -> Void
    let toggleLog: () -> Void
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                checkmark
                logo
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(spec.name).font(.system(size: 15, weight: .semibold))
                        Text(spec.maker).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(spec.blurb)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    detail.padding(.top, 4)
                }
                Spacer(minLength: 8)
                StatusPill(phase: phase)
            }
            if showLog && !log.isEmpty {
                ScrollView {
                    Text(log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.25)))
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.primary.opacity(hover ? 0.14 : 0.07),
                              lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.2), value: selected)
        .animation(.snappy(duration: 0.2), value: phase)
        .opacity(locked && !isActive ? 0.6 : 1)
    }

    private var isActive: Bool {
        switch phase { case .queued, .installing: return true; default: return false }
    }

    @ViewBuilder private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *), !agentsNoGlass {
            Color.clear.glassEffect(.regular.tint(selected ? Color.accentColor.opacity(0.12) : .clear), in: shape)
        } else {
            shape.fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.regularMaterial))
        }
    }

    private var checkmark: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                .background(Circle().fill(selected ? Color.accentColor : .clear))
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 20, height: 20)
        .padding(.top, 12)
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: spec.tint).opacity(0.85), Color(nsColor: spec.tint)],
                                     startPoint: .top, endPoint: .bottom))
            if let img = spec.logo {
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .padding(9)
            } else {
                Text(spec.name.prefix(1)).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
        .shadow(color: Color(nsColor: spec.tint).opacity(0.35), radius: 6, y: 3)
    }

    /// The command that runs (it's the whole story), or what it's doing now.
    @ViewBuilder private var detail: some View {
        switch phase {
        case .installing(let line):
            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            logButton
        case .failed(let why):
            Text(why)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            logButton
        default:
            HStack(spacing: 6) {
                Text(spec.installCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(spec.installCommand, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Copy the command")
                if !log.isEmpty { logButton }
            }
        }
    }

    private var logButton: some View {
        Button(showLog ? "Hide Output" : "Show Output", action: toggleLog)
            .buttonStyle(.link)
            .font(.caption)
    }
}

private struct StatusPill: View {
    let phase: AgentInstaller.Phase

    var body: some View {
        HStack(spacing: 5) {
            switch phase {
            case .unknown:
                ProgressView().controlSize(.mini)
                Text("Checking")
            case .missing:
                Text("Not installed")
            case .installed(let version, _):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(version)
            case .queued:
                Image(systemName: "clock")
                Text("Queued")
            case .installing:
                ProgressView().controlSize(.mini)
                Text("Installing")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Failed")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
