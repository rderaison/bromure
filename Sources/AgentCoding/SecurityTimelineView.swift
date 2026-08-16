#if os(macOS)
import SwiftUI

/// The Security Timeline window: one chronological table of every decision the
/// security engines made — credential brokering, the egress firewall, supply
/// chain, prompt injection, and credential use — newest first, colour-coded by
/// outcome. Backed by the live `SecurityTimeline` store, so it updates as
/// workspaces run.
struct SecurityTimelineView: View {
    var timeline = SecurityTimeline.shared
    let onClose: () -> Void

    @State private var query = ""
    @State private var engineFilter: String?

    private var engines: [String] {
        Array(Set(timeline.events.map(\.engine))).sorted()
    }

    private var rows: [SecurityTimeline.Event] {
        var e = timeline.events
        if let engineFilter { e = e.filter { $0.engine == engineFilter } }
        if !query.isEmpty {
            let q = query.lowercased()
            e = e.filter {
                $0.engine.lowercased().contains(q)
                    || $0.condition.lowercased().contains(q)
                    || $0.decision.lowercased().contains(q)
            }
        }
        return e.reversed()   // newest first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(
                    timeline.events.isEmpty
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
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField(NSLocalizedString("Filter events…", comment: ""), text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 200)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))

            Picker("", selection: $engineFilter) {
                Text(NSLocalizedString("All engines", comment: "")).tag(String?.none)
                ForEach(engines, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 0)

            Text(String(format: NSLocalizedString("%d events", comment: ""), rows.count))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button(NSLocalizedString("Clear", comment: "")) { timeline.clear() }
                .controlSize(.small)
                .disabled(timeline.events.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
                    .lineLimit(1).truncationMode(.middle)
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
        default:                     return "shield"
        }
    }
}
#endif
