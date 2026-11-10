import Foundation

// Policy steering on a Linux server (macOS: PolicySteeringDelivery.swift):
// an agent told, in its own session, that the workspace's policy refused
// what it tried, so it asks instead of routing around the block. Claude
// reads a note file its hook claims from the meta share (PolicyNotes); the
// other agents get the note typed into their tab once their turn is over.
extension Daemon {
    // @port ACAppDelegate.wirePolicySteering(_: MitmEngine) h=9911fe1a443d03d2 @a32a5505
    func wirePolicySteering() {
        guard let mitm else { return }
        let steering = PolicySteering.shared
        let modes = OpenShellAdvisorModeCache.shared
        steering.enabledProvider = { modes.tellsAgentOnDeny($0) }
        steering.openShellProvider = { [weak mitm] in mitm?.guardrailsConfig(for: $0)?.egressPolicy?.openShell }
        steering.advisorOnProvider = { modes.mode(for: $0) != .off }
        steering.deliver = { pid, window, text, soleOnly, done in
            Task { @MainActor in
                guard let host = LinuxSessionHost.shared else { done(false); return }
                done(await host.deliverPolicyNote(profileID: pid, window: window, text: text, soleOnly: soleOnly))
            }
        }
    }
}

extension LinuxSessionHost {
    /// True once the note reached a tab: a Claude note file is in place (its
    /// hook reads it), or a typed note is queued.
    // partial: no pid attribution yet (a denied flow names its process only through the kernel sentry, held off by the sandbox guard): a note goes to every agent tab, or to the sole one
    // @port ACAppDelegate.deliverPolicyNote(profileID: UUID, window: Int?, text: String, soleOnly: Bool) h=3cc12d2d4fe6b0ec @a32a5505
    // partial: calls shared PolicyNotes.drop inline
    // @port ACAppDelegate.static dropPolicyNote(in: URL, window: Int, text: String, now: Date) h=9d945777bf1ae425 @a32a5505
    // partial: calls shared PolicyNotes.typedWindows inline
    // @port ACAppDelegate.static typedNoteWindows(targets: [(window:Int,tool:Profile.Tool)], attributed: Bool) h=22c98ce234c8f999 @a32a5505
    // partial: writes into the VM meta dir inline, sequentially
    // @port ACAppDelegate.writePolicyNote(profileID: UUID, window: Int, text: String) h=5b6b975092e9090f @a32a5505
    @MainActor @discardableResult
    func deliverPolicyNote(profileID: UUID, window: Int?, text: String, soleOnly: Bool) async -> Bool {
        // This server's VMs only (an attached machine runs its own policy).
        guard Self.running.withLockedValue({ $0.contains(profileID) }),
              let store = SessionStores.shared?.sessions else { return false }
        let live = store.sessions.filter {
            $0.profileID == profileID && $0.windowIndex != nil && !$0.isDeleted && !$0.isArchived
                && !$0.hasEnded && $0.agentAlive != false
        }
        var targets: [(window: Int, tool: Profile.Tool)]
        if let window {
            targets = [(window, live.first { $0.windowIndex == window }?.tool ?? .claude)]
        } else {
            targets = live.compactMap { s in s.windowIndex.map { ($0, s.tool) } }
            for w in PolicySteering.shared.agentWindows(profileID: profileID).sorted()
            where !targets.contains(where: { $0.window == w }) {
                targets.append((w, .claude))
            }
            if soleOnly && targets.count != 1 { return false }
        }
        PolicySteering.log("deliver to \(targets.isEmpty ? "no agent tab" : targets.map { "w\($0.window) (\($0.tool.rawValue))" }.joined(separator: ", "))")
        var delivered = false
        // Claude's notes first: the sooner the file is in place, the likelier
        // the blocked tool's own PostToolUse hook reads it.
        let meta = URL(fileURLWithPath: stateDir + "/vms/" + profileID.uuidString.lowercased() + "/meta", isDirectory: true)
        for t in targets where t.tool == .claude {
            do {
                try PolicyNotes.drop(in: meta, window: t.window, text: text)
                delivered = true
            } catch {
                PolicySteering.log("note for w\(t.window) not written: \(error)")
            }
        }
        for w in PolicyNotes.typedWindows(targets: targets, attributed: window != nil) {
            queueTypedPolicyNote(profileID: profileID, window: w, text: text)
            delivered = true
        }
        return delivered
    }

    /// Notes owed to non-Claude tabs, typed once the tab's agent is idle.
    @MainActor static var typedPolicyNotes: [String: [String]] = [:]

    // @port ACAppDelegate.queueTypedPolicyNote(profileID: UUID, window: Int, text: String) h=d75d2475f4ec41ef @a32a5505
    @MainActor
    func queueTypedPolicyNote(profileID: UUID, window: Int, text: String) {
        let key = "\(profileID.uuidString)|\(window)"
        let first = Self.typedPolicyNotes[key] == nil
        Self.typedPolicyNotes[key, default: []].append(text)
        guard first else { return }
        Task { @MainActor [weak self] in
            // Wait for the turn to end (up to 15 minutes); typing into a
            // working agent would queue a new prompt behind its turn anyway.
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline {
                let status = self?.tabsModel(for: profileID)?.tabs.first { $0.index == window }?.agentStatus
                if status == nil || status == .done { break }
                try? await Task.sleep(for: .seconds(3))
            }
            let notes = Self.typedPolicyNotes.removeValue(forKey: key) ?? []
            guard let self, let head = notes.first else { return }
            let line = notes.count == 1 ? head
                : head + " (\(notes.count - 1) more action\(notes.count == 2 ? " was" : "s were") blocked the same way.)"
            let target = SessionStores.shared?.sessions.session(profileID: profileID, windowIndex: window)
                .flatMap { AgentSessionEngine.paneTarget($0) } ?? .index(window)
            _ = await CodingTaskEngine.typeWhenFreeResult(self, profileID: profileID, target: target,
                                                          text: line, patience: 300)
        }
    }
}
