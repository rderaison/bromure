import Foundation
import NIOConcurrencyHelpers

/// What the compromise handler does to a VM (FirecrackerMachine's; a
/// stand-in in tests).
// @port-skip linux-only: the handler's VM, for tests
protocol CompromiseVM: AnyObject, Sendable {
    func pause() async throws
    func resume() async throws
    /// true: paused; false: running; nil: unknown (the API didn't say).
    func isPaused() async -> Bool?
}

extension FirecrackerMachine: CompromiseVM {
    // @port-skip linux-only: the handler's VM, for tests
    func isPaused() async -> Bool? {
        switch try? await api.instanceState() {
        case "Paused"?: return true
        case "Running"?: return false
        default: return nil
        }
    }
}

extension Daemon {
    /// Tests: the VM the handler acts on, by workspace (nil: the live one).
    static let compromiseVMForTesting = NIOLockedValueBox<(@Sendable (UUID) -> (id: String, vm: any CompromiseVM)?)?>(nil)
    /// Tests: the owner's answer, by workspace (nil: asked through the broker).
    static let compromiseAnswerForTesting = NIOLockedValueBox<(@Sendable (UUID) async -> Int)?>(nil)

    /// Workspace `pid`'s running VM, by its record id.
    // @port-skip linux-only: the handler's VM lookup
    func compromiseVM(_ pid: UUID) -> (id: String, vm: any CompromiseVM)? {
        if let hook = Self.compromiseVMForTesting.withLockedValue({ $0 }) { return hook(pid) }
        guard let id = runningVMID(of: pid), let m = live[id]?.machine else { return nil }
        return (id, m)
    }

    /// A workspace row of /state, with `compromised` (macOS: its rows'
    /// key, which the fat client reads).
    // @port-skip linux-only: /state's workspace rows
    func compromisedRow(_ rec: VMRecord) -> JSONValue {
        guard case .object(var o) = rec.workspaceJSON else { return rec.workspaceJSON }
        o["compromised"] = .bool(existingProfile(for: rec).map { Self.isCompromised($0, store: profileStore) } ?? false)
        return .object(o)
    }

    /// Hands the proxy's compromise events to handleCompromise (macOS:
    /// engine.swapper.setCompromiseHandler at launch).
    // @port-skip linux-only: the daemon's share of ACAppDelegate's compromise handler wiring
    func wireCompromiseHandler() {
        // The event's session is its request's (taken when the request was
        // read, carried to here): a leak from a session that ended, even one
        // held at a consent meanwhile, pauses and asks nothing. Raised
        // outside a request: the current session. The proxy is held weakly
        // (the swapper it owns keeps this closure).
        let proxy = mitm
        mitm?.swapper.setCompromiseHandler { [weak self, weak proxy] event in
            let session = MitmProxy.raisingSession ?? proxy?.strictSession(of: event.profileID) ?? 0
            Task { await self?.handleCompromise(event, session: session) }
        }
    }

    /// A stand-in leaving the VM for a host it isn't bound to (macOS:
    /// HTTPProxy's detectCompromise step, and the app delegate's
    /// handleCompromise): the request is refused (451) and recorded, and the
    /// workspace's VM is paused while its owner is asked, through the client
    /// (PendingPromptBroker, as macOS asks a headless or mirrored session):
    /// Shut down (the workspace is marked compromised and won't boot until
    /// the mark is cleared), Block (just that request; the VM resumes), or
    /// Allow (the host becomes one of the credential's destinations for the
    /// session; the VM resumes). No answer in 180 s is a shut down.
    /// Strict credential mode's events (a credential Bromure didn't issue)
    /// ask the same; their Allow lets exactly those credentials through for
    /// the session, to any host (macOS's semantics).
    // partial: Save for Investigation needs a local folder picker (macOS-only, as on a headless Mac)
    // @port ACAppDelegate.handleCompromise(_: CompromiseEvent) h=e4f537275a5a956e @a0266d0e
    func handleCompromise(_ event: CompromiseEvent, session raised: UInt64? = nil) async {
        let pid = event.profileID
        // The workspace's session (a stop starts the next): the event's, or
        // the current one when the caller has none.
        let session = raised ?? mitm?.strictSession(of: pid) ?? 0
        func current() -> Bool { (mitm?.strictSession(of: pid) ?? 0) == session }
        guard current() else {
            FileHandle.standardError.write(Data("bromure-ac daemon: compromise: raised in a session that ended; dropped\n".utf8))
            return
        }
        guard let profile = profileStore.loadAll().first(where: { $0.id == pid }) else { return }
        // The workspace's opt-out: the proxy refused the request and recorded
        // it; no question, no pause.
        if profile.disableExfiltrationAlerts { return }
        // One question at a time per session (a retried leak fires again);
        // the next session's VM is asked on its own.
        let asking = "\(pid)#\(session)"
        guard compromiseAsking.insert(asking).inserted else { return }
        defer { compromiseAsking.remove(asking) }
        guard let (id, machine) = compromiseVM(pid) else { return }
        do { try await holdPause(id, machine) } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': compromise: pause failed (\(error))\n".utf8))
        }
        let (title, message) = Self.compromiseQuestion(event, workspace: profile.name)
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': compromise: VM paused at \(Date()); asking \(PendingPromptBroker.hasLiveListener() ? "the client" : "nobody (no client watching: shut down)")\n".utf8))
        let choice: Int
        if let answer = Self.compromiseAnswerForTesting.withLockedValue({ $0 }) {
            choice = await answer(pid)
        } else {
            choice = await PendingPromptBroker.shared.askAsync(
                profileID: pid, title: title, message: message,
                buttons: ["Shut down", "Block", "Allow"], fallback: 0, timeout: 180)
        }
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': compromise: answer \(choice) at \(Date()) (a client watching: \(PendingPromptBroker.hasLiveListener()))\n".utf8))
        // The answer is about that VM: one stopped (or replaced by a new
        // session) while the question was up gets none of it. An "Allow"
        // after the stop's clear would carry into the next session, and a
        // late "Shut down" would kill the new one.
        guard current(), let now = compromiseVM(pid), now.vm === machine, now.id == id else {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': compromise: the VM it was about is gone; answer \(choice) dropped\n".utf8))
            return
        }
        switch choice {
        case 2 where !event.unmanagedFingerprints.isEmpty:
            // Strict credential mode: exactly these credentials, for this
            // session (not the host for every other credential).
            UnmanagedCredentialGuard.shared.allowForSession(event.unmanagedFingerprints, profileID: pid)
            BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "credential.exfiltration_allowed",
                                                eventData: ["observed_host": .string(event.observedHost),
                                                            "scope": .string("session"), "unmanaged": .bool(true)])
            await letGoPause(id, machine)
        case 2:
            // The user vouches for the destination: the credential may go
            // there for the rest of the session (cleared at teardown).
            let hosts = Array(Set(event.leaks.map(\.observedHost)))
            mitm?.swapper.allowSessionHosts(hosts, for: pid)
            for host in hosts {
                BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "credential.exfiltration_allowed",
                                                    eventData: ["observed_host": .string(host), "scope": .string("session")])
            }
            await letGoPause(id, machine)
        case 1:
            // Just that request (already refused); a retry asks again.
            await letGoPause(id, machine)
        default:
            // Contained: marked, and stopped. It boots again once the mark is
            // cleared (POST /profiles/<id>/compromised).
            Self.markCompromised(profile, store: profileStore)
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': marked compromised and shut down\n".utf8))
            if let rec = registry.find(id) { _ = await deleteVM(rec, action: "kill") }
        }
    }

    /// The question's title and text (macOS: presentCompromiseAlert's).
    // @port-skip linux-only: presentCompromiseAlert's text, for the broker
    static func compromiseQuestion(_ event: CompromiseEvent, workspace: String) -> (String, String) {
        let lines = event.leaks.map {
            "• \($0.fakeTokenPreview) (\($0.credentialDisplayName)): meant for \($0.declaredHost), sent to \(sanitizedHost($0.observedHost))"
        }
        // Strict mode's Allow approves the credentials themselves, wherever
        // they go; a stand-in's approves the destination.
        let allow = event.unmanagedFingerprints.isEmpty
            ? "Allow trusts this destination for the rest of this session (the credential will be sent there). "
            : "Allow lets these credentials through for the rest of this session, to any host. "
        return ("“\(workspace)” tried to send a credential to the wrong host",
                "The VM is paused. Bromure blocked the request:\n" + lines.joined(separator: "\n")
                + "\n" + allow + "Block stops just this request. Shutting the VM down is the safest choice.")
    }

    /// A host the guest named, fit to show: host characters only (letters,
    /// digits, `.-:[]_`), at most 253 of them.
    // @port-skip linux-only: the prompt text's guest-controlled part
    static func sanitizedHost(_ host: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]_")
        let h = String(host.filter { ok.contains($0) }.prefix(253))
        return h.isEmpty ? "(unprintable host)" : h
    }

    // MARK: The compromise mark (SessionDisk's files, in the profile directory)

    /// `compromised.flag` in the workspace's directory (macOS: SessionDisk.compromiseMarkURL).
    // @port SessionDisk.static compromiseMarkURL(profile: Profile, store: ProfileStore) h=f360ea547e538e83 @9c8246cb
    static func compromiseMarkURL(_ profile: Profile, store: ProfileStore) -> URL {
        store.profileDirectory(for: profile).appendingPathComponent("compromised.flag", isDirectory: false)
    }

    // @port-skip linux-only: SessionDisk.isCompromised's static lookup
    static func isCompromised(_ profile: Profile, store: ProfileStore) -> Bool {
        FileManager.default.fileExists(atPath: compromiseMarkURL(profile, store: store).path)
    }

    /// The mark, its last resolution dropped (macOS: SessionDisk.markCompromised).
    // @port-skip linux-only: SessionDisk.markCompromised at the same paths
    static func markCompromised(_ profile: Profile, store: ProfileStore) {
        let url = compromiseMarkURL(profile, store: store)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("compromise.resolved"))
    }

    /// `POST /profiles/<id>/compromised {"action": "clear"}`: a false alarm,
    /// the mark goes and the disk is kept (macOS: resolveCompromise's clear).
    // partial: "wipe" isn't on Linux yet (the workspace's disk and home erased): clear the mark or remove the workspace
    // @port-skip linux-only: resolveCompromise's clear on the daemon
    func resolveCompromise(_ key: String, action: String) -> ControlResponse {
        guard let profile = Self.workspace(key) else { return ControlResponse(404, ["ok": false, "error": "workspace not found"]) }
        switch action {
        case "clear":
            let url = Self.compromiseMarkURL(profile, store: profileStore)
            guard FileManager.default.fileExists(atPath: url.path) else { return ControlResponse(200, ["ok": true]) }
            do { try FileManager.default.removeItem(at: url) } catch {
                return ControlResponse(500, ["ok": false, "error": .string("the mark couldn't be removed: \(error.localizedDescription)")])
            }
            try? Data("clear".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("compromise.resolved"), options: .atomic)
            BACEventEmitter.shared.emitDetached(profileID: profile.id, eventType: "vm.compromise_cleared",
                                                eventData: ["reason": .string("false alarm")])
            return ControlResponse(200, ["ok": true])
        case "wipe":
            return ControlResponse(501, ["ok": false, "error": "wiping a compromised workspace isn't on Linux yet: clear the mark (a false alarm) or remove the workspace"])
        default:
            return ControlResponse(400, ["ok": false, "error": "action must be wipe or clear"])
        }
    }
}
