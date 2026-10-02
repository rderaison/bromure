#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Quick Task (⇧⌥Space, from anywhere)
//
// Jot a task into the board's backlog without leaving what you're doing: a
// floating panel over whatever is in front — Bromure or any other app (the
// shortcut is a system-wide hotkey) — one line to type, ↩ to add (⌘↩ to add
// and keep going). Closing it gives focus back to the app you were in. It's queued for whoever the chip says — by default the
// board's standing choice, else the session in front of you — and that
// worker picks it up on its own.

@MainActor
final class QuickTaskPanel {
    private weak var delegate: ACAppDelegate?
    private var panel: NSPanel?
    /// Where the task goes, decided when the panel opens.
    private var target: Target?

    /// The board a quick task lands on: this Mac's, or — when a fat-client
    /// window is in front — the host it mirrors (its workspaces, its
    /// sessions' nicknames, its board).
    private struct Target {
        let profiles: [Profile]
        let choices: TaskAssigneeChoices
        /// The session in front of the user there, if any.
        let current: AgentSession?
        let label: (AgentSession) -> String
        let save: (CodingTask) -> Void
        let assign: (UUID, TaskAssignment) -> Void
        let plan: (UUID) -> Void

        func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }

        @MainActor
        static func local(_ d: ACAppDelegate) -> Target {
            let current = d.unifiedWindow?.listModel.selectedSessionID.flatMap { d.agentSessionStore.session($0) }
            return Target(profiles: d.profiles, choices: d.taskDispatcher.choices(), current: current,
                          label: { d.delegationEngine.label($0) },
                          save: { d.codingTaskStore.upsert($0) },
                          assign: { d.taskDispatcher.assign($0, to: $1) },
                          plan: { d.codingTaskEngine.plan($0) })
        }

        @MainActor
        static func remote(_ w: RemoteHostWindow) -> Target {
            let c = w.controller
            func label(_ s: AgentSession) -> String { s.nickname.map { "@" + $0 } ?? s.title }
            let sessions = c.sessionStore.sessions
                .filter { !$0.isDeleted && !$0.isArchived && !$0.isSwitchboard }
                .sorted { SessionHome.lastActivity($0) > SessionHome.lastActivity($1) }
                .prefix(40)
                .map { s -> TaskAssigneeChoices.Session in
                    let b = SessionHome.bucket(for: s, in: c.listModel)
                    return .init(id: s.id, label: label(s), workspace: c.profile(for: s.profileID)?.name ?? "",
                                 busy: b == .working || b == .needsYou)
                }
            let rooms = c.roomStore.rooms.filter { $0.archivedAt == nil }
                .map { TaskAssigneeChoices.Room(id: $0.id, name: $0.name) }
            return Target(profiles: c.profiles,
                          choices: TaskAssigneeChoices(sessions: Array(sessions), rooms: rooms),
                          current: w.selectedSessionID.flatMap { c.sessionStore.session($0) },
                          label: label,
                          save: { c.upsertTask($0) },
                          assign: { id, a in
                              c.taskCommand(id, "assign", body: ["kind": a.kind.rawValue, "id": a.id.uuidString,
                                                                 "label": a.label])
                          },
                          plan: { [weak w] id in w?.planQuickTask(id) })
        }
    }
    /// The app that was in front when the panel was summoned from outside
    /// Bromure — it gets focus back when the panel closes.
    private var previousApp: NSRunningApplication?

    init(delegate: ACAppDelegate?) {
        self.delegate = delegate
    }

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        show()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        if let app = previousApp {
            previousApp = nil
            app.activate()
        }
    }

    func show() {
        guard let delegate else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        // A fat-client window in front: the task is for the host it mirrors.
        let target: Target = (previousApp == nil ? NSApp.keyWindow as? RemoteHostWindow : nil)
            .map(Target.remote) ?? Target.local(delegate)
        self.target = target
        // Context: the session in front of the user, if any.
        let current = target.current
        let choices = target.choices
        let profiles = target.profiles
        guard let workspace = current?.profileID ?? profiles.first?.id else { return }
        let here = current.map {
            TaskAssignment(kind: .session, id: $0.id, label: target.label($0))
        }
        // The board's standing choice names a session of this Mac's board:
        // only when it's one of the target's.
        let standing = TaskAssignment.autoAssign.flatMap { a in
            a.kind != .session || choices.sessions.contains { $0.id == a.id } ? a : nil
        }
        let initial = standing ?? here
        let folder = current?.cwd ?? "~"
        let tool = current?.tool ?? target.profile(workspace)?.tool ?? .claude
        let view = QuickTaskView(
            choices: choices,
            here: here,
            folder: folder,
            workspaceName: target.profile(workspace)?.name ?? "",
            initialAssignment: initial,
            profiles: profiles,
            profileID: workspace,
            tool: tool,
            onAdd: { [weak self] title, details, assignment, keepOpen in
                self?.add(title: title, details: details, assignment: assignment,
                          profileID: workspace, folder: folder, tool: tool)
                if !keepOpen { self?.close() }
            },
            onAddTask: { [weak self] task in
                self?.add(task, plan: false)
                self?.close()
            },
            onPlanTask: { [weak self] task in
                self?.add(task, plan: true)
                self?.close()
            },
            onExpand: { [weak self] in self?.expand() },
            onClose: { [weak self] in self?.close() })
        // A fixed, mostly transparent window with the content pinned to its
        // top: suggestions and the full editor grow downward inside it, and
        // clicks on the clear part fall through to whatever is underneath.
        let size = NSSize(width: 800, height: 700)
        let host = NSHostingView(rootView: view
            .padding(.top, 16)
            .frame(width: size.width, height: size.height, alignment: .top))
        host.sizingOptions = []
        let p = QuickPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .fullSizeContentView],
                           backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        // Summoned over another app, it must stay up while Bromure isn't
        // the active app's main window.
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.contentView = host
        p.onEscape = { [weak self] in self?.close() }
        // Upper third of Bromure's window when it's in front, else of the
        // screen the pointer is on.
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let anchor = previousApp == nil
            ? (NSApp.keyWindow?.frame ?? delegate.unifiedWindow?.frame ?? pointerScreen?.visibleFrame ?? .zero)
            : (pointerScreen?.visibleFrame ?? .zero)
        p.setFrame(NSRect(x: anchor.midX - size.width / 2,
                          y: anchor.maxY - anchor.height * 0.18 - size.height,
                          width: size.width, height: size.height), display: true)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    /// Grow into the full editor: the content does it inside the window
    /// (which already has the room); just make sure it's key.
    private func expand() {
        panel?.makeKey()
    }

    /// A task from the full editor.
    private func add(_ task: CodingTask, plan: Bool) {
        guard let target else { return }
        var t = task
        t.stage = .backlog
        target.save(t)
        if plan {
            target.plan(t.id)
        } else if let a = t.assignment {
            target.assign(t.id, a)
        }
        BACDebug.log("tasks", "quick task “\(t.title)” (editor) → \(t.assignment?.label ?? "backlog")")
    }

    private func add(title: String, details: String, assignment: TaskAssignment?,
                     profileID: UUID, folder: String, tool: Profile.Tool?) {
        guard let target else { return }
        let profile = target.profile(profileID)
        let task = CodingTask(title: title, details: details, profileID: profileID,
                              repoPath: folder, tool: tool ?? profile?.tool ?? .claude,
                              stage: .backlog)
        target.save(task)
        if let assignment {
            target.assign(task.id, assignment)
        }
        BACDebug.log("tasks", "quick task “\(title)” → \(assignment?.label ?? "backlog")")
    }
}

/// ⇧⌥Space, system-wide: a Carbon hot key (the system hands it to Bromure
/// whichever app is in front, before any view sees it).
@MainActor
enum QuickTaskHotKey {
    private static var ref: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    fileprivate static var action: (() -> Void)?

    /// The menu item's key equivalent, for display (the hot key fires first).
    static let keyEquivalent = " "
    static let modifiers: NSEvent.ModifierFlags = [.shift, .option]

    static func register(_ action: @escaping () -> Void) {
        guard ref == nil else { return }
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            FileHandle.standardError.write(Data("[quick-task] hot key pressed\n".utf8))
            DispatchQueue.main.async { MainActor.assumeIsolated { QuickTaskHotKey.action?() } }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4252_5154), id: 1)   // "BRQT"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(shiftKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        // One line either way: a shortcut that silently does nothing is the
        // worst kind of bug to report.
        FileHandle.standardError.write(Data((status == noErr
            ? "[quick-task] ⇧⌥Space registered\n"
            : "[quick-task] ⇧⌥Space NOT registered (status \(status)) — another app owns it?\n").utf8))
    }
}

/// A borderless panel that can take keyboard focus and closes on Escape.
private final class QuickPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

struct QuickTaskView: View {
    let choices: TaskAssigneeChoices
    /// The session in front of the user ("this session").
    let here: TaskAssignment?
    let folder: String
    let workspaceName: String
    let profiles: [Profile]
    let profileID: UUID
    let tool: Profile.Tool
    var onAdd: (String, String, TaskAssignment?, Bool) -> Void
    var onAddTask: (CodingTask) -> Void = { _ in }
    var onPlanTask: (CodingTask) -> Void = { _ in }
    var onExpand: () -> Void = {}
    var onClose: () -> Void

    @State private var title = ""
    @State private var details = ""
    @State private var showDetails = false
    @State private var assignment: TaskAssignment?
    @State private var added: [String] = []
    @State private var highlighted = 0
    @State private var lastTab: Date = .distantPast
    /// The full editor, once grown (⇥⇥).
    @State private var expanded: CodingTask?
    @FocusState private var focus: Field?
    private enum Field { case title, details }

    init(choices: TaskAssigneeChoices, here: TaskAssignment?, folder: String, workspaceName: String,
         initialAssignment: TaskAssignment?,
         profiles: [Profile] = [], profileID: UUID = UUID(), tool: Profile.Tool = .claude,
         onAdd: @escaping (String, String, TaskAssignment?, Bool) -> Void,
         onAddTask: @escaping (CodingTask) -> Void = { _ in },
         onPlanTask: @escaping (CodingTask) -> Void = { _ in },
         onExpand: @escaping () -> Void = {},
         onClose: @escaping () -> Void) {
        self.choices = choices
        self.here = here
        self.folder = folder
        self.workspaceName = workspaceName
        self.profiles = profiles
        self.profileID = profileID
        self.tool = tool
        self.onAdd = onAdd
        self.onAddTask = onAddTask
        self.onPlanTask = onPlanTask
        self.onExpand = onExpand
        self.onClose = onClose
        _assignment = State(initialValue: initialAssignment)
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: @mentions

    /// The word being typed, when it's an @session or #room.
    private var mention: (sigil: Character, query: String)? {
        guard let last = title.split(separator: " ", omittingEmptySubsequences: false).last,
              let first = last.first, first == "@" || first == "#" else { return nil }
        return (first, String(last.dropFirst()).lowercased())
    }

    private struct Suggestion: Identifiable {
        let id: String
        let assignment: TaskAssignment
        let detail: String
    }

    private var suggestions: [Suggestion] {
        guard let m = mention else { return [] }
        var out: [Suggestion] = []
        if m.sigil == "@" {
            if m.query.isEmpty || "new".hasPrefix(m.query) || "agent".hasPrefix(m.query) {
                out.append(Suggestion(id: "new", assignment: .newAgent,
                                      detail: NSLocalizedString("in its own worktree", comment: "quick task")))
            }
            if m.query.isEmpty || "switchboard".hasPrefix(m.query) {
                out.append(Suggestion(id: "switchboard", assignment: .switchboard,
                                      detail: NSLocalizedString("picks the session best placed for it", comment: "quick task")))
            }
            for r in choices.rooms where !m.query.isEmpty
                && (r.name.lowercased().hasPrefix(m.query) || "switchboard".hasPrefix(m.query)) {
                out.append(Suggestion(id: "room-" + r.id.uuidString,
                                      assignment: TaskAssignment(kind: .room, id: r.id, label: "#" + r.name),
                                      detail: String(format: NSLocalizedString("%@'s Switchboard picks a member", comment: "quick task"),
                                                     "#" + r.name)))
            }
            for s in choices.sessions where m.query.isEmpty
                || s.label.lowercased().contains(m.query) || s.workspace.lowercased().contains(m.query) {
                out.append(Suggestion(id: s.id.uuidString,
                                      assignment: TaskAssignment(kind: .session, id: s.id, label: s.label),
                                      detail: s.workspace + (s.busy ? " · " + NSLocalizedString("busy — takes it after its current work", comment: "quick task") : "")))
            }
        } else {
            for r in choices.rooms where m.query.isEmpty || r.name.lowercased().contains(m.query) {
                out.append(Suggestion(id: r.id.uuidString,
                                      assignment: TaskAssignment(kind: .room, id: r.id, label: "#" + r.name),
                                      detail: NSLocalizedString("the room's Switchboard picks a member", comment: "quick task")))
            }
        }
        return Array(out.prefix(6))
    }

    private func pick(_ s: Suggestion) {
        assignment = s.assignment
        // Drop the @word from the title.
        var words = title.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !words.isEmpty { words.removeLast() }
        title = words.joined(separator: " ")
        if !title.isEmpty, !title.hasSuffix(" ") { title += " " }
        highlighted = 0
    }

    // MARK: Actions

    private func submit(keepOpen: Bool) {
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed, details.trimmingCharacters(in: .whitespacesAndNewlines), assignment, keepOpen)
        if keepOpen {
            withAnimation(.snappy) { added.insert(trimmed, at: 0) }
            title = ""
            details = ""
            showDetails = false
            focus = .title
        }
    }

    /// ⇥⇥: grow into the full editor with what's typed so far.
    private func expand() {
        var t = CodingTask(title: trimmed, details: details, profileID: profileID,
                           repoPath: folder, tool: tool, stage: .backlog)
        t.assignment = assignment
        onExpand()
        withAnimation(.smooth(duration: 0.3)) { expanded = t }
    }

    private func tab(fromDetails: Bool) -> KeyPress.Result {
        if !fromDetails, let first = suggestions.first {
            pick(suggestions.indices.contains(highlighted) ? suggestions[highlighted] : first)
            return .handled
        }
        let now = Date()
        if fromDetails || now.timeIntervalSince(lastTab) < 0.5 {
            expand()
        } else {
            withAnimation(.snappy) { showDetails = true }
            focus = .details
        }
        lastTab = now
        return .handled
    }

    // MARK: View

    var body: some View {
        if let draft = expanded {
            TaskEditorSheet(
                task: draft, profiles: profiles, siblings: [], isNew: true,
                onSave: onAddTask, onPlan: onPlanTask, onDelete: { _ in }, onCancel: onClose,
                assignees: choices, canAssign: true, glass: true)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else {
            quick
        }
    }

    private var quick: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: added.count)
                TextField(NSLocalizedString("What needs doing?  @agent to assign", comment: "quick task"), text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .medium))
                    .focused($focus, equals: .title)
                    .onChange(of: title) { highlighted = 0 }
                    .onSubmit {
                        if let s = suggestions.first {
                            pick(suggestions.indices.contains(highlighted) ? suggestions[highlighted] : s)
                        } else {
                            submit(keepOpen: false)
                        }
                    }
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        submit(keepOpen: true)
                        return .handled
                    }
                    .onKeyPress(.tab) { tab(fromDetails: false) }
                    .onKeyPress(.downArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        highlighted = min(highlighted + 1, suggestions.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, s in
                        Button { pick(s) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: s.assignment.systemImage)
                                    .foregroundStyle(.tint)
                                    .frame(width: 18)
                                Text(s.assignment.label).font(.system(size: 13, weight: .semibold))
                                Text(s.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if i == highlighted {
                                    Text("⇥ / ↩").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(i == highlighted ? Color.accentColor.opacity(0.16) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 30)
                .transition(.opacity)
            }
            if showDetails {
                TextField(NSLocalizedString("Details (optional)", comment: "quick task"),
                          text: $details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($focus, equals: .details)
                    .onKeyPress(.tab) { tab(fromDetails: true) }
                    .padding(.leading, 34)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 8) {
                assigneeMenu
                // A session or room works where it already is: no workspace
                // or folder of ours to show.
                if assignment == nil || assignment?.kind == .worktree {
                    Text(folder == "~" ? workspaceName : "\(workspaceName) · \(folder)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer()
                if let last = added.first {
                    Label(String(format: NSLocalizedString("Added “%@”", comment: "quick task"), last),
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Text(NSLocalizedString("↩ add · ⌘↩ add another · ⇥⇥ full editor", comment: "quick task"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 34)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 620)
        .modifier(GlassPanelBackground(cornerRadius: 24))
        .animation(.snappy(duration: 0.2), value: suggestions.count)
        .onAppear { focus = .title }
    }

    private var assigneeMenu: some View {
        Menu {
            Button(NSLocalizedString("Backlog only — I'll start it", comment: "quick task")) { assignment = nil }
            Button(NSLocalizedString("A new agent (own worktree)", comment: "quick task")) { assignment = .newAgent }
            Button(NSLocalizedString("The Switchboard — it picks a session", comment: "quick task")) { assignment = .switchboard }
            if let here {
                Button(String(format: NSLocalizedString("This session (%@)", comment: "quick task"), here.label)) {
                    assignment = here
                }
            }
            if !choices.sessions.isEmpty {
                Divider()
                ForEach(choices.sessions) { s in
                    Button(s.label + (s.workspace.isEmpty ? "" : "  ·  " + s.workspace)) {
                        assignment = TaskAssignment(kind: .session, id: s.id, label: s.label)
                    }
                }
            }
            if !choices.rooms.isEmpty {
                Divider()
                ForEach(choices.rooms) { r in
                    Button("#" + r.name) {
                        assignment = TaskAssignment(kind: .room, id: r.id, label: "#" + r.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: assignment?.systemImage ?? "tray")
                Text(assignment.map {
                    String(format: NSLocalizedString("Queue for %@", comment: "quick task"), $0.label)
                } ?? NSLocalizedString("Backlog only", comment: "quick task"))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(assignment == nil ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill((assignment == nil ? Color.secondary : Color.accentColor).opacity(0.14)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Liquid Glass on macOS 26, a thick material before it.
struct GlassPanelBackground: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}
#endif
