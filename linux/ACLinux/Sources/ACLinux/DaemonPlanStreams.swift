import Foundation

// Streamed planning sessions on a Linux server (macOS: ACAppDelegate's
// planStreamHub, planEventBridges and their fat-client relay routes): the
// hub folds each workspace's plan-stream events into the transcript items
// the client renders, ends the task's plan on a terminal event, and carries
// the client's turns and answers back to the driver.
extension SessionStores {
    /// The hub's hooks (macOS: the planStreamHub initializer): a terminal
    /// event ends the task's plan in the engine. No plan windows here: the
    /// fat client polls the relay.
    // @port-skip linux-only: the hooks of ACAppDelegate's lazy planStreamHub (a closure, not a tracked function)
    func wirePlanStreamHub() {
        planStreamHub.onStarted = { pid, branch in
            BACDebug.log("plan-stream", "\(branch) started (\(pid))")
        }
        planStreamHub.onEnded = { pid, branch, ok, error in
            SessionStores.shared?.codingTaskEngine?.planStreamEnded(
                profileID: pid, branch: branch, ok: ok, error: error)
        }
    }

    /// Wire a workspace's listener into the hub, with the
    /// died-without-a-terminal-event detection: a bound connection closing
    /// starts a grace period; if nothing rebinds the branch, the session is
    /// declared dead so the card doesn't spin until the watchdog's cap.
    // @port ACAppDelegate.wirePlanBridge(_: PlanEventBridge, pid: Profile.ID) h=9f950cd74c6142dd @ac3ea65d
    func wirePlanBridge(_ bridge: PlanStreamListener, pid: Profile.ID) {
        bridge.onEvent = { [weak self] branch, event in
            self?.planStreamHub.handle(profileID: pid, branch: branch, event: event)
        }
        bridge.onConnectionLost = { [weak self, weak bridge] branch in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.planReconnectGrace)
                guard let self, let bridge,
                      !bridge.isBound(branch: branch),
                      self.planStreamHub.isLive(profileID: pid, branch: branch)
                else { return }
                self.planStreamHub.handle(
                    profileID: pid, branch: branch,
                    event: .fatal(NSLocalizedString(
                        "The planning driver disconnected and did not reconnect.",
                        comment: "plan stream")))
            }
        }
    }

    /// macOS's grace before a lost driver is declared dead (90 s).
    nonisolated(unsafe) static var planReconnectGrace: UInt64 = 90_000_000_000

    /// A running workspace's listener, wired; the previous one stopped.
    // @port-skip linux-only: the planEventBridges[pid] assignment at launch, by the daemon
    func attachPlanBridge(_ bridge: PlanStreamListener, pid: Profile.ID) {
        planBridges[pid]?.stop()
        wirePlanBridge(bridge, pid: pid)
        planBridges[pid] = bridge
    }

    /// The workspace's VM stopped or rebooted: its listener goes, and so do
    /// its sessions (the driver died with the guest; un-ended, its session
    /// would pin the plan watchdog live and block a Plan retry).
    // @port-skip linux-only: the planEventBridges / removeSessions teardown in cleanupSessionRegistrations
    func detachPlanBridge(pid: Profile.ID) {
        planBridges[pid]?.stop()
        planBridges.removeValue(forKey: pid)
        planStreamHub.removeSessions(profileID: pid)
    }

    /// `POST /tasks/<id>/plan-events {since}`: the streamed plan session's
    /// rendered items from `since` on (a growing-log cursor).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onTaskCommand h=09891b7729777755 @ac3ea65d
    func planEvents(_ id: UUID, _ body: [String: Any]) -> [String: Any] {
        guard let task = codingTasks.task(id),
              let slug = task.branchSlug,
              let s = planStreamHub.session(profileID: task.profileID, branch: "wt/" + slug)
        else { return ["live": false, "items": [], "since": 0] }
        let since = max(0, min(body["since"] as? Int ?? 0, s.items.count))
        var out: [String: Any] = [
            "live": s.ended == nil,
            "since": since,
            // Session identity: a Plan retry can reuse the branch, and the
            // client must drop its cache instead of splicing two sessions.
            "session": s.token,
            "items": s.items[since...].map(TranscriptItemWire.encode),
        ]
        if let end = s.ended {
            out["ended"] = ["ok": end.ok, "error": end.error ?? ""]
        }
        return out
    }

    /// `POST /tasks/<id>/plan-cmd {type, …}`: a user turn, structured
    /// answers or an interrupt into the streamed session.
    // @port-skip linux-only: the plan-cmd case of onTaskCommand (see planEvents)
    func planCommand(_ id: UUID, _ body: [String: Any]) -> [String: Any] {
        guard let task = codingTasks.task(id),
              let slug = task.branchSlug,
              let bridge = planBridges[task.profileID],
              planStreamHub.isLive(profileID: task.profileID, branch: "wt/" + slug)
        else { return ["ok": false, "error": "no live plan stream"] }
        let branch = "wt/" + slug
        let sent: Bool
        switch body["type"] as? String ?? "" {
        case "user":
            sent = bridge.send(branch: branch, .user(body["text"] as? String ?? ""))
        case "answer":
            guard let session = planStreamHub.session(profileID: task.profileID, branch: branch),
                  let qid = session.pendingQID
            else { return ["ok": false, "error": "no pending question"] }
            let answers = ((body["answers"] as? [[String: Any]]) ?? []).map {
                (question: $0["question"] as? String ?? "",
                 labels: $0["labels"] as? [String] ?? [],
                 other: $0["other"] as? String)
            }
            sent = bridge.send(branch: branch, .answer(qid: qid, answers: answers))
            if sent { session.markAnswered(qid: qid) }
        case "interrupt":
            sent = bridge.send(branch: branch, .interrupt)
        default:
            return ["ok": false, "error": "unknown plan-cmd type"]
        }
        return ["ok": sent]
    }
}

extension Daemon {
    /// The VM's plan-stream listener (macOS: the PlanEventBridge made with
    /// the workspace's other vsock bridges at launch), attached to the hub;
    /// `stored` is a restarted daemon's, from the fd store. The workspace's
    /// id, or nil when it couldn't listen.
    // @port-skip linux-only: launch's PlanEventBridge on hybrid vsock, kept in the fd store
    func servePlanStream(_ rec: VMRecord, udsPath: String, stored: Int32?) async -> UUID? {
        guard let pid = UUID(uuidString: rec.id) else { return nil }
        let short = rec.shortId, name = rec.name
        return await MainActor.run {
            do {
                let bridge = try PlanStreamListener(udsPath: udsPath, fdStoreName: "plan-" + short, stored: stored)
                guard let stores = SessionStores.shared else { bridge.stop(); return nil }
                stores.attachPlanBridge(bridge, pid: pid)
                return pid
            } catch {
                FileHandle.standardError.write(Data("bromure-ac daemon: '\(name)': no plan-stream listener: \(error)\n".utf8))
                return nil
            }
        }
    }
}
