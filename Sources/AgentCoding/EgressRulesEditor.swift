import SwiftUI
import AppKit
import SandboxEngine

/// Editor for a profile's outbound-connection firewall. Rules are stored as
/// pf-style text (`Profile.egressRules`) but edited as a table; the two stay in
/// sync. Order is precedence (first match wins), so rows can be reordered.
struct EgressRulesEditor: View {
    @Binding var pfText: String
    /// The workspace being edited — lets the table pick up rule changes made
    /// elsewhere while it's open (a Security Timeline quick action, an expiry).
    var profileID: UUID? = nil
    /// The workspace's "Log allowed connections" choice (nil: automatic).
    var logAllowed: Binding<Bool?>? = nil

    @State private var rows: [EgressPolicy.EditRow] = []
    @State private var defaultAllow = true
    @State private var showPF = false
    @State private var loaded = false
    /// The rules changed outside the editor while it had unsaved edits.
    @State private var externalChange: ExternalChange?

    private enum ExternalChange: Equatable {
        /// Merged into the unsaved edits, rule by rule.
        case merged
        /// Couldn't be merged (the edits don't parse): the saved rules, for
        /// "Reload".
        case conflict(String)
    }

    /// Fixed column widths; Host is flexible (min `hostMin`).
    private enum Col {
        static let toggle: CGFloat = 18
        static let action: CGFloat = 70
        static let proto: CGFloat = 62
        static let hostMin: CGFloat = 140
        static let ports: CGFloat = 56
        static let methods: CGFloat = 92
        static let buttons: CGFloat = 58
        /// Clock + the widest badge / header in the current language
        /// ("jusqu'à l'arrêt", "bis zum Stopp"…), never clipped.
        static let timer: CGFloat = {
            let font = NSFont.systemFont(ofSize: 10)   // SwiftUI .caption2 on macOS
            let labels = [
                NSLocalizedString("until stop", comment: "firewall rule badge: on until the workspace stops"),
                NSLocalizedString("expired", comment: "firewall rule badge"),
                "88h 88m",
            ]
            let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let header = (NSLocalizedString("Time limit", comment: "") as NSString)
                .size(withAttributes: [.font: font]).width
            // clock (~16) + spacing (3) + badge, a little slack.
            return max(64, ceil(max(16 + 3 + widest, header)) + 6)
        }()
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
            Text("Changes apply to a running workspace as soon as you save — no restart. Untick a rule to switch it off without deleting it, or use its clock menu to turn it on for a limited time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("Unmatched traffic", selection: $defaultAllow) {
                Text("Allow").tag(true)
                Text("Deny").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .accessibilityLabel(Text("Unmatched traffic"))

            if let logAllowed {
                VStack(alignment: .leading, spacing: 2) {
                    // AppKit checkbox (like the rule checkboxes): its title is
                    // the AX name out-of-process tools see — SwiftUI's Toggle
                    // exposed none.
                    RuleCheckbox(isOn: Binding(get: { logAllowed.wrappedValue ?? autoLogsAllowed },
                                               set: { logAllowed.wrappedValue = $0 }),
                                 label: NSLocalizedString("Log allowed connections", comment: "firewall pane toggle"),
                                 help: NSLocalizedString("List allowed connections in the Security Timeline too", comment: "firewall pane: Log allowed connections tooltip"),
                                 title: NSLocalizedString("Log allowed connections", comment: "firewall pane toggle"))
                        .fixedSize()
                    Text(NSLocalizedString("Lists the connections the firewall lets through in the Security Timeline too — one row per destination, repeats folded in — so you can block a host from there. Off: only blocked connections are listed. Until you choose, it's on while the workspace has rules.",
                                           comment: "firewall pane: Log allowed connections explanation"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let change = externalChange { externalChangeBanner(change) }

            // The Host column takes every spare point: it holds the long
            // values (domains, CIDRs). Ports and Methods are short ("any",
            // "443", "GET,POST"), and Methods only exists when a `web` rule
            // does — without one the column is dropped altogether.
            let showMethods = rows.contains { $0.proto == "web" }
            if !rows.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: Col.toggle)
                    Text("Action").frame(width: Col.action, alignment: .leading)
                    Text("Proto").frame(width: Col.proto, alignment: .leading)
                    Text("Host / CIDR").frame(minWidth: Col.hostMin, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    Text("Ports").frame(width: Col.ports, alignment: .leading)
                    if showMethods { Text("Methods").frame(width: Col.methods, alignment: .leading) }
                    Text("Time limit").frame(width: Col.timer, alignment: .leading)
                    Spacer().frame(width: Col.buttons)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }

            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    // An AppKit checkbox: it carries the rule as its
                    // accessibility label (AXDescription) for out-of-process
                    // assistive tools — SwiftUI's Toggle exposed no name there.
                    RuleCheckbox(isOn: enabledBinding($row),
                                 label: String(format: NSLocalizedString("Enable rule %@", comment: "firewall rule checkbox accessibility label; %@ = the rule, e.g. allow tcp example.com:443"),
                                               Self.ruleText(row)),
                                 help: row.enabled
                                     ? NSLocalizedString("On — untick to switch this rule off without deleting it", comment: "firewall rule toggle")
                                     : NSLocalizedString("Off — this rule is ignored until you tick it", comment: "firewall rule toggle"))
                        .frame(width: Col.toggle)
                    Group {
                    Picker("Action", selection: $row.action) { ForEach(actions, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: Col.action)
                        .accessibilityLabel(Text("Action"))
                    Picker("Proto", selection: $row.proto) { ForEach(protos, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: Col.proto)
                        .accessibilityLabel(Text("Proto"))
                    TextField("any / example.com / 10.0.0.0/8", text: $row.host)
                        .frame(minWidth: Col.hostMin, maxWidth: .infinity)
                        .layoutPriority(1)
                        .help(row.host)
                        .accessibilityLabel(Text("Host / CIDR"))
                    TextField("any", text: $row.ports).frame(width: Col.ports)
                        .accessibilityLabel(Text("Ports"))
                    if showMethods {
                        TextField(methodsPlaceholder(row), text: $row.methods)
                            .frame(width: Col.methods).disabled(row.proto != "web")
                            .help(row.methods)
                            .accessibilityLabel(Text("Methods"))
                    }
                    }
                    .opacity(row.enabled ? 1 : 0.45)
                    temporaryMenu($row).frame(width: Col.timer, alignment: .leading)
                    HStack(spacing: 0) {
                        Button { move(row, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                            .accessibilityLabel(Text(NSLocalizedString("Move rule up", comment: "firewall rule button accessibility label")))
                        Button { move(row, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                            .accessibilityLabel(Text(NSLocalizedString("Move rule down", comment: "firewall rule button accessibility label")))
                        Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            .accessibilityLabel(Text(NSLocalizedString("Delete rule", comment: "firewall rule button accessibility label")))
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
        .onReceive(NotificationCenter.default.publisher(for: .bromureFirewallRulesChanged)) { note in
            // Saved elsewhere while this editor is open: adopt it, so this
            // (older) copy can't overwrite it on Save.
            guard let profileID, (note.object as? UUID) == profileID,
                  let text = note.userInfo?["rules"] as? String, text != pfText else { return }
            switch Self.adopt(external: text, previous: note.userInfo?["previous"] as? String, editing: pfText) {
            case .replace(let t):
                pfText = t
                load()
            case .merged(let t):
                pfText = t
                load()
                externalChange = .merged
            case .ask:
                externalChange = .conflict(text)
            }
        }
    }

    /// The on/off checkbox. Switching a rule off also ends any time limit;
    /// switching an EXPIRED timed rule back on makes it permanent (otherwise
    /// it would come back already expired).
    private func enabledBinding(_ row: Binding<EgressPolicy.EditRow>) -> Binding<Bool> {
        Binding(get: { row.wrappedValue.enabled && !isExpired(row.wrappedValue) },
                set: { on in
                    row.wrappedValue.enabled = on
                    if !on || isExpired(row.wrappedValue) {
                        row.wrappedValue.expiresAt = nil
                        row.wrappedValue.untilStop = false
                    }
                })
    }

    private func isExpired(_ row: EgressPolicy.EditRow, now: Date = Date()) -> Bool {
        row.expiresAt.map { now >= $0 } ?? false
    }

    /// The per-rule time limit: a clock menu (turn on for 15 min / 1 hour /
    /// until the workspace stops, or make permanent) whose label counts down.
    private func temporaryMenu(_ row: Binding<EgressPolicy.EditRow>) -> some View {
        let r = row.wrappedValue
        let temporary = r.enabled && (r.untilStop || r.expiresAt != nil)
        return HStack(spacing: 3) {
        Menu {
            Button(NSLocalizedString("On for 15 minutes", comment: "firewall rule time limit")) {
                setLimit(row, expiresIn: 15 * 60)
            }
            Button(NSLocalizedString("On for 1 hour", comment: "firewall rule time limit")) {
                setLimit(row, expiresIn: 60 * 60)
            }
            Button(NSLocalizedString("On until the workspace stops", comment: "firewall rule time limit")) {
                row.wrappedValue.enabled = true
                row.wrappedValue.expiresAt = nil
                row.wrappedValue.untilStop = true
            }
            if r.expiresAt != nil || r.untilStop {
                Divider()
                Button(NSLocalizedString("Make permanent", comment: "firewall rule time limit")) {
                    row.wrappedValue.expiresAt = nil
                    row.wrappedValue.untilStop = false
                }
            }
        } label: {
            // A borderless menu draws its label through AppKit as a template
            // image, ignoring SwiftUI tints: bake the color into a
            // non-template image so a timed rule's clock is really orange.
            Image(nsImage: Self.clockImage(temporary: temporary))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(NSLocalizedString("Time limit", comment: "")))
        if temporary {
            // The countdown lives outside the menu (a menu label is drawn
            // once by AppKit and wouldn't tick).
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                limitLabel(r, now: ctx.date)
            }
        }
        }
        .help(limitHelp(r))
    }

    private func setLimit(_ row: Binding<EgressPolicy.EditRow>, expiresIn seconds: TimeInterval) {
        row.wrappedValue.enabled = true
        row.wrappedValue.untilStop = false
        row.wrappedValue.expiresAt = EgressPolicy.expiry(in: seconds)
    }

    @ViewBuilder
    private func limitLabel(_ r: EgressPolicy.EditRow, now: Date) -> some View {
        if r.untilStop {
            Text(NSLocalizedString("until stop", comment: "firewall rule badge: on until the workspace stops"))
                .font(.caption2).foregroundStyle(.orange).lineLimit(1)
        } else if let e = r.expiresAt {
            if now >= e {
                Text(NSLocalizedString("expired", comment: "firewall rule badge"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(verbatim: Self.remaining(e.timeIntervalSince(now)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    private func limitHelp(_ r: EgressPolicy.EditRow) -> String {
        if r.enabled, r.untilStop {
            return NSLocalizedString("On until this workspace stops, then switched off automatically", comment: "firewall rule time limit help")
        }
        if r.enabled, let e = r.expiresAt {
            return String(format: NSLocalizedString("Switches off automatically at %@", comment: "firewall rule time limit help; %@ = time"),
                          e.formatted(date: .omitted, time: .shortened))
        }
        return NSLocalizedString("Turn this rule on for a limited time", comment: "firewall rule time limit help")
    }

    /// The clock glyph, colored (orange: timed rule; secondary otherwise)
    /// and not a template, so AppKit keeps the color.
    static func clockImage(temporary: Bool) -> NSImage {
        let name = temporary ? "clock.fill" : "clock"
        let color: NSColor = temporary ? .systemOrange : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let img = base.withSymbolConfiguration(config) else { return NSImage() }
        img.isTemplate = false
        img.accessibilityDescription = temporary
            ? NSLocalizedString("Time limit set", comment: "firewall rule clock accessibility")
            : NSLocalizedString("Time limit", comment: "")
        return img
    }

    /// The row as one pf rule (for its accessibility label).
    static func ruleText(_ row: EgressPolicy.EditRow) -> String {
        var parts = [row.action, row.proto.isEmpty ? "any" : row.proto]
        let ports = row.ports.trimmingCharacters(in: .whitespaces)
        let host = row.host.trimmingCharacters(in: .whitespaces)
        parts.append(ports.isEmpty || ports == "any" ? host : "\(host):\(ports)")
        if row.proto == "web", !row.methods.isEmpty { parts.append(row.methods) }
        return parts.joined(separator: " ")
    }

    /// "Rules changed outside the editor" — after a merge (dismissible), or
    /// when the edits couldn't be merged (Reload / Keep my edits).
    @ViewBuilder
    private func externalChangeBanner(_ change: ExternalChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
            switch change {
            case .merged:
                Text(NSLocalizedString("The rules changed outside the editor (a Security Timeline action or a time limit). The change was merged into your unsaved edits.",
                                       comment: "firewall editor banner"))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(NSLocalizedString("OK", comment: "")) { externalChange = nil }
                    .controlSize(.small)
            case .conflict(let saved):
                Text(NSLocalizedString("The rules changed outside the editor while you have unsaved edits.",
                                       comment: "firewall editor banner"))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(NSLocalizedString("Reload", comment: "firewall editor banner: discard edits, load the saved rules")) {
                    pfText = saved
                    load()
                    externalChange = nil
                }
                .controlSize(.small)
                Button(NSLocalizedString("Keep my edits", comment: "firewall editor banner")) { externalChange = nil }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
    }

    /// "Log allowed connections" when the workspace hasn't chosen: on while
    /// it has rules (or denies unmatched traffic).
    private var autoLogsAllowed: Bool {
        ((try? EgressPolicy.parse(pfText)) ?? .allowAll).isActive
    }

    /// "14m" / "1h 05m" / "45s" — compact, for the badge.
    static func remaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s < 60 { return "\(s)s" }
        let m = (s + 59) / 60
        if m < 60 { return "\(m)m" }
        return String(format: "%dh %02dm", m / 60, m % 60)
    }

    enum Adoption: Equatable { case replace(String), merged(String), ask }

    /// How to take in a rules change saved outside the editor: with no
    /// unsaved edits (the editor's text says what was saved before), just
    /// adopt it; with edits, merge it in rule by rule; if that's impossible,
    /// ask (never drop the edits silently).
    static func adopt(external text: String, previous: String?, editing: String) -> Adoption {
        guard let previous else { return .replace(text) }
        if FirewallRuleActions.sameRules(editing, previous) { return .replace(text) }
        guard let merged = FirewallRuleActions.merge(external: previous, text, into: editing) else { return .ask }
        return .merged(merged)
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

/// The rule on/off checkbox, in AppKit: an NSButton checkbox whose
/// accessibility label (the rule) reaches assistive tools as AXDescription.
private struct RuleCheckbox: NSViewRepresentable {
    @Binding var isOn: Bool
    let label: String
    let help: String
    /// The visible title (none for a rule row's checkbox).
    var title: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: context.coordinator,
                         action: #selector(Coordinator.toggled(_:)))
        b.setContentHuggingPriority(.required, for: .horizontal)
        update(b)
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) {
        context.coordinator.parent = self
        update(b)
    }

    private func update(_ b: NSButton) {
        let state: NSControl.StateValue = isOn ? .on : .off
        if b.state != state { b.state = state }
        if b.title != title { b.title = title }
        if b.accessibilityLabel() != label { b.setAccessibilityLabel(label) }
        if b.toolTip != help { b.toolTip = help }
    }

    final class Coordinator: NSObject {
        var parent: RuleCheckbox
        init(_ parent: RuleCheckbox) { self.parent = parent }
        @objc func toggled(_ sender: NSButton) { parent.isOn = sender.state == .on }
    }
}
