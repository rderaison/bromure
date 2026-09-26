#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Review
//
// One window to look at what an agent changed — a session's work, or a
// coding task's branch: the files on the left (what's been looked at, what
// has comments), the whole diff on the right. Against what is a choice —
// the edits not committed yet, everything on the branch since it left its
// parent, or the last commit. Comments pin to a line or a file and stay on
// the record until they're sent to the agent in one message. A branch
// merges from here too.

/// What a review window shows and does, read live (the stores it reads
/// are observable, so the window follows them).
struct ReviewSource {
    enum Place { case branch(String, parent: String?), folder(String) }
    var title: () -> String
    var place: () -> Place
    var accentHex: () -> String
    var workspaceName: () -> String
    /// The comparisons on offer, in order, and the one to open on.
    var bases: () -> [(TaskReviewData.Base, String)]
    var defaultBase: () -> TaskReviewData.Base
    var comments: () -> [ReviewComment]
    /// path → fingerprint of the diff seen.
    var viewed: () -> [String: String]
    var plan: () -> String? = { nil }
    var fetch: (TaskReviewData.Base) async -> TaskReviewData?
    var addComment: (_ text: String, _ file: String?, _ line: Int?) -> Void
    var removeComment: (UUID) -> Void
    var setViewed: (_ path: String, _ fingerprint: String?) -> Void
    /// Hand the draft comments over.
    var send: () -> Void
    var sendLabel: (Int) -> String
    var sendHelp: String
    /// The composer's key hint (⏎ adds a comment; ⇧⌘⏎ sends).
    var composerHint = NSLocalizedString("⏎ add comment   ⌥⏎ newline   ⇧⌘⏎ send to agent", comment: "review composer hint")
    var openTerminal: () -> Void
    /// The header's own controls (merge, …).
    var trailing: () -> AnyView = { AnyView(EmptyView()) }
    /// What the base picker says for a base (".branch" labels come from bases).
    static func standardBases(parent: String?) -> [(TaskReviewData.Base, String)] {
        var out: [(TaskReviewData.Base, String)] = []
        if let parent {
            out.append((.branch(parent), String(format: NSLocalizedString("Since %@", comment: "review base"), parent)))
        }
        out.append((.uncommitted, NSLocalizedString("Uncommitted", comment: "review base")))
        out.append((.lastCommit, NSLocalizedString("Last commit", comment: "review base")))
        return out
    }
}

/// Review windows, one per subject (a session or a task, by id).
@MainActor
final class ReviewWindowHost {
    private var windows: [UUID: NSWindow] = [:]
    private var focus: [UUID: ReviewFocus] = [:]

    func window(for id: UUID) -> NSWindow? { windows[id] }

    /// `files`: a turn's edited paths (absolute or relative) — the window
    /// opens on just those, with a way to see everything.
    func open(_ id: UUID, title: String, files: [String]? = nil, source: () -> ReviewSource) {
        let f = focus[id] ?? ReviewFocus()
        f.files = files
        f.generation += 1
        focus[id] = f
        if let win = windows[id] { win.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = String(format: NSLocalizedString("Review — %@", comment: "review window title"), title)
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 760, height: 460)
        win.tabbingMode = .disallowed
        win.contentView = NSHostingView(rootView: ReviewView(source: source(), focus: f))
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { _ in
            MainActor.assumeIsolated { f.refresh += 1 }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windows[id] = nil
                self?.focus[id] = nil
            }
        }
        windows[id] = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ id: UUID) {
        windows[id]?.close()
        windows[id] = nil
    }
}

/// A session's review: opened from Review Changes (header, ⌘K, the branch
/// menu) and from a chat's "Changed N files" line — then on that turn's
/// files.
@MainActor
final class SessionReviewWindowManager {
    struct Context {
        var session: (UUID) -> AgentSession?
        var fetch: (UUID, TaskReviewData.Base) async -> TaskReviewData?
        var addComment: (_ id: UUID, _ text: String, _ file: String?, _ line: Int?) -> Void
        var removeComment: (_ id: UUID, _ commentID: UUID) -> Void
        var setViewed: (_ id: UUID, _ path: String, _ fingerprint: String?) -> Void
        var send: (UUID) -> Void
        var actions: () -> SessionStageActions
        var accentHex: (Profile.ID) -> String
        var workspaceName: (Profile.ID) -> String
    }

    private let context: Context
    private let host = ReviewWindowHost()

    init(context: Context) { self.context = context }

    func window(for id: UUID) -> NSWindow? { host.window(for: id) }

    func open(sessionID id: UUID, files: [String]? = nil) {
        guard let s = context.session(id) else { return }
        let c = context
        host.open(id, title: s.title, files: files) {
            ReviewSource(
                title: { c.session(id)?.title ?? "" },
                place: {
                    let s = c.session(id)
                    if let b = s?.worktreeBranch, !b.isEmpty { return .branch(b, parent: s?.branchParent) }
                    return .folder(prettyGuestPath(SessionHome.guestPath(s?.cwd ?? "~")))
                },
                accentHex: { c.session(id).map { c.accentHex($0.profileID) } ?? "#888888" },
                workspaceName: { c.session(id).map { c.workspaceName($0.profileID) } ?? "" },
                bases: {
                    let s = c.session(id)
                    let branch = s.map(SessionHome.isBranch) ?? false
                    return ReviewSource.standardBases(parent: branch ? s?.branchParent : nil)
                },
                defaultBase: {
                    if let s = c.session(id), SessionHome.isBranch(s), let p = s.branchParent { return .branch(p) }
                    return .uncommitted
                },
                comments: { c.session(id)?.reviewComments ?? [] },
                viewed: { c.session(id)?.reviewViewed ?? [:] },
                fetch: { base in await c.fetch(id, base) },
                addComment: { text, file, line in c.addComment(id, text, file, line) },
                removeComment: { c.removeComment(id, $0) },
                setViewed: { c.setViewed(id, $0, $1) },
                send: { c.send(id) },
                sendLabel: { n in
                    n == 0 ? NSLocalizedString("Send to Agent", comment: "review")
                    : n == 1 ? NSLocalizedString("Send 1 Comment to Agent", comment: "review")
                    : String(format: NSLocalizedString("Send %d Comments to Agent", comment: "review"), n)
                },
                sendHelp: NSLocalizedString("Sends every draft comment to the agent in one message (⇧⌘⏎)", comment: "review"),
                openTerminal: { c.actions().openLinux(id) },
                trailing: {
                    guard let s = c.session(id), SessionHome.isBranch(s), s.branchMerge?.phase != .merged
                    else { return AnyView(EmptyView()) }
                    return AnyView(BranchMergeControl(session: s, actions: c.actions()))
                })
        }
    }
}

/// What the open window is narrowed to — shared with the host so a second
/// "Changed N files" click re-aims the window already open.
@MainActor
@Observable
final class ReviewFocus {
    var files: [String]?
    var generation = 0
    /// Bumped when the window comes back to the front.
    var refresh = 0
}

struct ReviewView: View {
    let source: ReviewSource
    var focus: ReviewFocus

    @State private var base: TaskReviewData.Base = .uncommitted
    @State private var data: TaskReviewData?
    @State private var loading = false
    @State private var loadFailed = false
    @State private var showAll = false
    @State private var selectedFile: String?
    @State private var draft = ""
    @State private var draftFile: String?
    @State private var baseChosen = false
    @State private var planOpen = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                fileList
                    .frame(minWidth: 220, idealWidth: 270, maxWidth: 380)
                diffPane
                    .frame(minWidth: 420)
            }
            Divider()
            commentsBar
        }
        .background(Color.platformWindowBackground)
        .task(id: focus.generation) {
            if !baseChosen { base = source.defaultBase() }
            showAll = focus.files == nil
            await load()
        }
        .onChange(of: focus.refresh) { _, _ in
            // Back from the chat: the agent may have changed things.
            guard !loading, data != nil else { return }
            Task { await load(quiet: true) }
        }
    }

    // MARK: Loading

    private func load(quiet: Bool = false) async {
        if !quiet { loading = true; loadFailed = false }
        let fetched = await source.fetch(base)
        loading = false
        if let fetched { data = fetched; loadFailed = false }
        else if !quiet { data = nil; loadFailed = true }
        if let sel = selectedFile, !(visibleFiles.contains { $0.path == sel }) { selectedFile = nil }
    }

    /// Files in the review, narrowed to the turn's when asked.
    private var visibleFiles: [TaskDiffFile] {
        let all = data?.files ?? []
        guard !showAll, let wanted = focus.files, !wanted.isEmpty else { return all }
        return all.filter { f in wanted.contains { Self.samePath($0, f.path) } }
    }

    /// A tool call's path (often absolute) against a repo-relative one.
    static func samePath(_ edited: String, _ repoRelative: String) -> Bool {
        let e = edited.hasPrefix("./") ? String(edited.dropFirst(2)) : edited
        return e == repoRelative || e.hasSuffix("/" + repoRelative)
    }

    private func isViewed(_ f: TaskDiffFile) -> Bool {
        guard let fp = source.viewed()[f.path] else { return false }
        return fp == TaskReviewData.fingerprint(f)
    }

    private var comments: [ReviewComment] { source.comments() }
    private var drafts: [ReviewComment] { comments.filter { $0.sentAt == nil } }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: source.accentHex()))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title())
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    switch source.place() {
                    case .branch(let b, let parent):
                        Label(b, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11, design: .monospaced))
                        if let parent {
                            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                            Text(parent).font(.system(size: 11, design: .monospaced))
                        }
                    case .folder(let f):
                        Label(f, systemImage: "folder")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    if !source.workspaceName().isEmpty {
                        Text("· " + source.workspaceName())
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            basePicker
            Button {
                Task { await load() }
            } label: { Image(systemName: "arrow.clockwise") }
                .help(NSLocalizedString("Refresh the diff", comment: ""))
                .keyboardShortcut("r", modifiers: .command)
            Button(NSLocalizedString("Open Terminal", comment: "review"), action: source.openTerminal)
            source.trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var basePicker: some View {
        let options = source.bases()
        return Picker("", selection: Binding(get: { base }, set: { v in
            base = v; baseChosen = true
            Task { await load() }
        })) {
            ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(NSLocalizedString("What the changes are compared against", comment: "review"))
    }

    // MARK: File list

    private var fileList: some View {
        let files = visibleFiles
        let viewedCount = files.filter(isViewed).count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(files.count == 1 ? NSLocalizedString("1 file", comment: "review")
                         : String(format: NSLocalizedString("%d files", comment: "review"), files.count))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if !files.isEmpty {
                        Text(String(format: NSLocalizedString("%d of %d viewed", comment: "review"), viewedCount, files.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if !files.isEmpty {
                    ProgressView(value: Double(viewedCount), total: Double(max(1, files.count)))
                        .progressViewStyle(.linear)
                        .tint(viewedCount == files.count ? .green : .accentColor)
                }
                if let wanted = focus.files, !wanted.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(showAll ? NSLocalizedString("All changes", comment: "review")
                                     : NSLocalizedString("Changed in this turn", comment: "review"))
                        Spacer()
                        Button(showAll ? NSLocalizedString("This turn", comment: "review")
                                       : NSLocalizedString("Show all", comment: "review")) {
                            showAll.toggle()
                        }
                        .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(files) { f in fileRow(f) }
                }
                .padding(6)
            }
            if let d = data {
                let untracked = d.statusLines.filter { $0.hasPrefix("??") }.count
                if !d.logLines.isEmpty || untracked > 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        if !d.logLines.isEmpty {
                            Label(d.logLines.count == 1 ? NSLocalizedString("1 commit", comment: "branch status")
                                  : String(format: NSLocalizedString("%d commits", comment: "branch status"), d.logLines.count),
                                  systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                                .font(.system(size: 11, weight: .semibold))
                            ForEach(d.logLines.prefix(6), id: \.self) { l in
                                Text(l).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                            }
                        }
                        if untracked > 0, base != .lastCommit {
                            Label(untracked == 1 ? NSLocalizedString("1 new file not added to git yet", comment: "review")
                                  : String(format: NSLocalizedString("%d new files not added to git yet", comment: "review"), untracked),
                                  systemImage: "plus.square.dashed")
                                .font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                }
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    private func fileRow(_ f: TaskDiffFile) -> some View {
        let viewed = isViewed(f)
        let n = comments.filter { $0.file == f.path }.count
        let name = (f.path as NSString).lastPathComponent
        let dir = (f.path as NSString).deletingLastPathComponent
        return Button {
            selectedFile = f.path
        } label: {
            HStack(spacing: 7) {
                Button {
                    source.setViewed(f.path, viewed ? nil : TaskReviewData.fingerprint(f))
                } label: {
                    Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(viewed ? Color.green : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(viewed ? NSLocalizedString("Viewed — click to unmark", comment: "review")
                             : NSLocalizedString("Mark as viewed", comment: "review"))
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.system(size: 12, weight: selectedFile == f.path ? .semibold : .regular))
                        .foregroundStyle(viewed ? .secondary : .primary)
                        .lineLimit(1)
                    if !dir.isEmpty {
                        Text(dir)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if n > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "text.bubble.fill")
                        Text("\(n)")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                }
                Text("+\(f.added)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.green)
                Text("−\(f.removed)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.red)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selectedFile == f.path ? Color.accentColor.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(f.path)
    }

    // MARK: Diff
    // MARK: Diff

    @ViewBuilder private var diffPane: some View {
        if let data {
            let files = visibleFiles
            if files.isEmpty {
                emptyState(data)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let plan = source.plan(), !plan.isEmpty { planCard(plan) }
                            ForEach(files) { f in
                                DiffFileView(
                                    file: f,
                                    lineComments: comments.filter { $0.file == f.path && $0.line != nil },
                                    onComment: { draftFile = f.path },
                                    onLineComment: { line, text in source.addComment(text, f.path, line) },
                                    viewed: isViewed(f),
                                    onToggleViewed: {
                                        source.setViewed(f.path, isViewed(f) ? nil : TaskReviewData.fingerprint(f))
                                    },
                                    onRemoveComment: { source.removeComment($0) },
                                    linePlaceholder: NSLocalizedString("Comment on line %d", comment: "diff pane"))
                                .id(f.path)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: selectedFile) { _, p in
                        guard let p else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(p, anchor: .top) }
                    }
                }
            }
        } else if loadFailed {
            ContentUnavailableView(
                NSLocalizedString("Can't reach the machine", comment: "review"),
                systemImage: "bolt.horizontal.circle",
                description: Text(NSLocalizedString("The changes are read live from the machine — start it and refresh.", comment: "review")))
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Reading the changes from the machine…", comment: "review"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A task's plan, above its diff — what the change set out to do.
    private func planCard(_ plan: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { planOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: planOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    Label(NSLocalizedString("Plan", comment: "review"), systemImage: "list.bullet.clipboard")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if planOpen {
                MarkdownBlocks(text: plan, compact: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.06)))
            }
        }
    }

    @ViewBuilder private func emptyState(_ data: TaskReviewData) -> some View {
        let turnHidden = !showAll && focus.files != nil && !data.files.isEmpty
        VStack(spacing: 12) {
            ContentUnavailableView(
                turnHidden ? NSLocalizedString("This turn's files have no changes here", comment: "review")
                           : NSLocalizedString("No changes", comment: "review"),
                systemImage: "checkmark.seal",
                description: Text(emptyExplanation(turnHidden: turnHidden)))
            HStack {
                if turnHidden {
                    Button(NSLocalizedString("Show All Changes", comment: "review")) { showAll = true }
                }
                if base == .uncommitted {
                    Button(NSLocalizedString("Show the Last Commit", comment: "review")) {
                        base = .lastCommit; baseChosen = true
                        Task { await load() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyExplanation(turnHidden: Bool) -> String {
        if turnHidden {
            return NSLocalizedString("They may already be committed — try Last commit, or show everything.", comment: "review")
        }
        switch base {
        case .uncommitted: return NSLocalizedString("Nothing uncommitted: the agent may have committed its work.", comment: "review")
        case .branch(let p): return String(format: NSLocalizedString("The branch has nothing %@ doesn't have.", comment: "review"), p)
        case .lastCommit: return NSLocalizedString("The last commit changed nothing that can be shown.", comment: "review")
        }
    }

    // MARK: Comments

    private var commentsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            let general = comments.filter { $0.line == nil }
            if !general.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(general) { c in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: c.sentAt == nil ? "bubble.left.fill" : "checkmark.bubble")
                                    .font(.system(size: 10))
                                    .foregroundStyle(c.sentAt == nil ? .purple : .secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    if let file = c.file {
                                        Text(file).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    Text(c.text)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(c.sentAt == nil ? .primary : .secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                                if c.sentAt == nil {
                                    Button { source.removeComment(c.id) } label: {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Text(NSLocalizedString("sent", comment: "review comment"))
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .frame(height: min(96, CGFloat(general.count) * 34))
            }
            VStack(alignment: .leading, spacing: 4) {
                if let draftFile {
                    HStack(spacing: 3) {
                        Text(draftFile).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        Button { self.draftFile = nil } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
                }
                ChatComposer(
                    placeholder: draftFile == nil
                        ? NSLocalizedString("A comment on the whole change — or hover a line to comment on it", comment: "review")
                        : NSLocalizedString("A comment on this file", comment: "review"),
                    text: $draft, accent: .purple,
                    hint: source.composerHint,
                    sendSymbol: "plus.bubble.fill",
                    sendHelp: NSLocalizedString("Add the comment (⏎) — it waits with the others until you send them", comment: "review"),
                    accessory: AnyView(sendPill),
                    onSend: addComment)
            }
        }
        .padding(12)
    }

    /// "Send 3 comments to agent", inside the composer's footer.
    private var sendPill: some View {
        let n = drafts.count
        return Button {
            source.send()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperplane.fill").font(.system(size: 10, weight: .semibold))
                Text(source.sendLabel(n))
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(n == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.purple))
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(Capsule().fill(Color.purple.opacity(n == 0 ? 0.04 : 0.12)))
        }
        .buttonStyle(.plain)
        .disabled(n == 0)
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .help(n == 0
              ? NSLocalizedString("Add comments first — on a line, a file or the whole change", comment: "review")
              : source.sendHelp)
    }

    private func addComment() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        source.addComment(t, draftFile, nil)
        draft = ""
        draftFile = nil
    }
}
#endif
