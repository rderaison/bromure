import SwiftUI

// MARK: - Flamegraph (one session) and room timeline (several)
//
// The session view lays its turns end to end — only time the agent was
// working takes space — with each turn's tool calls and model time stacked
// under it. The room view keeps real clock time, one lane per session, so
// overlap (who was busy while whom) shows.

extension SessionTimeline.Kind {
    /// Two tones per kind: bars are drawn as a soft vertical gradient.
    var colors: (Color, Color) {
        switch self {
        case .model: return (Color(red: 0.60, green: 0.47, blue: 0.98), Color(red: 0.45, green: 0.33, blue: 0.88))
        case .shell: return (Color(red: 1.00, green: 0.66, blue: 0.30), Color(red: 0.93, green: 0.47, blue: 0.16))
        case .edit:  return (Color(red: 0.35, green: 0.84, blue: 0.53), Color(red: 0.18, green: 0.66, blue: 0.40))
        case .read:  return (Color(red: 0.38, green: 0.66, blue: 1.00), Color(red: 0.20, green: 0.48, blue: 0.90))
        case .web:   return (Color(red: 0.30, green: 0.82, blue: 0.84), Color(red: 0.12, green: 0.62, blue: 0.68))
        case .agent: return (Color(red: 1.00, green: 0.47, blue: 0.66), Color(red: 0.86, green: 0.28, blue: 0.50))
        case .mcp:   return (Color(red: 0.70, green: 0.72, blue: 0.80), Color(red: 0.50, green: 0.52, blue: 0.62))
        case .other: return (Color(red: 0.78, green: 0.74, blue: 0.62), Color(red: 0.60, green: 0.56, blue: 0.46))
        }
    }
    var color: Color { colors.0 }
    var gradient: LinearGradient { LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom) }
    var symbol: String {
        switch self {
        case .model: return "sparkles"
        case .shell: return "terminal"
        case .edit:  return "pencil"
        case .read:  return "doc.text.magnifyingglass"
        case .web:   return "globe"
        case .agent: return "person.2"
        case .mcp:   return "puzzlepiece.extension"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

enum TimelineFormat {
    static func duration(_ t: TimeInterval) -> String {
        if t < 1 { return String(format: "%.1fs", t) }
        return TranscriptSearchIndex.duration(t)
    }
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    /// Ticks across more than a day carry the day too.
    static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        return f
    }()
    /// A turn long enough to be worth celebrating: the agent carried on by
    /// itself this long.
    static let longRun: TimeInterval = 10 * 60
}

private let heroGradient = LinearGradient(
    colors: [Color(red: 0.55, green: 0.40, blue: 0.98), Color(red: 0.25, green: 0.55, blue: 1.0),
             Color(red: 0.20, green: 0.78, blue: 0.70)],
    startPoint: .leading, endPoint: .trailing)

/// A number and its caption, as a small raised tile.
private struct StatTile: View {
    let value: String
    let caption: String
    let symbol: String
    var accent: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                Text(caption).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// The share of time per kind: one proportional bar plus a legend.
/// Left-to-right rows that wrap at the offered width, and never ask for
/// more width than they're offered.
struct LegendFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rs = rows(subviews, width: width)
        let height = rs.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) }
            + lineSpacing * CGFloat(max(rs.count - 1, 0))
        let widest = rs.map { r in r.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(r.count - 1, 0)) }.max() ?? 0
        return CGSize(width: proposal.width.map { min($0, widest) } ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let h = row.map(\.1.height).max() ?? 0
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += h + lineSpacing
        }
    }
}

struct TimelineBreakdown: View {
    let totals: [(kind: SessionTimeline.Kind, time: TimeInterval)]
    @State private var shown = false
    var body: some View {
        let sum = max(totals.reduce(0) { $0 + $1.time }, 0.001)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(totals, id: \.kind) { t in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(t.kind.gradient)
                            .frame(width: max((geo.size.width - CGFloat(totals.count - 1) * 2) * CGFloat(t.time / sum), 2))
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .scaleEffect(x: shown ? 1 : 0.02, anchor: .leading)
            }
            .frame(height: 9)
            .clipShape(Capsule())
            // Wraps: eight fixed-size entries in one row outgrew the
            // popover, which then centred (and clipped) everything.
            LegendFlow(spacing: 14, lineSpacing: 6) {
                ForEach(totals, id: \.kind) { t in
                    HStack(spacing: 5) {
                        Image(systemName: t.kind.symbol).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(t.kind.color)
                        Text(t.kind.label).foregroundStyle(.secondary).lineLimit(1)
                        Text(TimelineFormat.duration(t.time)).monospacedDigit()
                        Text("\(Int((t.time / sum * 100).rounded()))%").foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .fixedSize()
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.15)) { shown = true } }
    }
}

/// One bar: a gradient capsule-ish rectangle, glowing when hovered.
private struct FlameBar: View {
    let label: String
    let gradient: LinearGradient
    let glow: Color
    let width: CGFloat
    let height: CGFloat
    let highlighted: Bool
    var trophy = false
    var body: some View {
        RoundedRectangle(cornerRadius: min(5, height / 3))
            .fill(gradient)
            .overlay(RoundedRectangle(cornerRadius: min(5, height / 3))
                .strokeBorder(Color.white.opacity(highlighted ? 0.85 : 0.18), lineWidth: highlighted ? 1.5 : 0.5))
            .overlay(alignment: .leading) {
                if width > 30 {
                    HStack(spacing: 4) {
                        if trophy { Image(systemName: "trophy.fill").font(.system(size: 9.5)) }
                        Text(label).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(.horizontal, 6)
                }
            }
            .frame(width: width, height: height)
            .shadow(color: glow.opacity(highlighted ? 0.55 : 0), radius: highlighted ? 8 : 0)
            .scaleEffect(highlighted ? 1.02 : 1, anchor: .center)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

/// The line under the graph: what the pointer is on, or how to use it.
private struct HoverLine: View {
    let text: String?
    let hint: String
    var body: some View {
        Text(text ?? hint)
            .font(.system(size: 11.5, weight: text == nil ? .regular : .medium))
            .foregroundStyle(text == nil ? .tertiary : .primary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 30, alignment: .topLeading)
            .animation(.none, value: text)
    }
}

// MARK: Session

struct FlameGraphView: View {
    let timeline: SessionTimeline
    @State private var focus: Int?
    @State private var zoom: Double = 1
    @State private var hovered: Int?
    @State private var hoverText: String?
    @State private var grown = false

    private static let rowHeight: CGFloat = 22
    private static let turnHeight: CGFloat = 28
    private static let turnGap: CGFloat = 4

    private var shown: [SessionTimeline.Turn] {
        focus.flatMap { f in timeline.turns.first { $0.id == f } }.map { [$0] } ?? timeline.turns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if timeline.turns.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "stopwatch").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(NSLocalizedString("No timed turns yet: the timeline fills in as the agent works.", comment: "flamegraph"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                hero
                if focus == nil, let run = timeline.longestTurn, run.duration >= TimelineFormat.longRun {
                    celebration(run)
                }
                graphCard
                HoverLine(text: hoverText,
                          hint: NSLocalizedString("Hover a bar for what the agent was doing · click a turn to zoom in", comment: "flamegraph"))
                TimelineBreakdown(totals: SessionTimeline(turns: shown).totals)
                    .id(focus ?? -1)   // replay its grow-in on focus change
            }
        }
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.86)) { grown = true } }
    }

    private var hero: some View {
        let turns = shown
        let busy = turns.reduce(0) { $0 + $1.duration }
        let sub = SessionTimeline(turns: turns)
        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                if let f = focus, let t = timeline.turns.first(where: { $0.id == f }) {
                    Button { withAnimation(.spring(response: 0.45)) { focus = nil; zoom = 1 } } label: {
                        Label(NSLocalizedString("All turns", comment: "flamegraph"), systemImage: "chevron.left")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.link)
                    Text(t.prompt.isEmpty ? NSLocalizedString("(no message)", comment: "flamegraph") : t.prompt)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(TimelineFormat.duration(busy))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(heroGradient)
                Text(focus == nil
                     ? String(format: NSLocalizedString("of work across %d turns", comment: "flamegraph hero"), turns.count)
                     : NSLocalizedString("in this turn", comment: "flamegraph hero"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatTile(value: "\(sub.toolCalls)", caption: NSLocalizedString("tool calls", comment: "flamegraph"),
                     symbol: "wrench.and.screwdriver.fill", accent: SessionTimeline.Kind.shell.color)
            if sub.filesTouched > 0 {
                StatTile(value: "\(sub.filesTouched)", caption: NSLocalizedString("files edited", comment: "flamegraph"),
                         symbol: "pencil", accent: SessionTimeline.Kind.edit.color)
            }
            if let run = sub.longestTurn {
                StatTile(value: TimelineFormat.duration(run.duration),
                         caption: NSLocalizedString("longest solo run", comment: "flamegraph"),
                         symbol: run.duration >= TimelineFormat.longRun ? "trophy.fill" : "figure.run",
                         accent: run.duration >= TimelineFormat.longRun ? .orange : .accentColor)
            }
            VStack(spacing: 4) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...40).frame(width: 92).controlSize(.mini)
            }
        }
    }

    private func celebration(_ run: SessionTimeline.Turn) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 16))
                .foregroundStyle(LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: NSLocalizedString("Worked %@ on its own", comment: "flamegraph celebration"),
                            TimelineFormat.duration(run.duration)))
                    .font(.system(size: 13, weight: .semibold))
                Text(String(format: NSLocalizedString("%d tool calls without a single prompt — “%@”", comment: "flamegraph celebration"),
                            run.segments.filter { $0.kind != .model }.count, run.prompt))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(NSLocalizedString("See it", comment: "flamegraph celebration")) {
                withAnimation(.spring(response: 0.45)) { focus = run.id; zoom = 1 }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(LinearGradient(colors: [Color.orange.opacity(0.16), Color.yellow.opacity(0.07)],
                                 startPoint: .leading, endPoint: .trailing)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.25)))
    }

    private var graphCard: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    graph(width: max(geo.size.width - 20, 200) * zoom)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .frame(minHeight: 110)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func graph(width: CGFloat) -> some View {
        let turns = shown
        let total = max(turns.reduce(0) { $0 + $1.duration }, 0.001)
        let gaps = CGFloat(max(turns.count - 1, 0)) * Self.turnGap
        let scale = (width - gaps) / CGFloat(total)
        var offsets: [Int: CGFloat] = [:]
        var x: CGFloat = 0
        for t in turns { offsets[t.id] = x; x += CGFloat(t.duration) * scale + Self.turnGap }
        let lanes = turns.map(\.lanes).max() ?? 0
        let height = Self.turnHeight + 5 + CGFloat(max(lanes, 1)) * (Self.rowHeight + 3)
        let long = TimelineFormat.longRun

        return ZStack(alignment: .topLeading) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { i, t in
                let x0 = offsets[t.id] ?? 0
                let w = max(CGFloat(t.duration) * scale, 2)
                let isLong = t.duration >= long
                FlameBar(label: (t.prompt.isEmpty ? "" : t.prompt + " · ") + TimelineFormat.duration(t.duration),
                         gradient: isLong
                            ? LinearGradient(colors: [.orange, Color(red: 0.93, green: 0.35, blue: 0.35)], startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.72)], startPoint: .top, endPoint: .bottom),
                         glow: isLong ? .orange : .accentColor,
                         width: w, height: Self.turnHeight, highlighted: hovered == t.id, trophy: isLong)
                    .offset(x: x0, y: 0)
                    .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                    .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(Double(i) * 0.03), value: grown)
                    .onHover { on in
                        hovered = on ? t.id : (hovered == t.id ? nil : hovered)
                        hoverText = on ? String(format: NSLocalizedString("“%@” — %@, %d tool calls · click to zoom in", comment: "flamegraph turn"),
                                                t.prompt, TimelineFormat.duration(t.duration),
                                                t.segments.filter { $0.kind != .model }.count) : nil
                    }
                    .onTapGesture { if focus == nil { withAnimation(.spring(response: 0.45)) { focus = t.id; zoom = 1 } } }
                ForEach(t.segments) { s in
                    let sx = x0 + CGFloat(s.start.timeIntervalSince(t.start)) * scale
                    let sw = max(CGFloat(s.duration) * scale, 1.5)
                    FlameBar(label: s.kind == .model ? s.kind.label : (s.detail.isEmpty ? s.name : s.detail),
                             gradient: s.kind.gradient, glow: s.kind.color,
                             width: sw, height: Self.rowHeight, highlighted: hovered == s.id)
                        .offset(x: sx, y: Self.turnHeight + 5 + CGFloat(s.lane) * (Self.rowHeight + 3))
                        .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                        .animation(.spring(response: 0.8, dampingFraction: 0.86).delay(0.08 + Double(i) * 0.03), value: grown)
                        .onHover { on in
                            hovered = on ? s.id : (hovered == s.id ? nil : hovered)
                            hoverText = on ? (s.kind == .model
                                ? String(format: NSLocalizedString("Thinking & writing — %@", comment: "flamegraph"), TimelineFormat.duration(s.duration))
                                : "\(s.name)\(s.detail.isEmpty ? "" : " · \(s.detail)") — \(TimelineFormat.duration(s.duration))") : nil
                        }
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

// MARK: Room

struct RoomTimelineView: View {
    struct Lane: Identifiable {
        let id: UUID
        let title: String
        let tool: Profile.Tool
        let timeline: SessionTimeline
        /// The session's nickname ("@api"), what the room calls it by.
        var nickname: String? = nil
        /// The session in a hover line: its nickname when it has one.
        var shortName: String { nickname.map { "@" + $0 } ?? title }
    }
    let lanes: [Lane]
    /// Where the zoom starts (the offline render looks at an overflowing chart).
    var initialZoom: Double = 1
    @State private var zoom: Double = 1
    @State private var hovered: Int?
    @State private var hoverText: String?
    @State private var grown = false

    private static let laneHeight: CGFloat = 26
    private static let labelWidth: CGFloat = 180
    /// One session's row, label and track alike (they sit in two columns).
    private static let rowHeight: CGFloat = 30

    /// Most sessions working at the same moment.
    private static func peak(_ lanes: [Lane]) -> Int {
        var events: [(Date, Int)] = []
        for l in lanes { for t in l.timeline.turns { events.append((t.start, 1)); events.append((t.end, -1)) } }
        var cur = 0, best = 0
        for e in events.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) { cur += e.1; best = max(best, cur) }
        return best
    }

    var body: some View {
        let withTurns = lanes.filter { !$0.timeline.turns.isEmpty }
        let all = SessionTimeline(turns: withTurns.flatMap(\.timeline.turns))
        VStack(alignment: .leading, spacing: 14) {
            if withTurns.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(NSLocalizedString("No timed turns in this room yet.", comment: "room timeline"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TimelineFormat.duration(all.busy))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(heroGradient)
                        Text(String(format: NSLocalizedString("of combined work by %d agents", comment: "room timeline hero"), withTurns.count))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    StatTile(value: "\(Self.peak(withTurns))", caption: NSLocalizedString("at once, at peak", comment: "room timeline"),
                             symbol: "person.3.fill", accent: SessionTimeline.Kind.agent.color)
                    StatTile(value: "\(all.toolCalls)", caption: NSLocalizedString("tool calls", comment: "flamegraph"),
                             symbol: "wrench.and.screwdriver.fill", accent: SessionTimeline.Kind.shell.color)
                    if let busiest = withTurns.max(by: { $0.timeline.busy < $1.timeline.busy }) {
                        StatTile(value: busiest.shortName, caption: NSLocalizedString("worked the most", comment: "room timeline"),
                                 symbol: "trophy.fill", accent: .orange)
                            .frame(maxWidth: 200)
                    }
                    VStack(spacing: 4) {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: $zoom, in: 1...60).frame(width: 92).controlSize(.mini)
                    }
                }
                GeometryReader { geo in
                    // Vertical here; the tracks scroll sideways on their own
                    // inside `chart`, so the session labels stay put.
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            chart(withTurns, width: max(geo.size.width - Self.labelWidth - 28, 200) * zoom)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                .frame(minHeight: 140)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
                HoverLine(text: hoverText,
                          hint: NSLocalizedString("Hover a bar for who was doing what, and for how long", comment: "room timeline"))
                TimelineBreakdown(totals: all.totals)
            }
        }
        .onAppear {
            zoom = initialZoom
            withAnimation(.spring(response: 0.8, dampingFraction: 0.86)) { grown = true }
        }
    }

    private func chart(_ lanes: [Lane], width: CGFloat) -> some View {
        let start = lanes.compactMap(\.timeline.start).min() ?? Date()
        let end = lanes.compactMap(\.timeline.end).max() ?? start.addingTimeInterval(1)
        let span = max(end.timeIntervalSince(start), 1)
        let scale = width / CGFloat(span)
        func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start)) * scale }

        return HStack(alignment: .top, spacing: 0) {
            // The sessions, pinned: scrolling the tracks sideways leaves them
            // where they are.
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(width: Self.labelWidth, height: 14)
                ForEach(lanes) { lane in
                    laneLabel(lane)
                        .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
                }
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<6, id: \.self) { i in
                            let t = start.addingTimeInterval(span * Double(i) / 5)
                            Text((span > 20 * 3600 ? TimelineFormat.dayClock : TimelineFormat.clock).string(from: t))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .offset(x: min(x(t), width - 44))
                        }
                    }
                    .frame(width: width, height: 14, alignment: .topLeading)
                    ForEach(Array(lanes.enumerated()), id: \.element.id) { li, lane in
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.035))
                                .frame(width: width, height: Self.laneHeight)
                            ForEach(lane.timeline.turns) { t in
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.accentColor.opacity(0.18))
                                    .frame(width: max(CGFloat(t.duration) * scale, 2), height: Self.laneHeight)
                                    .offset(x: x(t.start))
                                ForEach(t.segments) { s in
                                    FlameBar(label: "", gradient: s.kind.gradient, glow: s.kind.color,
                                             width: max(CGFloat(s.duration) * scale, 1.5), height: Self.laneHeight - 8,
                                             highlighted: hovered == s.id)
                                        .offset(x: x(s.start), y: 4)
                                        .onHover { on in
                                            hovered = on ? s.id : (hovered == s.id ? nil : hovered)
                                            hoverText = on ? "\(lane.shortName) · \(s.kind == .model ? s.kind.label : s.name)\(s.detail.isEmpty ? "" : " · \(s.detail)") — \(TimelineFormat.duration(s.duration)) · \(TimelineFormat.clock.string(from: s.start))" : nil
                                        }
                                }
                            }
                        }
                        .frame(width: width, height: Self.laneHeight, alignment: .topLeading)
                        .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                        .animation(.spring(response: 0.8, dampingFraction: 0.86).delay(Double(li) * 0.06), value: grown)
                        .frame(height: Self.rowHeight)
                    }
                }
                .padding(.trailing, 6)
            }
        }
    }

    /// A session's row label: avatar, title, @nickname · time worked.
    private func laneLabel(_ lane: Lane) -> some View {
        HStack(spacing: 7) {
            AgentAvatar(tool: lane.tool, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(lane.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    if let nick = lane.nickname {
                        Text("@" + nick)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1).truncationMode(.tail)
                        Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Text(TimelineFormat.duration(lane.timeline.busy)).font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .padding(.trailing, 8)
    }
}

// MARK: Opening them

/// A session's flamegraph in its own window, following the live timeline.
struct SessionFlameWindow: View {
    let sessionID: UUID
    var body: some View {
        if let tl = SessionTimelineStore.shared.timeline(sessionID) {
            FlameGraphView(timeline: tl)
        } else {
            Text(NSLocalizedString("No timed turns yet: the timeline fills in as the agent works.", comment: "flamegraph"))
                .foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
@MainActor
enum TimelineWindows {
    private static var windows: [NSWindow] = []

    static func open<V: View>(title: String, _ view: V) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 520),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        win.collectionBehavior.insert(.fullScreenPrimary)
        let host = NSHostingView(rootView: view.padding(16).frame(minWidth: 520, minHeight: 280))
        host.sizingOptions = []
        win.contentView = host
        win.center()
        windows.removeAll { !$0.isVisible }
        windows.append(win)
        win.makeKeyAndOrderFront(nil)
    }
}
#endif

#if os(macOS)
extension FlameGraphView {
    /// Hidden verification hook (`bromure-ac __shot-flame <png> <transcript.jsonl> [agent]`):
    /// build the timeline from a real transcript, render the flamegraph to a
    /// PNG, print the turn count and working time, exit. No app delegate.
    static func renderSnapshot(transcript: Data, agent: String?, to path: String,
                               room: [(title: String, data: Data)] = []) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let tl = SessionTimeline.build(AgentTranscript.parse(transcript, agent: agent))
            let content: AnyView = room.isEmpty
                ? AnyView(FlameGraphView(timeline: tl))
                : AnyView(RoomTimelineView(lanes: room.map {
                    RoomTimelineView.Lane(id: UUID(), title: $0.title, tool: .claude,
                                          timeline: SessionTimeline.build(AgentTranscript.parse($0.data, agent: agent)),
                                          // A stand-in nickname: the file's stem, as the room would show one.
                                          nickname: String((($0.title as NSString).deletingPathExtension).prefix(10)))
                }, initialZoom: Double(ProcessInfo.processInfo.environment["BROMURE_SHOT_ZOOM"] ?? "") ?? 1))
            // BROMURE_SHOT_WIDTH: a narrower surface (the popover, a small window).
            let w = CGFloat(Double(ProcessInfo.processInfo.environment["BROMURE_SHOT_WIDTH"] ?? "") ?? 1000)
            let host = NSHostingView(rootView: content.padding(14)
                .frame(width: w, height: 460).background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(x: 0, y: 0, width: w, height: 460)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            let until = Date().addingTimeInterval(2.5)
            while Date() < until {
                if let ev = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                          inMode: .default, dequeue: true) { app.sendEvent(ev) }
                app.updateWindows()
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            print("turns=\(tl.turns.count) busy=\(Int(tl.busy))s segments=\(tl.turns.reduce(0) { $0 + $1.segments.count })")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("png=\(path)")
                }
            }
            exit(0)
        }
    }
}
#endif
