import Foundation

/// Where `PolicySteering`'s notes go. Claude reads them mid-turn: its
/// PostToolUse / UserPromptSubmit / Stop hook (`agent-status.sh policy`)
/// claims the files in `policy-notes/` of the read-only meta share
/// (`/mnt/bromure-meta`) and hands their text to the model, right after the
/// tool call that hit the block. The other agents' hooks only report status,
/// so their note is typed into the tab as one line once the agent's turn is
/// over.
///
/// The notes live where only the host can write: a Stop note becomes the
/// instruction that keeps the turn going, and any guest process (every tab is
/// the same `ubuntu` user, and it has sudo outside the strict sandbox) could
/// plant one in a guest directory. (Finding CWE-345, "Any guest process can
/// plant a policy note that blocks Stop".)
extension ACAppDelegate {
    /// The notes' folder in the meta share (host side) and as the guest sees it.
    nonisolated static let policyNotesShareDir = "policy-notes"
    nonisolated static let guestPolicyNotesDir = "/mnt/bromure-meta/policy-notes"
    /// A note nobody's hook took within this long is dropped on the next write
    /// (a closed tab's index gets reused).
    nonisolated static let policyNoteLifetime: TimeInterval = 3600

    func wirePolicySteering(_ engine: MitmEngine) {
        let steering = PolicySteering.shared
        let modes = OpenShellAdvisorModeCache.shared
        steering.enabledProvider = { modes.tellsAgentOnDeny($0) }
        steering.openShellProvider = { [weak engine] in engine?.guardrailsConfig(for: $0)?.egressPolicy?.openShell }
        steering.advisorOnProvider = { modes.mode(for: $0) != .off }
        steering.deliver = { [weak self] pid, window, text, soleOnly, done in
            Task { @MainActor in
                guard let self else { done(false); return }
                done(await self.deliverPolicyNote(profileID: pid, window: window, text: text, soleOnly: soleOnly))
            }
        }
    }

    /// The windows of the agent tabs the host itself opened in a workspace
    /// (bound by its own launch, `AgentSessionStore.hostLaunchedTabs`): the
    /// ones `PolicySteering.noteAgent` keeps a slot for, whatever the guest
    /// wrote. Not a session adopted from the guest roster: any guest process
    /// can open a tmux window labelled as an agent (Finding CWE-807,
    /// "Guest-adopted tmux windows are spared from pid-pin eviction, so a
    /// guest can still fill every slot").
    @MainActor
    func hostAgentWindows(profileID: UUID) -> Set<Int> {
        agentSessionStore.hostLaunchedWindows(profileID: profileID)
    }

    /// True once the note reached a tab: a Claude note file is in place (its
    /// hook reads it), or a typed note is queued.
    @MainActor @discardableResult
    func deliverPolicyNote(profileID: UUID, window: Int?, text: String, soleOnly: Bool) async -> Bool {
        // This Mac's VMs only (an attached Sidecar runs its own policy).
        guard runningSessions[profileID] != nil else { return false }
        let live = agentSessionStore.sessions.filter {
            $0.profileID == profileID && $0.windowIndex != nil && !$0.isDeleted && !$0.isArchived
                && !$0.hasEnded && $0.agentAlive != false
        }
        var targets: [(window: Int, tool: Profile.Tool)]
        if let window {
            // A tab no session owns (an agent started from the shell) whose
            // agent's hook named it: Claude is the one that reports a pid.
            targets = [(window, live.first { $0.windowIndex == window }?.tool ?? .claude)]
        } else {
            targets = live.compactMap { s in s.windowIndex.map { ($0, s.tool) } }
            // An agent the app doesn't list as a session still reported its
            // tab through its hooks (Claude's are the ones that do).
            for w in PolicySteering.shared.agentWindows(profileID: profileID).sorted()
            where !targets.contains(where: { $0.window == w }) {
                targets.append((w, .claude))
            }
            if soleOnly && targets.count != 1 { return false }
        }
        PolicySteering.log("deliver to \(targets.isEmpty ? "no agent tab" : targets.map { "w\($0.window) (\($0.tool.rawValue))" }.joined(separator: ", "))")
        var delivered = false
        // Claude's notes first, written in parallel and awaited: the sooner
        // the file is in place, the likelier the blocked tool's own
        // PostToolUse hook reads it (else its Stop hook does).
        await withTaskGroup(of: Bool.self) { group in
            for t in targets where t.tool == .claude {
                group.addTask { @MainActor in await self.writePolicyNote(profileID: profileID, window: t.window, text: text) }
            }
            for await ok in group where ok { delivered = true }
        }
        for w in Self.typedNoteWindows(targets: targets, attributed: window != nil) {
            queueTypedPolicyNote(profileID: profileID, window: w, text: text)
            delivered = true
        }
        return delivered
    }

    /// The non-Claude tabs a note is typed into (as the user's message — the
    /// only way those agents learn of a block). Never broadcast into every
    /// agent's composer: the tab whose process was blocked (`attributed`),
    /// else the only non-Claude agent there is — an L7, guardrails or
    /// unattributed sandbox block has no tab of its own, and that agent was
    /// told nothing (Finding CWE-670, "Unattributed policy notes are never
    /// typed into a non-Claude tab").
    static func typedNoteWindows(targets: [(window: Int, tool: Profile.Tool)], attributed: Bool) -> [Int] {
        let others = targets.filter { $0.tool != .claude }.map(\.window)
        return attributed || others.count == 1 ? others : []
    }

    /// One file per note, moved into place whole, so the hook never reads
    /// half of one.
    @MainActor
    private func writePolicyNote(profileID: UUID, window: Int, text: String) async -> Bool {
        guard let meta = runningSessions[profileID]?.sandbox.sessionDisk?.metadataDirectory else {
            PolicySteering.log("note for w\(window) not written: no meta share")
            return false
        }
        do {
            try Self.dropPolicyNote(in: meta, window: window, text: text)
            return true
        } catch {
            PolicySteering.log("note for w\(window) not written: \(error)")
            return false
        }
    }

    /// Write `text` as window `window`'s next note under `meta`'s notes
    /// folder, and drop the notes older than `policyNoteLifetime`.
    @discardableResult
    nonisolated static func dropPolicyNote(in meta: URL, window: Int, text: String, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let dir = meta.appendingPathComponent(policyNotesShareDir, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".note") {
            let f = dir.appendingPathComponent(name)
            if let at = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(at) > policyNoteLifetime {
                try? fm.removeItem(at: f)
            }
        }
        let stamp = UInt64(now.timeIntervalSince1970 * 1_000_000_000)
        let name = "w\(window)-\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).note"
        let tmp = dir.appendingPathComponent(".\(name).tmp")
        try Data((text + "\n").utf8).write(to: tmp)
        let dest = dir.appendingPathComponent(name)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Notes owed to non-Claude tabs, typed once the tab's agent is idle.
    private static var typedNotes: [String: [String]] = [:]

    @MainActor
    private func queueTypedPolicyNote(profileID: UUID, window: Int, text: String) {
        let key = "\(profileID.uuidString)|\(window)"
        let first = Self.typedNotes[key] == nil
        Self.typedNotes[key, default: []].append(text)
        guard first else { return }
        Task { @MainActor [weak self] in
            // Wait for the turn to end (up to 15 minutes); typing into a
            // working agent would queue a new prompt behind its turn anyway.
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline {
                let status = self?.pane(for: profileID)?.model.tabs.first { $0.index == window }?.agentStatus
                if status == nil || status == .done { break }
                try? await Task.sleep(for: .seconds(3))
            }
            let notes = Self.typedNotes.removeValue(forKey: key) ?? []
            guard let self, let head = notes.first else { return }
            let line = notes.count == 1 ? head
                : head + " (\(notes.count - 1) more action\(notes.count == 2 ? " was" : "s were") blocked the same way.)"
            let target = self.agentSessionStore.session(profileID: profileID, windowIndex: window)
                .flatMap { AgentSessionEngine.paneTarget($0) } ?? .index(window)
            _ = await CodingTaskEngine.typeWhenFreeResult(self, profileID: profileID, target: target,
                                                          text: line, patience: 300)
        }
    }
}
