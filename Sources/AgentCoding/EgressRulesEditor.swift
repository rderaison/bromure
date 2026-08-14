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

    private let actions = ["allow", "deny", "web"]
    private let protos = ["tcp", "udp", "any"]

    private var validationError: String? {
        do { _ = try EgressPolicy.parse(pfText); return nil }
        catch let e as EgressPolicy.ParseError { return "Line \(e.line): \(e.message)" }
        catch { return "\(error)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Outbound connections").font(.headline)
            Text("Allow or deny the VM's TCP/UDP connections by host, IP/CIDR, protocol and port — matched top to bottom, first match wins. A **web** rule allows the site but lets you restrict HTTP methods (e.g. read-only, or GET,POST). Enforced host-side, so a compromised agent can't bypass it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("Unmatched traffic", selection: $defaultAllow) {
                Text("Allow + log").tag(true)
                Text("Deny (allowlist)").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            if !rows.isEmpty {
                HStack(spacing: 6) {
                    Text("Action").frame(width: 66, alignment: .leading)
                    Text("Proto").frame(width: 56, alignment: .leading)
                    Text("Host / CIDR").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Ports").frame(width: 84, alignment: .leading)
                    Text("Methods").frame(width: 128, alignment: .leading)
                    Spacer().frame(width: 66)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }

            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    Picker("", selection: $row.action) { ForEach(actions, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: 66)
                    Picker("", selection: $row.proto) { ForEach(protos, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: 56).disabled(row.action == "web")
                    TextField("any / example.com / 10.0.0.0/8", text: $row.host).frame(maxWidth: .infinity)
                    TextField("any", text: $row.ports).frame(width: 84)
                    TextField(row.action == "web" ? "read-only / GET,POST" : "—", text: $row.methods)
                        .frame(width: 128).disabled(row.action != "web")
                    HStack(spacing: 2) {
                        Button { move(row, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { move(row, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }.frame(width: 66)
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

    private func move(_ row: EgressPolicy.EditRow, by delta: Int) {
        guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let j = i + delta
        guard rows.indices.contains(j) else { return }
        rows.swapAt(i, j)
    }
}
