#if os(macOS)
import AppKit
#endif
import SwiftUI

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
    }

    /// The short commit the diff is against ("" when unknown).
    var baseRef = ""

    /// The review of a session's folder against `base`. New files the agent
    /// hasn't added to git yet are shown too (up to 40, under 200 KB each).
    static func sessionCommand(dir: String, base: Base) -> String {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let setBase: String
        var withWorktree = true
        switch base {
        case .uncommitted: setBase = "b=HEAD"
        case .branch(let p): setBase = "b=$(git merge-base \(q(p)) HEAD 2>/dev/null || echo \(q(p)))"
        case .lastCommit: setBase = "b=HEAD~1"; withWorktree = false
        }
        let diff = withWorktree
            ? "{ git diff \"$b\" -- 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null | head -n 40 "
                + "| while IFS= read -r f; do [ \"$(stat -c%s \"$f\" 2>/dev/null || echo 0)\" -lt 204800 ] "
                + "&& git diff --no-index -- /dev/null \"$f\"; done; }"
            : "git diff \"$b\" HEAD -- 2>/dev/null"
        return "cd \(q(dir)) || exit 1; \(setBase); echo ===BASE===; git rev-parse --short \"$b\" 2>/dev/null; "
            + "echo ===LOG===; [ \"$b\" = HEAD ] || git log --oneline \"$b..HEAD\" 2>/dev/null | head -50; "
            + "echo ===STATUS===; git status --porcelain 2>/dev/null | head -100; "
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

#if os(macOS)
// MARK: - Window manager

/// Review windows for Testing cards — the shared review UI (ReviewView) on
/// the task's branch: its diff against the parent, the plan above it,
/// comments that go back with "Send Back", and the ways out: merge (into
/// the parent, squashed, or another branch) or a pull request.
@MainActor
final class TaskReviewWindowManager {
    struct Context {
        var store: () -> CodingTaskStore?
        /// Fetch log/status/diff from the guest. nil = workspace unreachable.
        var fetchReview: (CodingTask, TaskReviewData.Base) async -> TaskReviewData?
        /// Jump to the task's worktree tab (main window locally, the mirror
        /// stage on a fat client).
        var openTerminal: (CodingTask) -> Void
        var accentHex: (Profile.ID) -> String
        var workspaceName: (Profile.ID) -> String
        /// Deliver the unsent comments to the agent and return the task to
        /// In Progress. Host: the task engine; fat client: POST /tasks/…
        /// over the tunnel.
        var sendBack: (UUID) -> Void
        /// Merge the branch — into its parent by default, `target` when the
        /// picker chose another branch, squashed on request.
        var merge: (_ taskID: UUID, _ target: String?, _ squash: Bool,
                    _ cleanup: Bool) -> Void
        /// "Create Pull Request…" — the worktree-pr agent flow.
        var openPR: (UUID) -> Void
        /// Branches of the task's repo, for the "Merge into…" picker.
        var fetchBranches: (CodingTask) async -> [String]
        /// Append a review comment. Host: store.mutate; fat client: POST
        /// (the mirror confirms on the next poll).
        var addComment: (_ taskID: UUID, _ text: String, _ file: String?,
                         _ line: Int?) -> Void
        /// Take back a draft comment.
        var removeComment: (_ taskID: UUID, _ commentID: UUID) -> Void
        /// Mark a file viewed at this state of its diff (nil = not viewed).
        var setViewed: (_ taskID: UUID, _ path: String, _ fingerprint: String?) -> Void
    }

    private let context: Context
    private let host = ReviewWindowHost()

    init(context: Context) {
        self.context = context
    }

    /// The open window for a task, if any — the E2E ui-shot hook renders it.
    func window(for taskID: UUID) -> NSWindow? { host.window(for: taskID) }

    func open(taskID id: UUID) {
        guard let store = context.store(), let task = store.task(id) else { return }
        let c = context
        let t: () -> CodingTask? = { c.store()?.task(id) }
        host.open(id, title: task.title) {
            ReviewSource(
                title: { t()?.title ?? "" },
                place: { .branch(t()?.branch ?? "", parent: t()?.parentBranch) },
                accentHex: { t().map { c.accentHex($0.profileID) } ?? "#888888" },
                workspaceName: { t().map { c.workspaceName($0.profileID) } ?? "" },
                bases: { ReviewSource.standardBases(parent: t()?.parentBranch) },
                defaultBase: { t()?.parentBranch.map { .branch($0) } ?? .uncommitted },
                comments: { t()?.comments ?? [] },
                viewed: { t()?.reviewViewed ?? [:] },
                plan: { t()?.plan },
                fetch: { base in
                    guard let task = t() else { return nil }
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
                    n == 0 ? NSLocalizedString("Send Back to In Progress", comment: "review")
                    : n == 1 ? NSLocalizedString("Send Back with 1 Comment", comment: "review")
                    : String(format: NSLocalizedString("Send Back with %d Comments", comment: "review"), n)
                },
                sendHelp: NSLocalizedString("Sends the comments to the agent and moves the task back to In Progress (⇧⌘⏎)", comment: "review"),
                composerHint: NSLocalizedString("⏎ add comment   ⌥⏎ newline   ⇧⌘⏎ send back", comment: "review composer hint"),
                openTerminal: { if let task = t() { c.openTerminal(task) } },
                trailing: { [weak self] in
                    AnyView(TaskMergeMenu(
                        branch: t()?.branch, parent: t()?.parentBranch,
                        fetchBranches: {
                            guard let task = t() else { return [] }
                            return await c.fetchBranches(task)
                        },
                        onMerge: { target, squash, cleanup in
                            c.merge(id, target, squash, cleanup)
                            self?.host.close(id)
                        },
                        onOpenPR: {
                            c.openPR(id)
                            self?.host.close(id)
                        }))
                })
        }
    }
}

/// The ways out of a task's review: plain or squash merge into the parent,
/// a pull request, or a merge into any other branch of the repo.
struct TaskMergeMenu: View {
    let branch: String?
    let parent: String?
    let fetchBranches: () async -> [String]
    let onMerge: (_ target: String?, _ squash: Bool, _ cleanup: Bool) -> Void
    let onOpenPR: () -> Void

    @State private var cleanupAfterMerge = true
    @State private var branches: [String] = []

    var body: some View {
        let parent = self.parent ?? "parent"
        Menu {
            Button {
                onMerge(nil, true, cleanupAfterMerge)
            } label: {
                Label(String(format: NSLocalizedString("Squash & Merge into %@", comment: "review"), parent),
                      systemImage: "arrow.triangle.merge")
            }
            Divider()
            // Default ON: a merged task's worktree has done its job; the
            // engine removes checkout + branch once the merge is VERIFIED
            // on the target (never before).
            Toggle(NSLocalizedString("Remove worktree after merge", comment: "review"),
                   isOn: $cleanupAfterMerge)
            Divider()
            Button {
                onOpenPR()
            } label: {
                Label(NSLocalizedString("Create Pull Request…", comment: "review"),
                      systemImage: "arrow.up.forward.square")
            }
            let others = branches.filter { $0 != branch && $0 != parent }
            if !others.isEmpty {
                Divider()
                Menu(NSLocalizedString("Merge into…", comment: "review")) {
                    ForEach(others.prefix(30), id: \.self) { b in
                        Button(b) { onMerge(b, false, cleanupAfterMerge) }
                    }
                }
            }
        } label: {
            Label(String(format: NSLocalizedString("Merge into %@", comment: "review"), parent),
                  systemImage: "arrow.triangle.merge")
        } primaryAction: {
            onMerge(nil, false, cleanupAfterMerge)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help(NSLocalizedString(
            "Click to merge into the parent; hold for squash, pull-request, and other-branch options.",
            comment: "review"))
        .task { branches = await fetchBranches() }
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
                        onComment()
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("Comment on this file", comment: "review"))
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
                        .help(NSLocalizedString("Mark as looked at — it folds away until it changes again", comment: "review"))
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
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.06))
                        }
                    }
                    if file.lines.count > Self.maxLines {
                        Text(String(format: NSLocalizedString(
                            "… %d more lines (open the terminal for the full diff)",
                            comment: ""), file.lines.count - Self.maxLines))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(6)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.primary.opacity(0.10)))
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
            .help(NSLocalizedString("Comment on this line", comment: "review"))
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
            Spacer(minLength: 0)
            if comment.sentAt == nil, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Remove this comment", comment: "review"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 3)
        .background(Color.purple.opacity(0.05))
    }
}
