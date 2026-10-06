#if os(macOS)
import SwiftUI
import SandboxEngine

/// The Security Timeline window: one chronological table of every decision the
/// security engines made — credential brokering, the egress firewall, supply
/// chain, prompt injection, and credential use — newest first, colour-coded by
/// outcome. Backed by the live `SecurityTimeline` store, so it updates as
/// workspaces run.
/// A workspace's protections, for the Overview.
struct SecurityPosture: Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
    let firewall: Bool
    let supplyChain: Bool
    let guardrails: Bool
    let promptInjection: Bool
    var pii: Bool = false
}

extension SecurityPosture {
    /// A workspace's posture, one column per engine. Guardrails is the
    /// CREDENTIAL engine only (write policies, ask-before-use) — the egress
    /// ruleset is its own Firewall column and no longer lights Guardrails up.
    /// Firewall is on when the user wrote a ruleset that restricts something
    /// (a rule, or `default deny`), not merely when the text is non-empty.
    @MainActor init(profile p: Profile) {
        var credentialsOnly = p
        credentialsOnly.egressRules = ""
        let ruleset = p.egressRules.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: p.id, name: p.name, colorHex: p.color.hexInUI,
                  firewall: !ruleset.isEmpty && ((try? EgressPolicy.parse(ruleset))?.isActive ?? false),
                  supplyChain: p.supplyChain.isActive,
                  guardrails: ACAppDelegate.guardrailsRestrict(credentialsOnly),
                  promptInjection: p.promptInjection.isActive,
                  pii: p.pii.isActive)
    }
}

extension SecurityTimeline.Event {
    /// How many identical routine events this coalesced row stands for, when
    /// more than one (nil otherwise). `count` on a non-coalesced row means
    /// something else (PII values in one request) and is not a repeat.
    var repeats: Int? {
        guard coalesceKey != nil, let n = count, n > 1 else { return nil }
        return n
    }
}

/// Opens a workspace's editor on one pane — the Overview's protection cells.
@MainActor
enum SecurityEditorLauncher {
    static func open(profileID: UUID, category: EditorCategory) {
        guard let d = NSApp.delegate as? ACAppDelegate,
              let p = d.profiles.first(where: { $0.id == profileID }) else { return }
        d.openEditorWindow(editing: p, category: category)
    }
}

struct SecurityTimelineView: View {
    var timeline = SecurityTimeline.shared
    let onClose: () -> Void
    /// This Mac's workspaces and which protections each has on.
    var postures: () -> [SecurityPosture] = { [] }

    /// Open on the Timeline tab instead of the Overview (screenshots).
    var startOnTimeline = false

    private enum Tab: String { case overview, timeline }
    @State private var tab: Tab = .overview

    @State private var query = ""
    @State private var engineFilter: String?
    /// The Overview's Blocked / Allowed tiles narrow by outcome.
    @State private var outcomeFilter: SecurityTimeline.Decision?
    /// "" = this Mac; a host's name = that mirrored host; nil = all.
    @State private var machineFilter: String?
    /// Selected rows (the context menu acts on the clicked one).
    @State private var selection = Set<SecurityTimeline.Event.ID>()

    private var machines: [String] { timeline.remote.keys.sorted() }

    private var engines: [String] {
        Array(Set(timeline.allEvents.map(\.engine))).sorted()
    }

    private var rows: [SecurityTimeline.Event] {
        var e = timeline.allEvents
        if let machineFilter { e = e.filter { ($0.machine ?? "") == machineFilter } }
        if let engineFilter { e = e.filter { $0.engine == engineFilter } }
        if let outcomeFilter { e = e.filter { $0.kind == outcomeFilter } }
        if !query.isEmpty {
            let q = query.lowercased()
            e = e.filter {
                $0.engine.lowercased().contains(q)
                    || $0.condition.lowercased().contains(q)
                    || $0.decision.lowercased().contains(q)
                    || ($0.workspace ?? "").lowercased().contains(q)
                    || ($0.machine ?? "").lowercased().contains(q)
            }
        }
        return e.reversed()   // newest first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if tab == .overview {
                SecurityOverview(timeline: timeline, postures: postures(),
                                 showTimeline: { engine, outcome in
                                     engineFilter = engine
                                     outcomeFilter = outcome
                                     tab = .timeline
                                 })
            } else if rows.isEmpty {
                ContentUnavailableView(
                    timeline.allEvents.isEmpty
                        ? NSLocalizedString("No security events yet", comment: "")
                        : NSLocalizedString("No matching events", comment: ""),
                    systemImage: "shield.lefthalf.filled",
                    description: Text(NSLocalizedString(
                        "Credential swaps, firewall verdicts, package checks, prompt-injection scans, and credential use appear here as your workspaces run.",
                        comment: "")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .frame(minWidth: 760, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if startOnTimeline { tab = .timeline } }
        .onDisappear(perform: onClose)
    }

    /// One row when it fits; on a narrower window the filters take a row of
    /// their own under the tabs and actions (the one row used to squeeze
    /// the event count into a character-per-line column, and clip).
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                tabPicker
                if tab == .timeline { filters }
                Spacer(minLength: 0)
                trailingActions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    tabPicker
                    Spacer(minLength: 0)
                    trailingActions
                }
                if tab == .timeline {
                    HStack(spacing: 10) { filters; Spacer(minLength: 0) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            Text(NSLocalizedString("Overview", comment: "security timeline tab")).tag(Tab.overview)
            Text(NSLocalizedString("Timeline", comment: "security timeline tab")).tag(Tab.timeline)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var trailingActions: some View {
        if tab == .timeline {
            Text(String(format: NSLocalizedString("%d events", comment: ""), rows.count))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        Button {
            exportCSV()
        } label: {
            Label(NSLocalizedString("Export…", comment: "security timeline"), systemImage: "square.and.arrow.up")
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(timeline.allEvents.isEmpty)
        .help(NSLocalizedString("Save the events (with any filter applied) as a CSV file", comment: "security timeline"))
        if tab == .timeline {
            Button(NSLocalizedString("Clear", comment: "")) { timeline.clear() }
                .controlSize(.small)
                .fixedSize()
                .disabled(timeline.allEvents.isEmpty)
        }
    }

    /// The Timeline tab's search and filters.
    @ViewBuilder private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField(NSLocalizedString("Filter events…", comment: ""), text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 200)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))

            if !machines.isEmpty {
                Picker("", selection: $machineFilter) {
                    Text(NSLocalizedString("All machines", comment: "security timeline")).tag(String?.none)
                    Text(NSLocalizedString("This Mac", comment: "security timeline")).tag(String?.some(""))
                    ForEach(machines, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }

            Picker("", selection: $engineFilter) {
                Text(NSLocalizedString("All engines", comment: "")).tag(String?.none)
                ForEach(engines, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()

            Picker("", selection: $outcomeFilter) {
                Text(NSLocalizedString("All outcomes", comment: "security timeline")).tag(SecurityTimeline.Decision?.none)
                Text(NSLocalizedString("Blocked", comment: "security overview")).tag(SecurityTimeline.Decision?.some(.blocked))
                Text(NSLocalizedString("Allowed", comment: "security overview")).tag(SecurityTimeline.Decision?.some(.allowed))
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// CSV of what the Timeline shows (filters applied), oldest first.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "bromure-security-\(day).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func field(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let iso = ISO8601DateFormatter()
        var out = "time,machine,workspace,engine,condition,decision,outcome\n"
        for e in (tab == .timeline ? rows.reversed() : timeline.allEvents) {
            // Never export secret characters, whatever an older row carries.
            out += [iso.string(from: e.time), e.machine ?? "This Mac", e.workspace ?? "", e.engine,
                    SecretFingerprint.redactLegacy(e.condition), SecretFingerprint.redactLegacy(e.decision),
                    e.kind.wire].map(field).joined(separator: ",") + "\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    private var table: some View {
        let rows = rows
        return Table(rows, selection: $selection) {
            TableColumn(NSLocalizedString("Time", comment: "")) { e in
                Text(e.time, format: .dateTime.year().month(.twoDigits).day(.twoDigits)
                        .hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 150, ideal: 165, max: 190)

            TableColumn(NSLocalizedString("Workspace", comment: "security timeline")) { e in
                Text(machines.isEmpty ? (e.workspace ?? "—")
                     : "\(e.machine ?? NSLocalizedString("This Mac", comment: "security timeline")) · \(e.workspace ?? "—")")
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .help(e.workspace ?? "")
            }
            .width(min: 90, ideal: 130, max: 220)

            TableColumn(NSLocalizedString("Engine", comment: "")) { e in
                Label {
                    Text(e.engine)
                } icon: {
                    Image(systemName: Self.icon(e.engine)).foregroundStyle(color(e.kind))
                }
            }
            .width(min: 140, ideal: 160, max: 190)

            TableColumn(NSLocalizedString("Condition", comment: "")) { e in
                // The hover area is the whole cell (not just the glyphs), so
                // a truncated host:port shows in full in the tooltip.
                Text(e.condition)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .help(e.condition)
            }
            .width(min: 140, ideal: 240)

            TableColumn(NSLocalizedString("Decision", comment: "")) { e in
                HStack(spacing: 5) {
                    Circle().fill(color(e.kind)).frame(width: 7, height: 7)
                    Text(e.decision).foregroundStyle(color(e.kind)).lineLimit(1).truncationMode(.tail)
                    if let n = e.repeats {
                        Text(verbatim: "×\(n)")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(e.repeats.map {
                    String(format: NSLocalizedString("%1$@ (%2$d times, last one shown)", comment: "security timeline: coalesced row; 1 = decision, 2 = repeats"), e.decision, $0)
                } ?? e.decision)
            }
            .width(min: 140, ideal: 260, max: 520)

            // Firewall rows: allow a block / block an allow / switch the
            // deciding rule off — applied live to the running workspace.
            TableColumn("") { e in
                FirewallRowActionButton(event: e)
            }
            .width(min: 64, ideal: 80, max: 110)
        }
        .contextMenu(forSelectionType: SecurityTimeline.Event.ID.self) { ids in
            if let id = ids.first, let e = rows.first(where: { $0.id == id }), e.firewall != nil {
                FirewallRowMenuItems(event: e)
            }
        }
    }

    private func color(_ kind: SecurityTimeline.Decision) -> Color {
        switch kind {
        case .allowed: return .green
        case .blocked: return .red
        case .info:    return .blue
        }
    }

    private static func icon(_ engine: String) -> String {
        switch engine {
        case "PII protection":       return "person.crop.circle.badge.checkmark"
        case "Credential brokering": return "arrow.left.arrow.right"
        case "Credential used":      return "key.fill"
        case "Guardrails":           return "hand.raised.fill"
        case "Firewall":             return "network"
        case "Supply chain":         return "shippingbox"
        case "Prompt injection":     return "exclamationmark.shield"
        case "Agent delegation":     return "arrow.triangle.branch"
        default:                     return "shield"
        }
    }
}
/// What the firewall quick actions on one timeline row can work with: the
/// verdict, plus — for this Mac's own workspaces — the workspace's current
/// rules (to offer only a rule that still exists).
@MainActor
private struct FirewallRowContext {
    let event: SecurityTimeline.Event
    let fw: SecurityTimeline.Firewall
    /// nil: a mirrored (remote) host's row, or a workspace that's gone.
    let profile: Profile?

    init?(_ e: SecurityTimeline.Event) {
        guard let fw = e.firewall, FirewallRuleActions.isActionable(fw) else { return nil }
        event = e
        self.fw = fw
        profile = e.machine == nil
            ? (NSApp.delegate as? ACAppDelegate)?.profiles.first(where: { $0.id == e.profileID })
            : nil
    }

    var isRemote: Bool { event.machine != nil }

    /// What the workspace's rules decide for this destination NOW, when that
    /// differs from the row (a blocked host allowed since, or the reverse):
    /// the row then says so instead of offering the same flip again.
    var changedSince: (denied: Bool, rule: String?)? {
        guard let profile,
              let now = FirewallRuleActions.currentDecision(for: fw, policy: profile.resolvedEgressPolicy),
              now.denied != fw.denied else { return nil }
        return now
    }

    /// The deciding rule, when it's still in the workspace's rules.
    var editableRule: String? {
        guard let rule = fw.rule, let profile,
              FirewallRuleActions.contains(ruleText: rule, in: profile.egressRules) else { return nil }
        return rule
    }

    var portSuffix: String { (fw.port ?? 0) > 0 ? ":\(fw.port!)" : "" }

    /// The inline button's title.
    var buttonTitle: String {
        if let now = changedSince {
            return now.denied
                ? NSLocalizedString("Blocked now", comment: "security timeline: firewall row whose destination the current rules block")
                : NSLocalizedString("Allowed now", comment: "security timeline: firewall row whose destination the current rules allow")
        }
        if fw.denied { return NSLocalizedString("Allow…", comment: "security timeline: firewall quick action button") }
        if fw.rule != nil { return NSLocalizedString("Rule…", comment: "security timeline: firewall quick action button") }
        return NSLocalizedString("Block…", comment: "security timeline: firewall quick action button")
    }

    func perform(_ edit: FirewallRuleActions.Edit) {
        guard let profile else { return }
        (NSApp.delegate as? ACAppDelegate)?.applyFirewallEdit(edit, profileID: profile.id)
    }
}

/// The firewall quick actions for one timeline row — shared by the row's
/// context menu and its inline button.
@MainActor
private struct FirewallRowMenuItems: View {
    let event: SecurityTimeline.Event

    var body: some View {
        if let ctx = FirewallRowContext(event) {
            if ctx.isRemote {
                Text(NSLocalizedString("Change this workspace's firewall rules in its settings on the Mac that runs it.",
                                       comment: "security timeline: firewall quick actions, remote row"))
            } else if ctx.profile != nil {
                items(ctx)
            }
        }
    }

    @ViewBuilder
    private func items(_ ctx: FirewallRowContext) -> some View {
        let targets = FirewallRuleActions.targets(for: ctx.fw)
        if let now = ctx.changedSince {
            // Already flipped by the current rules: say by what, don't offer
            // to insert the same rule again.
            let word = now.denied
                ? NSLocalizedString("Blocked now by “%@”", comment: "security timeline: the current rules block this destination; %@ = rule")
                : NSLocalizedString("Allowed now by “%@”", comment: "security timeline: the current rules allow this destination; %@ = rule")
            Text(now.rule.map { String(format: word, $0) }
                 ?? (now.denied
                     ? NSLocalizedString("Blocked now by the default policy", comment: "security timeline: the current default policy blocks this destination")
                     : NSLocalizedString("Allowed now by the default policy", comment: "security timeline: the current default policy allows this destination")))
        } else if ctx.fw.denied {
            ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                if let rule = FirewallRuleActions.allowRule(target: target.name, fw: ctx.fw) {
                    Menu(target.wholeDomain
                         ? String(format: NSLocalizedString("Allow all of %@", comment: "security timeline: allow a whole domain; %@ = domain:port"),
                                  target.name + ctx.portSuffix)
                         : String(format: NSLocalizedString("Allow %@", comment: "security timeline: allow a blocked destination; %@ = host:port"),
                                  target.name + ctx.portSuffix)) {
                        if let existing = ctx.profile.flatMap({ FirewallRuleActions.existing(rule, in: $0.egressRules) }) {
                            // Re-allowing replaces this rule (moved first): show
                            // its current state so a shorter time isn't picked
                            // by accident.
                            Text(Self.existingSummary(existing))
                            Divider()
                        }
                        allowDurations(rule, ctx)
                    }
                }
            }
        } else if ctx.fw.rule == nil {
            ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                if let rule = FirewallRuleActions.blockRule(target: target.name) {
                    Button(target.wholeDomain
                           ? String(format: NSLocalizedString("Block all of %@", comment: "security timeline: block a whole domain; %@ = domain"), target.name)
                           : String(format: NSLocalizedString("Block %@", comment: "security timeline: block a destination; %@ = host"), target.name)) {
                        ctx.perform(.insert(rule))
                    }
                }
            }
        }
        if let rule = ctx.editableRule {
            if ctx.fw.denied || ctx.changedSince != nil { Divider() }
            Button(String(format: NSLocalizedString("Switch off rule “%@”", comment: "security timeline: disable the rule that decided; %@ = rule"), rule)) {
                ctx.perform(.disable(ruleText: rule))
            }
            Button(String(format: NSLocalizedString("Remove rule “%@”", comment: "security timeline: delete the rule that decided; %@ = rule"), rule),
                   role: .destructive) {
                ctx.perform(.remove(ruleText: rule))
            }
        } else if !ctx.fw.denied, ctx.fw.rule != nil, ctx.changedSince == nil {
            Text(NSLocalizedString("The rule that allowed this is no longer in the workspace's rules.",
                                   comment: "security timeline: firewall quick actions"))
        }
    }

    /// "“allow tcp a.com:443” is on until 14:05" — an identical rule's state.
    static func existingSummary(_ r: EgressPolicy.Rule, now: Date = Date()) -> String {
        if !r.isEffective(at: now) {
            return String(format: NSLocalizedString("“%@” exists and is off", comment: "security timeline: an identical firewall rule exists, switched off; %@ = rule"), r.text)
        }
        if r.untilStop {
            return String(format: NSLocalizedString("“%@” is on until the workspace stops", comment: "security timeline: an identical firewall rule exists; %@ = rule"), r.text)
        }
        if let e = r.expiresAt {
            return String(format: NSLocalizedString("“%1$@” is on until %2$@", comment: "security timeline: an identical timed firewall rule exists; 1 = rule, 2 = time"),
                          r.text, e.formatted(date: .omitted, time: .shortened))
        }
        return String(format: NSLocalizedString("“%@” is already on, with no time limit", comment: "security timeline: an identical permanent firewall rule exists; %@ = rule"), r.text)
    }

    @ViewBuilder
    private func allowDurations(_ rule: EgressPolicy.Rule, _ ctx: FirewallRowContext) -> some View {
        Button(NSLocalizedString("Always", comment: "security timeline: allow duration")) { insert(rule, .always, ctx) }
        Button(NSLocalizedString("For 15 minutes", comment: "security timeline: allow duration")) { insert(rule, .fifteenMinutes, ctx) }
        Button(NSLocalizedString("For 1 hour", comment: "security timeline: allow duration")) { insert(rule, .oneHour, ctx) }
        Button(NSLocalizedString("Until the workspace stops", comment: "security timeline: allow duration")) { insert(rule, .untilStop, ctx) }
    }

    private func insert(_ rule: EgressPolicy.Rule, _ d: FirewallRuleActions.Duration, _ ctx: FirewallRowContext) {
        var r = rule
        d.apply(to: &r, now: Date())
        ctx.perform(.insert(r))
    }
}

/// The inline quick-action button in a firewall row's last column. A
/// mirrored host's row shows it disabled, with why in the tooltip: the fat
/// client doesn't edit a remote workspace's rules from here.
@MainActor
private struct FirewallRowActionButton: View {
    let event: SecurityTimeline.Event

    var body: some View {
        if let ctx = FirewallRowContext(event) {
            if ctx.isRemote {
                Text(ctx.buttonTitle)
                    .font(.caption).foregroundStyle(.tertiary)
                    .help(NSLocalizedString("Change this workspace's firewall rules in its settings on the Mac that runs it.",
                                            comment: "security timeline: firewall quick actions, remote row"))
            } else if ctx.profile != nil {
                Menu {
                    FirewallRowMenuItems(event: event)
                } label: {
                    Text(ctx.buttonTitle).font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(ctx.changedSince != nil
                      ? NSLocalizedString("The workspace's rules have changed since this connection",
                                          comment: "security timeline: firewall quick action help")
                      : ctx.fw.denied
                      ? NSLocalizedString("Add a rule allowing this destination — applies to the running workspace at once",
                                          comment: "security timeline: firewall quick action help")
                      : NSLocalizedString("Switch off the rule that allowed this, or block the destination — applies at once",
                                          comment: "security timeline: firewall quick action help"))
            }
        }
    }
}

/// The Overview tab: what the engines did in the last 24 hours, each
/// workspace's protections, and the latest blocks.
private struct SecurityOverview: View {
    var timeline: SecurityTimeline
    let postures: [SecurityPosture]
    /// Open the Timeline filtered by engine and/or outcome.
    let showTimeline: (_ engine: String?, _ outcome: SecurityTimeline.Decision?) -> Void

    private var recent: [SecurityTimeline.Event] {
        let since = Date().addingTimeInterval(-86400)
        return timeline.allEvents.filter { $0.time >= since }
    }

    var body: some View {
        let recent = recent
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Last 24 hours", comment: "security overview"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(NSLocalizedString("What Bromure's security engines decided for your agents.", comment: "security overview"))
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    tile(NSLocalizedString("Blocked", comment: "security overview"), recent.filter { $0.kind == .blocked }.count,
                         "hand.raised.fill", .red, engine: nil, outcome: .blocked)
                    tile(NSLocalizedString("Allowed", comment: "security overview"), recent.filter { $0.kind == .allowed }.count,
                         "checkmark.seal.fill", .green, engine: nil, outcome: .allowed)
                    // Tiles carry the engine names the Protections columns use.
                    // Swaps, not rows: a coalesced row carries its repeat count.
                    tile(NSLocalizedString("Credential brokering", comment: "Security Timeline engine"),
                         recent.filter { $0.engine == NSLocalizedString("Credential brokering", comment: "Security Timeline engine") }
                             .reduce(0) { $0 + ($1.count ?? 1) },
                         "arrow.left.arrow.right", .blue,
                         engine: NSLocalizedString("Credential brokering", comment: "Security Timeline engine"))
                    tile(NSLocalizedString("Supply chain", comment: "Security Timeline engine"),
                         recent.filter { $0.engine == NSLocalizedString("Supply chain", comment: "Security Timeline engine") }.count,
                         "shippingbox.fill", .orange,
                         engine: NSLocalizedString("Supply chain", comment: "Security Timeline engine"))
                    // Values swapped, not requests: each row carries its count.
                    tile(NSLocalizedString("PII protection", comment: "Security Timeline engine"),
                         recent.filter { $0.engine == NSLocalizedString("PII protection", comment: "Security Timeline engine") }
                             .reduce(0) { $0 + ($1.count ?? 1) },
                         "person.crop.circle.badge.checkmark", .purple,
                         engine: NSLocalizedString("PII protection", comment: "Security Timeline engine"))
                }

                if !postures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Protections", comment: "security overview"))
                                .font(.system(size: 15, weight: .semibold))
                            Text(NSLocalizedString("Click a protection that's off to turn it on in that workspace's settings.", comment: "security overview"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            postureHeader
                            ForEach(postures) { p in
                                Divider().opacity(0.5)
                                postureRow(p)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07)))
                    }
                }

                let blocks = recent.filter { $0.kind == .blocked }.suffix(8).reversed()
                if !blocks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(NSLocalizedString("Latest blocks", comment: "security overview"))
                            .font(.system(size: 15, weight: .semibold))
                        VStack(spacing: 6) {
                            ForEach(Array(blocks)) { e in
                                HStack(spacing: 10) {
                                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.condition).lineLimit(1).truncationMode(.tail)
                                        Text("\(e.engine) · \(e.decision)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(e.time.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))).font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.red.opacity(0.09)))
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func tile(_ title: String, _ n: Int, _ icon: String, _ tint: Color, engine: String?,
                      outcome: SecurityTimeline.Decision? = nil) -> some View {
        Button { showTimeline(engine, outcome) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(tint.opacity(0.14)))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                }
                Text("\(n)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Show these in the timeline", comment: "security overview"))
    }

    private static let columns = [NSLocalizedString("Firewall", comment: "Security Timeline engine"),
                                  NSLocalizedString("Supply chain", comment: "Security Timeline engine"),
                                  NSLocalizedString("Guardrails", comment: "Security Timeline engine"),
                                  NSLocalizedString("Prompt injection", comment: "Security Timeline engine"),
                                  NSLocalizedString("PII protection", comment: "Security Timeline engine"),
                                  NSLocalizedString("Credential brokering", comment: "Security Timeline engine")]
    /// The editor pane behind each column, in `columns` order.
    private static let columnCategories: [EditorCategory] =
        [.firewall, .supplyChain, .guardrails, .promptInjection, .pii, .credentials]

    private var postureHeader: some View {
        HStack(spacing: 0) {
            Text(NSLocalizedString("Workspace", comment: "security timeline"))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Self.columns, id: \.self) { c in
                Text(c).multilineTextAlignment(.center).frame(width: 96)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func postureRow(_ p: SecurityPosture) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color(hex: p.colorHex).gradient)
                    .frame(width: 10, height: 10)
                Text(p.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array([p.firewall, p.supplyChain, p.guardrails, p.promptInjection, p.pii, true].enumerated()), id: \.offset) { i, on in
                PostureCell(on: on, workspace: p.name, column: Self.columns[i]) {
                    SecurityEditorLauncher.open(profileID: p.id, category: Self.columnCategories[i])
                }
                .frame(width: 96)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

/// One protection in the Overview's table. On: a green check. Off: a muted
/// minus that turns into a "Turn on" pill on hover. Either way a click opens
/// that workspace's editor on the protection's pane.
private struct PostureCell: View {
    let on: Bool
    let workspace: String
    let column: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if on {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if hover {
                    Text(NSLocalizedString("Turn on…", comment: "security overview: off protection, hovered"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                } else {
                    Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(on
              ? String(format: NSLocalizedString("%1$@ is on for %2$@. Click to change it.", comment: "security overview: 1 = protection, 2 = workspace"), column, workspace)
              : String(format: NSLocalizedString("%1$@ is off for %2$@. Click to turn it on.", comment: "security overview: 1 = protection, 2 = workspace"), column, workspace))
    }
}
#endif
