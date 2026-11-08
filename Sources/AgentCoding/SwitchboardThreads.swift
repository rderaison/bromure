import AppKit
import SwiftUI

// The Switchboard talks about many sessions at once. Each thing it does is
// about a particular one, and the transcript says which: a tool call names its
// `session`, a host notice names it in quotes, a reply refers to it by handle.
// That's enough to tell the chains apart, with nothing asked of the agent.

/// One chain of discussion: everything about one session.
struct SwitchboardThread: Identifiable, Equatable {
    /// The session's handle, lowercased, or a name only a notice knows.
    var id: String
    var name: String
    var sessionID: UUID?
    /// How many of the conversation's items are about it.
    var count: Int
    var last: Date?
    /// Its colour, stable for the conversation (see `ThreadInk`).
    var hue: Int
}

/// The conversation, cut and attributed.
struct ThreadedConversation: Equatable {
    /// A reply covering several sessions comes back as one item per section.
    var items: [TranscriptItem] = []
    /// Item id → the threads it's about, for labelling.
    var threadsOf: [Int: [String]] = [:]
    /// Item id → the threads whose view includes it: also what you said that
    /// led to them, which carries no label of its own.
    var visibleIn: [Int: Set<String>] = [:]
    /// Most recently active first.
    var threads: [SwitchboardThread] = []

    func thread(_ id: String) -> SwitchboardThread? { threads.first { $0.id == id } }

    /// `filter` if there's still such a thread. Picked, then gone (the transcript
    /// replaced, the conversation caught up empty), it counts as no filter:
    /// the chips to undo it may be gone with it, leaving a blank chat.
    func effective(_ filter: String?) -> String? {
        filter.flatMap { thread($0)?.id }
    }

    /// The conversation as shown with `filter` picked (nil: all of it).
    func items(in filter: String?) -> [TranscriptItem] {
        guard let filter = effective(filter) else { return items }
        return items.filter { visibleIn[$0.id]?.contains(filter) == true }
    }

    /// Row id → the threads to head it with: where the subject changes. A notice
    /// heads itself, and your own message ends the run.
    func headers(_ rows: [TranscriptRow]) -> [Int: [String]] {
        var out: [Int: [String]] = [:]
        var current: [String] = []
        for row in rows {
            switch row {
            case .changes:
                continue
            case .item(let item):
                if case .userText(let t) = item.kind {
                    current = DelegationNotice.stripSwitchboard(t) != nil ? (threadsOf[item.id] ?? []) : []
                    continue
                }
                head(row.id, threadsOf[item.id] ?? [], &current, &out)
            case .activity(let run):
                var keys: [String] = []
                for i in run { for k in threadsOf[i.id] ?? [] where !keys.contains(k) { keys.append(k) } }
                head(row.id, keys, &current, &out)
            }
        }
        return out
    }

    private func head(_ id: Int, _ keys: [String], _ current: inout [String], _ out: inout [Int: [String]]) {
        guard !keys.isEmpty else { return }
        if Set(keys) != Set(current) { out[id] = keys }
        current = keys
    }
}

enum SwitchboardThreading {
    /// What the conversation calls a session.
    struct Alias: Equatable {
        var text: String      // lowercased
        var key: String
        var name: String
        var sessionID: UUID
    }

    static func aliases(handles: [UUID: String], sessions: [AgentSession]) -> [Alias] {
        var out: [Alias] = []
        for s in sessions where !s.isSwitchboard && !s.isDeleted {
            guard let h = handles[s.id] else { continue }
            let key = h.lowercased()
            out.append(Alias(text: key, key: key, name: h, sessionID: s.id))
            if !s.title.isEmpty, s.title.lowercased() != key {
                out.append(Alias(text: s.title.lowercased(), key: key, name: h, sessionID: s.id))
            }
        }
        return out.sorted { $0.text.count > $1.text.count }   // the longest name wins
    }

    /// The aliases ready to look for: by first character, so a message is read
    /// once instead of once per name (a busy Switchboard has thousands of
    /// messages and two names a session; searched name by name, opening it
    /// froze the window for seconds). In Unicode scalars: comparing and hashing
    /// `Character`s costs more than the whole rest of the scan.
    struct AliasIndex {
        struct Entry {
            var rank: Int            // in `aliases`' order: the longest first
            var scalars: [Unicode.Scalar]
            var key: String
            var compound: Bool
        }
        fileprivate var byFirst: [Unicode.Scalar: [Entry]] = [:]

        init(_ aliases: [Alias]) {
            for (rank, a) in aliases.enumerated() where a.text.count >= 3 {
                let scalars = Array(a.text.unicodeScalars)
                byFirst[scalars[0], default: []].append(Entry(
                    rank: rank, scalars: scalars, key: a.key,
                    compound: a.text.contains("-") || a.text.contains(" ")))
            }
        }
    }

    /// The sessions `text` refers to, in order of mention. A handle of several
    /// words reads as itself anywhere. A single word (`infra`, `docs`) could be
    /// plain English: it counts only marked as a name (`@infra`, `infra` in code
    /// or quotes or bold) or leading its line.
    static func mentions(in text: String, aliases: [Alias]) -> [String] {
        mentions(in: text, index: AliasIndex(aliases))
    }

    static func mentions(in text: String, index: AliasIndex) -> [String] {
        guard !index.byFirst.isEmpty else { return [] }
        let lower = Array(text.lowercased().unicodeScalars)
        // Every place a name could start: not inside a word.
        var hits: [(rank: Int, start: Int, end: Int, key: String)] = []
        for p in lower.indices {
            guard let entries = index.byFirst[lower[p]] else { continue }
            let before: Unicode.Scalar? = p > 0 ? lower[p - 1] : nil
            guard !isWordScalar(before) else { continue }
            for e in entries {
                let end = p + e.scalars.count
                guard end <= lower.count, lower[p..<end].elementsEqual(e.scalars) else { continue }
                let after: Unicode.Scalar? = end < lower.count ? lower[end] : nil
                guard !isWordScalar(after) else { continue }
                let marked = before.map { "@`“\"*'‘".unicodeScalars.contains($0) } ?? false
                guard e.compound || marked || leadsLine(lower, p) else { continue }
                hits.append((e.rank, p, end, e.key))
            }
        }
        // The longest name wins where two overlap.
        var claimed: [Range<Int>] = []
        var found: [(at: Int, key: String)] = []
        for h in hits.sorted(by: { ($0.rank, $0.start) < ($1.rank, $1.start) }) {
            let r = h.start..<h.end
            guard !claimed.contains(where: { $0.overlaps(r) }) else { continue }
            claimed.append(r)
            found.append((h.start, h.key))
        }
        var keys: [String] = []
        for f in found.sorted(by: { $0.at < $1.at }) where !keys.contains(f.key) { keys.append(f.key) }
        return keys
    }

    /// Part of a word: a letter or digit (or a mark on one), `-`, `_`.
    private static func isWordScalar(_ s: Unicode.Scalar?) -> Bool {
        guard let s else { return false }
        if s.isASCII {
            let v = s.value
            return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) || (v >= 0x30 && v <= 0x39) || v == 0x2D || v == 0x5F
        }
        let p = s.properties
        switch p.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return p.isAlphabetic || p.numericType != nil
        }
    }

    /// Only bullets, numbering or blanks between the line's start and `p`.
    private static func leadsLine(_ scalars: [Unicode.Scalar], _ p: Int) -> Bool {
        var i = p
        while i > 0 {
            i -= 1
            let c = scalars[i]
            if "\n\r\u{0B}\u{0C}\u{85}\u{2028}\u{2029}".unicodeScalars.contains(c) { return true }
            guard " \t•-*>.".unicodeScalars.contains(c) || c.properties.numericType != nil else { return false }
        }
        return true
    }

    /// The `session` argument of a Switchboard tool call.
    static func sessionArgument(_ detail: String) -> String? {
        guard let data = detail.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = o["session"] as? String, !s.isEmpty else { return nil }
        return s.hasPrefix("@") ? String(s.dropFirst()) : s
    }

    private static func isJSONObject(_ s: String) -> Bool {
        guard let d = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) is [String: Any]
    }

    /// A notice names its session in quotes, even one no longer on this Mac.
    static func quotedName(_ text: String) -> String? {
        guard let a = text.firstIndex(of: "“"), let b = text[a...].firstIndex(of: "”") else { return nil }
        let name = text[text.index(after: a)..<b]
        return name.isEmpty ? nil : String(name)
    }

    /// `text` cut where one session's part ends: paragraphs and top-level
    /// bullets, whole code blocks staying with what they follow. Lines naming no
    /// session (a blocked session's numbered options) stay with the one before.
    static func sections(_ text: String, aliases: [Alias]) -> [(text: String, keys: [String])] {
        sections(text, index: AliasIndex(aliases))
    }

    static func sections(_ text: String, index: AliasIndex) -> [(text: String, keys: [String])] {
        var blocks: [String] = []
        var cur: [String] = []
        var fence = false
        func flush() { if !cur.isEmpty { blocks.append(cur.joined(separator: "\n")); cur = [] } }
        // "\r\n" is one Character to Swift: unfolded, a CRLF reply never splits.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence.toggle(); cur.append(line); continue }
            if fence { cur.append(line); continue }
            if t.isEmpty { flush(); continue }
            if line.hasPrefix("• ") || line.hasPrefix("- ") || line.hasPrefix("* ") { flush() }
            cur.append(line)
        }
        flush()
        var out: [(text: String, keys: [String])] = []
        for b in blocks {
            // Code belongs to what it follows, whatever names it happens to hold.
            let code = b.trimmingCharacters(in: .whitespaces).hasPrefix("```") || b.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
            if code, let last = out.indices.last {
                out[last].text += "\n\n" + b
                continue
            }
            let keys = mentions(in: b, index: index)
            if keys.isEmpty, let last = out.indices.last, !out[last].keys.isEmpty {
                out[last].text += "\n\n" + b
            } else if let last = out.indices.last, keys == out[last].keys {
                out[last].text += "\n\n" + b
            } else {
                out.append((b, keys))
            }
        }
        return out
    }

    static func analyze(_ items: [TranscriptItem], aliases: [Alias]) -> ThreadedConversation {
        let index = AliasIndex(aliases)
        var c = ThreadedConversation()
        var names: [String: (name: String, id: UUID?)] = [:]
        func resolve(_ raw: String) -> String {
            let l = raw.lowercased()
            if let a = aliases.first(where: { $0.text == l }) {
                names[a.key] = (a.name, a.sessionID)
                return a.key
            }
            if names[l] == nil { names[l] = (raw, nil) }
            return l
        }
        func known(_ keys: [String]) -> [String] {
            for k in keys { if let a = aliases.first(where: { $0.key == k }) { names[k] = (a.name, a.sessionID) } }
            return keys
        }
        // What the current turn is about: a notice's session, then the tools'.
        var turn: [String] = []
        var lastTool: [String] = []
        var order: [String] = []
        var counts: [String: Int] = [:]
        var lastAt: [String: Date] = [:]
        func emit(_ item: TranscriptItem, _ keys: [String]) {
            c.items.append(item)
            guard !keys.isEmpty else { return }
            c.threadsOf[item.id] = keys
            c.visibleIn[item.id] = Set(keys)
            for k in keys {
                if !order.contains(k) { order.append(k) }
                counts[k, default: 0] += 1
                if let t = item.timestamp { lastAt[k] = t }
            }
        }
        for item in items {
            switch item.kind {
            case .userText(let text):
                lastTool = []
                if let notice = DelegationNotice.stripSwitchboard(text) {
                    let keys = quotedName(notice).map { [resolve($0)] } ?? known(mentions(in: notice, index: index))
                    turn = keys
                    emit(item, keys)
                } else {
                    turn = known(mentions(in: text, index: index))
                    emit(item, turn)
                }
            case .toolUse(_, _, let detail):
                // Some agents keep a call's input as raw text, not an object: no
                // `session` to read, so the names in it are the best evidence.
                let raw = isJSONObject(detail) ? [] : known(mentions(in: detail, index: index))
                if let s = sessionArgument(detail) {
                    lastTool = [resolve(s)]
                    if !turn.contains(lastTool[0]) { turn = turn.isEmpty ? lastTool : turn + lastTool }
                } else if raw.count == 1 {
                    lastTool = raw
                    if !turn.contains(raw[0]) { turn = turn.isEmpty ? raw : turn + raw }
                } else {
                    lastTool = turn.count == 1 ? turn : []
                }
                emit(item, lastTool)
            case .toolResult:
                emit(item, lastTool)
            case .assistantText(let text):
                let parts = sections(text, index: index)
                let named = Set(parts.flatMap(\.keys))
                if named.count >= 2, parts.count >= 2 {
                    for (k, part) in parts.enumerated() {
                        let id = k == 0 ? item.id : TranscriptRow.chunkID(item.id, 1_000 + k)
                        emit(TranscriptItem(id: id, kind: .assistantText(part.text), timestamp: item.timestamp),
                             known(part.keys))
                    }
                } else if !named.isEmpty {
                    emit(item, known(parts.flatMap(\.keys).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }))
                } else {
                    // Says no name: it's about what this turn was about, if that's one thing.
                    emit(item, turn.count == 1 ? turn : [])
                }
            default:
                emit(item, turn.count == 1 ? turn : [])
            }
        }
        // What you said belongs with whatever it led to, up to the next turn.
        var opening: Int?
        for item in c.items {
            if case .userText(let t) = item.kind, DelegationNotice.stripSwitchboard(t) == nil {
                opening = item.id
            } else if case .userText = item.kind {
                opening = nil
            } else if let opening, let keys = c.threadsOf[item.id] {
                c.visibleIn[opening, default: []].formUnion(keys)
            }
        }
        // A colour each, by first appearance: the same ones as the chat grows.
        var used: Set<Int> = []
        var hues: [String: Int] = [:]
        for key in order {
            var h = ThreadInk.seed(key)
            for step in 0..<ThreadInk.count where !used.contains((h + step) % ThreadInk.count) {
                h = (h + step) % ThreadInk.count
                break
            }
            used.insert(h)
            if used.count == ThreadInk.count { used = [] }
            hues[key] = h
        }
        c.threads = order.map { k in
            SwitchboardThread(id: k, name: names[k]?.name ?? k, sessionID: names[k]?.id, count: counts[k] ?? 0,
                              last: lastAt[k], hue: hues[k] ?? 0)
        }.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
        return c
    }
}

/// What threading needs from the session store.
struct SwitchboardThreadingInputs: Equatable {
    var aliases: [SwitchboardThreading.Alias]
    /// Sessions waiting on the user, for their chips.
    var waiting: Set<UUID>

    @MainActor
    init(sessions: [AgentSession]) {
        aliases = SwitchboardThreading.aliases(handles: SwitchboardEngine.handles(of: sessions), sessions: sessions)
        waiting = Set(sessions.filter { $0.awaitingAnswer == true }.map(\.id))
    }
}

/// Keeps the analysis for the last inputs: the body runs on every model change.
final class SwitchboardThreadMemo {
    private var items: [TranscriptItem] = []
    private var aliases: [SwitchboardThreading.Alias] = []
    private var cached = ThreadedConversation()

    func conversation(_ items: [TranscriptItem], aliases: [SwitchboardThreading.Alias]) -> ThreadedConversation {
        if items == self.items, aliases == self.aliases { return cached }
        self.items = items
        self.aliases = aliases
        cached = SwitchboardThreading.analyze(items, aliases: aliases)
        return cached
    }
}

/// Thread colours: clearly apart in both appearances, none of them read as
/// red-for-error or the app's accent. The brand has no categorical palette, so
/// these are chosen to sit with its indigo at the same weight.
enum ThreadInk {
    private static let light: [UInt32] = [0x0B7A75, 0xB5541C, 0x7A3FB8, 0x2F7D32, 0xA8326E, 0x1F6FB2, 0x8A6D00, 0x5B6472]
    private static let dark: [UInt32] = [0x4FD1C5, 0xF6A06B, 0xC4A1F5, 0x8BD48F, 0xF08DBC, 0x7FBEF0, 0xE3C75A, 0xAAB4C4]
    static let count = light.count

    /// Stable across launches, unlike `hashValue`.
    static func seed(_ key: String) -> Int {
        var h: UInt32 = 2_166_136_261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Int(h % UInt32(count))
    }

    static func color(_ hue: Int, _ scheme: ColorScheme) -> Color {
        let v = (scheme == .dark ? dark : light)[((hue % count) + count) % count]
        return Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}

private extension View {
    func threadLabel(_ size: CGFloat = 10) -> some View {
        font(.system(size: size, weight: .semibold)).tracking(size * 0.1).textCase(.uppercase)
    }
}

private struct ThreadSwatch: View {
    let thread: SwitchboardThread
    var size: CGFloat = 8
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(ThreadInk.color(thread.hue, scheme)).frame(width: size, height: size)
    }
}

/// Across the top: every chain in the conversation, one click to read only it.
struct SwitchboardThreadBar: View {
    let conversation: ThreadedConversation
    @Binding var filter: String?
    /// Sessions waiting on the user, marked on their chips.
    var waiting: Set<UUID> = []
    var onOpen: ((UUID) -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(selected: conversation.effective(filter) == nil, label: NSLocalizedString("All", comment: "switchboard threads"),
                     count: nil, thread: nil) { filter = nil }
                ForEach(conversation.threads) { t in
                    chip(selected: filter == t.id, label: t.name, count: t.count, thread: t) {
                        filter = filter == t.id ? nil : t.id
                    }
                    .contextMenu {
                        if let id = t.sessionID, let onOpen {
                            Button(NSLocalizedString("Open Session", comment: "switchboard threads")) { onOpen(id) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
        .animation(.easeOut(duration: 0.15), value: filter)
    }

    private func chip(selected: Bool, label: String, count: Int?, thread: SwitchboardThread?,
                      action: @escaping () -> Void) -> some View {
        let ink = thread.map { ThreadInk.color($0.hue, scheme) } ?? Color.primary
        return Button(action: action) {
            HStack(spacing: 6) {
                if let thread { ThreadSwatch(thread: thread) }
                Text(label).lineLimit(1)
                if let count {
                    Text(verbatim: "\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
                if let id = thread?.sessionID, waiting.contains(id) {
                    Text(NSLocalizedString("Needs you", comment: "switchboard threads"))
                        .foregroundStyle(Color.red)
                }
            }
            .threadLabel()
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? ink.opacity(0.14) : Color.clear)
            .overlay(Rectangle().strokeBorder(selected ? ink.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Where the conversation turns to a chain: its name and colour, across the column.
struct SwitchboardThreadHeader: View {
    let threads: [SwitchboardThread]
    var onPick: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            ForEach(threads) { t in
                Button { onPick(t.id) } label: {
                    HStack(spacing: 6) {
                        ThreadSwatch(thread: t)
                        Text(t.name).threadLabel().foregroundStyle(ThreadInk.color(t.hue, scheme)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Show only this thread", comment: "switchboard threads"))
            }
            Rectangle()
                .fill(threads.first.map { ThreadInk.color($0.hue, scheme).opacity(0.3) } ?? .clear)
                .frame(height: 1)
        }
        .padding(.top, 8)
    }
}

/// A notice from the host, one quiet line: there are many of them, and they say
/// where the conversation turned rather than being part of it.
struct SwitchboardNoticeLine: View {
    let text: String
    let thread: SwitchboardThread?
    let time: Date?
    var onPick: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            if let thread {
                Button { onPick(thread.id) } label: {
                    HStack(spacing: 6) {
                        ThreadSwatch(thread: thread)
                        Text(thread.name).threadLabel().foregroundStyle(ThreadInk.color(thread.hue, scheme)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Show only this thread", comment: "switchboard threads"))
            }
            Text(remainder)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let time {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 8)
    }

    /// The notice without the name its label already shows.
    private var remainder: String {
        guard let thread else { return text }
        for form in ["“\(thread.name)” ", "\(thread.name) "] where text.hasPrefix(form) {
            return String(text.dropFirst(form.count))
        }
        return text
    }
}

// MARK: - Offscreen render (`__shot-ui switchboard`)

@MainActor
enum SwitchboardThreadsPreview {
    private static var retained: BeautifiedSessionModel?
    /// `BROMURE_SHOT_THREAD`: the shot shows this chain alone.
    static var picked: String? {
        CommandLine.arguments.contains("__shot-ui") ? ProcessInfo.processInfo.environment["BROMURE_SHOT_THREAD"] : nil
    }

    static func view() -> (AnyView, NSSize) {
        let now = Date()
        let f = ISO8601DateFormatter()
        func at(_ t: TimeInterval) -> String { f.string(from: now.addingTimeInterval(t)) }
        func user(_ t: TimeInterval, _ s: String) -> [String: Any] {
            ["type": "user", "timestamp": at(t), "message": ["role": "user", "content": s]]
        }
        func reply(_ t: TimeInterval, _ s: String) -> [String: Any] {
            ["type": "assistant", "timestamp": at(t), "message": ["role": "assistant", "content": [["type": "text", "text": s]]]]
        }
        func tool(_ t: TimeInterval, _ name: String, _ session: String) -> [String: Any] {
            ["type": "assistant", "timestamp": at(t), "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "t\(Int(t))", "name": "mcp__switchboard__\(name)", "input": ["session": session]]]]]
        }
        let lines: [[String: Any]] = [
            user(-2_400, "What's going on across my sessions?"),
            reply(-2_380, "Three are in flight, one needs you:\n\n• add-apple-pay needs you: it asks whether to store cards with Stripe or Adyen.\n\n• fix-login-redirect is working on the admin login, 4 of 6 tests pass.\n\n• nightly-docs finished, nothing to do."),
            user(-1_900, "Stripe. And tell fix-login-redirect to skip the SSO case for now."),
            tool(-1_890, "answer_question", "add-apple-pay"),
            tool(-1_880, "send_to_session", "fix-login-redirect"),
            reply(-1_870, "Done. add-apple-pay has Stripe, and fix-login-redirect will skip SSO."),
            user(-1_200, "[Switchboard] “nightly-docs” finished its turn — call next_events."),
            reply(-1_190, "It rebuilt the API reference. Nothing needs you there."),
            user(-700, "[Switchboard] “fix-login-redirect” finished its turn — call next_events."),
            tool(-695, "read_session", "fix-login-redirect"),
            reply(-680, "All 6 tests pass with SSO skipped. It's ready for review on `wt/login-redirect`."),
            user(-300, "[Switchboard] “add-apple-pay” needs you — call next_events."),
            tool(-295, "pending_question", "add-apple-pay"),
            reply(-280, "It wants to know where to put the webhook secret:\n\n1. In the environment\n2. In the vault\n\nTell me: add-apple-pay 2"),
        ]
        let data = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        let pid = UUID()
        var board = AgentSession(profileID: pid, tool: .claude, title: "Switchboard", windowIndex: 1)
        board.role = AgentSession.switchboardRole
        let others = ["Add Apple Pay", "Fix login redirect", "Nightly docs"].enumerated().map { n, title in
            AgentSession(profileID: pid, tool: .claude, title: title, createdAt: now.addingTimeInterval(Double(n) - 9_000), windowIndex: n + 2)
        }
        let store = AgentSessionStore(mirror: true)
        store.applyMirror([board] + others)
        let m = BeautifiedSessionModel(provider: FixtureTranscriptProvider(accent: .accentColor, transcript: data, working: false))
        m.sessionStore = store
        m.currentSession = { board }
        m.start()
        retained = m
        return (AnyView(BeautifiedSessionView(model: m)), NSSize(width: 980, height: 820))
    }
}
