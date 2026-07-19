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
        /// Async: a detached session is resolved by asking the guest.
        var liveBranch: (CodingTask) async -> String?
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
                      let branch = await self.context.liveBranch(t) else { return false }
                return await self.context.send(t.profileID, branch, text)
            },
            onSendKeys: { [weak self] keys in
                guard let self, let t = self.context.store()?.task(taskID),
                      let branch = await self.context.liveBranch(t) else { return false }
                return await self.context.sendKeys(t.profileID, branch, keys)
            },
            onOpenTerminal: { [weak self] in
                guard let t = self?.context.store()?.task(taskID) else { return }
                self?.context.openTerminal(t)
            },
            onClose: { [weak self] in
                self?.windows[taskID]?.close()
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
            model.phase = await context.liveBranch(task) != nil ? .live : .starting
        }
        if previous == .starting, model.phase == .live,
           let win = windows[taskID], win.isVisible, !win.isKeyWindow {
            // The session tab surfacing is exactly when this window used to
            // get buried — put it back on top, once.
            win.makeKeyAndOrderFront(nil)
        }
        model.phaseCount = store.tasks.filter { $0.parentTaskID == taskID }.count
        guard task.validationRequestedAt != nil else { return }
        if let raw = await context.fetchTranscript(task) {
            let parsed = await Task.detached(priority: .userInitiated) {
                ClaudeTranscriptParser.parse(Data(raw.utf8))
            }.value
            if parsed.count != model.items.count { model.items = parsed }
        }
    }
}

/// One answered question round, folded: "N questions answered · headers",
/// expandable to the full static cards.
private struct AnsweredQuestionsRow: View {
    let questions: [TranscriptQuestion]
    @State private var expanded = false

    private var summary: String {
        let headers = questions.map { $0.header.isEmpty
            ? String($0.question.prefix(24)) : $0.header }
        return headers.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "checkmark.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)
                    Text(questions.count == 1
                         ? String(format: NSLocalizedString(
                            "1 question answered — %@", comment: "plan window"), summary)
                         : String(format: NSLocalizedString(
                            "%d questions answered — %@", comment: "plan window"),
                            questions.count, summary))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(questions.indices, id: \.self) { i in
                    TranscriptQuestionCard(question: questions[i])
                }
            }
        }
        .padding(.vertical, 2)
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
    /// Phases filed under this task — the completion bar's count.
    var phaseCount = 0

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
    let onClose: () -> Void

    /// The trailing run of question items — the picker currently on screen
    /// in the session. Empty once a tool_result (the answers) lands.
    private var openBatch: [TranscriptItem] {
        var batch: [TranscriptItem] = []
        for item in model.items.reversed() {
            if case .question = item.kind { batch.append(item) } else { break }
        }
        return batch.reversed()
    }

    /// What the transcript area renders: plain items, with ANSWERED
    /// question rounds folded into one collapsed row each — a full stack
    /// of dead question cards buries the conversation.
    private enum Block: Identifiable {
        case item(TranscriptItem)
        case answeredRound([TranscriptQuestion], firstID: Int)
        var id: Int {
            switch self {
            case .item(let i): return i.id
            case .answeredRound(_, let f): return 1_000_000 + f
            }
        }
    }

    private var blocks: [Block] {
        let liveCount = model.phase == .live ? openBatch.count : 0
        var out: [Block] = []
        var round: [TranscriptItem] = []
        func flush() {
            guard let first = round.first else { return }
            let qs = round.compactMap { item -> TranscriptQuestion? in
                if case .question(let q) = item.kind { return q } else { return nil }
            }
            out.append(.answeredRound(qs, firstID: first.id))
            round = []
        }
        for item in model.items.dropLast(liveCount) {
            if case .question = item.kind { round.append(item) }
            else { flush(); out.append(.item(item)) }
        }
        flush()
        return out
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
                        ForEach(blocks) { block in
                            switch block {
                            case .item(let item):
                                TranscriptItemView(item: item)
                            case .answeredRound(let qs, _):
                                AnsweredQuestionsRow(questions: qs)
                            }
                        }
                        if !batch.isEmpty {
                            TranscriptQuestionBatchCard(
                                questions: batch.compactMap {
                                    if case .question(let q) = $0.kind { q }
                                    else { nil }
                                },
                                onSubmit: onSendKeys)
                                // A new batch = fresh local answers.
                                .id(batch.first?.id ?? -1)
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

            // The conversation composer — or, once the plan landed, the
            // completion bar.
            if model.phase == .phasesFiled {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("Plan is ready", comment: "plan window"))
                            .font(.system(size: 15, weight: .bold))
                        Text(model.phaseCount > 0
                             ? String(format: NSLocalizedString(
                                "%d phases are on the board — start them from the Plan column.",
                                comment: "plan window"), model.phaseCount)
                             : NSLocalizedString(
                                "The plan is recorded on the board.",
                                comment: "plan window"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(NSLocalizedString("Close", comment: "plan window"),
                           action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(Color.green.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.green.opacity(0.25)))
                .padding(12)
            } else {
            VStack(alignment: .leading, spacing: 4) {
                if sendFailed {
                    Text(NSLocalizedString("Couldn't reach the session — try again.",
                                           comment: "plan window"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .padding(.leading, 4)
                }
                ChatComposer(
                    placeholder: model.phase == .live
                        ? NSLocalizedString("Answer the agent…", comment: "plan window")
                        : NSLocalizedString("Session not accepting input",
                                            comment: "plan window"),
                    text: $draft,
                    disabled: model.phase != .live,
                    busy: sending,
                    accent: Color(hex: model.accentHex),
                    onSend: send)
            }
            .padding(12)
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
