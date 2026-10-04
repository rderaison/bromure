import SwiftUI
import SandboxEngine

/// Editor for a profile's outbound-connection firewall. Rules are stored as
/// pf-style text (`Profile.egressRules`) but edited as a table; the two stay in
/// sync. Order is precedence (first match wins), so rows can be reordered.
struct EgressRulesEditor: View {
    @Binding var pfText: String

    @State private var rows: [EgressPolicy.EditRow] = []
    @State private var defaultAllow = true
    @State private var showPF = false
    @State private var loaded = false

    /// Fixed column widths; Host is flexible (min `hostMin`).
    private enum Col {
        static let action: CGFloat = 70
        static let proto: CGFloat = 62
        static let hostMin: CGFloat = 140
        static let ports: CGFloat = 56
        static let methods: CGFloat = 92
        static let buttons: CGFloat = 58
    }

    private let actions = ["allow", "deny"]
    private let protos = ["tcp", "udp", "web", "any"]

    private var validationError: String? {
        do { _ = try EgressPolicy.parse(pfText); return nil }
        catch let e as EgressPolicy.ParseError { return "Line \(e.line): \(e.message)" }
        catch { return "\(error)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Outbound connections").font(.headline)
            Text("Allow or deny the VM's connections by host, IP/CIDR, protocol and port — matched top to bottom, first match wins. Use the **web** protocol to control HTTP methods on a host: `allow web api.example.com GET,POST` permits only those verbs, `deny web api.example.com PUT,DELETE` blocks those. Every decision is recorded in the Security Timeline, and enforcement is host-side so a compromised agent can't bypass it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("Unmatched traffic", selection: $defaultAllow) {
                Text("Allow").tag(true)
                Text("Deny").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            // The Host column takes every spare point: it holds the long
            // values (domains, CIDRs). Ports and Methods are short ("any",
            // "443", "GET,POST"), and Methods only exists when a `web` rule
            // does — without one the column is dropped altogether.
            let showMethods = rows.contains { $0.proto == "web" }
            if !rows.isEmpty {
                HStack(spacing: 6) {
                    Text("Action").frame(width: Col.action, alignment: .leading)
                    Text("Proto").frame(width: Col.proto, alignment: .leading)
                    Text("Host / CIDR").frame(minWidth: Col.hostMin, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    Text("Ports").frame(width: Col.ports, alignment: .leading)
                    if showMethods { Text("Methods").frame(width: Col.methods, alignment: .leading) }
                    Spacer().frame(width: Col.buttons)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }

            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    Picker("", selection: $row.action) { ForEach(actions, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: Col.action)
                    Picker("", selection: $row.proto) { ForEach(protos, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: Col.proto)
                    TextField("any / example.com / 10.0.0.0/8", text: $row.host)
                        .frame(minWidth: Col.hostMin, maxWidth: .infinity)
                        .layoutPriority(1)
                        .help(row.host)
                    TextField("any", text: $row.ports).frame(width: Col.ports)
                    if showMethods {
                        TextField(methodsPlaceholder(row), text: $row.methods)
                            .frame(width: Col.methods).disabled(row.proto != "web")
                            .help(row.methods)
                    }
                    HStack(spacing: 0) {
                        Button { move(row, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { move(row, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }.frame(width: Col.buttons)
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            }

            Button { rows.append(EgressPolicy.EditRow()) } label: { Label("Add rule", systemImage: "plus") }
                .buttonStyle(.borderless)

            if let err = validationError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            DisclosureGroup(isExpanded: $showPF) {
                Text(pfText.isEmpty ? "default allow" : pfText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(4)
            } label: {
                Text("pf format").font(.caption)
            }
        }
        .onAppear { if !loaded { load(); loaded = true } }
        .onChange(of: rows) { syncToText() }
        .onChange(of: defaultAllow) { syncToText() }
    }

    private func load() {
        let p = (try? EgressPolicy.parse(pfText)) ?? .allowAll
        rows = p.editRows()
        defaultAllow = p.defaultAction == .allow
    }

    private func syncToText() {
        pfText = EgressPolicy.pfText(rows: rows, defaultAllow: defaultAllow)
    }

    /// Hint text for the Methods field — only meaningful for `web` rules, and
    /// reads the opposite way for allow vs deny (allowlist vs blocklist).
    private func methodsPlaceholder(_ row: EgressPolicy.EditRow) -> String {
        guard row.proto == "web" else { return "—" }
        return row.action == "deny" ? "PUT,DELETE" : "GET,POST"
    }

    private func move(_ row: EgressPolicy.EditRow, by delta: Int) {
        guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let j = i + delta
        guard rows.indices.contains(j) else { return }
        rows.swapAt(i, j)
    }
}
