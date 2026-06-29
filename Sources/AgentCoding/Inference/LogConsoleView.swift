import SwiftUI

/// Reusable `tail -f` viewer over a ``LogBuffer`` — filter, auto-scroll, clear,
/// and copy-all (handy for "paste me your engine log" diagnostics). Subscribes
/// to the buffer and auto-scrolls as new lines arrive. The empty-state copy and
/// per-line color are supplied by the caller so the same console serves any log.
struct LogConsoleView: View {
    let buffer: LogBuffer
    let emptyIcon: String
    let emptyTitle: String
    let emptyHints: [String]
    let color: (String) -> Color

    @StateObject private var model: LogConsoleModel
    @State private var filter: String = ""
    @State private var autoScroll: Bool = true

    init(buffer: LogBuffer,
         emptyIcon: String,
         emptyTitle: String,
         emptyHints: [String],
         color: @escaping (String) -> Color) {
        self.buffer = buffer
        self.emptyIcon = emptyIcon
        self.emptyTitle = emptyTitle
        self.emptyHints = emptyHints
        self.color = color
        _model = StateObject(wrappedValue: LogConsoleModel(buffer: buffer))
    }

    private var filtered: [LogBuffer.Entry] {
        guard !filter.isEmpty else { return model.entries }
        return model.entries.filter { $0.message.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("Filter…", comment: ""), text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle(NSLocalizedString("Auto-scroll", comment: ""), isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Button {
                    copyToPasteboard()
                } label: {
                    Label(NSLocalizedString("Copy", comment: ""), systemImage: "doc.on.doc")
                }
                .help(NSLocalizedString("Copy the shown log lines to the clipboard", comment: ""))
                .disabled(filtered.isEmpty)
                Button {
                    buffer.clear()
                    model.entries.removeAll()
                } label: {
                    Label(NSLocalizedString("Clear", comment: ""), systemImage: "trash")
                }
                .help(NSLocalizedString("Clear the buffer", comment: ""))
            }
            .padding(10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if filtered.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(filtered) { entry in
                                row(entry).id(entry.id)
                            }
                            // Stable bottom anchor for auto-scroll (avoids the
                            // re-render-by-last-id thrash).
                            Color.clear.frame(height: 1).id("__bottom__")
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: filtered.last?.id) {
                    guard autoScroll else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
                .onAppear { proxy.scrollTo("__bottom__", anchor: .bottom) }
            }

            Divider()
            HStack {
                Text(footerLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 720, minHeight: 360)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyIcon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(emptyTitle).font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(emptyHints, id: \.self) { bullet($0) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 540, alignment: .leading)
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ entry: LogBuffer.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timestamp(entry.date))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(color(entry.message))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var footerLabel: String {
        let total = model.entries.count
        if filter.isEmpty {
            return String(format: NSLocalizedString("%d lines", comment: ""), total)
        }
        return String(format: NSLocalizedString("%d of %d lines", comment: ""),
                      filtered.count, total)
    }

    private func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func copyToPasteboard() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let text = filtered.map { "\(f.string(from: $0.date))  \($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class LogConsoleModel: ObservableObject {
    @Published var entries: [LogBuffer.Entry] = []
    private var task: Task<Void, Never>?

    init(buffer: LogBuffer) {
        entries = buffer.snapshot()
        let stream = buffer.stream()
        task = Task { [weak self] in
            for await entry in stream {
                await MainActor.run {
                    self?.entries.append(entry)
                    // Mirror the buffer's cap so a long-open panel doesn't grow
                    // unbounded.
                    if let self, self.entries.count > 6_000 {
                        self.entries.removeFirst(self.entries.count - 5_000)
                    }
                }
            }
        }
    }

    deinit { task?.cancel() }
}

// MARK: - Inference-engine flavor

extension LogConsoleView {
    /// The Inference Engine Log console: the engine child's output + the
    /// parent's engine-lifecycle events, color-coded for diagnostics.
    static func inferenceEngine() -> LogConsoleView {
        LogConsoleView(
            buffer: InferenceLog.shared,
            emptyIcon: "cpu",
            emptyTitle: NSLocalizedString("No inference-engine activity yet", comment: ""),
            emptyHints: [
                NSLocalizedString("Enable local models for a workspace and open a session — the on-device MLX engine starts on demand.", comment: ""),
                NSLocalizedString("Model load, \"serving\", and any load/serve errors (unsupported architecture, out-of-memory, …) appear here live.", comment: ""),
                NSLocalizedString("The engine runs out-of-process; if it's OOM-killed and restarts, you'll see that here too.", comment: ""),
            ],
            color: Self.engineColor)
    }

    /// Color-code engine lines: red for failures, green for healthy/serving,
    /// orange for warnings, blue for in-progress.
    static func engineColor(_ message: String) -> Color {
        let l = message.lowercased()
        if l.contains("error") || l.contains("failed") || l.contains("couldn't")
            || l.contains("oom") || l.contains("crash") || l.contains("traceback")
            || l.contains("✗") {
            return .red
        }
        if l.contains("ready") || l.contains("serving") || l.contains("loaded") || l.contains("✓") {
            return .green
        }
        if l.contains("warn") {
            return .orange
        }
        if l.contains("loading") || l.contains("starting") || l.contains("spawn")
            || l.contains("restart") || l.contains("→") {
            return .blue
        }
        return .primary
    }
}
