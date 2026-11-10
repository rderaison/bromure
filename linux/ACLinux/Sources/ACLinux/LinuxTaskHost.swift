import Foundation

/// The daemon as the coding-task and scheduled-automation engines' host
/// (macOS: ACAppDelegate, CodingTaskHost+App / AutomationHost+App). guestExec,
/// automationWorktreeCommand, profile(for:), unattendedLaunchRefusal and
/// tabsModel(for:) are the session host's (LinuxSessionHost).
extension LinuxSessionHost: CodingTaskHost, AutomationHost {
    // MARK: The guest

    /// A task's transcript: its archived copy, else the guest's, else (a
    /// Claude task's, the workspace off) read from its home image.
    // @port ACAppDelegate.fetchTaskTranscriptRaw(_: CodingTask) h=b4e71a368ec3c7eb @9936e30c
    // partial: calls HomeImageReader.claudeTranscript inline
    // @port ACAppDelegate.static ext4Transcript(imagePath: String, slug: String, guestCwd: String) h=d0ebf29eb8eb89b3 @d3ebbda2
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
        // Offline: read the image directly (read-only; safe even if a VM
        // has the disk attached, as macOS). Claude only: the ext4 walker
        // knows ~/.claude/projects; other tools' stores are reachable while
        // the workspace runs (above).
        guard task.tool == .claude, let daemon else { return nil }
        let img = await daemon.vmDir(task.profileID.uuidString.lowercased()) + "/home.img"
        guard FileManager.default.fileExists(atPath: img) else { return nil }
        let slug = String(branch.dropFirst(3))
        let guestCwd = ScheduledAutomationEngine.guestPath(task.repoPath)
        return await Task.detached(priority: .userInitiated) {
            HomeImageReader.claudeTranscript(imagePath: img, slug: slug, guestCwd: guestCwd)
        }.value
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
    func startProfileForAutomation(_ id: Profile.ID, detached: Bool) { boot(id, unattended: true) }

    /// One process runs the workspaces here: none is open elsewhere.
    // @port ACAppDelegate.workspaceOpenElsewhere(_: Profile.ID) h=da71c9e10f9c8655 @9936e30c
    func workspaceOpenElsewhere(_ id: Profile.ID) -> Bool { false }

    /// Duplicate a workspace for a clone-first automation run: the profile
    /// and its VM's images as reflinks (Daemon.cloneWorkspace; none on a
    /// filesystem without them, and the run fails with the engine's
    /// "couldn't clone"). A running source is cloned live, crash-consistent,
    /// after a guest `sync`, as on macOS.
    // @port ACAppDelegate.cloneWorkspaceForAutomation(_: Profile.ID, runSlug: String) h=257b4270865422a3 @641863f2
    func cloneWorkspaceForAutomation(_ baseID: Profile.ID, runSlug: String) async -> Profile? {
        guard let daemon else { return nil }
        if LinuxSessionHost.running.withLockedValue({ $0.contains(baseID) }) {
            _ = try? await guestExec(profileID: baseID, command: "sync", timeout: 60)
        }
        return await daemon.cloneWorkspace(baseID, runSlug: runSlug)
    }

    /// The run's clone goes once it's stopped (Daemon.destroyClone).
    // @port ACAppDelegate.destroyAutomationClone(_: Profile.ID) h=dc6672c36db37645 @641863f2
    func destroyAutomationClone(_ id: Profile.ID) {
        guard let daemon else { return }
        Task { await daemon.destroyClone(id) }
    }

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

    /// True while a streamed planning session for this branch is running:
    /// the plan watchdog's "the session exists" signal in driver mode.
    // @port ACAppDelegate.planStreamLive(profileID: Profile.ID, branch: String) h=bdfe0a6387699d1a @ac3ea65d
    func planStreamLive(profileID: Profile.ID, branch: String) -> Bool {
        SessionStores.shared?.planStreamHub.isLive(profileID: profileID, branch: branch) ?? false
    }

    /// Tear a streamed planning session down: the driver replies with its
    /// terminal result and exits. A no-op when no live stream claims the
    /// branch.
    // @port ACAppDelegate.endPlanStream(profileID: Profile.ID, branch: String) h=d13b0e0c9f3fbf03 @ac3ea65d
    func endPlanStream(profileID: Profile.ID, branch: String) {
        guard let stores = SessionStores.shared,
              stores.planStreamHub.isLive(profileID: profileID, branch: branch) else { return }
        _ = stores.planBridges[profileID]?.send(branch: branch, .end)
    }

    // MARK: Sessions and the task dispatcher

    // @port-skip linux-only: the daemon's session store
    var agentSessionStore: AgentSessionStore { SessionStores.shared!.sessions }

    // @port ACAppDelegate.dispatcherSendBack(_: UUID, feedback: String) h=9ed1a4fccf48b950 @0c31f70f
    func dispatcherSendBack(_ taskID: UUID, feedback: String) async -> Bool {
        await SessionStores.shared?.taskDispatcher?.sendBack(taskID, feedback: feedback) ?? false
    }

    // @port ACAppDelegate.dispatcherSteerLanding(_: UUID, text: String) h=f8667552280f3a78 @0c31f70f
    func dispatcherSteerLanding(_ taskID: UUID, text: String) async -> Bool {
        await SessionStores.shared?.taskDispatcher?.steerLanding(taskID, text: text) ?? false
    }

    // @port ACAppDelegate.dispatcherRecall(_: UUID) h=20cea9c7d2978c98 @0c31f70f
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
    /// This server's sessions and the attached machines'.
    // @port ACAppDelegate.var allSessionRecords h=465c6e879255dab4 @d2db8346
    var allSessionRecords: [AgentSession] {
        agentSessionStore.sessions + (LinuxMachines.shared?.attached.values.flatMap(\.sessionStore.sessions) ?? [])
    }
    /// The session list's model, kept without a window (refreshSidebar).
    // @port ACAppDelegate.var sessionListModel h=b55aac90da9b04da @a1896aec
    var sessionListModel: SessionListModel? { listModel }
    // @port ACAppDelegate.attachedMachineName(_: Profile.ID) h=2b2c216aa08778df @fa0f94e5
    func attachedMachineName(_ id: Profile.ID) -> String? { LinuxMachines.shared?.attached[id]?.name }
    // @port ACAppDelegate.ensureSwitchboard(room: AgentRoom?) h=68b9817700f6a730 @a1896aec
    func ensureSwitchboard(room: AgentRoom?) -> UUID? { SessionStores.shared?.switchboardEngine?.ensureSwitchboard(room: room) }
}

/// The Switchboard's host (macOS: the app delegate).
extension LinuxSessionHost: SwitchboardHost {
    // @port-skip linux-only: LinuxMachines answers it (DaemonMachines)
    func machine(forSession id: UUID) -> AttachedMachine? { LinuxMachines.shared?.machine(forSession: id) }
    /// The Macs attached to this server (macOS: ACAppDelegate.attachedMachines).
    // @port-skip linux-only: LinuxMachines' roster (DaemonMachines)
    var attachedMachines: [UUID: AttachedMachine] { LinuxMachines.shared?.attached ?? [:] }
}
