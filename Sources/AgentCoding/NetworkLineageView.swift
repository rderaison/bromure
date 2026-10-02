#if os(macOS)
import AppKit
import SwiftUI

/// One network flow's lineage, assembled from Security Timeline rows: the
/// `net.flow` event itself, the agent's reasoning for the tool call that
/// caused it (`agent.reasoning`, joined on `tool_use_id`), and every other flow
/// the same tool call caused (NETWORK_LINEAGE.md).
struct FlowLineage {
    struct Proc: Identifiable {
        let id: Int
        let pid: Int
        let comm: String
        let exe: String?
        let argv: String?
    }

    let event: SecurityTimeline.Event
    let proto: String
    let destination: String
    let port: Int
    let ip: String?
    let sport: Int?
    let viaProxy: Bool
    let count: Int
    let decision: String
    let layer: String?
    let reason: String?
    let processes: [Proc]
    let tool: String?
    let toolUseID: String?
    let confidence: String?
    let command: String?
    let reasoning: String?
    /// The user's request the agent was acting on, and the call's stated intent.
    let prompt: String?
    let intent: String?
    /// Other flows from the same tool call, newest first.
    let siblings: [SecurityTimeline.Event]

    static func s(_ d: [String: AnyJSON]?, _ k: String) -> String? {
        if case .string(let v)? = d?[k] { return v }; return nil
    }
    static func i(_ d: [String: AnyJSON]?, _ k: String) -> Int? {
        if case .int(let v)? = d?[k] { return v }; return nil
    }

    static func toolUseID(of e: SecurityTimeline.Event) -> String? {
        guard let d = e.detail else { return nil }
        if case .object(let agent)? = d["agent"] { return s(agent, "tool_use_id") }
        return s(d, "tool_use_id")
    }

    /// The lineage behind `event` (a `net.flow` row, or an `agent.reasoning`
    /// row: then its first flow, or the reasoning alone).
    init?(event: SecurityTimeline.Event, all: [SecurityTimeline.Event]) {
        guard let d = event.detail else { return nil }
        let id = Self.toolUseID(of: event)
        let flows = id.map { tid in
            all.filter { $0.eventType == "net.flow" && $0.profileID == event.profileID && Self.toolUseID(of: $0) == tid }
        } ?? []
        let flow: SecurityTimeline.Event? = event.eventType == "net.flow" ? event : flows.last
        let fd = flow?.detail
        self.event = flow ?? event
        proto = (Self.s(fd, "proto") ?? "").uppercased()
        destination = Self.s(fd, "host") ?? Self.s(fd, "dst") ?? "—"
        port = Self.i(fd, "dport") ?? 0
        ip = Self.s(fd, "host") != nil ? Self.s(fd, "dst") : nil
        sport = Self.i(fd, "sport")
        if case .bool(true)? = fd?["via_proxy"] { viaProxy = true } else { viaProxy = false }
        count = Self.i(fd, "count") ?? 1
        decision = Self.s(fd, "decision") ?? (flow == nil ? "none" : "unknown")
        layer = Self.s(fd, "layer")
        reason = Self.s(fd, "reason")
        var procs: [Proc] = []
        if case .array(let ps)? = fd?["processes"] {
            for (n, p) in ps.enumerated() {
                guard case .object(let o) = p else { continue }
                procs.append(Proc(id: n, pid: Self.i(o, "pid") ?? 0, comm: Self.s(o, "comm") ?? "?",
                                  exe: Self.s(o, "exe"), argv: Self.s(o, "argv")))
            }
        }
        processes = procs
        var agent: [String: AnyJSON]?
        if case .object(let a)? = fd?["agent"] { agent = a }
        let reasoningEvent = id.flatMap { tid in
            all.last { $0.eventType == "agent.reasoning" && $0.profileID == event.profileID && Self.s($0.detail, "tool_use_id") == tid }
        }
        tool = Self.s(agent, "tool") ?? Self.s(reasoningEvent?.detail ?? d, "tool")
        toolUseID = id
        confidence = Self.s(agent, "confidence")
        command = Self.s(fd, "command")
        let why = reasoningEvent?.detail ?? (event.eventType == "agent.reasoning" ? d : nil)
        reasoning = Self.s(why, "text").flatMap { $0.isEmpty ? nil : $0 }
        prompt = Self.s(why, "prompt")
        intent = Self.s(why, "intent")
        siblings = flows.filter { $0.id != flow?.id }.reversed()
    }
}

/// The whole chain behind a network flow, as a vertical stack of connected
/// steps: reasoning → tool call → processes → flow → decision.
struct NetworkLineageView: View {
    var timeline: SecurityTimeline
    @State var focus: SecurityTimeline.Event
    let onClose: () -> Void
    /// Off only for offscreen renders (ImageRenderer draws no ScrollView).
    var scrolls = true

    @State private var reasoningExpanded = false
    @State private var showAllProcesses = false

    var body: some View {
        let lineage = FlowLineage(event: focus, all: timeline.allEvents)
        VStack(spacing: 0) {
            if let lineage {
                header(lineage)
                Divider()
                if scrolls {
                    ScrollView { steps(lineage) }
                } else {
                    steps(lineage)
                    Spacer(minLength: 0)
                }
            } else {
                ContentUnavailableView(NSLocalizedString("No lineage recorded for this event", comment: "network lineage"),
                                       systemImage: "point.3.connected.trianglepath.dotted")
            }
            Divider()
            HStack {
                Spacer()
                Button(NSLocalizedString("Done", comment: "")) { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func steps(_ lineage: FlowLineage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            reasoningStep(lineage)
            toolStep(lineage)
            processStep(lineage)
            flowStep(lineage)
            decisionStep(lineage, last: true)
            if !lineage.siblings.isEmpty { siblings(lineage) }
        }
        .padding(20)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    private func header(_ l: FlowLineage) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(lineageTint(l.decision).gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text(l.port > 0 ? "\(l.destination):\(l.port)" : l.destination)
                    .font(.system(size: 17, weight: .semibold))
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(l.event.time, format: .dateTime.month().day().hour().minute().second())
                    if let w = l.event.workspace { Text("·"); Text(w) }
                    if let m = l.event.machine { Text("·"); Text(m) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            DecisionBadge(decision: l.decision)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Steps

    @ViewBuilder private func reasoningStep(_ l: FlowLineage) -> some View {
        Step(icon: "brain.head.profile", tint: .purple,
             title: NSLocalizedString("Why", comment: "network lineage step"),
             dimmed: l.reasoning == nil && l.prompt == nil && l.intent == nil) {
            VStack(alignment: .leading, spacing: 10) {
                if let p = l.prompt {
                    Labeled(label: NSLocalizedString("Prompt", comment: "network lineage"), icon: "person.fill") {
                        Text(p).font(.callout).lineLimit(reasoningExpanded ? nil : 4)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                if l.reasoning != nil || (l.prompt == nil && l.intent == nil) {
                    Labeled(label: NSLocalizedString("Reasoning", comment: "network lineage"), icon: "brain") {
                        reasoningBody(l)
                    }
                }
                if let i = l.intent {
                    Labeled(label: NSLocalizedString("Stated intent", comment: "network lineage"), icon: "quote.bubble") {
                        Text(i).font(.callout.italic()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private func reasoningBody(_ l: FlowLineage) -> some View {
            if let r = l.reasoning {
                VStack(alignment: .leading, spacing: 6) {
                    Text(r)
                        .font(.callout)
                        .lineLimit(reasoningExpanded ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if r.count > 320 {
                        Button(reasoningExpanded ? NSLocalizedString("Show less", comment: "")
                                                 : NSLocalizedString("Show more", comment: "")) {
                            withAnimation(.snappy) { reasoningExpanded.toggle() }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            } else {
                Text(l.toolUseID == nil
                     ? NSLocalizedString("Not traced to an agent's tool call.", comment: "network lineage")
                     : NSLocalizedString("The model went straight to the call: it wrote nothing first, and returned its thinking (if any) without readable text.", comment: "network lineage"))
                    .font(.callout).foregroundStyle(.secondary)
            }
    }

    @ViewBuilder private func toolStep(_ l: FlowLineage) -> some View {
        Step(icon: "wrench.and.screwdriver.fill", tint: .indigo,
             title: l.tool.map { String(format: NSLocalizedString("Tool call · %@", comment: "network lineage step"), $0) }
                ?? NSLocalizedString("Tool call", comment: "network lineage step"),
             accessory: l.confidence.map { AnyView(Chip(text: $0 == "exact" ? NSLocalizedString("exact match", comment: "network lineage")
                                                                      : $0, tint: .indigo)) },
             dimmed: l.toolUseID == nil) {
            if let c = l.command {
                CodeBlock(text: c)
            } else if l.toolUseID != nil {
                Text(NSLocalizedString("A tool call without a shell command.", comment: "network lineage"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(NSLocalizedString("Started outside any tool call the AI proxy saw (a background service, a build step the agent didn't run directly, or a process older than the session).", comment: "network lineage"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func processStep(_ l: FlowLineage) -> some View {
        let procs = l.processes
        let collapsed = !showAllProcesses && procs.count > 6
        let shown: [(FlowLineage.Proc?, Int)] = collapsed
            ? procs.prefix(2).map { ($0, $0.id) } + [(nil, -1)] + procs.suffix(3).map { ($0, $0.id) }
            : procs.map { ($0, $0.id) }
        Step(icon: "terminal.fill", tint: .orange,
             title: String(format: NSLocalizedString("Processes · %d", comment: "network lineage step"), procs.count),
             dimmed: procs.isEmpty) {
            if procs.isEmpty {
                Text(NSLocalizedString("The kernel sentry didn't report the process (it may be off in this workspace).", comment: "network lineage"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { depth, item in
                        if let p = item.0 {
                            ProcessRow(proc: p, depth: depth, isLeaf: p.id == procs.last?.id)
                        } else {
                            Button {
                                withAnimation(.snappy) { showAllProcesses = true }
                            } label: {
                                Label(String(format: NSLocalizedString("%d more", comment: "network lineage"), procs.count - 5),
                                      systemImage: "ellipsis")
                                    .font(.caption)
                            }
                            .buttonStyle(.link)
                            .padding(.leading, CGFloat(depth) * 18 + 22).padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func flowStep(_ l: FlowLineage) -> some View {
        Step(icon: "arrow.up.right.circle.fill", tint: .teal,
             title: NSLocalizedString("Network flow", comment: "network lineage step")) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text(NSLocalizedString("Protocol", comment: "network lineage")).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Chip(text: l.proto.isEmpty ? "—" : l.proto, tint: .teal)
                        if l.viaProxy { Chip(text: NSLocalizedString("via proxy", comment: "network lineage"), tint: .gray) }
                        if l.count > 1 { Chip(text: "×\(l.count)", tint: .gray) }
                    }
                }
                GridRow {
                    Text(NSLocalizedString("Destination", comment: "network lineage")).foregroundStyle(.secondary)
                    Text(l.port > 0 ? "\(l.destination):\(l.port)" : l.destination).textSelection(.enabled).monospaced()
                }
                if let ip = l.ip {
                    GridRow {
                        Text(NSLocalizedString("Address", comment: "network lineage")).foregroundStyle(.secondary)
                        Text(ip).textSelection(.enabled).monospaced()
                    }
                }
                if let sport = l.sport {
                    GridRow {
                        Text(l.proto == "ICMP" ? NSLocalizedString("Echo id", comment: "network lineage")
                                               : NSLocalizedString("Source port", comment: "network lineage"))
                            .foregroundStyle(.secondary)
                        Text("\(sport)").monospaced()
                    }
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder private func decisionStep(_ l: FlowLineage, last: Bool) -> some View {
        Step(icon: l.decision == "deny" ? "xmark.shield.fill" : "checkmark.shield.fill", tint: lineageTint(l.decision),
             title: NSLocalizedString("Decision", comment: "network lineage step"), last: last) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    DecisionBadge(decision: l.decision)
                    if let layer = l.layer { Chip(text: Self.layerName(layer), tint: .gray) }
                }
                if let r = l.reason { Text(r).font(.callout).textSelection(.enabled) }
                if l.decision == "unfiltered" {
                    Text(NSLocalizedString("The firewall filters TCP and UDP; this protocol passes without a rule.", comment: "network lineage"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func siblings(_ l: FlowLineage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: NSLocalizedString("Other flows from this tool call · %d", comment: "network lineage"), l.siblings.count))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 18)
            LazyVStack(spacing: 4) {
                ForEach(l.siblings) { e in
                    let s = FlowLineage(event: e, all: [])
                    Button { withAnimation(.snappy) { focus = e } } label: {
                        HStack(spacing: 10) {
                            Circle().fill(lineageTint(s?.decision ?? "")).frame(width: 7, height: 7)
                            Text(s?.proto ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                            Text(s.map { $0.port > 0 ? "\($0.destination):\($0.port)" : $0.destination } ?? "")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(s?.processes.last?.comm ?? "").font(.caption).foregroundStyle(.secondary)
                            Text(e.time, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func layerName(_ layer: String) -> String {
        switch layer {
        case "l4": return NSLocalizedString("firewall (L4)", comment: "network lineage layer")
        case "l7": return NSLocalizedString("request policy (L7)", comment: "network lineage layer")
        case "identity": return NSLocalizedString("binary identity", comment: "network lineage layer")
        case "proxy": return NSLocalizedString("proxy", comment: "network lineage layer")
        default: return layer
        }
    }
}

func lineageTint(_ decision: String) -> Color {
    switch decision {
    case "deny": return .red
    case "allow": return .green
    case "audit": return .orange
    default: return .gray
    }
}

/// One step of the lineage: an icon on a rail connecting it to the next.
private struct Step<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var accessory: AnyView? = nil
    var dimmed = false
    var last = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(dimmed ? 0.06 : 0.15)))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(dimmed ? .secondary : .primary)
                    if let accessory { accessory }
                }
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(dimmed ? 0.5 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .padding(.bottom, last ? 0 : 12)
        }
        // The rail to the next step: a background, so it follows the card's
        // height instead of stretching the layout.
        .background(alignment: .topLeading) {
            if !last {
                Rectangle().fill(Color.primary.opacity(0.12))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 14).padding(.top, 32)
            }
        }
    }
}

private struct ProcessRow: View {
    let proc: FlowLineage.Proc
    let depth: Int
    let isLeaf: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if depth > 0 {
                Text("└").foregroundStyle(.tertiary).font(.system(.callout, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(proc.comm).font(.callout.weight(isLeaf ? .semibold : .regular))
                    Text("\(proc.pid)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    if let exe = proc.exe, !exe.hasSuffix("/" + proc.comm) {
                        Text(exe).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let argv = proc.argv, !argv.isEmpty, argv != proc.comm {
                    Text(argv)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(argv)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.vertical, 4)
    }
}

/// A small caption above one part of the "Why" step.
private struct Labeled<Content: View>: View {
    let label: String
    let icon: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct Chip: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
    }
}

private struct DecisionBadge: View {
    let decision: String
    var body: some View {
        let label: String = {
            switch decision {
            case "deny": return NSLocalizedString("Blocked", comment: "network lineage decision")
            case "allow": return NSLocalizedString("Allowed", comment: "network lineage decision")
            case "audit": return NSLocalizedString("Audited", comment: "network lineage decision")
            case "unfiltered": return NSLocalizedString("Not filtered", comment: "network lineage decision")
            case "none": return NSLocalizedString("No flow", comment: "network lineage decision")
            default: return NSLocalizedString("Seen", comment: "network lineage decision")
            }
        }()
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(lineageTint(decision).opacity(0.16)))
            .foregroundStyle(lineageTint(decision))
    }
}

private struct CodeBlock: View {
    let text: String
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Copy", comment: ""))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.indigo.opacity(0.07)))
    }
}
#endif
