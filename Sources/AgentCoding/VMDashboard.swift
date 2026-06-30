import SwiftUI
import Charts

/// A professional dashboard for a single workspace VM, shown in the stage when
/// its name is selected in the source list (mirrors `DockerDashboardView`'s look
/// and reuses its `StatCard` / `CPUStatCard`). Live vitals — a CPU sparkline,
/// memory, load — plus the static machine spec and the profile's configuration.
struct VMDashboardView: View {
    let model: TabsModel
    let profile: Profile
    let accentHex: String
    let vCPUs: Int
    let diskAllocatedBytes: Int64
    let diskCapacityBytes: Int64
    let startedAt: Date?
    let onNewTerminal: () -> Void
    let onSuspend: () -> Void
    let onReboot: () -> Void
    let onShutdown: () -> Void

    @State private var cpuHistory: [Double] = []
    @State private var now = Date()

    private var accent: Color { Color(hex: accentHex) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statStrip
                configCard
            }
            .padding(18)
        }
        .background(.background)
        // Sample CPU on a steady cadence so the sparkline keeps moving; also
        // ticks `now` so uptime stays live.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
            cpuHistory.append(model.vmCPU)
            if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "desktopcomputer")
                    .font(.system(size: 20)).foregroundStyle(accent))
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.system(size: 20, weight: .semibold))
                HStack(spacing: 8) {
                    runningPill
                    if let ip = model.ipAddress, !ip.isEmpty {
                        Label(ip, systemImage: "network")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    }
                }
            }
            Spacer()
            actionBar
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { onNewTerminal() } label: { Label("New Terminal", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            Button { onSuspend() } label: { Label("Suspend", systemImage: "pause.fill") }
                .help("Save the VM's state to disk")
            Button { onReboot() } label: { Label("Reboot", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { onShutdown() } label: { Label("Shut Down", systemImage: "power") }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
    }

    private var runningPill: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text("Running").font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.green.opacity(0.14)))
        .foregroundStyle(.green)
    }

    // MARK: Vitals

    private var statStrip: some View {
        HStack(spacing: 12) {
            CPUStatCard(value: model.vmCPU, history: cpuHistory, tint: accent)
            StatCard(title: "Memory",
                     value: gb(model.vmMemUsedKB),
                     caption: "of \(profile.memoryGB) GB",
                     systemImage: "memorychip.fill", tint: .purple)
            StatCard(title: "vCPUs",
                     value: "\(vCPUs)",
                     caption: "load \(String(format: "%.2f", model.vmLoad))",
                     systemImage: "cpu.fill", tint: .blue)
            StatCard(title: "Disk",
                     value: gbBytes(diskAllocatedBytes),
                     caption: "of \(gbBytes(diskCapacityBytes))",
                     systemImage: "internaldrive.fill", tint: .teal)
            StatCard(title: "Uptime",
                     value: uptimeText,
                     caption: "since boot",
                     systemImage: "clock.fill", tint: .orange)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

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
        rows.append(.init(icon: "shield.lefthalf.filled", label: "Guardrails", value: guardrailsText))
        rows.append(.init(icon: "lock.shield", label: "Prompt-injection scan",
                          value: promptInjectionOn ? "On" : "Off"))
        rows.append(.init(icon: "folder.fill", label: "Shared folders", value: foldersText))
        return rows
    }

    // MARK: Derived values

    /// Where a tool runs + how it authenticates / which local model it serves.
    private func toolModeText(_ spec: Profile.ToolSpec) -> String {
        if spec.authMode == .local {
            let model = spec.localModelID.flatMap { CatalogStore.shared.resolve($0)?.name ?? $0 }
            return "On-device · \(model ?? "local model")"
        }
        return "Cloud · \(spec.authMode.displayName)"
    }
    private var guardrailsText: String {
        let g = profile.guardrails
        let modes = [g.kubernetes, g.aws, g.digitalOcean, g.docker, g.github, g.gitlab, g.bitbucket]
        let active = modes.filter { $0 != .off }
        if active.isEmpty { return "Off" }
        let names = Set(active.map(\.displayName))
        return names.count == 1 ? names.first! : "Custom (\(active.count) domains)"
    }
    private var promptInjectionOn: Bool {
        profile.promptInjection.detectSourceInjection || profile.promptInjection.detectRulesInjection
    }
    private var foldersText: String {
        profile.folderPaths.isEmpty ? "None"
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
