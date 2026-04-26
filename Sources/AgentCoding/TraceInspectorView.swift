import AppKit
import SwiftUI

/// Trace Inspector: live + historical view of every MITM exchange
/// the proxy has recorded for any profile that opted into tracing.
///
/// Two-pane layout:
///   - Left: list of records, newest first, with leak / swap badges.
///   - Right: details for the selected record (headers, swap report,
///     leak warnings, body bytes if captured).
///
/// Filter controls at the top: profile, host substring, leak-only.
/// SwiftUI tracks `store.recent` directly (it's @Observable) so new
/// records appear without polling.
struct TraceInspectorView: View {
    let store: TraceStore
    let profiles: [Profile]
    /// Pre-fill the profile filter when the window is opened from a
    /// per-profile entry point (e.g. the session window's toolbar
    /// button). nil = "All profiles" by default.
    let initialProfileFilter: UUID?

    init(store: TraceStore, profiles: [Profile],
         initialProfileFilter: UUID? = nil) {
        self.store = store
        self.profiles = profiles
        self.initialProfileFilter = initialProfileFilter
        self._profileFilter = State(initialValue: initialProfileFilter)
    }

    @State private var selectedID: UUID?
    @State private var profileFilter: UUID?
    @State private var hostFilter: String = ""
    @State private var leaksOnly: Bool = false
    @State private var conversationsOnly: Bool = false
    @State private var bodyRequest: Data?
    @State private var bodyResponse: Data?
    @State private var detailMode: DetailMode = .conversation

    enum DetailMode: String, CaseIterable, Identifiable {
        case conversation, raw
        var id: String { rawValue }
        var label: String {
            switch self {
            case .conversation: return NSLocalizedString("Conversation", comment: "")
            case .raw:          return NSLocalizedString("Raw", comment: "")
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            if let record = filteredRecords.first(where: { $0.id == selectedID }) {
                detail(for: record)
            } else {
                ContentUnavailableView(
                    NSLocalizedString("Pick a request", comment: ""),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(NSLocalizedString(
                        "Choose a row on the left to inspect headers, swaps, and (if captured) bodies.",
                        comment: "")))
            }
        }
        .navigationTitle(NSLocalizedString("Trace Inspector", comment: ""))
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { store.reload() }
    }

    // MARK: - List pane

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.bar)

            List(filteredRecords, selection: $selectedID) { record in
                row(record)
                    .tag(record.id)
            }
            .listStyle(.inset)

            HStack {
                Text(String(format: NSLocalizedString(
                    "%lld records (last %lld in memory)", comment: ""),
                    Int(filteredRecords.count), Int(store.recent.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(NSLocalizedString("Reload from disk", comment: ""))
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .navigationSplitViewColumnWidth(min: 380, ideal: 460, max: 600)
    }

    @ViewBuilder
    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack {
                Picker(selection: $profileFilter) {
                    Text(NSLocalizedString("All profiles", comment: "")).tag(UUID?.none)
                    ForEach(profiles) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                } label: {
                    Image(systemName: "person.2")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Toggle(isOn: $leaksOnly) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(NSLocalizedString("Leaks only", comment: ""))
                }
                .toggleStyle(.checkbox)
                Toggle(isOn: $conversationsOnly) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(NSLocalizedString("Conversations only", comment: ""))
                }
                .toggleStyle(.checkbox)
                .help(NSLocalizedString(
                    "Show only requests to known LLM hosts that captured a body — i.e. an actual chat exchange.",
                    comment: ""))
                Spacer()
            }
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Host filter", comment: ""),
                          text: $hostFilter)
                    .textFieldStyle(.plain)
            }
        }
    }

    private var filteredRecords: [TraceRecord] {
        store.recent.filter { rec in
            if let pf = profileFilter, rec.profileID != pf { return false }
            if leaksOnly, rec.leaks.isEmpty { return false }
            if conversationsOnly, !Self.looksLikeAIConversation(rec) { return false }
            let q = hostFilter.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty, !rec.host.lowercased().contains(q) { return false }
            return true
        }
    }

    /// True when the proxy successfully parsed the captured bodies as
    /// an AI chat exchange — set at record time so the filter is a
    /// boolean read, not a re-parse round-trip. Records on disk from
    /// before the flag existed default to false; the user re-records
    /// to surface them.
    private static func looksLikeAIConversation(_ rec: TraceRecord) -> Bool {
        rec.isConversation
    }

    private func row(_ rec: TraceRecord) -> some View {
        HStack(spacing: 8) {
            statusDot(rec.statusCode)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(rec.method)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                    Text(rec.host)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    if !rec.leaks.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(String(format: NSLocalizedString(
                                "%lld unswapped credential(s)", comment: ""),
                                Int(rec.leaks.count)))
                    }
                    if !rec.swaps.isEmpty {
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.blue)
                            .help(String(format: NSLocalizedString(
                                "%lld token(s) swapped", comment: ""),
                                Int(rec.swaps.count)))
                    }
                    if rec.bodyStored {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                            .help(NSLocalizedString("Body captured", comment: ""))
                    }
                }
                Text(rec.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(rec.statusCode)")
                    .font(.caption.monospaced())
                    .foregroundStyle(statusColor(rec.statusCode))
                Text(String(format: "%.0fms", rec.latencyMs))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusDot(_ code: Int) -> some View {
        Circle().fill(statusColor(code))
    }
    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500...:    return .red
        default:        return .gray
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private func detail(for rec: TraceRecord) -> some View {
        let conversation = rec.bodyStored
            ? ConversationParser.parse(host: rec.host,
                                       requestBody: bodyRequest,
                                       responseBody: bodyResponse)
            : nil
        VStack(spacing: 0) {
            detailHeader(for: rec, conversationAvailable: conversation != nil)

            if detailMode == .conversation, let conv = conversation {
                ConversationView(conversation: conv)
            } else {
                rawDetail(for: rec)
            }
        }
        .onAppear { reloadBodies(for: rec) }
        .onChange(of: rec.id) { _, _ in reloadBodies(for: rec) }
    }

    @ViewBuilder
    private func detailHeader(for rec: TraceRecord, conversationAvailable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row
            HStack(alignment: .firstTextBaseline) {
                Text(rec.method)
                    .font(.title3.monospaced())
                    .foregroundStyle(.secondary)
                Text("https://\(rec.host)\(rec.path)")
                    .font(.title3.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Text("\(rec.statusCode)")
                    .font(.title3.monospaced())
                    .foregroundStyle(statusColor(rec.statusCode))
            }
            // Meta row
            HStack(spacing: 16) {
                metaCell(NSLocalizedString("Profile", comment: ""),
                         profileName(for: rec.profileID))
                metaCell(NSLocalizedString("Latency", comment: ""),
                         String(format: "%.0f ms", rec.latencyMs))
                metaCell(NSLocalizedString("Request", comment: ""),
                         ByteCountFormatter.string(fromByteCount: Int64(rec.requestBytes), countStyle: .file))
                metaCell(NSLocalizedString("Response", comment: ""),
                         ByteCountFormatter.string(fromByteCount: Int64(rec.responseBytes), countStyle: .file))
                metaCell(NSLocalizedString("Time", comment: ""),
                         rec.timestamp.formatted(date: .abbreviated, time: .standard))
                Spacer()
                // View-mode toggle. Conversation tab is disabled
                // when the parser couldn't make sense of the body
                // (non-AI host, missing body capture, etc.).
                Picker("", selection: $detailMode) {
                    ForEach(DetailMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .disabled(!conversationAvailable && detailMode == .conversation)
                .onChange(of: conversationAvailable) { _, available in
                    if !available { detailMode = .raw }
                }
            }
            .font(.caption)
        }
        .padding(20)
        .background(.bar)
    }

    @ViewBuilder
    private func rawDetail(for rec: TraceRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Leaks pane (red, prominent)
                if !rec.leaks.isEmpty {
                    section(NSLocalizedString("Unswapped credentials (potential leaks)", comment: ""),
                            symbol: "exclamationmark.triangle.fill",
                            tint: .orange) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(rec.leaks.enumerated()), id: \.offset) { (_, leak) in
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.shield.fill")
                                        .foregroundStyle(.orange)
                                    Text(leak.header).font(.caption.monospaced().bold())
                                    Text(leak.valuePreview).font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text("·").foregroundStyle(.tertiary)
                                    Text(leak.suspicion.rawValue).font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                // Swap report
                if !rec.swaps.isEmpty {
                    section(NSLocalizedString("Token swaps", comment: ""),
                            symbol: "arrow.left.arrow.right",
                            tint: .blue) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(rec.swaps.enumerated()), id: \.offset) { (_, sw) in
                                HStack(spacing: 6) {
                                    Text(sw.header).font(.caption.monospaced().bold())
                                    Text(sw.fakePreview).font(.caption.monospaced())
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                    Text(sw.realPreview).font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                // Bodies (only if captured + decryptable)
                if rec.bodyStored {
                    section(NSLocalizedString("Request body", comment: ""),
                            symbol: "arrow.up.doc",
                            tint: .secondary) {
                        bodyView(bodyRequest)
                    }
                    section(NSLocalizedString("Response body", comment: ""),
                            symbol: "arrow.down.doc",
                            tint: .secondary) {
                        bodyView(bodyResponse)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reloadBodies(for rec: TraceRecord) {
        guard rec.bodyStored else {
            bodyRequest = nil; bodyResponse = nil; return
        }
        bodyRequest  = store.loadBody(for: rec, kind: .request)
        bodyResponse = store.loadBody(for: rec, kind: .response)
    }

    private func metaCell(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundStyle(.tertiary)
            Text(v).font(.caption.monospaced())
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        symbol: String,
                                        tint: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            content()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func bodyView(_ data: Data?) -> some View {
        if let data {
            // Best-effort UTF-8; fall back to a hex-ish preview.
            if let s = String(data: data, encoding: .utf8) {
                Text(s)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(40)
                    .truncationMode(.tail)
            } else {
                Text(String(format: NSLocalizedString("(binary %lld bytes)", comment: ""),
                            Int(data.count)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text(NSLocalizedString("(not captured / decryption failed)", comment: ""))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func profileName(for id: UUID) -> String {
        profiles.first(where: { $0.id == id })?.name ?? "—"
    }
}
