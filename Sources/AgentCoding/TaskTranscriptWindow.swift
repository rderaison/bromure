import AppKit
import SwiftUI

// A finished task's full session transcript, rendered natively long after
// the tab closed and the worktree merged away. The transcript lives in the
// workspace's PERSISTENT home (~/.claude/projects/…), so nothing is
// archived host-side — the window fetches it from the guest on demand,
// which just requires the workspace to be running.

@MainActor
final class TaskTranscriptWindowManager {
    struct Context {
        var store: () -> CodingTaskStore?
        /// The raw transcript for the task's branch, or nil when the
        /// workspace is unreachable / no transcript exists.
        var fetch: (_ task: CodingTask) async -> String?
        var workspaceName: (Profile.ID) -> String
        var accentHex: (Profile.ID) -> String
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

        let view = TaskTranscriptView(
            title: task.title,
            workspaceName: context.workspaceName(task.profileID),
            accentHex: context.accentHex(task.profileID),
            fetch: { [weak self] in
                guard let self, let t = self.context.store()?.task(taskID)
                else { return nil }
                return await self.context.fetch(t)
            })

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = String(format: NSLocalizedString("Transcript — %@",
                                                     comment: "task transcript"),
                           task.title)
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 400)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        win.contentView = host

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windows[taskID] = nil }
        }
        windows[taskID] = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TaskTranscriptView: View {
    let title: String
    let workspaceName: String
    let accentHex: String
    let fetch: () async -> String?

    private enum State {
        case loading
        case loaded([TranscriptItem])
        case unavailable
    }
    @SwiftUI.State private var state: State = .loading

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: accentHex))
                    .frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Text(workspaceName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
            Divider()

            switch state {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(NSLocalizedString("Reading the transcript…",
                                           comment: "task transcript"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                ContentUnavailableView(
                    NSLocalizedString("Transcript unavailable", comment: "task transcript"),
                    systemImage: "doc.questionmark",
                    description: Text(NSLocalizedString(
                        "No transcript was found for this task in the workspace's home.",
                        comment: "task transcript")))
            case .loaded(let items):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { TranscriptItemView(item: $0) }
                    }
                    .padding(16)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .task {
            guard let raw = await fetch(), !raw.isEmpty else {
                state = .unavailable
                return
            }
            let parsed = await Task.detached(priority: .userInitiated) {
                ClaudeTranscriptParser.parse(Data(raw.utf8))
            }.value
            state = parsed.isEmpty ? .unavailable : .loaded(parsed)
        }
    }
}
