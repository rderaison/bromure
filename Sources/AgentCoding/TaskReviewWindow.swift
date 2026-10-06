#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Build and cache litter an agent's run leaves UNTRACKED in a checkout
/// (`__pycache__/`, `*.pyc`, `.DS_Store`, `node_modules/`) — not the task's
/// changes: left out of every uncommitted count, the review's new-file
/// list, and the "is the branch empty" check. Tracked files are never
/// filtered; git's own ignore rules apply on top.
enum TaskLitter {
    /// Filters `git status --porcelain` lines (only untracked "??" ones).
    static let statusFilter =
        #"grep -vE '^\?\? (.*/)?(__pycache__/|node_modules/|\.DS_Store$|[^/]*\.pyc$)'"#
    /// Filters a list of paths (`git ls-files --others`).
    static let pathFilter =
        #"grep -vE '(^|/)(__pycache__|node_modules)/|(^|/)\.DS_Store$|\.pyc$'"#
    /// `git status --porcelain` in `dir` (already shell-quoted), litter out.
    /// Untracked folders are listed file by file: a folder holding only
    /// `__pycache__/` would otherwise show (and count) as one new folder.
    static func status(_ quotedDir: String) -> String {
        "git -C \(quotedDir) status --porcelain --untracked-files=all 2>/dev/null | \(statusFilter)"
    }
}

// MARK: - Review data

/// What a review window shows: the commits a branch added, the working-tree
/// status, and the diff against the chosen base. The guest command is
/// shared by the host (vsock guestExec) and the fat client (tunnel
/// guestExec) so the two can't drift.
struct TaskReviewData: Equatable, Sendable {
    var logLines: [String] = []
    var statusLines: [String] = []
    var files: [TaskDiffFile] = []

    /// What a session's review compares against.
    enum Base: Hashable, Sendable {
        /// The working tree against HEAD — edits not committed yet, new
        /// files included.
        case uncommitted
        /// Everything since the branch left `parent` (its merge base),
        /// committed or not.
        case branch(String)
        /// The last commit alone.
        case lastCommit
        /// Everything since this moment — from the last commit before it,
        /// committed or not: a turn's changes even after the agent committed
        /// (and merged) them.
        case since(Date)
    }

    /// The short commit the diff is against ("" when unknown).
    var baseRef = ""

    /// The review of a session's folder against `base`. New files the agent
    /// hasn't added to git yet are shown too (up to 40, under 200 KB each).
    /// `focusFiles`: the absolute paths the review is about (a turn's
    /// edits) — the git checkout holding the first of them that is in one is
    /// diffed instead of `dir` (an agent working in a worktree of the
    /// session's folder edits files `dir`'s diff never shows; a memory note
    /// outside any repo must not decide); `dir` when none is.
    static func sessionCommand(dir: String, base: Base, focusFiles: [String] = []) -> String {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let parents = focusFiles.filter { $0.hasPrefix("/") }.prefix(12)
            .map { ($0 as NSString).deletingLastPathComponent }
        let enter: String
        if !parents.isEmpty {
            enter = "d=; for p in \(parents.map(q).joined(separator: " ")); do "
                + "d=$(git -C \"$p\" rev-parse --show-toplevel 2>/dev/null) && [ -n \"$d\" ] && break; d=; done; "
                + "[ -n \"$d\" ] || d=\(q(dir)); cd \"$d\" || exit 1"
        } else {
            enter = "cd \(q(dir)) || exit 1"
        }
        let setBase: String
        var withWorktree = true
        switch base {
        case .uncommitted: setBase = "b=HEAD"
        case .branch(let p): setBase = "b=$(git merge-base \(q(p)) HEAD 2>/dev/null || echo \(q(p)))"
        case .lastCommit: setBase = "b=HEAD~1"; withWorktree = false
        case .since(let t):
            // The empty tree when the repo is younger than the moment.
            setBase = "b=$(git rev-list -1 --before=@\(Int(t.timeIntervalSince1970)) HEAD 2>/dev/null); "
                + "[ -n \"$b\" ] || b=4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        }
        let diff = withWorktree
            ? "{ git diff \"$b\" -- 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null | \(TaskLitter.pathFilter) | head -n 40 "
                + "| while IFS= read -r f; do [ \"$(stat -c%s \"$f\" 2>/dev/null || echo 0)\" -lt 204800 ] "
                + "&& git diff --no-index -- /dev/null \"$f\"; done; }"
            : "git diff \"$b\" HEAD -- 2>/dev/null"
        return "\(enter); \(setBase); echo ===BASE===; git rev-parse --short \"$b\" 2>/dev/null; "
            + "echo ===LOG===; [ \"$b\" = HEAD ] || git log --oneline \"$b..HEAD\" 2>/dev/null | head -50; "
            + "echo ===STATUS===; git status --porcelain 2>/dev/null | \(TaskLitter.statusFilter) | head -100; "
            + "echo ===DIFF===; \(diff) | head -c 600000; true"
    }

    /// A stable fingerprint of a file's diff — "viewed" holds while it
    /// matches.
    static func fingerprint(_ file: TaskDiffFile) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for line in file.lines {
            for b in line.text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            h = (h ^ 0x0a) &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// Split the guest command's marker-delimited output. Tolerant: missing
    /// sections yield empty lists.
    static func parse(_ raw: String) -> TaskReviewData {
        var out = TaskReviewData()
        var section = ""
        var diffLines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            switch line {
            case "===BASE===":   section = "base"; continue
            case "===LOG===":    section = "log"; continue
            case "===STATUS===": section = "status"; continue
            case "===DIFF===":   section = "diff"; continue
            default: break
            }
            switch section {
            case "base":
                if !line.isEmpty, out.baseRef.isEmpty { out.baseRef = String(line) }
            case "log":
                if !line.isEmpty { out.logLines.append(String(line)) }
            case "status":
                if !line.isEmpty { out.statusLines.append(String(line)) }
            case "diff":
                diffLines.append(String(line))
            default: break
            }
        }
        out.files = TaskDiffParser.parse(diffLines.joined(separator: "\n"))
        return out
    }
}

// MARK: - Review summary

/// Where a task's branch stands against its target, from one guest command:
/// commits on the branch / on the target since, what changed, both
/// checkouts' state, and the remote a pull request would go to.
struct TaskReviewSummary: Equatable, Sendable {
    /// Commits the branch adds.
    var ahead = 0
    /// Commits the target gained since the branch left it.
    var behind = 0
    var files = 0
    var insertions = 0
    var deletions = 0
    /// Uncommitted entries in the branch's checkout.
    var uncommitted = 0
    /// Where the target is checked out ("" = nowhere).
    var targetDir = ""
    /// Uncommitted entries in the target's checkout (nil: not checked out).
    var targetDirty: Int?
    /// The first remote ("origin"), nil when the repo has none.
    var remote: String?
    var remoteURL: String?

    /// Nothing to merge: no commit and no change on the branch.
    var isNoCode: Bool { ahead == 0 && files == 0 && uncommitted == 0 }

    /// Bromure can land it itself (no agent): strictly ahead, nothing
    /// uncommitted, the target's checkout clean.
    func fastForward(squash: Bool) -> Bool {
        behind == 0 && uncommitted == 0 && (targetDirty ?? 0) == 0 && ahead > 0 && (!squash || ahead == 1)
    }

    static func command(root: String, worktreeDir: String?, branch: String, target: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var cmd = "r=\(q(root)); "
            + "echo \"AB $(git -C \"$r\" rev-list --left-right --count \(q(target + "..." + branch)) 2>/dev/null)\"; "
        if let wt = worktreeDir, !wt.isEmpty {
            cmd += "w=\(q(wt)); "
                + "m=$(git -C \"$w\" merge-base \(q(target)) HEAD 2>/dev/null); "
                + "echo \"SS $(git -C \"$w\" diff --shortstat \"$m\" 2>/dev/null)\"; "
                + "echo \"UC $(\(TaskLitter.status("\"$w\"")) | wc -l | tr -d ' ')\"; "
        } else {
            cmd += "echo \"SS $(git -C \"$r\" diff --shortstat \(q(target + "..." + branch)) 2>/dev/null)\"; echo 'UC 0'; "
        }
        cmd += "d=$(git -C \"$r\" worktree list --porcelain 2>/dev/null | awk -v want=\(q("branch refs/heads/" + target)) "
            + "'/^worktree /{w=substr($0,10)} $0==want{print w; exit}'); echo \"TD $d\"; "
            + "[ -n \"$d\" ] && echo \"TC $(git -C \"$d\" status --porcelain 2>/dev/null | wc -l | tr -d ' ')\"; "
            + "rm=$(git -C \"$r\" remote 2>/dev/null | head -1); echo \"RM $rm\"; "
            + "[ -n \"$rm\" ] && echo \"RU $(git -C \"$r\" remote get-url \"$rm\" 2>/dev/null)\"; true"
        return cmd
    }

    static func parse(_ out: String) -> TaskReviewSummary {
        var s = TaskReviewSummary()
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.count >= 2 else { continue }
            let tag = String(line.prefix(2))
            let rest = line.count > 3 ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : ""
            switch tag {
            case "AB":
                let n = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int($0) }
                if n.count == 2 { s.behind = n[0]; s.ahead = n[1] }
            case "SS":
                // " 3 files changed, 10 insertions(+), 2 deletions(-)"
                for part in rest.split(separator: ",") {
                    let words = part.split(separator: " ")
                    guard let n = words.first.flatMap({ Int($0) }) else { continue }
                    if part.contains("file") { s.files = n }
                    else if part.contains("insertion") { s.insertions = n }
                    else if part.contains("deletion") { s.deletions = n }
                }
            case "UC": s.uncommitted = Int(rest) ?? 0
            case "TD": s.targetDir = rest
            case "TC": s.targetDirty = Int(rest)
            case "RM": s.remote = rest.isEmpty ? nil : rest
            case "RU": s.remoteURL = rest.isEmpty ? nil : rest
            default: break
            }
        }
        return s
    }

    /// The agent's last words in a task transcript — its final report: what
    /// it wrote in its last turn (since the last prompt), not only its last
    /// message. A no-code task's answer is often a message of its own ("the
    /// haiku") followed by a wrap-up that points at it ("I wrote the haiku
    /// in the chat above") — the wrap-up alone showed no haiku. The last
    /// three messages at most.
    static func finalReport(fromTranscript text: String, agent: String?) -> String? {
        let items = AgentTranscript.parse(Data(text.utf8), agent: agent)
        var turn: [String] = []
        for item in items.reversed() {
            if case .userText = item.kind { break }
            if case .assistantText(let t) = item.kind {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { turn.insert(trimmed, at: 0) }
            }
        }
        if turn.isEmpty {
            // No prose since the last prompt: its last words anywhere.
            for item in items.reversed() {
                if case .assistantText(let t) = item.kind {
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        return turn.suffix(3).joined(separator: "\n\n")
    }
}

#if os(macOS)
// MARK: - Window manager

/// Review windows for Review cards — the shared review UI (ReviewView) on
/// the task's branch: its diff against the parent, the plan above it, a
/// summary of where the branch stands, comments that go back with "Send
/// Back", and the ways out: land it (merge, or a pull request), mark it
/// done as it is, or discard the branch.
@MainActor
final class TaskReviewWindowManager {
    struct Context {
        var store: () -> CodingTaskStore?
        /// Fetch log/status/diff from the guest. nil = workspace unreachable.
        var fetchReview: (CodingTask, TaskReviewData.Base) async -> TaskReviewData?
        /// Where the branch stands (summary banner). nil = unreachable.
        var fetchSummary: (CodingTask, _ target: String) async -> TaskReviewSummary?
        /// The agent's final report (no-code tasks), from its transcript.
        var fetchFinalReport: (CodingTask) async -> String?
        /// Jump to the task's session (main window locally, the mirror
        /// stage on a fat client).
        var openTerminal: (CodingTask) -> Void
        var openTranscript: (CodingTask) -> Void
        var accentHex: (Profile.ID) -> String
        var workspaceName: (Profile.ID) -> String
        /// The task's effective finish preference (task → workspace → app).
        var finishPreference: (CodingTask) -> TaskFinish
        /// Deliver the unsent comments to the agent and return the task to
        /// In Progress.
        var sendBack: (UUID) -> Void
        /// Land it: merge / squash / pull request into `target` (nil = parent).
        var land: (_ taskID: UUID, _ mode: TaskLanding.Mode, _ target: String?, _ keepBranch: Bool) -> Void
        var retryLanding: (UUID) -> Void
        var cancelLanding: (UUID) -> Void
        /// Review → Done as it stands, nothing merged or removed.
        var markDone: (UUID) -> Void
        /// A delegated task's pull request merged on the forge.
        var markMerged: (UUID) -> Void
        /// Discard the branch (and its checkout): Done, closed without merging.
        var discard: (UUID) -> Void
        /// Branches of the task's repo, for "Merge into another branch".
        var fetchBranches: (CodingTask) async -> [String]
        /// Remember what the summary measured (0 files = a no-code task).
        var setCodeChanges: (UUID, Int) -> Void = { _, _ in }
        var addComment: (_ taskID: UUID, _ text: String, _ file: String?,
                         _ line: Int?) -> Void
        var removeComment: (_ taskID: UUID, _ commentID: UUID) -> Void
        var setViewed: (_ taskID: UUID, _ path: String, _ fingerprint: String?) -> Void
    }

    private let context: Context
    private let host = ReviewWindowHost()
    /// Per task: the landing confirm to open as soon as the window shows
    /// (a card's context-menu Merge).
    private var pendingConfirm: [UUID: ReviewLandingRequest] = [:]

    init(context: Context) {
        self.context = context
    }

    /// The open window for a task, if any — the E2E ui-shot hook renders it.
    func window(for taskID: UUID) -> NSWindow? { host.window(for: taskID) }

    /// `confirm`: open straight on the landing confirmation (merge / PR).
    func open(taskID id: UUID, confirm: TaskLanding.Mode? = nil) {
        guard let store = context.store(), let task = store.task(id) else { return }
        let c = context
        let t: () -> CodingTask? = { c.store()?.task(id) }
        let request = pendingConfirm[id] ?? ReviewLandingRequest()
        pendingConfirm[id] = request
        if let confirm { request.mode = confirm; request.generation += 1 }
        host.open(id, title: task.title) {
            ReviewSource(
                title: { t()?.title ?? "" },
                place: { .branch(t()?.branch ?? "", parent: t()?.landingTarget) },
                accentHex: { t().map { c.accentHex($0.profileID) } ?? "#888888" },
                workspaceName: { t().map { c.workspaceName($0.profileID) } ?? "" },
                bases: { ReviewSource.standardBases(parent: t()?.parentBranch) },
                defaultBase: { t()?.parentBranch.map { .branch($0) } ?? .uncommitted },
                comments: { t()?.comments ?? [] },
                viewed: { t()?.reviewViewed ?? [:] },
                plan: { t()?.plan },
                note: {
                    guard let task = t(), let text = task.mergeReport ?? task.deliverySummary else { return nil }
                    return (task.assignment?.label ?? NSLocalizedString("The agent", comment: "review"), text)
                },
                noCode: { t()?.isNoCode == true },
                fetch: { base, _ in
                    guard let task = t() else { return nil }
                    // A refresh (↻) re-reads the summary banner too.
                    await MainActor.run { request.reloads += 1 }
                    return await c.fetchReview(task, base)
                },
                addComment: { text, file, line in c.addComment(id, text, file, line) },
                removeComment: { c.removeComment(id, $0) },
                setViewed: { c.setViewed(id, $0, $1) },
                send: { [weak self] in
                    c.sendBack(id)
                    self?.host.close(id)
                },
                sendLabel: { n in
                    n == 0 ? NSLocalizedString("Send Back", comment: "review")
                    : String(format: NSLocalizedString("Send Back (%d)", comment: "review: comments to send"), n)
                },
                sendHelp: NSLocalizedString("Sends the comments to the agent and moves the task back to In Progress (⇧⌘⏎)", comment: "review"),
                composerHint: NSLocalizedString("⏎ add comment   ⇧⏎ newline   ⇧⌘⏎ send back", comment: "review composer hint"),
                openTerminal: { if let task = t() { c.openTerminal(task) } },
                banner: { [weak self] in
                    AnyView(TaskReviewBanner(
                        task: t, context: c, request: request,
                        close: { self?.host.close(id) }))
                })
        }
    }
}

/// The landing confirm a review window should open on (a card's Merge).
@MainActor
@Observable
final class ReviewLandingRequest {
    var mode: TaskLanding.Mode?
    var generation = 0
    /// Bumped on every diff (re)load — the banner re-reads its summary.
    var reloads = 0
}

/// Under the review header: where the branch stands, and the ways out —
/// the finish preference's action first (Merge into <target> / Open Pull
/// Request), the other ways in a menu, Mark Done, More → Discard. A task
/// that produced no code shows the agent's final report and Mark Done.
struct TaskReviewBanner: View {
    let task: () -> CodingTask?
    let context: TaskReviewWindowManager.Context
    let request: ReviewLandingRequest
    let close: () -> Void

    @State private var summary: TaskReviewSummary?
    @State private var summaryFailed = false
    @State private var report: String?
    @State private var branches: [String] = []
    @State private var confirming: ConfirmLanding?
    @State private var confirmingDone = false
    @State private var confirmingDiscard = false
    @State private var reportOpen = true
    /// The summary is being re-read before the landing confirm opens.
    @State private var preparingConfirm = false

    struct ConfirmLanding: Identifiable {
        var mode: TaskLanding.Mode
        var target: String
        var pickTarget: Bool
        var id: String { mode.rawValue + target + (pickTarget ? "?" : "") }
    }

    private var agentName: String { task().map(CodingTaskEngine.landingAgentName) ?? "" }

    private var noCode: Bool {
        guard let t = task() else { return false }
        if t.isNoCode { return true }
        return summary?.isNoCode ?? false
    }

    var body: some View {
        if let t = task() {
            VStack(alignment: .leading, spacing: 8) {
                summaryLine(t)
                if noCode { reportCard(t) }
                if let l = t.landing, t.stage == .testing { landingStatus(t, l) }
                if t.stage == .testing { undeliveredLine(t) }
                HStack(spacing: 8) {
                    if t.stage == .testing {
                        actions(t)
                    } else {
                        Text(NSLocalizedString("This task isn't in Review any more.", comment: "review"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.025))
            .overlay(alignment: .bottom) { Divider() }
            .task(id: t.id.uuidString + (t.landingTarget ?? "") + "#\(request.reloads)") { await load(t) }
            .onChange(of: request.generation) { _, _ in consumeRequest() }
            .onChange(of: t.stage) { old, new in
                // Landed (or sent back, marked done elsewhere): the window's
                // job is over — close it, as Mark Done does.
                if old == .testing, new != .testing { close() }
            }
            .onAppear { consumeRequest() }
            .sheet(item: $confirming) { c in confirmSheet(c, t) }
            .confirmationDialog(
                NSLocalizedString("Mark done without merging?", comment: "review"),
                isPresented: $confirmingDone, titleVisibility: .visible) {
                Button(NSLocalizedString("Mark Done", comment: "review")) { markDone(t) }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            } message: {
                let pending = t.comments.filter { $0.sentAt == nil }.count
                Text(String(format: NSLocalizedString(
                    "Nothing is merged. The branch %@ and its checkout are kept in the workspace.",
                    comment: "review"), t.branch ?? "")
                     + (pending == 0 ? "" : "\n\n" + TaskPlurals.undeliveredDropped(pending)))
            }
            .confirmationDialog(
                NSLocalizedString("Discard this branch?", comment: "review"),
                isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button(NSLocalizedString("Discard Branch", comment: "review"), role: .destructive) {
                    context.discard(t.id); close()
                }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            } message: {
                Text(String(format: NSLocalizedString(
                    "The branch %@ and its checkout are deleted and the agent's session is put away. The task goes to Done as closed without merging; its transcript is kept.",
                    comment: "review"), t.branch ?? "") + TaskPlurals.droppedSuffix(t))
            }
        }
    }

    private func load(_ t: CodingTask) async {
        await refreshSummary(t)
        if noCode, report == nil { report = await context.fetchFinalReport(t) }
        branches = await context.fetchBranches(t)
    }

    /// Re-read where the branch stands (on open, on ↻, and right before a
    /// landing confirm — so what it promises is what will happen).
    private func refreshSummary(_ t: CodingTask) async {
        let target = t.landingTarget ?? ""
        guard !target.isEmpty, t.branch != nil else {
            summaryFailed = summary == nil
            return
        }
        if let s = await context.fetchSummary(t, target) {
            summary = s; summaryFailed = false
            context.setCodeChanges(t.id, s.files + s.uncommitted)
        } else {
            summaryFailed = true
        }
    }

    private func consumeRequest() {
        guard let mode = request.mode, let t = task(), t.stage == .testing else { return }
        request.mode = nil
        openConfirm(ConfirmLanding(mode: mode, target: t.landingTarget ?? "", pickTarget: false))
    }

    private func openConfirm(_ c: ConfirmLanding) {
        guard let t = task(), !preparingConfirm else { return }
        preparingConfirm = true
        Task { @MainActor in
            await refreshSummary(t)
            preparingConfirm = false
            confirming = c
        }
    }

    // MARK: Summary

    private func summaryLine(_ t: CodingTask) -> some View {
        let target = t.landingTarget ?? ""
        var parts: [String] = []
        let ws = context.workspaceName(t.profileID)
        if let b = t.branch {
            parts.append(String(format: NSLocalizedString("%1$@ worked on %2$@ in %3$@", comment: "review summary: agent, branch, workspace"),
                                agentName, "`\(b)`", ws))
        } else {
            parts.append(String(format: NSLocalizedString("%1$@ worked in %2$@", comment: "review summary: agent, workspace"), agentName, ws))
        }
        parts.append(t.repoPath)
        if let s = summary, !noCode {
            parts.append(s.ahead == 1 ? NSLocalizedString("1 commit", comment: "branch status")
                         : String(format: NSLocalizedString("%d commits", comment: "branch status"), s.ahead))
            let files = s.files == 1 ? NSLocalizedString("1 file", comment: "review")
                : String(format: NSLocalizedString("%d files", comment: "review"), s.files)
            parts.append(String(format: NSLocalizedString("%1$@ (+%2$d −%3$d) vs %4$@", comment: "review summary: files, +, −, target"),
                                files, s.insertions, s.deletions, "`\(target)`"))
            if s.uncommitted > 0 {
                parts.append(String(format: NSLocalizedString("%d uncommitted", comment: "review summary"), s.uncommitted))
            }
            if s.behind > 0 {
                parts.append(s.behind == 1
                    ? String(format: NSLocalizedString("%@ moved 1 commit since", comment: "review summary: target"), target)
                    : String(format: NSLocalizedString("%1$@ moved %2$d commits since", comment: "review summary: target, n"),
                             target, s.behind))
            }
            if let dirty = s.targetDirty {
                parts.append(dirty == 0
                    ? String(format: NSLocalizedString("%@ checkout clean", comment: "review summary"), target)
                    : String(format: NSLocalizedString("%@ checkout has uncommitted changes", comment: "review summary"), target))
            } else {
                parts.append(String(format: NSLocalizedString("%@ not checked out", comment: "review summary"), target))
            }
            parts.append(String(format: NSLocalizedString("remote: %@", comment: "review summary"),
                                s.remote ?? NSLocalizedString("none", comment: "review summary: no remote")))
        } else if summaryFailed {
            parts.append(NSLocalizedString("can't reach the machine for the details", comment: "review summary"))
        }
        let text = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        return Group {
            if let attr = try? AttributedString(markdown: text) { Text(attr) } else { Text(text) }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)
        .help(text)
    }

    private func reportCard(_ t: CodingTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { reportOpen.toggle() }
                } label: {
                    Label(String(format: NSLocalizedString("%@'s final report", comment: "review: no-code task"), agentName),
                          systemImage: reportOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.indigo)
                }
                .buttonStyle(.plain)
                Text(NSLocalizedString("No code changes to merge", comment: "review: no-code task"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("View Transcript", comment: "")) { context.openTranscript(t) }
                    .controlSize(.small)
            }
            if reportOpen {
                let text = report ?? t.deliverySummary ?? ""
                if text.isEmpty {
                    Text(NSLocalizedString("Reading the agent's report…", comment: "review"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        MarkdownBlocks(text: text, compact: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.indigo.opacity(0.06)))
                }
            }
        }
    }

    /// Comments still pending when the agent handed the task back: they
    /// never reached it. Said plainly, with the way to send them again.
    @ViewBuilder private func undeliveredLine(_ t: CodingTask) -> some View {
        let n = t.comments.filter { $0.sentAt == nil && $0.undelivered == true }.count
        if n > 0 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                Text(TaskPlurals.undeliveredBanner(n))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(NSLocalizedString("Send Back Again", comment: "review")) {
                    context.sendBack(t.id)
                    close()
                }
            }
            .font(.system(size: 11.5))
            .controlSize(.small)
        }
    }

    @ViewBuilder private func landingStatus(_ t: CodingTask, _ l: TaskLanding) -> some View {
        HStack(spacing: 8) {
            switch l.phase {
            case .needsYou:
                Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                Text(String(format: NSLocalizedString("Needs you — %@", comment: "task landing"), l.detail ?? ""))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Spacer(minLength: 4)
                Button(NSLocalizedString("Open Session", comment: "task landing")) { context.openTerminal(t) }
                Button(NSLocalizedString("Retry", comment: "")) { context.retryLanding(t.id) }
                Button(NSLocalizedString("Cancel Landing", comment: "task landing")) { context.cancelLanding(t.id) }
            default:
                ProgressView().controlSize(.small)
                Text(TaskLandingText.line(for: t) ?? "")
                    .lineLimit(2)
                Spacer(minLength: 4)
                if l.phase == .agentLanding {
                    Button(NSLocalizedString("Open Session", comment: "task landing")) { context.openTerminal(t) }
                    Button(NSLocalizedString("Cancel Landing", comment: "task landing")) { context.cancelLanding(t.id) }
                }
            }
        }
        .font(.system(size: 11.5))
        .controlSize(.small)
    }

    // MARK: Actions

    @ViewBuilder private func actions(_ t: CodingTask) -> some View {
        let landing = t.landing != nil && t.landing?.phase != .needsYou
        if noCode {
            Button { markDone(t) } label: {
                Label(NSLocalizedString("Mark Done", comment: "review"), systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .plainAccessibilityButton(NSLocalizedString("Mark Done", comment: "review")) { markDone(t) }
            .help(NSLocalizedString("The task produced no code: it goes to Done as it is.", comment: "review"))
            .accessibilityLabel(NSLocalizedString("Mark Done", comment: "review"))
            .accessibilityHint(NSLocalizedString("The task produced no code: it goes to Done as it is.", comment: "review"))
        } else if let pr = t.pullRequestURL, t.delegationID != nil, let url = URL(string: pr) {
            Link(destination: url) {
                Label(String(format: NSLocalizedString("View Pull Request #%@", comment: "review"), url.lastPathComponent),
                      systemImage: "arrow.triangle.pull")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(String(format: NSLocalizedString("View Pull Request #%@", comment: "review"), url.lastPathComponent))
            Button(NSLocalizedString("Mark Merged", comment: "review")) { context.markMerged(t.id); close() }
                .help(NSLocalizedString("The pull request was merged on the forge: the task goes to Done as merged.", comment: "review"))
                .accessibilityLabel(NSLocalizedString("Mark Merged", comment: "review"))
                .accessibilityHint(NSLocalizedString("The pull request was merged on the forge: the task goes to Done as merged.", comment: "review"))
            markDoneButton(t)
        } else {
            primaryLanding(t).disabled(landing)
            markDoneButton(t)
        }
        Menu {
            Button(NSLocalizedString("Open Session", comment: "task landing")) { context.openTerminal(t) }
            Button(NSLocalizedString("View Transcript", comment: "")) { context.openTranscript(t) }
            if t.branch != nil {
                Divider()
                Button(NSLocalizedString("Discard Branch…", comment: "review"), role: .destructive) {
                    confirmingDiscard = true
                }
            }
        } label: {
            Label(NSLocalizedString("More", comment: "review"), systemImage: "ellipsis.circle")
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel(NSLocalizedString("More", comment: "review"))
    }

    private var preference: TaskFinish { task().map(context.finishPreference) ?? .merge }

    @ViewBuilder private func primaryLanding(_ t: CodingTask) -> some View {
        let target = t.landingTarget ?? NSLocalizedString("parent", comment: "kanban menu")
        let hasRemote = summary?.remote != nil
        // A pull request needs a remote: decided only once the summary says
        // (couldn't read it: the preference stands — the agent finds out).
        let prFirst = preference == .pullRequest && (hasRemote || summaryFailed)
        let mergeTitle = String(format: NSLocalizedString("Merge into %@", comment: "review"), target)
        let prTitle = NSLocalizedString("Open Pull Request", comment: "review")
        if summary == nil && !summaryFailed {
            // Not known yet which way is first: no flash of the wrong one.
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(NSLocalizedString("Checking the branch…", comment: "review"))
                }
            }
            .disabled(true)
            .accessibilityLabel(NSLocalizedString("Checking the branch…", comment: "review"))
        } else {
            // A split button: the prominent primary, the other ways in the
            // chevron menu (a prominent style on a Menu renders gray).
            HStack(spacing: 2) {
                Button {
                    openConfirm(ConfirmLanding(mode: prFirst ? .pr : .merge, target: t.landingTarget ?? "", pickTarget: false))
                } label: {
                    Label(prFirst ? prTitle : mergeTitle,
                          systemImage: prFirst ? "arrow.triangle.pull" : "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .plainAccessibilityButton(prFirst ? prTitle : mergeTitle) {
                    openConfirm(ConfirmLanding(mode: prFirst ? .pr : .merge, target: t.landingTarget ?? "", pickTarget: false))
                }
                .help(prFirst
                      ? NSLocalizedString("Open a pull request for the branch.", comment: "review")
                      : NSLocalizedString("Merge the branch.", comment: "review"))
                .accessibilityLabel(prFirst ? prTitle : mergeTitle)
                .accessibilityHint(prFirst
                      ? NSLocalizedString("Open a pull request for the branch.", comment: "review")
                      : NSLocalizedString("Merge the branch.", comment: "review"))
                Menu {
                    if prFirst {
                        Button(mergeTitle) { confirm(.merge, t) }
                    } else if hasRemote {
                        Button(prTitle) { confirm(.pr, t) }
                    }
                    Button(String(format: NSLocalizedString("Squash & Merge into %@", comment: "review"), target)) { confirm(.squash, t) }
                    Button(NSLocalizedString("Merge into Another Branch…", comment: "review")) {
                        openConfirm(ConfirmLanding(mode: .merge, target: "", pickTarget: true))
                    }
                    Divider()
                    Button(NSLocalizedString("Keep Branch — Mark Done", comment: "review")) { confirmingDone = true }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(NSLocalizedString("Other ways to land it", comment: "review"))
                .accessibilityLabel(NSLocalizedString("Other ways to land it", comment: "review"))
            }
            .disabled(preparingConfirm)
        }
    }

    private func markDoneButton(_ t: CodingTask) -> some View {
        Button { confirmingDone = true } label: {
            Label(NSLocalizedString("Mark Done", comment: "review"), systemImage: "checkmark.circle")
        }
        .plainAccessibilityButton(NSLocalizedString("Mark Done", comment: "review")) { confirmingDone = true }
        .help(NSLocalizedString("Mark done without merging — the branch is kept.", comment: "review"))
        .accessibilityLabel(NSLocalizedString("Mark Done", comment: "review"))
        .accessibilityHint(NSLocalizedString("Mark done without merging — the branch is kept.", comment: "review"))
    }

    private func confirm(_ mode: TaskLanding.Mode, _ t: CodingTask) {
        openConfirm(ConfirmLanding(mode: mode, target: t.landingTarget ?? "", pickTarget: false))
    }

    private func markDone(_ t: CodingTask) {
        context.markDone(t.id)
        close()
    }

    // MARK: Confirm sheet

    private func confirmSheet(_ c: ConfirmLanding, _ t: CodingTask) -> some View {
        LandingConfirmSheet(
            confirm: c, task: t, summary: summary, agentName: agentName,
            branches: branches.filter { $0 != t.branch && !$0.hasPrefix("wt/") },
            onCancel: { confirming = nil },
            onConfirm: { target, keep in
                confirming = nil
                context.land(t.id, c.mode, target.isEmpty ? nil : target, keep)
            })
    }
}

/// "Merge into main?" — exactly what will happen, before it does.
struct LandingConfirmSheet: View {
    let confirm: TaskReviewBanner.ConfirmLanding
    let task: CodingTask
    let summary: TaskReviewSummary?
    let agentName: String
    let branches: [String]
    let onCancel: () -> Void
    let onConfirm: (_ target: String, _ keepBranch: Bool) -> Void

    @State private var target = ""
    @State private var keepBranch = false

    private var confirmTitle: String {
        confirm.mode == .pr ? NSLocalizedString("Open Pull Request", comment: "review")
            : NSLocalizedString("Merge", comment: "landing confirm")
    }

    private var title: String {
        switch confirm.mode {
        case .pr: return String(format: NSLocalizedString("Open a pull request into %@?", comment: "landing confirm"), target)
        case .squash: return String(format: NSLocalizedString("Squash & merge into %@?", comment: "landing confirm"), target)
        case .merge: return String(format: NSLocalizedString("Merge into %@?", comment: "landing confirm"), target)
        }
    }

    private var what: (text: String, warning: String?) {
        // The summary describes the task's own target; another branch is
        // only known once the agent looks.
        let known = target == (task.landingTarget ?? "") ? summary : nil
        return Self.describe(mode: confirm.mode, summary: known, target: target,
                             branch: task.branch ?? "", agent: agentName)
    }

    /// What landing will actually do, from where the branch stands now —
    /// the same decision `landingCheckCommand` makes — and what's in the
    /// way (`warning`). `summary` nil: not known, the agent's general path.
    nonisolated static func describe(mode: TaskLanding.Mode, summary: TaskReviewSummary?, target: String,
                                     branch: String, agent: String) -> (text: String, warning: String?) {
        var warning: String?
        if mode != .pr, let dirty = summary?.targetDirty, dirty > 0 {
            warning = String(format: NSLocalizedString(
                "The %1$@ checkout has uncommitted changes — if they touch the same files, %2$@ can't merge until you commit or stash them there.",
                comment: "landing confirm: target, agent"), target, agent)
        }
        if mode == .pr {
            return (String(format: NSLocalizedString(
                "%1$@, the agent that wrote it, will rebase onto %2$@, run the tests, push %3$@ to %4$@ and open a pull request. You'll see its progress on the task and in its session.",
                comment: "landing confirm"), agent, target, branch, summary?.remote ?? "origin"), warning)
        }
        guard let s = summary else {
            return (String(format: NSLocalizedString(
                "%1$@, the agent that wrote it, will rebase onto %2$@, fix conflicts, run the tests and merge. You'll see its progress on the task and in its session.",
                comment: "landing confirm"), agent, target), warning)
        }
        if s.ahead == 0 && s.uncommitted == 0 {
            return (String(format: NSLocalizedString(
                "%1$@ adds nothing %2$@ doesn't already have: the task goes to Done.",
                comment: "landing confirm"), branch, target), nil)
        }
        // Strictly ahead with a clean branch: Bromure fast-forwards it
        // itself (a dirty target checkout only stops it when the changes
        // are in the way).
        if s.behind == 0 && s.uncommitted == 0 && s.ahead > 0 && (mode != .squash || s.ahead == 1) {
            if (s.targetDirty ?? 0) > 0 {
                return (String(format: NSLocalizedString(
                    "%1$@ is ahead of %2$@: Bromure merges it directly.",
                    comment: "landing confirm"), branch, target),
                        String(format: NSLocalizedString(
                            "The %@ checkout has uncommitted changes — if they touch the same files, the merge stops until you commit or stash them there.",
                            comment: "landing confirm: target"), target))
            }
            return (String(format: NSLocalizedString(
                "%1$@ is ahead of %2$@ with nothing in the way: Bromure merges it directly.",
                comment: "landing confirm"), branch, target), nil)
        }
        // The agent lands it — say which of its steps are needed.
        var steps: [String] = []
        if s.uncommitted > 0 {
            steps.append(NSLocalizedString("commit what's left uncommitted", comment: "landing confirm step"))
        }
        if s.behind > 0 {
            steps.append(String(format: NSLocalizedString("rebase onto %@ and fix conflicts", comment: "landing confirm step"), target))
        }
        if mode == .squash && s.ahead + (s.uncommitted > 0 ? 1 : 0) > 1 {
            steps.append(NSLocalizedString("squash it into one commit", comment: "landing confirm step"))
        }
        steps.append(NSLocalizedString("run the tests", comment: "landing confirm step"))
        steps.append(NSLocalizedString("merge", comment: "landing confirm step"))
        let list = ListFormatter.localizedString(byJoining: steps)
        return (String(format: NSLocalizedString(
            "%1$@, the agent that wrote it, will %2$@. You'll see its progress on the task and in its session.",
            comment: "landing confirm: agent, steps"), agent, list), warning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if confirm.pickTarget {
                Picker(NSLocalizedString("Into", comment: "landing confirm"), selection: $target) {
                    ForEach(branches, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 320)
            }
            Text(what.text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            if let warning = what.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A Send Back that didn't get through leaves its comments pending.
            let pending = task.comments.filter { $0.sentAt == nil }.count
            if pending > 0 {
                Label(TaskPlurals.pendingAtLanding(pending), systemImage: "exclamationmark.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirm.mode == .pr {
                Text(NSLocalizedString("Afterwards the session is archived; the branch stays for the pull request.",
                                       comment: "landing confirm"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if task.delegationID == nil {
                Text(keepBranch
                     ? NSLocalizedString("Afterwards the session is archived; the branch and its checkout are kept.", comment: "landing confirm")
                     : NSLocalizedString("Afterwards the branch is removed and the session archived.", comment: "landing confirm"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle(NSLocalizedString("Keep branch", comment: "landing confirm"), isOn: $keepBranch)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(NSLocalizedString("Cancel", comment: ""))
                    .accessibilityHint(NSLocalizedString("Close without landing", comment: "landing confirm"))
                Button(confirmTitle) {
                    onConfirm(target, keepBranch)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target.isEmpty)
                .accessibilityLabel(confirmTitle)
                .accessibilityHint(keepBranch || confirm.mode == .pr
                    ? NSLocalizedString("Afterwards the session is archived; the branch and its checkout are kept.", comment: "landing confirm")
                    : NSLocalizedString("Afterwards the branch is removed and the session archived.", comment: "landing confirm"))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            target = confirm.pickTarget ? (branches.first ?? "") : confirm.target
        }
    }
}
#endif

// MARK: - Diff file view

struct DiffFileView: View {
    let file: TaskDiffFile
    /// Pending comments anchored to lines of THIS file (drafts + sent).
    var lineComments: [ReviewComment] = []
    let onComment: () -> Void
    /// Margin annotation: (new-file line, text).
    var onLineComment: (Int, String) -> Void = { _, _ in }
    /// Session review: whether the file is marked viewed (nil: no such
    /// mark), and its toggle. A viewed file folds away.
    var viewed: Bool? = nil
    var onToggleViewed: () -> Void = {}
    /// Take back a draft comment (nil: drafts can't be removed here).
    var onRemoveComment: ((UUID) -> Void)? = nil
    /// The inline editor's placeholder, for line %d.
    var linePlaceholder = NSLocalizedString("Comment on line %d — sent with “Send Back”", comment: "review")

    @State private var expanded = true
    /// The line id whose inline comment editor is open.
    @State private var composing: Int?
    @State private var draft = ""
    private static let maxLines = 800

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(file.path)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Text("+\(file.added)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.green)
                    Text("−\(file.removed)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                    Button {
                        platformCopyToPasteboard(file.patch)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .plainAccessibilityButton(NSLocalizedString("Copy this file's diff", comment: "review")) {
                        platformCopyToPasteboard(file.patch)
                    }
                    .help(NSLocalizedString("Copy this file's diff", comment: "review"))
                    .accessibilityLabel(NSLocalizedString("Copy this file's diff", comment: "review"))
                    Button {
                        onComment()
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .plainAccessibilityButton(NSLocalizedString("Comment on this file", comment: "review")) { onComment() }
                    .help(NSLocalizedString("Comment on this file", comment: "review"))
                    .accessibilityLabel(NSLocalizedString("Comment on this file", comment: "review"))
                    if let viewed {
                        Button(action: onToggleViewed) {
                            HStack(spacing: 4) {
                                Image(systemName: viewed ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(viewed ? Color.accentColor : .secondary)
                                Text(NSLocalizedString("Viewed", comment: "review"))
                            }
                            .font(.system(size: 10.5))
                        }
                        .buttonStyle(.plain)
                        .plainAccessibilityButton(NSLocalizedString("Viewed", comment: "review"), action: onToggleViewed)
                        .help(NSLocalizedString("Mark as looked at — it folds away until it changes again", comment: "review"))
                        .accessibilityLabel(NSLocalizedString("Viewed", comment: "review"))
                        .accessibilityValue(viewed ? NSLocalizedString("On", comment: "accessibility: toggle value")
                                                   : NSLocalizedString("Off", comment: "accessibility: toggle value"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))

            if expanded {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines.prefix(Self.maxLines)) { line in
                        DiffLineRow(
                            line: line,
                            color: color(for: line.kind),
                            background: background(for: line.kind),
                            annotatable: line.newLine != nil && line.kind != .hunk,
                            onAnnotate: {
                                draft = ""
                                composing = composing == line.id ? nil : line.id
                            })
                        // Anchored comments live under their line.
                        ForEach(lineComments.filter { $0.line == line.newLine
                                                      && line.newLine != nil
                                                      && line.kind != .hunk }) { c in
                            AnchoredCommentRow(comment: c, onRemove: onRemoveComment.map { f in { f(c.id) } })
                        }
                        if composing == line.id, let n = line.newLine {
                            HStack(spacing: 6) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.purple)
                                TextField(String(format: linePlaceholder, n), text: $draft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .onSubmit { submitLineComment(n) }
                                Button(NSLocalizedString("Add", comment: "review")) {
                                    submitLineComment(n)
                                }
                                .controlSize(.small)
                                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button {
                                    composing = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(NSLocalizedString("Cancel", comment: ""))
                                .accessibilityLabel(NSLocalizedString("Cancel", comment: ""))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.06))
                        }
                    }
                    if file.lines.count > Self.maxLines {
                        HStack(spacing: 10) {
                            Text(String(format: NSLocalizedString(
                                "… %d more lines (open the terminal for the full diff)",
                                comment: ""), file.lines.count - Self.maxLines))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Button {
                                platformCopyToPasteboard(file.patch)
                            } label: {
                                Label(NSLocalizedString("Copy this file's diff", comment: "review"),
                                      systemImage: "doc.on.doc")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(6)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.primary.opacity(0.10)))
        .contextMenu {
            Button(NSLocalizedString("Copy this file's diff", comment: "review")) {
                platformCopyToPasteboard(file.patch)
            }
        }
        .onAppear { if viewed == true { expanded = false } }
        .onChange(of: viewed) { _, v in
            withAnimation(.easeInOut(duration: 0.15)) { expanded = v != true }
        }
    }

    private func submitLineComment(_ line: Int) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onLineComment(line, text)
        draft = ""
        composing = nil
    }

    private func color(for kind: TaskDiffFile.LineKind) -> Color {
        switch kind {
        case .hunk:    return .secondary
        case .added:   return .primary
        case .removed: return .primary
        case .context: return .secondary
        }
    }

    private func background(for kind: TaskDiffFile.LineKind) -> Color {
        switch kind {
        case .added:   return .green.opacity(0.13)
        case .removed: return .red.opacity(0.13)
        case .hunk:    return .blue.opacity(0.07)
        case .context: return .clear
        }
    }
}

/// One diff line with a hover-revealed 💬 in the margin — the entry point
/// for a line-anchored review comment.
private struct DiffLineRow: View {
    let line: TaskDiffFile.Line
    let color: Color
    let background: Color
    let annotatable: Bool
    let onAnnotate: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onAnnotate) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 9))
                    .foregroundStyle(.purple)
                    .opacity(hovering && annotatable ? 1 : 0)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(!annotatable)
            .plainAccessibilityButton(NSLocalizedString("Comment on this line", comment: "review"), action: onAnnotate)
            .help(NSLocalizedString("Comment on this line", comment: "review"))
            .accessibilityLabel(NSLocalizedString("Comment on this line", comment: "review"))
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 0.5)
        }
        .padding(.horizontal, 4)
        .background(background)
        .onHover { hovering = $0 }
    }
}

/// A pending/sent comment pinned under the diff line it annotates.
struct AnchoredCommentRow: View {
    let comment: ReviewComment
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: comment.sentAt == nil
                  ? "bubble.left.fill" : "checkmark.bubble")
                .font(.system(size: 9))
                .foregroundStyle(comment.sentAt == nil ? .purple : .secondary)
                .padding(.top, 2)
            Text(comment.text)
                .font(.system(size: 11))
                .foregroundStyle(comment.sentAt == nil ? .primary : .secondary)
                .textSelection(.enabled)
            if comment.sentAt == nil, comment.undelivered == true {
                Text(NSLocalizedString("not delivered", comment: "review comment tag"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help(NSLocalizedString("The agent handed the task back before this comment reached it.", comment: "review"))
            }
            Spacer(minLength: 0)
            if comment.sentAt == nil, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Remove this comment", comment: "review"))
                .accessibilityLabel(NSLocalizedString("Remove this comment", comment: "review"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 3)
        .background(Color.purple.opacity(0.05))
    }
}
