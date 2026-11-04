import AppKit
import SwiftUI

// The chat's markers of time and of what's new, in Bromure's own look (see
// `BrandInk`): flat, square, hairlines and uppercase tracked labels.

/// A break in the transcript that says when the next row happened.
struct TranscriptTimeMarker: Equatable {
    enum Kind: Equatable { case day, time }
    var kind: Kind
    var date: Date
}

enum TranscriptTimeline {
    /// A pause this long within a day earns a marker of its own.
    static let gap: TimeInterval = 30 * 60

    static func date(of row: TranscriptRow) -> Date? {
        switch row {
        case .item(let i): return i.timestamp
        case .activity(let run): return run.first?.timestamp
        case .changes: return nil
        }
    }

    /// Row id → the marker that goes above it: where the day changes (and at
    /// the top), and after a long pause, unless the row is a message of yours,
    /// whose header already says the time. Rows with no time are stepped over.
    static func markers(_ rows: [TranscriptRow], calendar: Calendar = .current) -> [Int: TranscriptTimeMarker] {
        var out: [Int: TranscriptTimeMarker] = [:]
        var last: Date?
        for row in rows {
            guard let date = date(of: row) else { continue }
            if let previous = last {
                if !calendar.isDate(previous, inSameDayAs: date) {
                    out[row.id] = TranscriptTimeMarker(kind: .day, date: date)
                } else if date.timeIntervalSince(previous) >= gap, !isUserRow(row) {
                    out[row.id] = TranscriptTimeMarker(kind: .time, date: date)
                }
            } else {
                out[row.id] = TranscriptTimeMarker(kind: .day, date: date)
            }
            last = date
        }
        return out
    }

    private static func isUserRow(_ row: TranscriptRow) -> Bool {
        if case .item(let i) = row, case .userText = i.kind { return true }
        return false
    }

    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return NSLocalizedString("Today", comment: "chat time marker") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return NSLocalizedString("Yesterday", comment: "chat time marker")
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.weekday(.wide).month(.abbreviated).day()
                                       : .dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    static func timeLabel(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// The floating label while scrolling back: the day, and the time in it.
    static func scrubLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        dayLabel(date, now: now, calendar: calendar) + " · " + timeLabel(date)
    }
}

/// What the agent did since `since`.
struct UnseenSummary: Equatable {
    var since: Date
    var replies: Int
    var steps: Int
    /// The newest reply's opening words: what's new, at a glance.
    var latest: String?
    /// The first new item with a row of its own, for scrolling to it. nil when
    /// what's new is only a plan or a question, which aren't drawn among the rows.
    var firstItemIndex: Int?

    /// nil when there's nothing new. Times come from the transcript, so `since`
    /// must too: a guest's clock isn't this Mac's. Your own messages don't count.
    static func compute(_ items: [TranscriptItem], since: Date) -> UnseenSummary? {
        var first: Int?
        var anything = false
        var replies = 0, steps = 0
        var latest: String?
        for (i, item) in items.enumerated() {
            guard let t = item.timestamp, t > since else { continue }
            switch item.kind {
            case .userText: continue
            case .assistantText(let text):
                replies += 1
                latest = excerpt(text) ?? latest
            case .toolUse: steps += 1
            default: break
            }
            anything = true
            switch item.kind {
            case .todo, .question: break
            default: if first == nil { first = i }
            }
        }
        guard anything else { return nil }
        return UnseenSummary(since: since, replies: replies, steps: steps, latest: latest, firstItemIndex: first)
    }

    /// The first line that says something, without its markdown marks.
    static func excerpt(_ text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#>*_`-• ").union(.whitespaces))
                .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !line.isEmpty { return line }
        }
        return nil
    }

    /// The row the "new" divider goes above.
    static func firstRow(_ rows: [TranscriptRow], since: Date) -> Int? {
        for row in rows {
            switch row {
            case .item(let i):
                if case .userText = i.kind { continue }
                if let t = i.timestamp, t > since { return row.id }
            case .activity(let run):
                if run.contains(where: { ($0.timestamp ?? .distantPast) > since }) { return row.id }
            case .changes: continue
            }
        }
        return nil
    }

    var counts: String {
        var parts: [String] = []
        if replies > 0 {
            parts.append(replies == 1 ? NSLocalizedString("1 reply", comment: "chat: what's new")
                         : String(format: NSLocalizedString("%d replies", comment: "chat: what's new"), replies))
        }
        if steps > 0 {
            parts.append(steps == 1 ? NSLocalizedString("1 step", comment: "chat: what's new")
                         : String(format: NSLocalizedString("%d steps", comment: "chat: what's new"), steps))
        }
        return parts.isEmpty ? NSLocalizedString("New activity", comment: "chat: what's new")
                             : parts.joined(separator: " · ")
    }
}

/// How far each session's chat has been read on this Mac, by transcript time.
final class ChatSeenStore {
    static let shared = ChatSeenStore(defaults: .standard)
    private let defaults: UserDefaults
    private let key = "chat.seenUpTo"
    private let limit = 300

    init(defaults: UserDefaults) { self.defaults = defaults }

    func seen(_ id: UUID) -> Date? {
        (defaults.dictionary(forKey: key)?[id.uuidString] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// Only ever forward; the oldest entries make way past `limit`.
    func note(_ id: UUID, upTo date: Date) {
        var all = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let t = date.timeIntervalSince1970
        guard (all[id.uuidString] ?? 0) < t else { return }
        all[id.uuidString] = t
        if all.count > limit {
            for (k, _) in all.sorted(by: { $0.value < $1.value }).prefix(all.count - limit) { all[k] = nil }
        }
        defaults.set(all, forKey: key)
    }
}

/// Decides, a tick at a time, what the user hasn't seen. What's been seen moves
/// on only while the chat is in front of them with its end on screen. Arriving
/// (the chat opening, or coming back to the app) is when what's new is reported.
struct ChatArrivalTracker {
    private var armed = false
    private var wasActive = false

    /// The summary to show, when this tick is an arrival with something new.
    mutating func tick(id: UUID, items: [TranscriptItem], ready: Bool, active: Bool, atEnd: Bool,
                       store: ChatSeenStore) -> UnseenSummary? {
        guard ready, let newest = items.last(where: { $0.timestamp != nil })?.timestamp else {
            wasActive = active
            return nil
        }
        var found: UnseenSummary?
        let arriving = !armed || (active && !wasActive)
        if arriving, let seen = store.seen(id) {
            found = UnseenSummary.compute(items, since: seen)
        }
        // A chat never seen before starts here: all of it isn't "new".
        if !armed, store.seen(id) == nil { store.note(id, upTo: newest) }
        armed = true
        wasActive = active
        if active, atEnd { store.note(id, upTo: newest) }
        return found
    }
}

// MARK: - Views

private struct BrandLabel: ViewModifier {
    var size: CGFloat = 10
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .semibold)).tracking(size * 0.12).textCase(.uppercase)
    }
}
extension View {
    /// The brand's eyebrow: small, uppercase, tracked.
    func brandLabel(size: CGFloat = 10) -> some View { modifier(BrandLabel(size: size)) }
}

/// A square chip, as on the site: panel at rest, accent when it's the action.
private struct BrandChip: ButtonStyle {
    var prominent = false
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brandLabel()
            .foregroundStyle(prominent ? BrandInk.accentStrong(scheme) : BrandInk.secondary(scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(prominent ? BrandInk.accent(scheme).opacity(configuration.isPressed ? 0.25 : 0.15)
                                  : BrandInk.panel(scheme))
            .overlay(Rectangle().strokeBorder(prominent ? BrandInk.accent(scheme).opacity(0.5) : BrandInk.hairline(scheme),
                                              lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// A day or a long pause, across the column.
struct TranscriptTimeMarkerRow: View {
    let marker: TranscriptTimeMarker
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            switch marker.kind {
            case .day:
                Text(TranscriptTimeline.dayLabel(marker.date))
                    .brandLabel(size: 11)
                    .foregroundStyle(.primary)
            case .time:
                Text(TranscriptTimeline.timeLabel(marker.date))
                    .brandLabel()
                    .monospacedDigit()
                    .foregroundStyle(BrandInk.secondary(scheme))
            }
            Rectangle().fill(BrandInk.hairline(scheme)).frame(height: 1)
        }
        .padding(.top, marker.kind == .day ? 10 : 4)
        .accessibilityElement(children: .combine)
    }
}

/// Where the new part of the conversation begins.
struct TranscriptNewDivider: View {
    let since: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(BrandInk.accent(scheme)).frame(width: 52, height: 2)
            Text(NSLocalizedString("New", comment: "chat: where the new part begins"))
                .brandLabel(size: 11)
                .foregroundStyle(BrandInk.accentStrong(scheme))
            Text(String(format: NSLocalizedString("Since %@", comment: "chat: where the new part begins"),
                        TranscriptTimeline.timeLabel(since)))
                .brandLabel()
                .monospacedDigit()
                .foregroundStyle(BrandInk.secondary(scheme))
            Rectangle().fill(BrandInk.accent(scheme).opacity(0.35)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Floats over the chat on arriving: what happened, and the way to it.
struct WhileAwayPanel: View {
    let summary: UnseenSummary
    let onJump: () -> Void
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("While you were away", comment: "chat: what's new"))
                    .foregroundStyle(BrandInk.accentStrong(scheme))
                Text(summary.counts)
                    .foregroundStyle(BrandInk.secondary(scheme))
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BrandInk.secondary(scheme))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Dismiss", comment: "chat: what's new"))
                .accessibilityLabel(NSLocalizedString("Dismiss", comment: "chat: what's new"))
            }
            .brandLabel()
            HStack(alignment: .center, spacing: 14) {
                if let latest = summary.latest {
                    Text(latest)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                Button(action: onJump) {
                    Text(NSLocalizedString("Read what's new", comment: "chat: jump to where the new part begins"))
                }
                .buttonStyle(BrandChip(prominent: true))
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: 860, alignment: .leading)
        .background(BrandInk.panel(scheme))
        .overlay(Rectangle().strokeBorder(BrandInk.hairline(scheme), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Rectangle().fill(BrandInk.accent(scheme)).frame(width: 52, height: 2)
        }
    }
}

/// Where each timed row sits in the scroll view, for the floating label.
struct RowTimesKey: PreferenceKey {
    struct Entry: Equatable { var date: Date; var minY: CGFloat }
    static let defaultValue: [Entry] = []
    static func reduce(value: inout [Entry], nextValue: () -> [Entry]) { value.append(contentsOf: nextValue()) }
}

/// The floating label's state, apart from the chat's: it changes as often as the
/// user scrolls, and only the label should redraw for it, never the transcript.
@MainActor
final class ScrubLabelState: ObservableObject {
    @Published private(set) var label: String?
    private var lastTop: CGFloat?
    private var currentDate: Date?
    private var hide: Task<Void, Never>?

    /// Called as the rows move. `following`: the chat is at its end, or growing
    /// there; only scrolling back shows the label.
    func rowsMoved(_ rows: [RowTimesKey.Entry], following: Bool) {
        let top = rows.first?.minY
        defer { lastTop = top }
        guard !following, let top, let lastTop, abs(top - lastTop) > 0.5 else {
            if following, label != nil { label = nil }
            return
        }
        // The last row to have reached the top edge, else the first in view.
        let at = rows.last(where: { $0.minY <= 12 })?.date ?? rows.first?.date
        if let at, at != currentDate || label == nil {
            currentDate = at
            let text = TranscriptTimeline.scrubLabel(at)
            if text != label { label = text }
        }
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.label = nil
        }
    }
}

struct ScrubLabelView: View {
    @ObservedObject var state: ScrubLabelState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let label = state.label {
                Text(label)
                    .brandLabel(size: 11)
                    .monospacedDigit()
                    .foregroundStyle(BrandInk.accentOn(scheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(BrandInk.accent(scheme))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.label == nil)
        .allowsHitTesting(false)
    }
}

/// Back to the end of the chat, when scrolled up.
struct JumpToLatestButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                Text(NSLocalizedString("Jump to latest", comment: "beautified"))
            }
        }
        .buttonStyle(BrandChip())
    }
}

// MARK: - Offscreen render (`__shot-ui chat-indicators`)

@MainActor
enum ChatIndicatorsPreview {
    private static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }

    static func view() -> (AnyView, NSSize) {
        let now = Date()
        func user(_ t: TimeInterval, _ s: String) -> [String: Any] {
            ["type": "user", "timestamp": stamp(now.addingTimeInterval(t)), "message": ["role": "user", "content": s]]
        }
        func reply(_ t: TimeInterval, _ s: String) -> [String: Any] {
            ["type": "assistant", "timestamp": stamp(now.addingTimeInterval(t)),
             "message": ["role": "assistant", "content": [["type": "text", "text": s]]]]
        }
        func tool(_ t: TimeInterval, _ n: Int) -> [String: Any] {
            ["type": "assistant", "timestamp": stamp(now.addingTimeInterval(t)),
             "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t\(n)", "name": "Bash",
                                                            "input": ["command": "swift test --filter Login"]]]]]
        }
        let body = "The redirect loop comes from the session cookie being set on the wrong path, so the server never sees it on the way back.\n\n```swift\nlet cookie = HTTPCookie(properties: [.path: \"/\", .name: \"sid\"])\n```\n\nI'll change the path and add a test that follows the whole redirect chain."
        // Enough before it that scrolling back goes somewhere.
        let earlier: [[String: Any]] = (0..<10).flatMap { n -> [[String: Any]] in
            let at = TimeInterval(-190_000 + n * 1_500)
            return [user(at, "Earlier question number \(n + 1) about the login page."), reply(at + 60, body)]
        }
        var lines: [[String: Any]] = earlier + [
            user(-93_000, "Why does the login page keep redirecting to itself?"),
            reply(-92_900, body),
            user(-90_000, "Good. Do it, and check the admin login too."),
            reply(-89_900, "Done, both logins now share the same cookie setup. All 41 tests pass."),
            user(-7_000, "Now look at the logout flow. It feels slow."),
            reply(-6_900, "Logout waits on a session sweep it doesn't need. I'll move that to the background."),
            user(-1_500, "Please fix it and update the docs while you're there. I'll be back in a bit."),
        ]
        lines += (0..<3).map { tool(TimeInterval(-1_200 + $0 * 60), $0) }
        lines.append(reply(-1_000, "Logout is fixed: it now returns in 40 ms instead of 1.2 s."))
        lines.append(tool(-900, 9))
        lines.append(reply(-600, "**Docs are updated too.** The session page now explains the sweep, and the changelog has an entry. Ready for your review."))
        let data = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        let session = AgentSession(profileID: UUID(), tool: .claude, title: "Fix the login redirect loop", windowIndex: 1)
        ChatSeenStore.shared.note(session.id, upTo: now.addingTimeInterval(-1_400))
        let m = BeautifiedSessionModel(provider: FixtureTranscriptProvider(accent: .accentColor, transcript: data, working: false))
        m.currentSession = { session }
        m.start()
        retained = m
        return (AnyView(BeautifiedSessionView(model: m)), NSSize(width: 980, height: 760))
    }
    private static var retained: BeautifiedSessionModel?

    /// Scroll back as a user does, so the floating label shows as it really would.
    static func scrollBack(_ host: NSView, fraction: Double, window: NSWindow) {
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, s.documentView != nil, s.frame.height > 100 { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        guard let s = find(host), let doc = s.documentView else { return }
        ChatScrollDebug.assumeUserScrolling()
        let top = max(0, doc.frame.height - s.contentView.bounds.height) * (1 - fraction)
        for step in 1...10 {
            s.contentView.scroll(to: NSPoint(x: 0, y: s.contentView.bounds.minY + (top - s.contentView.bounds.minY) * Double(step) / 10))
            s.reflectScrolledClipView(s.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
}
