import AppKit
import SwiftUI

// The Plan session window: a NATIVE conversation surface onto the running
// planning agent — no terminal required. The body renders the session's
// live Claude transcript (tailed from the guest every couple of seconds,
// through the same parser the run windows use); the footer's input box
// types straight into the agent's session. Phases the agent files via the
// board MCP appear on the board as it works; when the session ends the
// window says so instead of pretending.

@MainActor
final class PlanSessionWindowManager {
    struct Context {
        var store: () -> CodingTaskStore?
        /// The raw live transcript for the task's planning session (tail),
        /// or nil when the workspace is unreachable / no transcript yet.
        var fetchTranscript: (_ task: CodingTask) async -> String?
        /// Type an answer into the live session (Enter included).
        var send: (_ profileID: Profile.ID, _ branch: String, _ text: String) async -> Bool
        /// Send picker keystrokes (AskUserQuestion answers) into the session.
        var sendKeys: (_ profileID: Profile.ID, _ branch: String, _ keys: [String]) async -> Bool
        /// Escape hatch: the raw terminal tab, for power users.
        var openTerminal: (CodingTask) -> Void
        var accentHex: (Profile.ID) -> String
        var workspaceName: (Profile.ID) -> String
        /// The live wt/ branch for a task's slug (nil = session gone).
        var liveBranch: (CodingTask) -> String?
    }

    private let context: Context
    private var windows: [UUID: NSWindow] = [:]
    private var models: [UUID: PlanSessionModel] = [:]
    private var pollers: [UUID: Task<Void, Never>] = [:]

    init(context: Context) {
        self.context = context
    }

    /// The open window for a task, if any — the E2E ui-shot hook renders it.
    func window(for taskID: UUID) -> NSWindow? { windows[taskID] }

    func open(taskID: UUID) {
        if let win = windows[taskID] { win.makeKeyAndOrderFront(nil); return }
        guard let store = context.store(), let task = store.task(taskID) else { return }

        let model = PlanSessionModel(
            taskID: taskID,
            title: task.title,
            workspaceName: context.workspaceName(task.profileID),
            accentHex: context.accentHex(task.profileID))
        models[taskID] = model

        let view = PlanSessionView(
            model: model,
            store: store,
            onSend: { [weak self] text in
                guard let self, let t = self.context.store()?.task(taskID),
                      let branch = self.context.liveBranch(t) else { return false }
                return await self.context.send(t.profileID, branch, text)
            },
            onSendKeys: { [weak self] keys in
                guard let self, let t = self.context.store()?.task(taskID),
                      let branch = self.context.liveBranch(t) else { return false }
                return await self.context.sendKeys(t.profileID, branch, keys)
            },
            onOpenTerminal: { [weak self] in
                guard let t = self?.context.store()?.task(taskID) else { return }
                self?.context.openTerminal(t)
            })

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = String(format: NSLocalizedString("Planning — %@", comment: "plan window"),
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
            Task { @MainActor in self?.reap(taskID) }
        }
        windows[taskID] = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        pollers[taskID] = Task { [weak self] in
            await self?.poll(taskID)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.poll(taskID)
            }
        }
    }

    private func reap(_ taskID: UUID) {
        pollers[taskID]?.cancel()
        pollers[taskID] = nil
        models[taskID] = nil
        windows[taskID] = nil
    }

    private func poll(_ taskID: UUID) async {
        guard let model = models[taskID], let store = context.store(),
              let task = store.task(taskID) else { return }
        // Session phase for the header: planning / phases landed / ended.
        let previous = model.phase
        if let done = task.validatedAt, let req = task.validationRequestedAt,
           done >= req {
            model.phase = .phasesFiled
        } else if !task.validationInFlight {
            model.phase = .ended(task.lastError)
        } else {
            model.phase = context.liveBranch(task) != nil ? .live : .starting
        }
        if previous == .starting, model.phase == .live,
           let win = windows[taskID], win.isVisible, !win.isKeyWindow {
            // The session tab surfacing is exactly when this window used to
            // get buried — put it back on top, once.
            win.makeKeyAndOrderFront(nil)
        }
        guard task.validationRequestedAt != nil else { return }
        if let raw = await context.fetchTranscript(task) {
            let parsed = await Task.detached(priority: .userInitiated) {
                ClaudeTranscriptParser.parse(Data(raw.utf8))
            }.value
            if parsed.count != model.items.count {
                model.items = parsed
                var firstQuestion: Int?
                for item in parsed.reversed() {
                    if case .question = item.kind { firstQuestion = item.id }
                    else { break }
                }
                if firstQuestion != model.answeredBatchFirstID {
                    model.answeredBatchFirstID = firstQuestion
                    model.answeredCount = 0
                }
            }
        }
    }
}

// MARK: - Model + view

@MainActor
@Observable
final class PlanSessionModel {
    enum Phase: Equatable {
        case starting
        case live
        case phasesFiled
        case ended(String?)
    }
    let taskID: UUID
    let title: String
    let workspaceName: String
    let accentHex: String
    var items: [TranscriptItem] = []
    var phase: Phase = .starting
    /// The open question batch (trailing question items): id of its first
    /// item + how many of its questions have been answered from this
    /// window. Gates the cards so answers land on the picker tab that is
    /// actually showing.
    var answeredBatchFirstID: Int?
    var answeredCount = 0

    init(taskID: UUID, title: String, workspaceName: String, accentHex: String) {
        self.taskID = taskID
        self.title = title
        self.workspaceName = workspaceName
        self.accentHex = accentHex
    }
}

private struct PlanSessionView: View {
    @Bindable var model: PlanSessionModel
    var store: CodingTaskStore
    let onSend: (String) async -> Bool
    let onSendKeys: ([String]) async -> Bool
    let onOpenTerminal: () -> Void

    /// The trailing run of question items — the picker currently on screen
    /// in the session. Empty once a tool_result (the answers) lands.
    private var openBatch: [TranscriptItem] {
        var batch: [TranscriptItem] = []
        for item in model.items.reversed() {
            if case .question = item.kind { batch.append(item) } else { break }
        }
        return batch.reversed()
    }

    @State private var draft = ""
    @State private var sending = false
    @State private var sendFailed = false

    private var statusLine: (text: String, tint: Color) {
        switch model.phase {
        case .starting:
            return (NSLocalizedString("starting the planning session…", comment: "plan window"),
                    .secondary)
        case .live:
            return (NSLocalizedString("planning — answers you type here go to the agent",
                                      comment: "plan window"), .blue)
        case .phasesFiled:
            return (NSLocalizedString("phases filed — see the Plan column", comment: "plan window"),
                    .green)
        case .ended(let reason):
            return (reason ?? NSLocalizedString("the session ended", comment: "plan window"),
                    .orange)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: this is a planning conversation, not a terminal.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: model.accentHex))
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.title)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)
                        if !model.workspaceName.isEmpty {
                            Text(model.workspaceName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 5) {
                        if model.phase == .live || model.phase == .starting {
                            ProgressView().controlSize(.mini)
                        }
                        Text(statusLine.text)
                            .font(.system(size: 11))
                            .foregroundStyle(statusLine.tint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button(NSLocalizedString("Open Terminal", comment: "plan window"),
                       action: onOpenTerminal)
                    .help(NSLocalizedString(
                        "The raw session, if you prefer the terminal.", comment: ""))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
            Divider()

            // Live transcript, natively rendered — newest at the bottom.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.items.isEmpty {
                            VStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(NSLocalizedString(
                                    "Waiting for the agent's first words…",
                                    comment: "plan window"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                        let batch = model.phase == .live ? openBatch : []
                        let batchFirst = batch.first?.id
                        ForEach(model.items) { item in
                            if case .question(let q) = item.kind,
                               let first = batchFirst, item.id >= first {
                                let index = item.id - first
                                // Answers must land on the picker tab that's
                                // showing — cards activate strictly in order.
                                let active = index == model.answeredCount
                                TranscriptQuestionCard(
                                    question: q,
                                    isLast: index == batch.count - 1,
                                    sendKeys: active ? { keys in
                                        model.answeredCount += 1
                                        Task { _ = await onSendKeys(keys) }
                                    } : nil)
                            } else {
                                TranscriptItemView(item: item)
                            }
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(16)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.items.count) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("tail", anchor: .bottom)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()

            // The conversation input.
            HStack(spacing: 8) {
                TextField(model.phase == .live
                          ? NSLocalizedString("Answer the agent…", comment: "plan window")
                          : NSLocalizedString("Session not accepting input", comment: "plan window"),
                          text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.phase != .live || sending)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .live || sending
                          || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .overlay(alignment: .topLeading) {
                if sendFailed {
                    Text(NSLocalizedString("Couldn't reach the session — try again.",
                                           comment: "plan window"))
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendFailed = false
        Task {
            let ok = await onSend(text)
            sending = false
            if ok { draft = "" } else { sendFailed = true }
        }
    }
}
