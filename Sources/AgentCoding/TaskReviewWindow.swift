import AppKit
import SwiftUI

// MARK: - Review data

/// What the review window shows for a task branch: the commits it added,
/// the working-tree status, and the full diff against the parent branch.
struct TaskReviewData: Equatable, Sendable {
    var logLines: [String] = []
    var statusLines: [String] = []
    var files: [TaskDiffFile] = []

    /// The guest shell command whose output `parse` reads — shared by the
    /// host (vsock guestExec) and the fat client (tunnel guestExec) so the
    /// two can't drift.
    static func guestCommand(worktreeDir: String, parent: String) -> String {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return """
        cd \(q(worktreeDir)) || exit 1; echo ===LOG===; \
        git log --oneline \(q(parent))..HEAD 2>/dev/null | head -50; \
        echo ===STATUS===; git status --porcelain 2>/dev/null | head -100; \
        echo ===DIFF===; git diff \(q(parent)) 2>/dev/null | head -c 400000
        """
    }

    /// Split the guest command's marker-delimited output. Tolerant: missing
    /// sections yield empty lists.
    static func parse(_ raw: String) -> TaskReviewData {
        var out = TaskReviewData()
        var section = ""
        var diffLines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            switch line {
            case "===LOG===":    section = "log"; continue
            case "===STATUS===": section = "status"; continue
            case "===DIFF===":   section = "diff"; continue
            default: break
            }
            switch section {
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

// MARK: - Window manager

/// Standalone review windows for Testing cards: the branch's diff against
/// its parent, a comment thread, and the two ways out — back to In
/// Progress with feedback, or merge into the parent.
@MainActor
final class TaskReviewWindowManager {
    struct Context {
        var store: () -> CodingTaskStore?
        /// Fetch log/status/diff from the guest. nil = workspace unreachable.
        var fetchReview: (CodingTask) async -> TaskReviewData?
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
        var merge: (_ taskID: UUID, _ target: String?, _ squash: Bool) -> Void
        /// "Create Pull Request…" — the worktree-pr agent flow.
        var openPR: (UUID) -> Void
        /// Branches of the task's repo, for the "Merge into…" picker.
        var fetchBranches: (CodingTask) async -> [String]
        /// Append a review comment. Host: store.mutate; fat client: POST
        /// (the mirror confirms on the next poll).
        var addComment: (_ taskID: UUID, _ text: String, _ file: String?) -> Void
    }

    private let context: Context
    private var windows: [UUID: NSWindow] = [:]

    init(context: Context) {
        self.context = context
    }

    /// The open window for a task, if any — the E2E ui-shot hook renders it.
    func window(for taskID: UUID) -> NSWindow? { windows[taskID] }

    func open(taskID: UUID) {
        if let win = windows[taskID] { win.makeKeyAndOrderFront(nil); return }
        guard let store = context.store(), let task = store.task(taskID) else { return }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = String(
            format: NSLocalizedString("Review — %@", comment: "review window title"),
            task.title)
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 640, height: 420)

        let view = TaskReviewView(
            store: store,
            taskID: taskID,
            accentHex: context.accentHex(task.profileID),
            workspaceName: context.workspaceName(task.profileID),
            fetchReview: context.fetchReview,
            onOpenTerminal: { [weak self] in
                guard let t = self?.context.store()?.task(taskID) else { return }
                self?.context.openTerminal(t)
            },
            onAddComment: { [weak self] text, file in
                self?.context.addComment(taskID, text, file)
            },
            onSendBack: { [weak self] in
                self?.context.sendBack(taskID)
                self?.close(taskID)
            },
            fetchBranches: context.fetchBranches,
            onMerge: { [weak self] target, squash in
                self?.context.merge(taskID, target, squash)
                self?.close(taskID)
            },
            onOpenPR: { [weak self] in
                self?.context.openPR(taskID)
                self?.close(taskID)
            })
        win.contentView = NSHostingView(rootView: view)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windows[taskID] = nil }
        }
        windows[taskID] = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close(_ taskID: UUID) {
        windows[taskID]?.close()
        windows[taskID] = nil
    }
}

// MARK: - Review view

private struct TaskReviewView: View {
    var store: CodingTaskStore
    let taskID: UUID
    let accentHex: String
    let workspaceName: String
    let fetchReview: (CodingTask) async -> TaskReviewData?
    let onOpenTerminal: () -> Void
    let onAddComment: (_ text: String, _ file: String?) -> Void
    let onSendBack: () -> Void
    let fetchBranches: (CodingTask) async -> [String]
    let onMerge: (_ target: String?, _ squash: Bool) -> Void
    let onOpenPR: () -> Void

    @State private var data: TaskReviewData?
    @State private var loadFailed = false
    @State private var draftComment = ""
    /// File path the draft comment is scoped to (via a file header's
    /// comment button); nil = about the whole change.
    @State private var draftFile: String?
    /// Repo branches for the "Merge into…" picker (loaded with the diff).
    @State private var branches: [String] = []

    private var task: CodingTask? { store.task(taskID) }

    private var unsentCount: Int {
        task?.comments.filter { $0.sentAt == nil }.count ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            commentsBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await load() }
    }

    private func load() async {
        guard let task else { return }
        data = nil; loadFailed = false
        if let fetched = await fetchReview(task) { data = fetched }
        else { loadFailed = true }
        branches = await fetchBranches(task)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: accentHex))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(task?.title ?? "")
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let branch = task?.branch {
                        Text(branch)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let parent = task?.parentBranch {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(parent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !workspaceName.isEmpty {
                        Text("· " + workspaceName)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await load() }
            } label: { Image(systemName: "arrow.clockwise") }
                .help(NSLocalizedString("Refresh the diff", comment: ""))
            Button(NSLocalizedString("Open Terminal", comment: "review"),
                   action: onOpenTerminal)
            Button(NSLocalizedString("Send Back to In Progress", comment: "review"),
                   action: onSendBack)
                .disabled(unsentCount == 0)
                .help(unsentCount == 0
                      ? NSLocalizedString("Add review comments first", comment: "")
                      : String(format: NSLocalizedString(
                          "Send %d comment(s) to the agent and continue the task",
                          comment: ""), unsentCount))
            mergeMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    /// The ways out of review: plain or squash merge into the parent, a
    /// pull request, or a merge into any other branch of the repo.
    private var mergeMenu: some View {
        let parent = task?.parentBranch ?? "parent"
        return Menu {
            Button {
                onMerge(nil, false)
            } label: {
                Label(String(format: NSLocalizedString("Merge into %@", comment: "review"),
                             parent),
                      systemImage: "arrow.triangle.merge")
            }
            Button {
                onMerge(nil, true)
            } label: {
                Label(String(format: NSLocalizedString("Squash & Merge into %@",
                                                       comment: "review"), parent),
                      systemImage: "arrow.triangle.merge")
            }
            Divider()
            Button {
                onOpenPR()
            } label: {
                Label(NSLocalizedString("Create Pull Request…", comment: "review"),
                      systemImage: "arrow.up.forward.square")
            }
            let others = branches.filter { $0 != task?.branch && $0 != parent }
            if !others.isEmpty {
                Divider()
                Menu(NSLocalizedString("Merge into…", comment: "review")) {
                    ForEach(others.prefix(30), id: \.self) { branch in
                        Button(branch) { onMerge(branch, false) }
                    }
                }
            }
        } label: {
            Label(String(format: NSLocalizedString("Merge into %@", comment: "review"),
                         parent),
                  systemImage: "arrow.triangle.merge")
        } primaryAction: {
            onMerge(nil, false)
        }
        .fixedSize()
        .help(NSLocalizedString(
            "Click to merge into the parent; hold for squash, pull-request, and other-branch options.",
            comment: "review"))
    }

    // MARK: Diff content

    @ViewBuilder
    private var content: some View {
        if let data {
            if data.files.isEmpty && data.logLines.isEmpty && data.statusLines.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("No changes yet", comment: "review"),
                    systemImage: "doc.badge.ellipsis",
                    description: Text(NSLocalizedString(
                        "The branch has no commits or edits against its parent.",
                        comment: "review")))
            } else {
                diffScroll(data)
            }
        } else if loadFailed {
            ContentUnavailableView(
                NSLocalizedString("Can't reach the workspace", comment: "review"),
                systemImage: "bolt.horizontal.circle",
                description: Text(NSLocalizedString(
                    "The diff is read live from the VM — start the workspace and refresh.",
                    comment: "review")))
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Reading the diff from the VM…", comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func diffScroll(_ data: TaskReviewData) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let plan = task?.plan, !plan.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(NSLocalizedString("Plan", comment: "review"),
                              systemImage: "list.bullet.clipboard")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.purple)
                        MarkdownBlocks(text: plan, compact: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.purple.opacity(0.06)))
                    }
                }
                if !data.logLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(String(format: NSLocalizedString("%d commit(s)", comment: ""),
                                     data.logLines.count),
                              systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(data.logLines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // Untracked/dirty files the diff can't show — surfaced so
                // "the agent forgot to commit" is visible at review time.
                let dirty = data.statusLines.filter { $0.hasPrefix("??") }
                if !dirty.isEmpty {
                    Label(String(format: NSLocalizedString(
                        "%d untracked file(s) not in the diff — the agent may not have committed everything",
                        comment: ""), dirty.count),
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                ForEach(data.files) { file in
                    DiffFileView(file: file) {
                        draftFile = file.path
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Comments

    private var commentsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let comments = task?.comments, !comments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(comments) { c in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: c.sentAt == nil
                                      ? "bubble.left.fill" : "checkmark.bubble")
                                    .font(.system(size: 10))
                                    .foregroundStyle(c.sentAt == nil ? .purple : .secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    if let file = c.file {
                                        Text(file)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(c.text)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(c.sentAt == nil ? .primary : .secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                                Text(c.sentAt == nil
                                     ? NSLocalizedString("draft", comment: "review comment")
                                     : NSLocalizedString("sent", comment: "review comment"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
            HStack(spacing: 8) {
                if let draftFile {
                    HStack(spacing: 3) {
                        Text(draftFile)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                        Button {
                            self.draftFile = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
                }
                TextField(NSLocalizedString(
                    "Add a review comment — sent to the agent with “Send Back”",
                    comment: ""), text: $draftComment, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addComment)
                Button(NSLocalizedString("Add", comment: "review comment"),
                       action: addComment)
                    .disabled(draftComment.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func addComment() {
        let text = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, task != nil else { return }
        onAddComment(text, draftFile)
        draftComment = ""
        draftFile = nil
    }
}

// MARK: - Diff file view

private struct DiffFileView: View {
    let file: TaskDiffFile
    let onComment: () -> Void

    @State private var expanded = true
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
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 0.5)
                            .background(background(for: line.kind))
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
