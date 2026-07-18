import AppKit
import SwiftUI

// MARK: - Run detail windows

/// Standalone windows onto individual automation runs — the kanban board's
/// card-click target. One window per run:
///
///   • while the run's tab is alive, a LIVE terminal — a second grouped-tmux
///     attach onto the same guest window (the GridCellView / popOutWorkspace
///     mechanism), fully interactive so a needs-input run can be answered
///     right here;
///   • once the run is over, the saved transcript, rendered natively;
///   • for runs that never launched (skipped / failed / blocked), the
///     outcome details.
///
/// The header brands the window as a run — automation name, workspace,
/// trigger detail, live status — so it never reads as "yet another
/// terminal".
@MainActor
final class AutomationRunWindowManager {
    /// Everything the manager needs from its owner, as closures so this file
    /// works for both the local app delegate and the fat-client mirror.
    struct Context {
        var store: () -> ScheduledAutomationStore?
        var profile: (Profile.ID) -> Profile?
        var tabsModel: (Profile.ID) -> TabsModel?
        var accentHex: (Profile.ID) -> String
        /// Fat client: the remote host id — terminal attaches go over SSH.
        var remoteHost: UUID? = nil
        /// Resolve the run's transcript to a local file, or nil if none
        /// exists (yet). Local: the archive path. Fat client: fetched over
        /// the tunnel into a cache the first time.
        var transcriptURL: (UUID) async -> URL? = { id in
            AutomationRunArchive.hasTranscript(id)
                ? AutomationRunArchive.transcriptURL(for: id) : nil
        }
    }

    private let context: Context
    private var windows: [UUID: NSWindow] = [:]
    private var terminals: [UUID: TerminalSessionController] = [:]
    private var watchers: [UUID: Task<Void, Never>] = [:]
    private var models: [UUID: RunWindowModel] = [:]
    /// What each window's body currently shows, to remount only on change.
    private var mountedModes: [UUID: Mode] = [:]
    /// The AppKit slot the live terminal surface mounts into (below the
    /// SwiftUI header — a libghostty surface can't live inside SwiftUI).
    private var terminalSlots: [UUID: NSView] = [:]

    init(context: Context) {
        self.context = context
    }

    /// The open window for a run, if any — the E2E ui-shot hook renders it.
    func window(for runID: UUID) -> NSWindow? { windows[runID] }

    func open(run: AutomationRunRecord) {
        if let win = windows[run.id] { win.makeKeyAndOrderFront(nil); return }
        guard let store = context.store() else { return }
        let automation = store.automation(run.automationID)
        let profileID = run.runProfileID ?? automation?.profileID

        let model = RunWindowModel(
            run: run,
            automationName: automation.map {
                $0.name.isEmpty
                    ? NSLocalizedString("Untitled automation", comment: "") : $0.name
            } ?? NSLocalizedString("Deleted automation", comment: "run window"),
            workspaceName: profileID.flatMap { context.profile($0)?.name } ?? "",
            accentHex: profileID.map(context.accentHex) ?? "#888888")
        models[run.id] = model

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = String(
            format: NSLocalizedString("%@ — run %@", comment: "run window title"),
            model.automationName,
            run.firedAt.formatted(date: .abbreviated, time: .shortened))
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 360)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = NSHostingView(rootView: RunWindowHeader(model: model))
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.wantsLayer = true
        content.addSubview(slot)
        terminalSlots[run.id] = slot

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            slot.topAnchor.constraint(equalTo: header.bottomAnchor),
            slot.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            slot.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            slot.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        win.contentView = content

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reap(run.id) }
        }

        windows[run.id] = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Re-evaluate every 2 s: the tab dying, completion being stamped, or
        // the transcript landing all flip the window's mode.
        watchers[run.id] = Task { [weak self] in
            await self?.refresh(run.id)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.refresh(run.id)
            }
        }
    }

    private func reap(_ runID: UUID) {
        watchers[runID]?.cancel()
        watchers[runID] = nil
        terminals[runID]?.retireAll()
        terminals[runID] = nil
        terminalSlots[runID] = nil
        mountedModes[runID] = nil
        models[runID] = nil
        windows[runID] = nil
    }

    // MARK: Mode resolution

    /// What the body of the window should show right now.
    private enum Mode: Equatable {
        case terminal(profileID: Profile.ID, windowIndex: Int)
        case transcript(URL)
        case outcome
    }

    private func currentMode(for model: RunWindowModel, transcript: URL?) -> Mode {
        let run = model.run
        // Live tab? (launched runs only — and prefer the transcript once the
        // run is stamped done and the transcript is on disk.)
        if run.outcome == .launched, let slug = run.branchSlug,
           let profileID = run.runProfileID
               ?? context.store()?.automation(run.automationID)?.profileID,
           let tabs = context.tabsModel(profileID)?.tabs,
           let tab = tabs.first(where: {
               AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
           }) {
            model.agentStatus = tab.agentStatus
            if run.completedAt == nil || transcript == nil {
                return .terminal(profileID: profileID, windowIndex: tab.index)
            }
        } else {
            model.agentStatus = nil
        }
        return transcript != nil ? .transcript(transcript!) : .outcome
    }

    /// Re-read the run from the store (completedAt/acknowledgedAt move under
    /// us) and remount the body if the mode changed.
    private func refresh(_ runID: UUID) async {
        guard models[runID] != nil else { return }
        let transcript = await context.transcriptURL(runID)
        guard let model = models[runID], let slot = terminalSlots[runID] else { return }
        if let fresh = context.store()?.runs.first(where: { $0.id == runID }) {
            model.run = fresh
        }
        let mode = currentMode(for: model, transcript: transcript)
        guard mode != mountedModes[runID] else { return }
        mountedModes[runID] = mode

        slot.subviews.forEach { $0.removeFromSuperview() }
        terminals[runID]?.retireAll()
        terminals[runID] = nil

        switch mode {
        case .terminal(let profileID, let windowIndex):
            guard let profile = context.profile(profileID) else { return }
            let ctl = TerminalSessionController(profile: profile,
                                                remoteHost: context.remoteHost)
            terminals[runID] = ctl
            guard let view = ctl.view(forWindow: windowIndex) else { return }
            slot.layer?.backgroundColor = NSColor.black.cgColor
            mount(view, in: slot)
            windows[runID]?.makeFirstResponder(view)
        case .transcript(let url):
            slot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let host = NSHostingView(rootView: ClaudeTranscriptPane(url: url))
            mount(host, in: slot)
        case .outcome:
            slot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let host = NSHostingView(rootView: RunOutcomeView(model: model))
            mount(host, in: slot)
        }
    }

    private func mount(_ view: NSView, in slot: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: slot.topAnchor),
            view.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
        ])
    }
}

// MARK: - Window model + header

/// Shared state between the manager's poll loop and the SwiftUI header.
@MainActor
@Observable
final class RunWindowModel {
    var run: AutomationRunRecord
    let automationName: String
    let workspaceName: String
    let accentHex: String
    /// Live agent status while a terminal is mounted; nil once the tab is gone.
    var agentStatus: AgentStatus?

    init(run: AutomationRunRecord, automationName: String,
         workspaceName: String, accentHex: String) {
        self.run = run
        self.automationName = automationName
        self.workspaceName = workspaceName
        self.accentHex = accentHex
    }
}

/// The strip that makes this window read as "an automation run", not a
/// terminal: accent-colored identity, run detail, live status.
private struct RunWindowHeader: View {
    @Bindable var model: RunWindowModel

    private var statusText: String {
        if let status = model.agentStatus {
            switch status {
            case .working:    return NSLocalizedString("Agent working…", comment: "run window")
            case .needsInput: return NSLocalizedString("Agent needs your input — answer below", comment: "run window")
            case .done:       return NSLocalizedString("Agent finished", comment: "run window")
            }
        }
        if let completed = model.run.completedAt {
            return String(format: NSLocalizedString("Finished %@", comment: "run window"),
                          completed.formatted(date: .abbreviated, time: .shortened))
        }
        switch model.run.outcome {
        case .launched: return NSLocalizedString("Run ended", comment: "run window")
        case .skipped:  return NSLocalizedString("Run skipped", comment: "run window")
        case .failed:   return NSLocalizedString("Run failed", comment: "run window")
        case .blocked:  return NSLocalizedString("Run blocked", comment: "run window")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: model.accentHex))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(model.automationName)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    if !model.workspaceName.isEmpty {
                        Text(model.workspaceName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if let status = model.agentStatus {
                        AgentStatusDot(status: status)
                    } else {
                        Image(systemName: model.run.outcome.glyph)
                            .font(.system(size: 10))
                            .foregroundStyle(model.run.outcome.tint)
                    }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(model.agentStatus == .needsInput
                                         ? .red : .secondary)
                    if !model.run.detail.isEmpty,
                       model.run.detail != model.run.branchSlug {
                        Text("· " + model.run.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(String(format: NSLocalizedString("fired %@", comment: "run window"),
                        model.run.firedAt.formatted(date: .abbreviated, time: .shortened)))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Body for runs with nothing to attach and no transcript: the outcome, in
/// words, with what to do about it.
private struct RunOutcomeView: View {
    @Bindable var model: RunWindowModel

    private var explanation: String {
        switch model.run.outcome {
        case .launched:
            return NSLocalizedString(
                "The run's session is gone and no transcript was captured — the workspace may have stopped before the agent finished.",
                comment: "run window")
        case .skipped:
            return NSLocalizedString(
                "This fire was skipped — nothing ran.", comment: "run window")
        case .failed:
            return NSLocalizedString(
                "The run never launched.", comment: "run window")
        case .blocked:
            return NSLocalizedString(
                "The prompt-injection screen refused this item's text — no agent saw it.",
                comment: "run window")
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.run.outcome.glyph)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(model.run.outcome.tint)
            Text(model.run.detail.isEmpty ? explanation : model.run.detail)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
            if !model.run.detail.isEmpty {
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
