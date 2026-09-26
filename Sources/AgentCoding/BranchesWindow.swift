#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Branches on a machine
//
// Every git worktree Bromure made on a machine (~/.bromure/worktrees), with
// what it holds and whose it is: a branch whose session is gone, archived
// or merged is easy to lose track of — here it can be picked up in a
// session again, reviewed, or thrown away.

@MainActor
final class BranchesWindowManager {
    struct Context {
        var machineName: (UUID) -> String
        var list: (UUID) async -> [WorktreeEntry]?
        var sessions: () -> [AgentSession]
        /// Pick the branch up in a new session (its agent, in its checkout).
        var openSession: (UUID, WorktreeEntry, Profile.Tool) -> Void
        var selectSession: (UUID) -> Void
        var review: (UUID) -> Void
        /// Remove the checkout and the branch (and the session, if any).
        var discard: (UUID, WorktreeEntry, AgentSession?) -> Void
        var defaultTool: (UUID) -> Profile.Tool
    }

    private let context: Context
    private var windows: [UUID: NSWindow] = [:]

    init(context: Context) { self.context = context }

    func window(for profileID: UUID) -> NSWindow? { windows[profileID] }

    func open(profileID: UUID) {
        if let win = windows[profileID] { win.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = String(format: NSLocalizedString("Branches on %@", comment: "branches window title"),
                           context.machineName(profileID))
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 620, height: 360)
        win.tabbingMode = .disallowed
        win.contentView = NSHostingView(rootView: BranchesView(profileID: profileID, context: context, window: win))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows[profileID] = nil }
        }
        windows[profileID] = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct BranchesView: View {
    let profileID: UUID
    let context: BranchesWindowManager.Context
    weak var window: NSWindow?

    @State private var entries: [WorktreeEntry]?
    @State private var failed = false
    @State private var onlyLoose = false

    /// Whose the branch is: a session (running or paused — it picks the work
    /// up when resumed), an archived one, or nobody's.
    private enum Owner { case live(AgentSession), archived(AgentSession), none }

    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func owner(_ e: WorktreeEntry) -> Owner {
        guard let s = e.session(in: context.sessions(), profileID: profileID) else { return .none }
        return s.isArchived ? .archived(s) : .live(s)
    }

    /// No session looking after it (none, or only an archived one).
    private func isLoose(_ e: WorktreeEntry) -> Bool {
        if case .live = owner(e) { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color.platformWindowBackground)
        .task { await load() }
    }

    private func load() async {
        failed = false
        if let got = await context.list(profileID) {
            entries = got.sorted {
                let (a, b) = (isLoose($0), isLoose($1))
                if a != b { return a }
                return ($0.lastCommit ?? .distantPast) > ($1.lastCommit ?? .distantPast)
            }
        } else {
            entries = nil
            failed = true
        }
    }

    private var header: some View {
        let all = entries ?? []
        let loose = all.filter(isLoose)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("Branches on %@", comment: "branches window title"),
                            context.machineName(profileID)))
                    .font(.system(size: 14, weight: .bold))
                Text(entries == nil ? " " : all.isEmpty
                     ? NSLocalizedString("No branches", comment: "branches")
                     : String(format: NSLocalizedString("%d branches · %d left behind", comment: "branches"),
                              all.count, loose.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(NSLocalizedString("Only without a session", comment: "branches"), isOn: $onlyLoose)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Button {
                Task { await load() }
            } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help(NSLocalizedString("Refresh", comment: "branches"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if let entries {
            let shown = onlyLoose ? entries.filter(isLoose) : entries
            if shown.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("Nothing left behind", comment: "branches"),
                    systemImage: "checkmark.seal",
                    description: Text(entries.isEmpty
                        ? NSLocalizedString("This machine has no branches made by Bromure.", comment: "branches")
                        : NSLocalizedString("Every branch has a session looking after it.", comment: "branches")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { e in row(e) }
                    }
                    .padding(14)
                }
            }
        } else if failed {
            ContentUnavailableView(
                NSLocalizedString("Can't reach the machine", comment: "review"),
                systemImage: "bolt.horizontal.circle",
                description: Text(NSLocalizedString("Branches are read live from the machine — start it and refresh.", comment: "branches")))
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ e: WorktreeEntry) -> some View {
        let own = owner(e)
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill((e.isEmpty ? Color.secondary : Color.purple).opacity(0.14))
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(e.isEmpty ? Color.secondary : Color.purple)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.display.isEmpty ? e.branch : e.display)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    switch own {
                    case .live(let s):
                        let running = s.windowIndex != nil && !s.hasEnded
                        tag(running ? NSLocalizedString("In a session", comment: "branches")
                                    : NSLocalizedString("Session paused", comment: "branches"),
                            running ? .green : .secondary, help: s.title)
                    case .archived(let s):
                        tag(s.branchMerge?.phase == .merged ? NSLocalizedString("Merged", comment: "branches")
                                                             : NSLocalizedString("Session archived", comment: "branches"),
                            .orange, help: s.title)
                    case .none:
                        tag(NSLocalizedString("No session", comment: "branches"), .red, help: "")
                    }
                }
                HStack(spacing: 6) {
                    Text(e.branch).font(.system(size: 11, design: .monospaced))
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Text(e.parent).font(.system(size: 11, design: .monospaced))
                    Text("·").foregroundStyle(.tertiary)
                    Text(summary(e))
                    if let t = e.lastCommit {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(format: NSLocalizedString("last commit %@", comment: "branches"),
                                    Self.ago.localizedString(for: t, relativeTo: Date())))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(prettyGuestPath(e.dir))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            switch own {
            case .live(let s):
                Button(NSLocalizedString("Review", comment: "branches")) { context.review(s.id) }
                Button(NSLocalizedString("Show Session", comment: "branches")) { context.selectSession(s.id) }
            case .archived(let s):
                Button(NSLocalizedString("Review", comment: "branches")) { context.review(s.id) }
                Button(NSLocalizedString("Show Session", comment: "branches")) { context.selectSession(s.id) }
            case .none:
                Button(NSLocalizedString("Open in a Session", comment: "branches")) {
                    context.openSession(profileID, e, context.defaultTool(profileID))
                }
            }
            Button(role: .destructive) {
                confirmDiscard(e, own)
            } label: {
                Image(systemName: "trash")
            }
            .help(NSLocalizedString("Discard the branch and its checkout", comment: "branches"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func tag(_ text: String, _ color: Color, help: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
            .help(help)
    }

    private func summary(_ e: WorktreeEntry) -> String {
        if e.isEmpty { return NSLocalizedString("no changes yet", comment: "branch status") }
        var parts: [String] = []
        if e.ahead > 0 {
            parts.append(e.ahead == 1 ? NSLocalizedString("1 commit", comment: "branch status")
                         : String(format: NSLocalizedString("%d commits", comment: "branch status"), e.ahead))
        }
        if e.changed > 0 {
            parts.append(e.changed == 1 ? NSLocalizedString("1 uncommitted file", comment: "branch status")
                         : String(format: NSLocalizedString("%d uncommitted files", comment: "branch status"), e.changed))
        }
        return parts.joined(separator: " · ")
    }

    private func confirmDiscard(_ e: WorktreeEntry, _ own: Owner) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Discard %@?", comment: "branches"), e.branch)
        var info = e.isEmpty
            ? NSLocalizedString("Nothing was done on it, so nothing is lost.", comment: "branches")
            : String(format: NSLocalizedString("Its work (%@) is deleted with the checkout. This can't be undone.", comment: "branches"), summary(e))
        if case .archived(let s) = own {
            info += " " + String(format: NSLocalizedString("The archived session “%@” goes too.", comment: "branches"), s.title)
        }
        alert.informativeText = info
        alert.addButton(withTitle: NSLocalizedString("Discard", comment: "discard branch"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let s: AgentSession? = { switch own { case .live(let s), .archived(let s): return s; case .none: return nil } }()
            context.discard(profileID, e, s)
            entries?.removeAll { $0.id == e.id }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await load()
            }
        }
    }
}
#endif
