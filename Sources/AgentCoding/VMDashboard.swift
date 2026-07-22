#if os(macOS)
import AppKit
#endif
import SwiftUI
import Charts

/// A professional dashboard for a single workspace VM, shown in the stage when
/// its name is selected in the source list (mirrors `DockerDashboardView`'s look
/// and reuses its `StatCard` / `CPUStatCard`). Shown for ANY run state — a
/// running VM gets live vitals; a suspended/off one still shows the machine spec
/// and the profile config (so the config is useful even with no framebuffer).
struct VMDashboardView: View {
    /// nil when the VM isn't running (no live vitals available).
    let model: TabsModel?
    let profile: Profile
    let accentHex: String
    let state: SessionListModel.RunState
    let vCPUs: Int
    let diskAllocatedBytes: Int64
    let diskCapacityBytes: Int64
    let startedAt: Date?
    let onNewTerminal: () -> Void
    let onSuspend: () -> Void
    let onReboot: () -> Void
    let onShutdown: () -> Void
    /// Start (off) / Resume (suspended).
    let onResume: () -> Void

    @State private var cpuHistory: [Double] = []
    @State private var now = Date()
    /// Compact = iPhone portrait; drives the phone-friendly stacked layout.
    /// Always `.regular` on macOS, so the desktop layout is unchanged.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    private var accent: Color { Color(hex: accentHex) }
    private var isRunning: Bool { state == .running || state == .booting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statStrip
                configCard
                if isRunning && !externalPorts.isEmpty { portsCard }
            }
            .padding(18)
        }
        .background(.background)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
            cpuHistory.append(model?.vmCPU ?? 0)
            if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
        }
    }

    // MARK: Header

    private var header: some View {
        // On a phone the identity row and the action buttons each need the full
        // width, so they stack; on macOS/iPad they sit side by side.
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                identityBadge
                identityText
                Spacer()
                if !compact { actionBar }
            }
            if compact { actionBar }
        }
    }

    private var identityBadge: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [accent, accent.opacity(0.6)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 48, height: 48)
            .overlay(Image(systemName: "server.rack")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(.white))
            .shadow(color: accent.opacity(0.35), radius: 5, y: 2)
    }

    private var identityText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(profile.name).font(.system(size: 20, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 8) {
                statePill
                if let ip = model?.ipAddress, !ip.isEmpty {
                    Label(ip, systemImage: "network")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
        }
    }

    private var statePill: some View {
        HStack(spacing: 5) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            Text(stateLabel).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(stateColor.opacity(0.14)))
        .foregroundStyle(stateColor)
    }

    @ViewBuilder private var actionBar: some View {
        if isRunning {
            let newTerminal = Button { onNewTerminal() } label: {
                Label("New Terminal", systemImage: "plus").fillWidth(compact)
            }.buttonStyle(.borderedProminent)
            let suspend = Button { onSuspend() } label: {
                Label("Suspend", systemImage: "pause.fill").fillWidth(compact)
            }.buttonStyle(.bordered).help("Save the VM's state to disk")
            let reboot = Button { onReboot() } label: {
                Label("Reboot", systemImage: "arrow.clockwise").fillWidth(compact)
            }.buttonStyle(.bordered)
            let shutdown = Button(role: .destructive) { onShutdown() } label: {
                Label("Shut Down", systemImage: "power").fillWidth(compact)
            }.buttonStyle(.bordered)

            Group {
                if compact {
                    // Two full-width rows so the labels stay legible on a phone.
                    VStack(spacing: 8) {
                        HStack(spacing: 8) { newTerminal; suspend }
                        HStack(spacing: 8) { reboot; shutdown }
                    }
                } else {
                    HStack(spacing: 8) { newTerminal; suspend; reboot; shutdown }
                }
            }
            .controlSize(compact ? .large : .regular)
            .labelStyle(.titleAndIcon)
        } else {
            Button { onResume() } label: {
                Label(state == .suspended ? "Resume" : "Start", systemImage: "play.fill").fillWidth(compact)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .large : .regular)
            .labelStyle(.titleAndIcon)
        }
    }

    // MARK: Vitals

    @ViewBuilder private var statStrip: some View {
        // A phone can't fit five cards across, so they wrap into a 2-column grid;
        // macOS/iPad keep the single row.
        if compact {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                statCards
            }
        } else {
            HStack(spacing: 12) { statCards }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statCards: some View {
        if isRunning {
            CPUStatCard(value: model?.vmCPU ?? 0, history: cpuHistory, tint: accent)
            StatCard(title: "Memory", value: gb(model?.vmMemUsedKB ?? 0),
                     caption: "of \(profile.memoryGB) GB",
                     systemImage: "memorychip.fill", tint: .purple)
        } else {
            StatCard(title: "CPU", value: "—", caption: stateCaption,
                     systemImage: "cpu.fill", tint: accent)
            StatCard(title: "Memory", value: "\(profile.memoryGB) GB", caption: "allocated",
                     systemImage: "memorychip.fill", tint: .purple)
        }
        StatCard(title: "vCPUs", value: "\(vCPUs)",
                 caption: isRunning ? "load \(String(format: "%.2f", model?.vmLoad ?? 0))" : "cores",
                 systemImage: "cpu.fill", tint: .blue)
        // Prefer the GUEST's df numbers (the filesystem's own truth) over
        // the host-side CoW clone allocation, which overstates real usage
        // — blocks the guest FS freed stay materialized in the clone.
        // Fall back to allocation while off / before the first report.
        if isRunning, let m = model, m.vmDiskTotalKB > 0 {
            StatCard(title: "Disk", value: gb(m.vmDiskUsedKB),
                     caption: "of \(gb(m.vmDiskTotalKB))",
                     systemImage: "internaldrive.fill", tint: .teal)
        } else {
            StatCard(title: "Disk", value: gbBytes(diskAllocatedBytes),
                     caption: "of \(gbBytes(diskCapacityBytes)) (host)",
                     systemImage: "internaldrive.fill", tint: .teal)
        }
        StatCard(title: "Uptime", value: isRunning ? uptimeText : "—",
                 caption: isRunning ? "since boot" : stateCaption,
                 systemImage: "clock.fill", tint: .orange)
    }

    // MARK: Listening ports

    @State private var copiedEndpoint: String?

    /// Externally-reachable listening sockets (loopback-bound ones are inside-VM
    /// only, so they're hidden here), deduped across the v4/v6 wildcard pair —
    /// preferring the entry that carries a process name.
    private var externalPorts: [ListeningPort] {
        var byKey: [String: ListeningPort] = [:]
        for p in (model?.vmListeningPorts ?? []) where !p.isLoopback {
            let key = "\(p.port)/\(p.proto)"
            if let existing = byKey[key], !existing.process.isEmpty { continue }
            byKey[key] = p
        }
        return byKey.values.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
    }

    /// The address a user would actually connect to: wildcard binds are
    /// reachable on the VM's IP; a specific bind names itself.
    private func endpoint(_ p: ListeningPort) -> String {
        let host = (p.addr == "0.0.0.0" || p.addr == "[::]")
            ? (model?.ipAddress ?? p.addr) : p.addr
        return "\(host):\(p.port)"
    }

    private func copyEndpoint(_ text: String) {
        platformCopyToPasteboard(text)
        copiedEndpoint = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedEndpoint == text { copiedEndpoint = nil }
        }
    }

    private var portsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Listening Ports")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.6)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            ForEach(Array(externalPorts.enumerated()), id: \.offset) { i, p in
                if i > 0 { Divider().opacity(0.35).padding(.leading, 14) }
                let ep = endpoint(p)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(ep)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                        Button { copyEndpoint(ep) } label: {
                            Image(systemName: copiedEndpoint == ep ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(copiedEndpoint == ep ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy \(ep)")
                        if p.proto == "udp" {
                            Text("udp")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(p.process.isEmpty ? "—" : p.process)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        // HTTP services only: a quick tunnel is browsable for
                        // web origins; raw TCP (ssh, databases, udp) would
                        // need cloudflared on every connecting client.
                        // (cloudflared runs as a local subprocess — macOS only.)
#if os(macOS)
                        if isExposable(p) { exposeButton(p) }
#endif
                    }
#if os(macOS)
                    if isExposable(p),
                       let info = CloudflareTunnelSupervisor.shared.tunnels[exposeID(p)] {
                        tunnelStatusLine(info)
                    }
#endif
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
    }

#if os(macOS)
    // MARK: Internet exposure (Cloudflare quick tunnels)

    private func exposeID(_ p: ListeningPort) -> String {
        "ws:\(profile.id.uuidString):\(p.port)"
    }

    private func isExposable(_ p: ListeningPort) -> Bool {
        p.proto == "tcp"
            && CloudflareTunnelSupervisor.isLikelyWebService(port: p.port, process: p.process)
    }

    /// The globe: click to expose this HTTP service to the internet through
    /// its own Cloudflare quick tunnel; click again to unexpose. One tunnel
    /// (and one random URL) per service — toggling one never disturbs the
    /// others.
    @ViewBuilder private func exposeButton(_ p: ListeningPort) -> some View {
        let info = CloudflareTunnelSupervisor.shared.tunnels[exposeID(p)]
        Button { toggleExposure(p) } label: {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(globeColor(info))
        }
        .buttonStyle(.borderless)
        .disabled((model?.ipAddress ?? "").isEmpty)
        .help(info == nil
              ? "Expose to the internet (Cloudflare quick tunnel)"
              : "Stop exposing to the internet")
    }

    private func globeColor(_ info: CloudflareTunnelSupervisor.Info?) -> Color {
        switch info?.state {
        case nil: return Color.secondary.opacity(0.55)
        case .running: return .green
        case .failed: return .red
        case .installing, .starting: return .orange
        }
    }

    @ViewBuilder private func tunnelStatusLine(_ info: CloudflareTunnelSupervisor.Info) -> some View {
        HStack(spacing: 6) {
            switch info.state {
            case .installing:
                ProgressView().controlSize(.mini)
                Text("Downloading & verifying cloudflared (~18 MB, one-time)…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.mini)
                Text("Starting tunnel…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.red)
                Text(msg).font(.system(size: 10)).foregroundStyle(.red)
                    .lineLimit(2)
            case .running(let host):
                let publicURL = "https://\(host)"
                if let url = URL(string: publicURL) {
                    Link(host, destination: url)
                        .font(.system(size: 10, design: .monospaced))
                } else {
                    Text(host)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button { copyEndpoint(publicURL) } label: {
                    Image(systemName: copiedEndpoint == publicURL ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(copiedEndpoint == publicURL ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy public URL")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private func toggleExposure(_ p: ListeningPort) {
        let sup = CloudflareTunnelSupervisor.shared
        let id = exposeID(p)
        if sup.tunnels[id] != nil {
            sup.unexpose(id)
            return
        }
        guard let ip = model?.ipAddress, !ip.isEmpty else { return }
        guard Self.confirmTunnelConsent() else { return }
        sup.expose(id: id, origin: "http://\(ip):\(p.port)")
    }

    /// One-time consent covering the cloudflared download and Cloudflare's
    /// service terms.
    private static func confirmTunnelConsent() -> Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: "cloudflareTunnel.consented") { return true }
        let a = NSAlert()
        a.messageText = NSLocalizedString("Expose services to the internet via Cloudflare Tunnel?",
                                          comment: "Cloudflare tunnel consent alert title")
        a.informativeText = String(
            format: NSLocalizedString(
                "Bromure will download cloudflared %@ (~18 MB) from GitHub, verify it against a pinned checksum and Cloudflare's Developer ID signature, and run one tunnel process per exposed service (recorded in the Supply Chain Log).\n\nTraffic transits Cloudflare's network under their Terms of Service (cloudflare.com/terms).\n\nEach service gets a random public https://….trycloudflare.com URL — anyone who has it can reach the service, so make sure the service itself expects that. The URL changes if the tunnel restarts.",
                comment: "Cloudflare tunnel consent alert body; %@ = cloudflared version"),
            CloudflaredPin.version)
        a.addButton(withTitle: NSLocalizedString("Agree & Expose", comment: "Cloudflare tunnel consent confirm button"))
        a.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        d.set(true, forKey: "cloudflareTunnel.consented")
        return true
    }
#endif

    // MARK: Configuration

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Configuration")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.6)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            ForEach(Array(configRows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider().opacity(0.35).padding(.leading, 14) }
                HStack(spacing: 10) {
                    Image(systemName: row.icon).font(.system(size: 12))
                        .foregroundStyle(.secondary).frame(width: 18)
                    Text(row.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.value).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
    }

    private struct ConfigRow { let icon: String; let label: String; let value: String }

    private var configRows: [ConfigRow] {
        // One row PER configured tool — each carries its own auth mode and (when
        // local) its own model, so a mixed workspace (e.g. Claude in the cloud +
        // Codex on-device) reads correctly instead of collapsing to the primary.
        var rows: [ConfigRow] = profile.allToolSpecs.map { spec in
            ConfigRow(icon: spec.authMode == .local ? "cpu" : "cloud",
                      label: spec.tool.displayName,
                      value: toolModeText(spec))
        }
        rows.append(.init(icon: "shield.lefthalf.filled",
                          label: NSLocalizedString("Guardrails", comment: "Config row label"),
                          value: guardrailsText))
        rows.append(.init(icon: "lock.shield",
                          label: NSLocalizedString("Prompt-injection scan", comment: "Config row label"),
                          value: promptInjectionOn ? NSLocalizedString("On", comment: "Feature enabled")
                                                   : NSLocalizedString("Off", comment: "Feature disabled")))
        rows.append(.init(icon: "folder.fill",
                          label: NSLocalizedString("Shared folders", comment: "Config row label"),
                          value: foldersText))
        return rows
    }

    // MARK: Derived values

    private var stateLabel: String {
        switch state {
        case .running:   return NSLocalizedString("Running", comment: "VM run-state pill")
        case .booting:   return NSLocalizedString("Booting", comment: "VM run-state pill")
        case .suspended: return NSLocalizedString("Suspended", comment: "VM run-state pill")
        case .off:       return NSLocalizedString("Off", comment: "VM run-state pill")
        }
    }
    /// Lowercase run-state word shown as a stat-card caption while the VM isn't
    /// running (only `suspended` / `off` actually appear).
    private var stateCaption: LocalizedStringKey {
        switch state {
        case .running:   return "running"
        case .booting:   return "booting"
        case .suspended: return "suspended"
        case .off:       return "off"
        }
    }
    private var stateColor: Color {
        switch state {
        case .running:   return .green
        case .booting:   return .orange
        case .suspended: return .blue
        case .off:       return Color.platformTertiaryLabel
        }
    }

    /// Where a tool runs + how it authenticates / which local model it serves.
    private func toolModeText(_ spec: Profile.ToolSpec) -> String {
        if spec.authMode == .local {
            // On macOS resolve the catalog's friendly name; the iOS fat client
            // has no local-model catalog, so it shows the raw model id.
#if os(macOS)
            let model = spec.localModelID.flatMap { CatalogStore.shared.resolve($0)?.name ?? $0 }
#else
            let model = spec.localModelID
#endif
            return String(format: NSLocalizedString("On-device · %@", comment: "Config value: tool runs locally; %@ = model name"),
                          model ?? NSLocalizedString("local model", comment: "Fallback when the local model name is unknown"))
        }
        return String(format: NSLocalizedString("Cloud · %@", comment: "Config value: tool runs in the cloud; %@ = auth mode"),
                      spec.authMode.displayName)
    }
    private var guardrailsText: String {
        let g = profile.guardrails
        let modes = [g.kubernetes, g.aws, g.digitalOcean, g.docker, g.github, g.gitlab, g.bitbucket]
        let active = modes.filter { $0 != .off }
        if active.isEmpty { return NSLocalizedString("Off", comment: "Guardrails disabled") }
        let names = Set(active.map(\.displayName))
        return names.count == 1 ? names.first!
            : String(format: NSLocalizedString("Custom (%d domains)", comment: "Guardrails active on N domains"), active.count)
    }
    private var promptInjectionOn: Bool {
        profile.promptInjection.detectSourceInjection || profile.promptInjection.detectRulesInjection
    }
    private var foldersText: String {
        profile.folderPaths.isEmpty ? NSLocalizedString("None", comment: "No shared folders")
            : profile.folderPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }

    private var uptimeText: String {
        guard let s = startedAt else { return "—" }
        let secs = Int(max(0, now.timeIntervalSince(s)))
        let h = secs / 3600, m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(secs)s"
    }

    /// KB → "N.N GB" / "N MB".
    private func gb(_ kb: Int) -> String {
        let mb = Double(kb) / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
    private func gbBytes(_ b: Int64) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }
}
