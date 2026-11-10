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

    /// /state's (and GET /workspaces') rows: each workspace's, with the
    /// agents it can run worked out on the main actor (the Models settings
    /// live there) once for all of them.
    // partial: no attached Mac's agents (a server's rows are its own workspaces)
    // @port ACAppDelegate.readyToolSpecs(for: Profile) h=f54a19bf83a16d1c @d3ebbda2
    func workspaceRows(_ recs: [VMRecord]) async -> [JSONValue] {
        let profiles = recs.map { existingProfile(for: $0) }
        let subscribed = profiles.map { $0.map(subscribedProviders(for:)) ?? [] }
        let ready: [UUID: [Profile.ToolSpec]] = await MainActor.run {
            var out: [UUID: [Profile.ToolSpec]] = [:]
            for (p, sub) in zip(profiles, subscribed) {
                if let p { out[p.id] = p.readyToolSpecs(ModelSettingsStore.shared.effective(for: p), subscribed: sub) }
            }
            return out
        }
        return zip(recs, profiles).map { compromisedRow($0, profile: $1, ready: $1.flatMap { ready[$0.id] }) }
    }

    /// A workspace row of /state, as macOS's: its run state and size, its
    /// color, agent and notes, which credentials it holds (never their
    /// values), the agents it can run, whether something restricts its
    /// traffic, Squelch, a boot failure, terminal appearance overrides.
    // partial: cpuCount is the VM record's; no attached Mac's agents (a server lists only its own)
    // @port ACAppDelegate.automationWorkspaceList() h=eae7cd8d00c7143c @d3ebbda2
    // @port ACAppDelegate.static homeImageBytes(_: URL) h=0a65e360ff407aee @d3ebbda2
    func compromisedRow(_ rec: VMRecord, profile: Profile?, ready: [Profile.ToolSpec]?) -> JSONValue {
        guard case .object(var o) = rec.workspaceJSON else { return rec.workspaceJSON }
        o["compromised"] = .bool(profile.map { Self.isCompromised($0, store: profileStore) } ?? false)
        let dir = vmDir(rec.id)
        var st = stat()
        let disk = stat(dir + "/disk.raw", &st) == 0 ? (Int64(st.st_blocks) * 512, Int64(st.st_size)) : (0, 0)
        o["diskAllocatedBytes"] = .number(Double(disk.0))
        o["diskCapacityBytes"] = .number(Double(disk.1))
        // A fat client's editor remeasures when this moves (a wipe, reset or
        // rollback leaves the run state as it was).
        o["homeImageBytes"] = stat(dir + "/home.img", &st) == 0 ? .number(Double(st.st_size)) : .null
        if let profile {
            o["accentHex"] = .string(profile.color.hexInUI)
            o["color"] = .string(profile.color.rawValue)
            o["tool"] = .string(profile.tool.rawValue)
            o["authMode"] = .string(profile.authMode.rawValue)
            o["memoryGB"] = .number(Double(profile.memoryGB))
            o["hasGitHubToken"] = .bool(profile.hasGitHubCredential)
            o["hasLinearToken"] = .bool(!profile.linearToken.isEmpty)
            o["askBeforeUseLabels"] = .array(profile.askBeforeUseCredentialLabels.map { .string($0) })
            o["additionalTools"] = .array(profile.additionalTools.filter { $0.tool != profile.tool }.map {
                ["tool": .string($0.tool.rawValue), "authMode": .string($0.authMode.rawValue)]
            })
            if let ready {
                o["readyTools"] = .array(ready.map { ["tool": .string($0.tool.rawValue), "authMode": .string($0.authMode.rawValue)] })
            }
            o["sandboxed"] = .bool(profile.restrictsEgress)
            o["comments"] = .string(profile.comments)
            if let v = profile.customFontFamily { o["fontFamily"] = .string(v) }
            if let v = profile.customFontSize { o["fontSize"] = .number(Double(v)) }
            if let v = profile.customBackgroundHex { o["backgroundHex"] = .string(v) }
            if let v = profile.customForegroundHex { o["foregroundHex"] = .string(v) }
        }
        // Squelch's setting and what it saved (macOS: the workspace row's
        // squelch / squelchSummary).
        if let profile {
            o["squelch"] = .bool(profile.squelch.enabled)
            if let sum = SquelchLedger.shared.summary(profile.id), let v = JSONValue.encoding(sum) { o["squelchSummary"] = v }
        }
        // Wedged at boot on filesystem errors (the decision prompt rides
        // pendingPrompts; this lets clients badge the workspace row too).
        if let failure = activeBootFailures[rec.id] { o["bootFailure"] = .string(failure) }
        return .object(o)
    }

    /// The firewall's proxy-route cut, to the guest: agentd resets the
    /// bridged client socket by its port (macOS: installFirewallGuestAbort,
    /// by vsock port there; Firecracker's vsock doesn't give the host the
    /// guest's).
    // @port-skip linux-only: ACAppDelegate.installFirewallGuestAbort's guest request, by the client's port
    func wireBridgeAbort() {
        mitm?.bridgeAbort.withLockedValue { $0 = { [weak self] pid, sport, peer, done in
            Task {
                defer { done() }
                _ = try? await self?.liveShell(of: pid)?.request(
                    ["bridge_abort": ["client_sport": sport, "client_peer": peer], "timeout": 5],
                    wait: .seconds(2), deadline: .seconds(5))
            }
        } }
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
    // partial: broker question Shut down/Block/Allow (handleCompromise asks it). No Save for Investigation (as macOS remote)
    // @port ACAppDelegate.presentCompromiseAlert(event: CompromiseEvent, profileName: String) h=547e3c42b283f232 @d3ebbda2
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
    // @port SessionDisk.var compromisedFlagURL h=0c48de97170c722e @e81ff085
    static func compromiseMarkURL(_ profile: Profile, store: ProfileStore) -> URL {
        store.profileDirectory(for: profile).appendingPathComponent("compromised.flag", isDirectory: false)
    }

    // @port SessionDisk.var isCompromised h=5c420fcf385f4c7a @e81ff085
    // @port SessionDisk.static isCompromised(profile: Profile, store: ProfileStore) h=a5e152bc5b098be3 @e81ff085
    static func isCompromised(_ profile: Profile, store: ProfileStore) -> Bool {
        FileManager.default.fileExists(atPath: compromiseMarkURL(profile, store: store).path)
    }

    /// The mark, its last resolution dropped (macOS: SessionDisk.markCompromised).
    // @port SessionDisk.markCompromised() h=602281e2fcb9820e @e81ff085
    static func markCompromised(_ profile: Profile, store: ProfileStore) {
        let url = compromiseMarkURL(profile, store: store)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("compromise.resolved"))
    }

    /// How the mark was last resolved (`compromise.resolved`: macOS's
    /// SessionDisk.lastCompromiseResolution), or nil.
    // @port SessionDisk.var compromiseResolutionURL h=9ec5206d52a9275b @e81ff085
    // @port SessionDisk.var lastCompromiseResolution h=62c01d9c9eb060b1 @e81ff085
    static func lastCompromiseResolution(_ profile: Profile, store: ProfileStore) -> SessionDisk.CompromiseRemedy? {
        let url = store.profileDirectory(for: profile).appendingPathComponent("compromise.resolved")
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap(SessionDisk.CompromiseRemedy.init(rawValue:))
    }

    // @port SessionDisk.recordCompromiseResolution(_: CompromiseRemedy) h=fbe0e725a52c70e1 @e81ff085
    static func recordCompromiseResolution(_ how: SessionDisk.CompromiseRemedy, _ profile: Profile, store: ProfileStore) {
        let url = store.profileDirectory(for: profile).appendingPathComponent("compromise.resolved")
        try? Data(how.rawValue.utf8).write(to: url, options: .atomic)
    }

    /// What a wipe or a clear does about the mark it was asked to resolve,
    /// checked when the answer comes: still marked, do it; gone the way
    /// asked, nothing to do; gone the other way (or nobody knows how), the
    /// asked one didn't happen.
    enum CompromiseStep: Equatable { case perform, already, undone }

    // @port ACAppDelegate.static compromiseStep(_: CompromiseRemedy, marked: Bool, last: CompromiseRemedy?) h=764c5a5b722b27d7 @641863f2
    static func compromiseStep(_ action: SessionDisk.CompromiseRemedy, marked: Bool,
                               last: SessionDisk.CompromiseRemedy?) -> CompromiseStep {
        if marked { return .perform }
        if last == action { return .already }
        // Unmarked with no record: a clear has nothing left to do; a wipe
        // can't say the disk was erased.
        return action == .clear && last == nil ? .already : .undone
    }

    /// What a compromise wipe erases of a VM (macOS: SessionDisk.wipeForCompromise's
    /// list, in the daemon's layout): the system disk, the home and data
    /// images, their checkpoints, the saved state, the meta share and the
    /// outbox. The profile (settings, credentials, keys) stays.
    // @port-skip linux-only: wipeForCompromise's contaminated list over the daemon's VM directory
    static func compromiseWipeTargets(vmDir: String) -> [String] {
        ["/disk.raw", "/home.img", "/data.img", "/checkpoints", "/snapshot", "/meta", "/outbox"].map { vmDir + $0 }
    }

    /// `POST /profiles/<id>/compromised {"action": "wipe" | "clear"}`: a fat
    /// client's "Wipe and Restore…" / "Clear Compromised Mark…" (macOS:
    /// automationCompromise and resolveCompromise). A wipe needs the VM
    /// stopped (a suspended one's saved state goes with it); a clear keeps
    /// the disk. A mark resolved the other way meanwhile is said, never
    /// reported as done.
    // @port ACAppDelegate.automationCompromise(_: String, _: String) h=28d2887ce4c1a943 @641863f2
    // @port SessionDisk.clearCompromised() h=148e625558c8d4ef @e81ff085
    // @port SessionDisk.clearCompromisedAsFalseAlarm() h=5f1a2f8c14587c10 @e81ff085
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onCompromise h=85d4565eef215859 @d3ebbda2
    // partial: POST /profiles/<id>/compromised {wipe|clear}. No dismisser for a pending wipe question (Linux has none)
    // @port ACAppDelegate.resolveCompromise(_: Profile, _: CompromiseRemedy) h=736d84da481c5181 @d3ebbda2
    func resolveCompromise(_ key: String, action: String) async -> ControlResponse {
        guard let how = SessionDisk.CompromiseRemedy(rawValue: action) else {
            return ControlResponse(400, ["ok": false, "error": "action must be wipe or clear"])
        }
        guard let profile = Self.workspace(key) else { return ControlResponse(404, ["ok": false, "error": "workspace not found"]) }
        let store = profileStore
        let marked = Self.isCompromised(profile, store: store)
        let step = Self.compromiseStep(how, marked: marked, last: Self.lastCompromiseResolution(profile, store: store))
        func refused(_ why: String) -> ControlResponse { ControlResponse(409, ["ok": false, "error": .string(why)]) }
        switch (how, step) {
        case (_, .already):
            return ControlResponse(200, ["ok": true])
        case (.wipe, .undone):
            return refused("Its compromised mark was cleared meanwhile, so nothing was wiped: it starts on its current disk.")
        case (.clear, .undone):
            return refused("It was already wiped: its disk and home were erased, and it boots fresh next time.")
        case (.clear, .perform):
            let url = Self.compromiseMarkURL(profile, store: store)
            do { try FileManager.default.removeItem(at: url) } catch {
                return ControlResponse(500, ["ok": false, "error": .string("the mark couldn't be removed: \(error.localizedDescription)")])
            }
            Self.recordCompromiseResolution(.clear, profile, store: store)
            FileHandle.standardError.write(Data("[compromise] mark cleared on \(profile.name) (\(profile.id)) by the user\n".utf8))
            BACEventEmitter.shared.emitDetached(profileID: profile.id, eventType: "vm.compromise_cleared",
                                                eventData: ["reason": .string("false alarm")])
            return ControlResponse(200, ["ok": true])
        case (.wipe, .perform):
            return await wipeCompromised(profile)
        }
    }

    /// The wipe (macOS: wipeCompromised + SessionDisk.wipeForCompromise):
    /// refused while the VM's disks are in use; anything left after it
    /// keeps the workspace marked.
    // @port ACAppDelegate.wipeCompromised(profile: Profile) h=aac0aae62f8a7fb9 @641863f2
    // partial: no tabs.json, EFI store, home backup or bootstrap home on Linux to erase
    // @port SessionDisk.wipeForCompromise() h=7313bf76da978491 @e81ff085
    // partial: same text inline in the 500 reply
    // @port ACAppDelegate.static wipeFailedMessage(_: [String]) h=e401d322b98f792a @d3ebbda2
    func wipeCompromised(_ profile: Profile) async -> ControlResponse {
        let key = profile.id.uuidString.lowercased()
        if let rec = registry.find(key) {
            guard live[key] == nil, !starting.contains(key), !repairMarks.contains(key), !hasRescue(for: key),
                  rec.state == .stopped || rec.state == .suspended else {
                return ControlResponse(409, ["ok": false, "error": "Shut the workspace down first: its disk is in use."])
            }
        }
        let fm = FileManager.default
        // A UUID-named directory of ours: the targets are its files.
        let targets = Self.compromiseWipeTargets(vmDir: vmDir(key))
        for t in targets { try? fm.removeItem(atPath: t) }
        let left = targets.filter { fm.fileExists(atPath: $0) }
        guard left.isEmpty else {
            let names = left.map { ($0 as NSString).lastPathComponent }
            FileHandle.standardError.write(Data("[compromise] wipe of \(profile.name) left \(left) -- still marked\n".utf8))
            return ControlResponse(500, ["ok": false, "error": .string(
                "Some of its files couldn't be erased (\(names.joined(separator: ", "))), so it's still marked compromised. Shut it down and try again.")])
        }
        // Its saved state went with it: it boots fresh.
        if var rec = registry.find(key), rec.state == .suspended {
            rec.state = .stopped
            try? registry.upsert(rec)
        }
        try? fm.removeItem(at: Self.compromiseMarkURL(profile, store: profileStore))
        Self.recordCompromiseResolution(.wipe, profile, store: profileStore)
        FileHandle.standardError.write(Data("[compromise] \(profile.name) (\(profile.id)) wiped by the user\n".utf8))
        // macOS: emitDiskResetEvent(reason: "compromised").
        BACEventEmitter.shared.emitDetached(profileID: profile.id, eventType: "vm.disk_reset",
                                            eventData: ["reason": .string("compromised")])
        return ControlResponse(200, ["ok": true])
    }
}

extension Daemon {
    /// Tests: the owner's answer to the wipe question, by workspace (nil: asked through the broker).
    static let wipeAnswerForTesting = NIOLockedValueBox<(@Sendable (UUID) async -> Int)?>(nil)

    /// A start of a workspace marked compromised: its owner is asked to wipe
    /// it (Wipe and Launch / Cancel; nobody answering is Cancel, never a
    /// wipe), through the client, as macOS asks a remote start. nil: wiped,
    /// boot it; otherwise why it didn't start.
    // partial: an unattended start (an agent's, an automation's) is refused, as before: nobody to ask
    // @port ACAppDelegate.confirmWipeAndProceedAsync(profile: Profile) h=55b2cb4c6b8adf35 @d3ebbda2
    // partial: the answer and the wipe's outcome mapped inline (wipeCompromised's reply)
    // @port ACAppDelegate.static compromiseWipe(confirmed: Bool, wiped: ()->CompromiseWipeStep) h=520e47ef500f357c @d3ebbda2
    func resolveCompromisePrompt(_ rec: VMRecord, _ profile: Profile, unattended: Bool) async -> ControlResponse? {
        if unattended {
            return .error(409, "'\(rec.name)' is marked compromised (a credential was sent to the wrong host): "
                          + "wipe it (POST /profiles/<id>/compromised {\"action\":\"wipe\"}) or clear the mark ({\"action\":\"clear\"})",
                          ["compromised": .bool(true)])
        }
        guard launchQuestions.begin(profile.id) else {
            return .error(409, "'\(rec.name)' already has a question up: answer it first")
        }
        let (title, info) = Self.compromisePromptParts(profile: profile)
        let answer: Int
        if let hook = Self.wipeAnswerForTesting.withLockedValue({ $0 }) {
            answer = await hook(profile.id)
        } else {
            answer = await PendingPromptBroker.shared.askAsync(
                profileID: profile.id, title: title, message: info,
                buttons: [NSLocalizedString("Wipe and Launch", comment: ""), NSLocalizedString("Cancel", comment: "")],
                fallback: 1)
        }
        launchQuestions.end(profile.id)
        guard answer == 0 else {
            return ControlResponse(409, ["ok": false, "cancelled": true, "error": "Not started: it's still marked compromised."])
        }
        guard registry.find(rec.id) != nil else { return .error(404, "'\(rec.name)' was removed") }
        // Cleared as a false alarm while the question was up: nothing wiped, not started.
        guard Self.isCompromised(profile, store: profileStore) else {
            let (title, message) = Self.markClearedParts(profile.name)
            return .error(409, title + ": " + message)
        }
        let wiped = await wipeCompromised(profile)
        switch wiped.status {
        case 200: return nil
        case 409:
            // Started meanwhile (an automation): not wiped, still marked.
            let (title, message) = Self.wipeSkippedParts(profile.name)
            return .error(409, title + ": " + message)
        default: return wiped
        }
    }

    /// The wipe question's title and text, shared folders listed (they're not wiped).
    // @port ACAppDelegate.static compromisePromptParts(profile: Profile) h=352fe8802d8fbdd7 @d3ebbda2
    static func compromisePromptParts(profile: Profile) -> (title: String, info: String) {
        let title = String(
            format: NSLocalizedString("⛔ “%@” is marked as compromised", comment: ""),
            profile.name)
        var info = NSLocalizedString(
            "Bromure refused to boot this VM because the proxy detected an outbound credential leak in a previous session.",
            comment: "")
        info += "\n\n"
        info += NSLocalizedString(
            "To continue, the VM disk image and the persistent home folder must be wiped. Your tokens, ssh keys, and workspace settings are preserved.",
            comment: "")
        let shares = profile.folderPaths
        if !shares.isEmpty {
            info += "\n\n"
            info += NSLocalizedString(
                "WARNING: shared folders are NOT wiped. Compromised packages or files may still be present in:",
                comment: "")
            info += "\n"
            for path in shares {
                info += "  • \(path)\n"
            }
            info += NSLocalizedString(
                "Inspect those folders before launching anything that re-uses them.",
                comment: "")
        }
        return (title, info)
    }

    // @port ACAppDelegate.static markClearedParts(_: String) h=8c2a7f2a145a4295 @d3ebbda2
    static func markClearedParts(_ name: String) -> (title: String, message: String) {
        (String(format: NSLocalizedString("“%@” wasn't wiped", comment: "compromise wipe skipped"), name),
         NSLocalizedString(
            "Its compromised mark was cleared as a false alarm while the question was up, so nothing was wiped and it didn't start. Start it again to boot it on its current disk.",
            comment: "compromise wipe skipped"))
    }

    // @port ACAppDelegate.static wipeSkippedParts(_: String) h=9666400fa5ad2e04 @d3ebbda2
    static func wipeSkippedParts(_ name: String) -> (title: String, message: String) {
        (String(format: NSLocalizedString("“%@” wasn't wiped", comment: "compromise wipe skipped"), name),
         NSLocalizedString(
            "It started on its current disk while the question was up (an automation launched it), so nothing was wiped and it's still marked compromised. Shut it down and start it again to wipe it.",
            comment: "compromise wipe skipped"))
    }
}
