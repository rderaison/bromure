import Foundation
import SwiftUI

// The sessions home's SwiftUI views and colours (AgentSessions.swift holds
// the session model and stores, which build without SwiftUI).

extension SessionBucket {
    var tint: Color {
        switch self {
        case .needsYou: return .red
        case .working:  return .orange
        case .idle:     return .green
        case .asleep:   return .secondary
        case .ended:    return .secondary
        }
    }

}

// MARK: - Agent avatar

/// The agent's mark on a tinted rounded square — the same identity everywhere
/// (sidebar rows, session header, pickers). Status dot optional.
struct AgentAvatar: View {
    let tool: Profile.Tool
    var size: CGFloat = 26
    var status: AgentStatus? = nil

    static func tint(for tool: Profile.Tool) -> Color {
        switch tool {
        case .claude: return Color(hex: "#D97757")
        case .codex:  return Color(hex: "#2B2B2E")
        case .grok:   return Color(hex: "#4B5563")
        case .kimi:   return Color(hex: "#4F46E5")
        case .omp:    return Color(hex: "#0E9F6E")
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Self.tint(for: tool))
                .frame(width: size, height: size)
                .overlay {
                    SVGIcon(name: tool.rawValue, fallbackSymbol: "sparkle", size: size * 0.58)
                        .foregroundStyle(.white)
                }
            if let status {
                AgentStatusDot(status: status)
                    .scaleEffect(size >= 24 ? 1.25 : 1)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Row + sections

/// A native machine: a plain Mac attached to this app (Bromure Agent Host)
/// whose agents run directly on it — no VM, no sandbox, none of the
/// isolation the virtual machines give. Everything it hosts carries this
/// cue, so an unsandboxed agent is never mistaken for a sandboxed one.
enum NativeMachine {
    static let sectionTitle = NSLocalizedString("Native Machines", comment: "sidebar section")
    static let sectionNarrowTitle = NSLocalizedString("Native", comment: "sidebar section, when narrow")
    static let notSandboxed = NSLocalizedString("Not sandboxed", comment: "native machine")
    static func help(_ machine: String) -> String {
        String(format: NSLocalizedString("Runs natively on %@ — not in a sandboxed VM. Its agents can reach everything on that Mac.",
                                         comment: "native machine"), machine)
    }
    static let tint = Color.orange
}

/// The cue itself: a small shield with a slash.
struct NativeMachineBadge: View {
    var size: CGFloat = 10
    var body: some View {
        Image(systemName: "shield.slash.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(NativeMachine.tint)
    }
}

struct SessionRowView: View {
    let session: AgentSession
    let workspaceName: String
    let accentHex: String
    let dot: AgentStatus?
    let statusLine: String
    /// "3m" — when it last did something; nil while starting.
    var when: String? = nil
    /// Machine or folder gone: dimmed, still readable.
    var gone = false
    /// A delegate: indented under its delegator, this many levels down.
    var depth = 0
    let selected: Bool
    let onSelect: () -> Void
    /// The title to show when it differs from the session's own (another
    /// session has the same one).
    var title: String? = nil
    /// ⌘ held: its ⌘1–9 number, in place of the time.
    var shortcut: Int? = nil
    /// Found by what was said: the words around the match, instead of the status.
    var snippet: String? = nil
    /// The last reply, shown on hover.
    var preview: String? = nil
    /// Runs on a native machine (not sandboxed): its ring is dashed orange,
    /// with the badge.
    var native = false
    /// The agent said something nobody has read (`SessionHome.showsUnread`).
    var unread = false
    @State private var hovering = false

    private var mergeTint: Color? {
        switch session.branchMerge?.phase {
        case .requested?: return .orange
        case .merging?: return .accentColor
        case .conflicts?: return .orange
        case .merged?: return .green
        case .failed?: return .red
        case nil: return nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // The machine is the ring's colour (its name in the tooltip):
            // the row's width goes to the title, not to a repeated name.
            // The status dot sits on top of the ring, not under it.
            ZStack(alignment: .bottomTrailing) {
                AgentAvatar(tool: session.tool, size: 28)
                    .padding(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(native ? NativeMachine.tint
                                          : workspaceName.isEmpty ? Color.clear : Color(hex: accentHex).opacity(0.85),
                                          style: StrokeStyle(lineWidth: 1.5, dash: native ? [3, 2] : [])))
                if let dot {
                    AgentStatusDot(status: dot).scaleEffect(1.25)
                }
            }
            .overlay(alignment: .topLeading) {
                if native {
                    NativeMachineBadge(size: 9)
                        .padding(1.5)
                        .background(Circle().fill(Color.acSidebar))
                        .offset(x: -4, y: -4)
                }
            }
            .opacity(session.hasEnded ? 0.6 : 1)
            .help(native ? NativeMachine.help(workspaceName) : workspaceName)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title ?? session.title)
                        .font(.system(size: 13, weight: selected || unread ? .semibold : .medium))
                        .foregroundStyle(session.hasEnded && !selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let shortcut {
                        Text("⌘\(shortcut)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                    } else if let when {
                        Text(when)
                            .font(.system(size: 10.5, weight: unread ? .semibold : .medium).monospacedDigit())
                            .foregroundStyle(unread ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    }
                    if unread && shortcut == nil {
                        UnreadMark()
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: unread)
                HStack(spacing: 5) {
                    if let nick = session.nickname, !nick.isEmpty {
                        Text("@" + nick)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    if let snippet {
                        Text(snippet)
                            .italic()
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if SessionHome.isBranch(session) {
                        // A branch: its glyph, and where its work stands
                        // (a merge under way says so, in its colour).
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(mergeTint ?? Color.secondary)
                        if let merge = SessionHome.mergeLine(session) {
                            Text(merge)
                                .foregroundStyle(mergeTint ?? Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text([statusLine, SessionHome.branchSummary(session)].compactMap { $0 }
                                    .joined(separator: " · "))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else {
                        Text(statusLine)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .help(preview ?? "")
        }
        .padding(.leading, 8 + CGFloat(min(depth, 3)) * 16)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16)
                               : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(gone ? 0.5 : 1)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The Switchboard's row: a baton instead of an avatar, a one-line tally of
/// the sessions it watches, and the status dot of its own conversation.
struct SwitchboardRowView: View {
    let summary: String
    let dot: AgentStatus?
    /// A Switchboard session exists (else a click starts one).
    let started: Bool
    let selected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                if let dot {
                    Circle()
                        .fill(dot == .needsInput ? SessionBucket.needsYou.tint
                              : dot == .working ? SessionBucket.working.tint
                              : SessionBucket.idle.tint)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Switchboard", comment: "switchboard row"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(started ? summary
                             : NSLocalizedString("Ask about all your sessions at once", comment: "switchboard row"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.acSelection
                           : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(NSLocalizedString("The Switchboard keeps track of every session: ask what's going on, answer them, start new work", comment: "switchboard row"))
    }
}

/// A room in the session list: a colored tile, its name and what its
/// sessions are up to; a caret folds its members away.
struct RoomRowView: View {
    let room: AgentRoom
    let summary: String
    let dot: AgentStatus?
    let folded: Bool
    let hasMembers: Bool
    let selected: Bool
    let dropTargeted: Bool
    let onSelect: () -> Void
    let onFold: () -> Void
    @State private var hovering = false

    static func colorName(_ hex: String) -> String {
        switch hex {
        case "#6366F1": return NSLocalizedString("Indigo", comment: "room color")
        case "#10B981": return NSLocalizedString("Green", comment: "room color")
        case "#F59E0B": return NSLocalizedString("Amber", comment: "room color")
        case "#EC4899": return NSLocalizedString("Pink", comment: "room color")
        case "#06B6D4": return NSLocalizedString("Cyan", comment: "room color")
        case "#8B5CF6": return NSLocalizedString("Violet", comment: "room color")
        case "#EF4444": return NSLocalizedString("Red", comment: "room color")
        case "#84CC16": return NSLocalizedString("Lime", comment: "room color")
        default: return hex
        }
    }

    var body: some View {
        let tint = Color(hex: room.colorHex)
        HStack(spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white))
                    .shadow(color: tint.opacity(0.35), radius: 3, y: 1)
                if let dot {
                    Circle()
                        .fill(dot == .needsInput ? SessionBucket.needsYou.tint
                              : dot == .working ? SessionBucket.working.tint
                              : SessionBucket.idle.tint)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if hasMembers {
                Button(action: onFold) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || folded ? 1 : 0.35)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(selected ? tint.opacity(0.16)
                           : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(dropTargeted ? tint : (selected ? tint.opacity(0.35) : .clear),
                          lineWidth: dropTargeted ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(NSLocalizedString("Open the room: all its sessions side by side, with its own Switchboard", comment: "room row"))
    }
}

/// A state group's label in the session list ("NEEDS YOU · 2"), tinted
/// by the state; the Ended one folds.
struct SessionGroupHeader: View {
    let bucket: SessionBucket
    let count: Int
    let foldable: Bool
    let folded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(bucket.tint).frame(width: 6, height: 6)
            Text(bucket.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if foldable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onTapGesture { if foldable { onToggle() } }
    }
}

/// The session list: one "Sessions" section holding every session — what
/// needs you first, then working, ready, asleep, ended, and last the ones
/// whose machine or folder is gone — and, under it, an "Archived" fold for
/// the ones put away (closed by default). The carets fold each list away;
/// a search always shows its matches.
struct SessionSectionsView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    var filter: String = ""
    let onSelect: (UUID) -> Void
    /// What a row's context menu can do (archive, end, delete).
    var actions = SessionStageActions()
    /// The rooms, shown above the loose sessions (host window only).
    var rooms: [AgentRoom] = []
    /// Sessions whose conversation mentions the search, with the words around it.
    var contentSearch: (String) -> [UUID: String] = { _ in [:] }
    /// A session's last reply, for its row's tooltip.
    var lastReply: (UUID) -> String? = { _ in nil }
    @AppStorage("sessions.listExpanded") private var expanded = true
    /// Rooms folded in the sidebar (their members hidden) — remembered
    /// across launches, on this Mac and in a fat client alike (room ids are
    /// unique across machines).
    @AppStorage("sessions.foldedRooms") private var foldedRoomsRaw = ""
    private var foldedRooms: Set<UUID> {
        Set(foldedRoomsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
    private func toggleFold(_ id: UUID) {
        var s = foldedRooms
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        foldedRoomsRaw = s.map(\.uuidString).sorted().joined(separator: ",")
    }
    /// The room a drag hovers.
    @State private var dropRoom: UUID?
    /// The session a drag hovers (dropping groups the two into a room).
    @State private var dropSession: UUID?
    /// The room naming sheet: new (with an optional session to move in) or rename.
    @State private var roomSheet: RoomSheet?

    private struct RoomSheet: Identifiable {
        let id = UUID()
        var renaming: AgentRoom?
        var withSession: UUID?
    }
    @AppStorage("sessions.archivedExpanded") private var archivedExpanded = false
    /// Opened for a moment because the selection went into it (not saved:
    /// the fold stays closed next time).
    @State private var archivedRevealed = false
    /// The Ended group, folded unless opened (or searched).
    @AppStorage("sessions.endedExpanded") private var endedExpanded = false
    /// The session a "New worktree…" sheet is open for.
    @State private var worktreeFor: AgentSession?
    /// The session a "Nickname…" sheet is open for.
    @State private var nicknameFor: AgentSession?

    /// ⌘1–9, by session (what the shortcuts jump to).
    private var shortcutNumbers: [UUID: Int] {
        var out: [UUID: Int] = [:]
        for (i, s) in SessionHome.sidebarOrder(store.sessions, rooms: rooms, in: model).prefix(9).enumerated() { out[s.id] = i + 1 }
        return out
    }

    /// Sessions found by what was said in them (not their name), with the words.
    private var contentHits: [UUID: String] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.count >= 3 ? contentSearch(q) : [:]
    }

    private var matching: [AgentSession] {
        var sessions = store.sessions
        let q = filter.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let bare = q.hasPrefix("@") ? String(q.dropFirst()) : q
            let hits = contentHits
            sessions = sessions.filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || ($0.openingMessage ?? "").localizedCaseInsensitiveContains(q)
                    || $0.cwd.localizedCaseInsensitiveContains(q)
                    || (!bare.isEmpty && ($0.nickname ?? "").localizedCaseInsensitiveContains(bare))
                    || hits[$0.id] != nil
            }
        }
        return sessions
    }

    private var sessions: [AgentSession] { SessionHome.orderedAll(matching, in: model) }
    private var roomIDs: Set<UUID> { Set(activeRooms.map(\.id)) }
    /// Sessions in no (existing) room.
    private func loose(_ list: [AgentSession]) -> [AgentSession] {
        let ids = roomIDs
        return list.filter { $0.roomID.map { !ids.contains($0) } ?? true }
    }
    /// Put-away sessions — those of an archived room show under its row.
    private var archived: [AgentSession] {
        let ids = Set(archivedRooms.map(\.id))
        return SessionHome.archived(matching).filter { $0.roomID.map { !ids.contains($0) } ?? true }
    }
    private var activeRooms: [AgentRoom] { rooms.filter { !$0.isArchived } }
    private var archivedRooms: [AgentRoom] { rooms.filter(\.isArchived) }

    private func workspaceName(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.name ?? ""
    }
    private func accentHex(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.accentHex ?? "#888888"
    }

    var body: some View {
        let list = sessions
        let needsYou = list.filter { SessionHome.bucket(for: $0, in: model) == .needsYou }.count
        let open = expanded || !filter.isEmpty
        VStack(alignment: .leading, spacing: 1) {
            SidebarSectionHeader(title: NSLocalizedString("Sessions", comment: "sidebar section"),
                                 expanded: open,
                                 badges: [(needsYou, SessionBucket.needsYou.tint)],
                                 count: list.count,
                                 help: NSLocalizedString("Your conversations with agents — click to fold the list", comment: "sidebar"),
                                 onTitle: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } },
                                 topPadding: 8)

            if open {
                if filter.isEmpty, SwitchboardGate.isVisible(store.sessions, in: model) {
                    switchboardRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if list.isEmpty && activeRooms.isEmpty { emptyHint }
                ForEach(activeRooms) { roomBlock($0, list) }
                // Grouped by state: what needs you first, ended folded away.
                let loose = loose(list)
                // Paused is one group: the sessions whose machine sleeps show,
                // the ones whose agent stopped fold away behind its caret.
                ForEach(SessionBucket.allCases.filter { $0 != .ended }) { bucket in
                    let group = loose.filter { SessionHome.bucket(for: $0, in: model) == bucket }
                    let stopped = bucket == .asleep
                        ? loose.filter { SessionHome.bucket(for: $0, in: model) == .ended } : []
                    if !group.isEmpty || !stopped.isEmpty {
                        let folded = !stopped.isEmpty && !endedExpanded && filter.isEmpty
                        SessionGroupHeader(bucket: bucket, count: group.count + stopped.count,
                                           foldable: !stopped.isEmpty, folded: folded) {
                            withAnimation(.easeInOut(duration: 0.15)) { endedExpanded.toggle() }
                        }
                        ForEach(Self.nested(folded ? group : group + stopped), id: \.session.id) {
                            row($0.session, depth: $0.depth)
                        }
                    }
                }
            }

            let put = archived
            let putRooms = archivedRooms
            if !put.isEmpty || !putRooms.isEmpty {
                // Put away, not gone: the fold opens on a click or a search
                // — and once, by itself, when the selection moves into it
                // (see `revealSelectedArchived`), so the caret still folds
                // it away with an archived session on stage.
                let openArchived = archivedExpanded || archivedRevealed || !filter.isEmpty
                SidebarSectionHeader(title: NSLocalizedString("Archived", comment: "sidebar section"),
                                     expanded: openArchived,
                                     count: put.count + putRooms.count,
                                     help: NSLocalizedString("Conversations you put away — still readable, back with one message", comment: "sidebar"),
                                     onTitle: { withAnimation(.easeInOut(duration: 0.15)) {
                                         if archivedRevealed { archivedRevealed = false; archivedExpanded = false }
                                         else { archivedExpanded.toggle() }
                                     } })
                if openArchived {
                    ForEach(putRooms) { roomBlock($0, SessionHome.archived(matching)) }
                    let orphans = put.filter { SessionHome.isGone($0, in: model) }
                    ForEach(put.filter { !SessionHome.isGone($0, in: model) }) { row($0) }
                    if !orphans.isEmpty { orphanCleanup(orphans) }
                }
            }
        }
        .onAppear { revealSelectedArchived(model.selectedSessionID) }
        .onChange(of: model.selectedSessionID) { _, id in revealSelectedArchived(id) }
        .sheet(item: $nicknameFor) { s in
            NicknameSheet(session: s, check: { actions.checkNickname(s.id, $0) }) { actions.setNickname(s.id, $0, $1) }
        }
        .sheet(item: $roomSheet) { sheet in
            if let r = sheet.renaming {
                RoomNameSheet(title: NSLocalizedString("Rename Room", comment: "room sheet"),
                              action: NSLocalizedString("Rename", comment: "room sheet"),
                              initial: r.name) { actions.renameRoom(r.id, $0) }
            } else {
                RoomNameSheet(title: NSLocalizedString("New Room", comment: "room sheet"),
                              action: NSLocalizedString("Create", comment: "room sheet")) {
                    actions.newRoom($0, sheet.withSession)
                }
            }
        }
        .sheet(item: $worktreeFor) { parent in
            NewWorktreeSheet(parent: parent, gitState: actions.gitState) { req in
                actions.newWorktree(parent.id, req)
            }
        }
    }

    /// The selection just landed on an archived session: open the fold so
    /// its row is on screen. One-shot — folding it back by hand sticks
    /// until the selection moves into the fold again.
    private func revealSelectedArchived(_ id: UUID?) {
        guard let id, let s = store.session(id), s.isArchived, !s.isDeleted else {
            // The selection left the fold: it closes again if it was only revealed.
            if archivedRevealed { withAnimation(.easeInOut(duration: 0.15)) { archivedRevealed = false } }
            return
        }
        guard !archivedExpanded else { return }
        withAnimation(.easeInOut(duration: 0.15)) { archivedRevealed = true }
    }

    /// Sessions whose machine or folder is gone: nothing to reopen them on. One line
    /// offers to clear them instead of a column of ghosts.
    private func orphanCleanup(_ orphans: [AgentSession]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(orphans.count == 1
                 ? NSLocalizedString("1 session whose machine or folder is gone", comment: "sidebar cleanup")
                 : String(format: NSLocalizedString("%d sessions whose machine or folder is gone", comment: "sidebar cleanup"), orphans.count))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(NSLocalizedString("Delete", comment: "sidebar cleanup")) {
                for o in orphans { actions.delete(o.id) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11.5, weight: .medium))
            .help(NSLocalizedString("Their machines are gone — delete these conversations", comment: "sidebar cleanup"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    static func origin(of s: AgentSession) -> UUID? { AgentSession.origin(of: s) }

    /// The list with each delegate placed right under its delegator (as
    /// deep as the chain goes), when the delegator is listed; a delegate
    /// whose delegator isn't stands on its own.

    static func nested(_ list: [AgentSession]) -> [(session: AgentSession, depth: Int)] {
        SessionHome.nested(list)
    }

    private func row(_ s: AgentSession, depth: Int = 0) -> some View {
        let gone = SessionHome.isGone(s, in: model)
        return SessionRowView(
            session: s,
            workspaceName: workspaceName(s.profileID),
            accentHex: accentHex(s.profileID),
            dot: SessionHome.dot(for: s, in: model),
            statusLine: SessionHome.statusLine(for: s, in: model),
            when: SessionHome.rowWhen(s, in: model),
            gone: gone,
            depth: depth,
            selected: model.selectedSessionID == s.id,
            onSelect: {
                onSelect(s.id)
                // Found by its words: the chat scrolls to them.
                if contentHits[s.id] != nil, !s.title.localizedCaseInsensitiveContains(filter) {
                    let q = filter
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        NotificationCenter.default.post(name: .bromureFindInChat, object: q)
                    }
                }
            },
            title: SessionHome.distinctTitle(s, among: store.sessions, in: model),
            shortcut: model.commandHeld ? shortcutNumbers[s.id] : nil,
            snippet: filter.isEmpty || s.title.localizedCaseInsensitiveContains(filter) ? nil : contentHits[s.id],
            preview: lastReply(s.id),
            native: model.machineIDs.contains(s.profileID),
            unread: SessionHome.showsUnread(s, in: model))
        .overlay {
            if dropSession == s.id {
                RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .draggable(s.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // Another session dropped on this one: the two share a room
            // (this one's, or a new one).
            let ids = items.compactMap(UUID.init(uuidString:)).filter { $0 != s.id }
            guard !gone, !s.isArchived, !ids.isEmpty else { return false }
            for id in ids { actions.groupSessions(id, s.id) }
            return true
        } isTargeted: { inside in
            dropSession = inside ? s.id : (dropSession == s.id ? nil : dropSession)
        }
        .contextMenu {
            // The header's ⋯ menu, one right-click away — minus Rename,
            // which is the title itself.
            if !gone {
                if s.isArchived {
                    Button(NSLocalizedString("Unarchive", comment: "session menu")) { actions.unarchive(s.id) }
                } else {
                    Button(s.windowIndex != nil && !s.hasEnded
                           ? NSLocalizedString("End & Archive", comment: "session menu")
                           : NSLocalizedString("Archive", comment: "session menu")) {
                        actions.archive(s.id)
                    }
                }
                if s.windowIndex != nil, !s.hasEnded {
                    Button(NSLocalizedString("End session", comment: "session menu")) { actions.close(s.id) }
                }
                Divider()
                Button(NSLocalizedString("Nickname…", comment: "session menu")) { nicknameFor = s }
                if SessionHome.hasFolder(s) {
                    Button(NSLocalizedString("New Branch…", comment: "session menu")) { worktreeFor = s }
                }
                if SessionHome.isBranch(s) {
                    BranchMenuItems(session: s, actions: actions)
                }
                if !s.isArchived { roomMenu(s) }
                Divider()
                Button(String(format: NSLocalizedString("“%@” Settings…", comment: "session menu: machine settings"),
                              workspaceName(s.profileID))) { actions.editMachine(s.profileID) }
                if s.windowIndex != nil, !s.hasEnded {
                    Button(NSLocalizedString("Open in Linux Terminal", comment: "session menu")) { actions.openLinux(s.id) }
                }
            } else if s.isArchived {
                Button(NSLocalizedString("Unarchive", comment: "session menu")) { actions.unarchive(s.id) }
            }
            Divider()
            Button(NSLocalizedString("Delete session", comment: "session menu"), role: .destructive) {
                actions.delete(s.id)
            }
        }
    }

    /// The Switchboard, pinned above the sessions it keeps track of — see
    /// `SwitchboardGate` for when it shows at all.
    private var switchboardRow: some View {
        let c = SwitchboardGate.switchboard(in: store.sessions)
        return SwitchboardRowView(
            summary: SwitchboardGate.summary(store.sessions, in: model),
            dot: c.flatMap { SessionHome.dot(for: $0, in: model) },
            started: c != nil,
            selected: c.map { model.selectedSessionID == $0.id } ?? false,
            onSelect: actions.openSwitchboard)
    }

    // MARK: Rooms

    /// "Move to Room" for a session's context menu.
    @ViewBuilder
    private func roomMenu(_ s: AgentSession) -> some View {
        Menu(NSLocalizedString("Move to Room", comment: "session menu")) {
            ForEach(activeRooms) { r in
                Button(r.name) { actions.moveToRoom(s.id, r.id) }
                    .disabled(s.roomID == r.id)
            }
            if !activeRooms.isEmpty { Divider() }
            Button(NSLocalizedString("New Room…", comment: "session menu")) {
                roomSheet = RoomSheet(withSession: s.id)
            }
        }
        if let rid = s.roomID, roomIDs.contains(rid) {
            Button(NSLocalizedString("Remove from Room", comment: "session menu")) { actions.moveToRoom(s.id, nil) }
        }
    }

    /// A room: its row (click → the room's grid), then its members nested
    /// under it unless folded. Sessions dropped on it move in.
    @ViewBuilder
    private func roomBlock(_ r: AgentRoom, _ list: [AgentSession]) -> some View {
        let members = list.filter { $0.roomID == r.id }
        let folded = foldedRooms.contains(r.id) && filter.isEmpty
        RoomRowView(
            room: r,
            summary: RoomTally.summary(r, store.sessions, in: model),
            dot: RoomTally.dot(r, store.sessions, in: model),
            folded: folded,
            hasMembers: !members.isEmpty,
            selected: model.selectedRoomID == r.id,
            dropTargeted: dropRoom == r.id,
            onSelect: { actions.openRoom(r.id) },
            onFold: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    toggleFold(r.id)
                }
            })
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:))
            for id in ids { actions.moveToRoom(id, r.id) }
            return !ids.isEmpty
        } isTargeted: { inside in
            dropRoom = inside ? r.id : (dropRoom == r.id ? nil : dropRoom)
        }
        .contextMenu {
            Button(NSLocalizedString("New Session in Room", comment: "room menu")) { actions.newSessionInRoom(r.id) }
            Divider()
            Button(NSLocalizedString("Rename…", comment: "room menu")) { roomSheet = RoomSheet(renaming: r) }
            Menu(NSLocalizedString("Color", comment: "room menu")) {
                ForEach(AgentRoom.palette, id: \.self) { hex in
                    Button {
                        actions.setRoomColor(r.id, hex)
                    } label: {
                        Label(RoomRowView.colorName(hex),
                              systemImage: r.colorHex == hex ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Divider()
            if r.isArchived {
                Button(NSLocalizedString("Unarchive Room", comment: "room menu")) { actions.unarchiveRoom(r.id) }
            } else {
                Button(NSLocalizedString("Archive Room", comment: "room menu")) { actions.archiveRoom(r.id) }
            }
            Button(NSLocalizedString("Ungroup Room", comment: "room menu")) { actions.ungroupRoom(r.id) }
            Divider()
            Button(NSLocalizedString("Delete Room…", comment: "room menu"), role: .destructive) { actions.deleteRoom(r.id) }
        }
        if !folded {
            ForEach(Self.nested(members), id: \.session.id) { row($0.session, depth: $0.depth + 1) }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(filter.isEmpty
                 ? NSLocalizedString("No sessions yet", comment: "session sidebar empty")
                 : NSLocalizedString("No matching sessions", comment: "session sidebar empty"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if filter.isEmpty {
                Text(NSLocalizedString("Start one: pick an agent, say what you're after, and go.",
                                       comment: "session sidebar empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

