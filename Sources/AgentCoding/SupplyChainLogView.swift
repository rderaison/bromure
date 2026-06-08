import SwiftUI

/// `tail -f` viewer for the MITM proxy's supply-chain log buffer.
/// Subscribes to `SupplyChainLog.shared` and auto-scrolls as new
/// lines arrive. Color-codes by event shape — green check / red
/// cross / blue arrow / red 451 / accent-color policy-engaged.
struct SupplyChainLogView: View {
    @StateObject private var model = SupplyChainLogModel()
    @State private var filter: String = ""
    @State private var autoScroll: Bool = true
    let onClose: () -> Void

    private var filtered: [SupplyChainLog.Entry] {
        guard !filter.isEmpty else { return model.entries }
        return model.entries.filter {
            $0.message.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Filter…", comment: ""),
                          text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle(NSLocalizedString("Auto-scroll", comment: ""),
                       isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Button {
                    SupplyChainLog.shared.clear()
                    model.entries.removeAll()
                } label: {
                    Label(NSLocalizedString("Clear", comment: ""),
                          systemImage: "trash")
                }
                .help(NSLocalizedString("Clear the buffer", comment: ""))
            }
            .padding(10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                        // Bottom anchor — scroll target when
                        // auto-scroll is on. Using a stable id (the
                        // sentinel string) avoids the
                        // re-render-by-last-id thrash.
                        Color.clear.frame(height: 1).id("__bottom__")
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: filtered.last?.id) {
                    guard autoScroll else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
                .onAppear {
                    // Initial jump to the latest entry without
                    // animation (would otherwise scroll from top
                    // through 5000 rows).
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }

            Divider()
            HStack {
                Text(footerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 720, minHeight: 360)
    }

    @ViewBuilder
    private func row(_ entry: SupplyChainLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timestamp(entry.date))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(color(for: entry.message))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var footerLabel: String {
        let total = model.entries.count
        if filter.isEmpty {
            return String(format: NSLocalizedString("%d entries", comment: ""), total)
        }
        return String(format: NSLocalizedString("%d of %d entries", comment: ""),
                      filtered.count, total)
    }

    private func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func color(for message: String) -> Color {
        if message.contains(" 451:") || message.contains("✗") {
            return .red
        }
        if message.contains("✓") {
            return .green
        }
        if message.contains("→") {
            return .blue
        }
        if message.contains("policy engaged") {
            return .accentColor
        }
        if message.contains("stripped") {
            return .orange
        }
        return .primary
    }
}

@MainActor
final class SupplyChainLogModel: ObservableObject {
    @Published var entries: [SupplyChainLog.Entry] = []
    private var task: Task<Void, Never>?

    init() {
        entries = SupplyChainLog.shared.snapshot()
        let stream = SupplyChainLog.shared.stream()
        task = Task { [weak self] in
            for await entry in stream {
                await MainActor.run {
                    self?.entries.append(entry)
                    // Mirror the buffer's cap so the in-memory view
                    // doesn't grow unbounded if the panel is left
                    // open over a long session.
                    if let self, self.entries.count > 6_000 {
                        self.entries.removeFirst(self.entries.count - 5_000)
                    }
                }
            }
        }
    }

    deinit { task?.cancel() }
}
