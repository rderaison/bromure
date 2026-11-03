import Foundation

/// The daemon as the coding-task and scheduled-automation engines' host
/// (macOS: ACAppDelegate, CodingTaskHost+App / AutomationHost+App). guestExec,
/// automationWorktreeCommand, profile(for:), unattendedLaunchRefusal and
/// tabsModel(for:) are the session host's (LinuxSessionHost).
extension LinuxSessionHost: CodingTaskHost, AutomationHost {
    // MARK: The guest

    /// A task's transcript: its archived copy, else the guest's.
    // partial: no offline read of a stopped workspace's home image (macOS's ext4 walker)
    // @port ACAppDelegate.fetchTaskTranscriptRaw(_: CodingTask) h=b4e71a368ec3c7eb @9936e30c
    func fetchTaskTranscriptRaw(_ task: CodingTask) async -> String? {
        if let archived = TaskTranscriptArchive.load(task.id) { return archived }
        guard let branch = task.branch ?? task.branchSlug.map({ "wt/" + $0 }) else { return nil }
        // Kimi: the session's own journal by id, when the task's session
        // learned it — no folder/slug guessing (Kimi cuts bucket names).
        if task.tool == .kimi {
            let slug = String(branch.dropFirst(3))
            if let id = agentSessionStore.sessions.first(where: { s in
                s.profileID == task.profileID
                    && (s.worktreeBranch == branch || (s.cwd as NSString).lastPathComponent == slug)
                    && (s.agentTranscriptID.map(AgentSessionLocator.isKimiSessionID) ?? false)
            })?.agentTranscriptID {
                let cmd = AgentSessionLocator.kimiPinnedFragment(id: id, into: "f")
                    + "if [ -n \"$f\" ]; then head -c 25000000 \"$f\" | iconv -f UTF-8 -t UTF-8 -c; fi"
                if let out = try? await guestExec(profileID: task.profileID, command: cmd, timeout: 30), !out.isEmpty {
                    return out
                }
            }
        }
        if let cmd = CodingTaskEngine.taskTranscriptCommand(branch: branch, agent: task.tool),
           let out = try? await guestExec(profileID: task.profileID, command: cmd, timeout: 30), !out.isEmpty {
            return out
        }
        return nil
    }

    /// Claude's trust dialog, accepted ahead for `dir` in the guest's
    /// ~/.claude.json, so an unattended run doesn't stop on it.
    // @port ACAppDelegate.pretrustGuestPath(profileID: Profile.ID, dir: String) h=5089240f67c94a3d @9936e30c
    func pretrustGuestPath(profileID: Profile.ID, dir rawDir: String) async {
        let dir = rawDir
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let py = """
        import json, os
        p = os.path.expanduser("~/.claude.json")
        try:
            cfg = json.load(open(p)) if os.path.exists(p) else {}
        except Exception:
            cfg = {}
        pr = cfg.setdefault("projects", {})
        e = pr.setdefault(os.path.expanduser("\(dir)"), {})
        if e.get("hasTrustDialogAccepted") is not True:
            e["hasTrustDialogAccepted"] = True
            tmp = p + ".tmp"
            json.dump(cfg, open(tmp, "w"), indent=2)
            os.replace(tmp, p)
        """
        let b64 = Data(py.utf8).base64EncodedString()
        _ = try? await guestExec(profileID: profileID, command: "echo \(b64) | base64 -d | python3 -", timeout: 10)
    }

    /// A Stop-hook "done" held until the session's transcript has been
    /// quiet for `quiet` seconds (background subagents may still write);
    /// an unreadable probe counts as quiet, `cap` bounds the wait. `tool`
    /// picks the agent's transcript store. Whether the probe read the
    /// transcript's age at all: false, nothing was watched.
    // @port ACAppDelegate.waitForSessionQuiet(profileID: Profile.ID, branch: String, tool: Profile.Tool?, quiet: Int, cap: TimeInterval) h=5c4cf5a05ff45dd8 @5f46a841
    @discardableResult
    func waitForSessionQuiet(profileID: Profile.ID, branch: String, tool: Profile.Tool?,
                             quiet: Int, cap: TimeInterval) async -> Bool {
        guard branch.hasPrefix("wt/"),
              let cmd = CodingTaskEngine.transcriptAgeCommand(slug: String(branch.dropFirst(3)), agent: tool)
        else { return false }
        let deadline = Date().addingTimeInterval(cap)
        var held = false, read = false
        while Date() < deadline {
            guard let out = try? await guestExec(profileID: profileID, command: cmd, timeout: 10),
                  let age = Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return read }
            read = true
            if age >= quiet {
                if held { BACDebug.log("session", "\(branch): transcript quiet — completing") }
                return true
            }
            if !held {
                held = true
                BACDebug.log("session", "\(branch): done signaled but the "
                    + "transcript is still active (\(age)s ago) — background "
                    + "agents? holding completion")
            }
            try? await Task.sleep(nanoseconds: UInt64(max(quiet - age, 5)) * 1_000_000_000)
        }
        BACDebug.log("session", "\(branch): settle cap reached — completing anyway")
        return read
    }

    /// A finished run's transcript, copied out of the guest into the run's
    /// archive before its worktree (or clone) goes.
    // @port ACAppDelegate.pullAutomationTranscript(profileID: Profile.ID, branch: String, runID: UUID, tool: Profile.Tool) h=9da9bd06ab914835 @9936e30c
    func pullAutomationTranscript(profileID: Profile.ID, branch: String, runID: UUID, tool: Profile.Tool) async {
        guard let cmd = CodingTaskEngine.taskTranscriptCommand(branch: branch, agent: tool) else { return }
        do {
            let out = try await guestExec(profileID: profileID, command: cmd, timeout: 60)
            guard !out.isEmpty else {
                BACDebug.log("automation", "no transcript found in guest for \(branch)")
                return
            }
            try AutomationRunArchive.saveTranscript(Data(out.utf8), runID: runID)
            BACDebug.log("automation", "transcript for \(branch) archived (\(out.count) bytes)")
        } catch {
            BACDebug.log("automation", "transcript pull for \(branch) failed: \(error)")
        }
    }

    // MARK: The workspace

    /// Boots the workspace for a run; headless either way on a server.
    // @port ACAppDelegate.startProfileForAutomation(_: Profile.ID, detached: Bool) h=94d42a800f5fdc4f @9936e30c
    func startProfileForAutomation(_ id: Profile.ID, detached: Bool) { boot(id) }

    /// One process runs the workspaces here: none is open elsewhere.
    // @port ACAppDelegate.workspaceOpenElsewhere(_: Profile.ID) h=da71c9e10f9c8655 @9936e30c
    func workspaceOpenElsewhere(_ id: Profile.ID) -> Bool { false }

    /// Clone-first runs need a workspace copy (macOS: an APFS CoW duplicate
    /// of the profile and its home), which the daemon can't make yet: the
    /// run fails with the engine's own "couldn't clone" reason.
    // partial: no workspace duplicate on Linux yet
    // @port-skip linux-only: no workspace clones on Linux yet (ACAppDelegate.cloneWorkspaceForAutomation)
    func cloneWorkspaceForAutomation(_ baseID: Profile.ID, runSlug: String) async -> Profile? { nil }

    // partial: no workspace duplicate on Linux yet
    // @port-skip linux-only: no workspace clones on Linux yet (ACAppDelegate.destroyAutomationClone)
    func destroyAutomationClone(_ id: Profile.ID) {}

    /// Every worktree branch with an open tab in a running workspace.
    // @port ACAppDelegate.openWorktreeBranches(profileID: UUID) h=a83ea7fd66826ea4 @9936e30c
    func openWorktreeBranches(profileID: UUID) -> [String] { liveWorktreeBranches(profileID: profileID) ?? [] }

    /// The roster's worktree branches; [] when the workspace isn't running.
    // @port ACAppDelegate.liveWorktreeBranches(profileID: UUID) h=03891fc4cd0a7be5 @9936e30c
    func liveWorktreeBranches(profileID: UUID) -> [String]? {
        tabsModel(for: profileID)?.tabs.compactMap(\.worktreeBranch) ?? []
    }

    /// A finished run's session goes to the Archived fold, resolved off the
    /// roster (so before the tab is killed). `windowIDs`: the tmux windows
    /// being closed; a session stamped with another id stays.
    // @port ACAppDelegate.archiveFinishedSession(profileID: Profile.ID, worktreeBranch: String, windowIDs: Set<String>?, strict: Bool) h=896954021a1bff83 @9936e30c
    func archiveFinishedSession(profileID: Profile.ID, worktreeBranch: String,
                                windowIDs: Set<String>?, strict: Bool) {
        let store = agentSessionStore
        for tab in tabsModel(for: profileID)?.tabs ?? [] where tab.worktreeBranch == worktreeBranch {
            guard let s = store.session(profileID: profileID, windowIndex: tab.index),
                  !s.isArchived, !s.isDeleted else { continue }
            if let ids = windowIDs {
                if let w = s.windowID { if !ids.contains(w) { continue } } else if strict { continue }
            }
            BACDebug.log("sessions", "archiving finished “\(s.title)” (\(worktreeBranch))")
            store.setArchived(s.id, true)
        }
    }

    // MARK: Plan streams

    /// No streamed planning sessions here (macOS's plan-stream hub and its
    /// per-workspace bridges): planning runs in a tab.
    // partial: no plan-stream bridge on Linux
    // @port-skip linux-only: no plan-stream hub on Linux (ACAppDelegate.planStreamLive)
    func planStreamLive(profileID: Profile.ID, branch: String) -> Bool { false }

    // partial: no plan-stream bridge on Linux
    // @port-skip linux-only: no plan-stream hub on Linux (ACAppDelegate.endPlanStream)
    func endPlanStream(profileID: Profile.ID, branch: String) {}

    // MARK: Sessions and the task dispatcher

    // @port-skip linux-only: the daemon's session store
    var agentSessionStore: AgentSessionStore { SessionStores.shared!.sessions }

    // @port-skip linux-only: the daemon's task dispatcher (ACAppDelegate.dispatcherSendBack)
    func dispatcherSendBack(_ taskID: UUID, feedback: String) async -> Bool {
        await SessionStores.shared?.taskDispatcher?.sendBack(taskID, feedback: feedback) ?? false
    }

    // @port-skip linux-only: the daemon's task dispatcher (ACAppDelegate.dispatcherSteerLanding)
    func dispatcherSteerLanding(_ taskID: UUID, text: String) async -> Bool {
        await SessionStores.shared?.taskDispatcher?.steerLanding(taskID, text: text) ?? false
    }

    // @port-skip linux-only: the daemon's task dispatcher (ACAppDelegate.dispatcherRecall)
    func dispatcherRecall(_ taskID: UUID) { SessionStores.shared?.taskDispatcher?.recall(taskID) }

    // @port ACAppDelegate.settleCodingTaskRefusals(now: Date, liveBranches: (UUID)->[String]) h=6c290afbe8141d2e @0c31f70f
    func settleCodingTaskRefusals(now: Date, liveBranches: (UUID) -> [String]) {
        SessionStores.shared?.codingTaskEngine?.settlePendingRefusals(now: now, liveBranches: liveBranches)
    }
}

/// The daemon as the board dispatcher's host (macOS: TaskDispatchHost+App.swift).
extension LinuxSessionHost: TaskDispatchHost {
    // @port-skip linux-only: the daemon's stores (set at start, before the dispatcher runs)
    var codingTaskStore: CodingTaskStore { SessionStores.shared!.codingTasks }
    // @port-skip linux-only: the daemon's engines (set at start, before the dispatcher runs)
    var codingTaskEngine: CodingTaskEngine { SessionStores.shared!.codingTaskEngine! }
    // @port-skip linux-only: the daemon's engines (set at start, before the dispatcher runs)
    var delegationEngine: DelegationEngine { SessionStores.shared!.delegationEngine! }
    /// No attached machines here: the daemon's own sessions.
    // @port-skip linux-only: no attached machines on Linux
    var allSessionRecords: [AgentSession] { agentSessionStore.sessions }
    /// No window: every live session is free unless its agent is mid-turn.
    // @port-skip linux-only: no session list window on a server
    var sessionListModel: SessionListModel? { nil }
    // @port-skip linux-only: no attached machines on Linux
    func attachedMachineName(_ id: Profile.ID) -> String? { nil }
    /// No Switchboard on Linux yet: a room's task has nowhere to go.
    // partial: no Switchboard on Linux yet
    // @port-skip linux-only: no Switchboard on Linux yet
    func ensureSwitchboard(room: AgentRoom?) -> UUID? { nil }
}
