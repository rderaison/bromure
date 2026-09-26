#if os(macOS)
import AppKit
import SwiftUI

// MARK: - ⌘K command palette
//
// One search field over the window: jump to any session, room or machine,
// or run an action (new session, a machine's settings, the Security
// Timeline…). Arrow keys move, Return runs, Esc closes. The window builds
// the items (local or a fat client's mirror) and hosts the panel.

struct PaletteItem: Identifiable {
    enum Section: Int, CaseIterable {
        case actions, sessions, rooms, machines, messages
        var title: String {
            switch self {
            case .messages: return NSLocalizedString("In conversations", comment: "command palette section")
            case .actions:  return NSLocalizedString("Actions", comment: "command palette section")
            case .sessions: return NSLocalizedString("Sessions", comment: "command palette section")
            case .rooms:    return NSLocalizedString("Rooms", comment: "command palette section")
            case .machines: return NSLocalizedString("Machines", comment: "command palette section")
            }
        }
    }

    let id = UUID()
    let section: Section
    let title: String
    var subtitle: String = ""
    /// SF Symbol, drawn on `tint`.
    let icon: String
    var tint: Color = .accentColor
    /// Extra words it answers to ("settings", "preferences"…).
    var keywords: String = ""
    var shortcut: String? = nil
    let run: () -> Void

    /// How well it matches `query` (0 = not at all): every word must be
    /// found; a title prefix beats a word start beats anywhere.
    func score(_ query: String) -> Int {
        let q = query.lowercased().split(separator: " ").map(String.init)
        guard !q.isEmpty else { return 1 }
        let t = title.lowercased()
        let hay = (title + " " + subtitle + " " + keywords).lowercased()
        var total = 0
        for w in q {
            if t.hasPrefix(w) { total += 30 }
            else if t.contains(" " + w) { total += 20 }
            else if t.contains(w) { total += 12 }
            else if hay.contains(w) { total += 5 }
            else { return 0 }
        }
        return total
    }
}

struct CommandPaletteView: View {
    let items: [PaletteItem]
    let onClose: () -> Void
    /// Sessions found by what was said in them, for a query.
    var search: (String) -> [PaletteItem] = { _ in [] }
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            // Nothing typed: the actions, then the most relevant sessions.
            var out: [PaletteItem] = items.filter { $0.section == .actions }
            out += Array(items.filter { $0.section == .sessions }.prefix(8))
            out += Array(items.filter { $0.section == .rooms }.prefix(4))
            return out
        }
        let scored: [(item: PaletteItem, score: Int)] = items.map { ($0, $0.score(q)) }.filter { $0.score > 0 }
        let sorted = scored.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.item.section.rawValue < b.item.section.rawValue
        }
        var out = Array(sorted.prefix(40).map(\.item))
        if q.count >= 3 { out += search(q).prefix(12) }
        return out
    }

    var body: some View {
        let results = results
        ZStack(alignment: .top) {
            // The window behind, dimmed; a click there closes.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(NSLocalizedString("Search sessions, rooms, machines, actions…", comment: "command palette"),
                              text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .onSubmit { run(results) }
                    Text("esc")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Divider().opacity(0.6)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if results.isEmpty {
                                Text(NSLocalizedString("No match", comment: "room composer target"))
                                    .foregroundStyle(.secondary)
                                    .padding(16)
                            }
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                if i == 0 || results[i - 1].section != item.section {
                                    Text(item.section.title.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .kerning(0.6)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 14)
                                        .padding(.top, i == 0 ? 6 : 12)
                                        .padding(.bottom, 4)
                                }
                                row(item, on: i == selected)
                                    .id(item.id)
                                    .onTapGesture { item.run(); onClose() }
                                    .onHover { if $0 { selected = i } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: selected) { _, i in
                        if results.indices.contains(i) { proxy.scrollTo(results[i].id, anchor: .center) }
                    }
                }
            }
            .frame(width: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, results.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onExitCommand(perform: onClose)
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(selected) else { return }
        let item = results[selected]
        onClose()
        item.run()
    }

    private func row(_ item: PaletteItem, on: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(item.tint.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let k = item.shortcut {
                Text(k).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            }
            if on {
                Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(on ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
    }
}

/// Hosts the palette over a window's content (one at a time).
@MainActor
final class CommandPaletteHost {
    private var host: NSView?

    var isShown: Bool { host != nil }

    func toggle(in window: NSWindow, items: [PaletteItem], search: @escaping (String) -> [PaletteItem] = { _ in [] }) {
        if isShown { close(); return }
        guard let content = window.contentView else { return }
        let view = NSHostingView(rootView: CommandPaletteView(items: items, onClose: { [weak self] in self?.close() },
                                                              search: search))
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        host = view
        window.makeFirstResponder(view)
    }

    func close() {
        host?.removeFromSuperview()
        host = nil
    }
}
#endif
