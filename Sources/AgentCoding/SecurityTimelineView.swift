#if os(macOS)
import SwiftUI

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
}

struct SecurityTimelineView: View {
    var timeline = SecurityTimeline.shared
    let onClose: () -> Void
    /// This Mac's workspaces and which protections each has on.
    var postures: () -> [SecurityPosture] = { [] }

    private enum Tab: String { case overview, timeline }
    @State private var tab: Tab = .overview

    @State private var query = ""
    @State private var engineFilter: String?
    /// "" = this Mac; a host's name = that mirrored host; nil = all.
    @State private var machineFilter: String?

    private var machines: [String] { timeline.remote.keys.sorted() }

    private var engines: [String] {
        Array(Set(timeline.allEvents.map(\.engine))).sorted()
    }

    private var rows: [SecurityTimeline.Event] {
        var e = timeline.allEvents
        if let machineFilter { e = e.filter { ($0.machine ?? "") == machineFilter } }
        if let engineFilter { e = e.filter { $0.engine == engineFilter } }
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
                                 showTimeline: { engine in
                                     engineFilter = engine
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
        .onDisappear(perform: onClose)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) {
                Text(NSLocalizedString("Overview", comment: "security timeline tab")).tag(Tab.overview)
                Text(NSLocalizedString("Timeline", comment: "security timeline tab")).tag(Tab.timeline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if tab == .timeline { filters }
            Spacer(minLength: 0)
            if tab == .timeline {
                Text(String(format: NSLocalizedString("%d events", comment: ""), rows.count))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button {
                exportCSV()
            } label: {
                Label(NSLocalizedString("Export…", comment: "security timeline"), systemImage: "square.and.arrow.up")
            }
            .controlSize(.small)
            .disabled(timeline.allEvents.isEmpty)
            .help(NSLocalizedString("Save the events (with any filter applied) as a CSV file", comment: "security timeline"))
            if tab == .timeline {
                Button(NSLocalizedString("Clear", comment: "")) { timeline.clear() }
                    .controlSize(.small)
                    .disabled(timeline.allEvents.isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
            out += [iso.string(from: e.time), e.machine ?? "This Mac", e.workspace ?? "", e.engine,
                    e.condition, e.decision, e.kind.wire].map(field).joined(separator: ",") + "\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    private var table: some View {
        Table(rows) {
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
                Text(e.condition)
                    .lineLimit(1).truncationMode(.tail)
                    .help(e.condition)
                    .textSelection(.enabled)
            }

            TableColumn(NSLocalizedString("Decision", comment: "")) { e in
                HStack(spacing: 5) {
                    Circle().fill(color(e.kind)).frame(width: 7, height: 7)
                    Text(e.decision).foregroundStyle(color(e.kind)).lineLimit(1)
                }
                .help(e.decision)
            }
            .width(min: 120, ideal: 160, max: 260)
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
/// The Overview tab: what the engines did in the last 24 hours, each
/// workspace's protections, and the latest blocks.
private struct SecurityOverview: View {
    var timeline: SecurityTimeline
    let postures: [SecurityPosture]
    let showTimeline: (String?) -> Void

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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    tile(NSLocalizedString("Blocked", comment: "security overview"), recent.filter { $0.kind == .blocked }.count,
                         "hand.raised.fill", .red, engine: nil)
                    tile(NSLocalizedString("Allowed", comment: "security overview"), recent.filter { $0.kind == .allowed }.count,
                         "checkmark.seal.fill", .green, engine: nil)
                    tile(NSLocalizedString("Credentials brokered", comment: "security overview"),
                         recent.filter { $0.engine == NSLocalizedString("Credential brokering", comment: "Security Timeline engine") }.count,
                         "arrow.left.arrow.right", .blue,
                         engine: NSLocalizedString("Credential brokering", comment: "Security Timeline engine"))
                    tile(NSLocalizedString("Packages checked", comment: "security overview"),
                         recent.filter { $0.engine == NSLocalizedString("Supply chain", comment: "Security Timeline engine") }.count,
                         "shippingbox.fill", .orange,
                         engine: NSLocalizedString("Supply chain", comment: "Security Timeline engine"))
                }

                if !postures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(NSLocalizedString("Protections", comment: "security overview"))
                            .font(.system(size: 15, weight: .semibold))
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
                                    .fill(Color.red.opacity(0.06)))
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

    private func tile(_ title: String, _ n: Int, _ icon: String, _ tint: Color, engine: String?) -> some View {
        Button { showTimeline(engine) } label: {
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
                                  NSLocalizedString("Credential brokering", comment: "Security Timeline engine")]

    private var postureHeader: some View {
        HStack(spacing: 0) {
            Text(NSLocalizedString("Workspace", comment: "security timeline"))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Self.columns, id: \.self) { c in
                Text(c).frame(width: 110)
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
            ForEach(Array([p.firewall, p.supplyChain, p.guardrails, p.promptInjection, true].enumerated()), id: \.offset) { _, on in
                Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(on ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    .frame(width: 110)
                    .help(on ? NSLocalizedString("On", comment: "security overview") : NSLocalizedString("Off", comment: "security overview"))
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}
#endif
