import Foundation

/// A stand-in leaving the VM for a host it isn't bound to (macOS:
/// HTTPProxy's detectCompromise step, and the app delegate's
/// handleCompromise): the request is refused (451) and recorded, and the
/// workspace's VM is paused while its owner is asked, through the client
/// (PendingPromptBroker, as macOS asks a headless or mirrored session):
/// Shut down (the workspace is marked compromised and won't boot until
/// the mark is cleared), Block (just that request; the VM resumes), or
/// Allow (the host becomes one of the credential's destinations for the
/// session; the VM resumes). No answer in 180 s is a shut down.
extension Daemon {
    /// Hands the proxy's compromise events to handleCompromise (macOS:
    /// engine.swapper.setCompromiseHandler at launch).
    // @port-skip linux-only: the daemon's share of ACAppDelegate's compromise handler wiring
    func wireCompromiseHandler() {
        mitm?.swapper.setCompromiseHandler { [weak self] event in
            Task { await self?.handleCompromise(event) }
        }
    }

    /// The paused VM, the question, and its answer applied.
    // partial: Save for Investigation needs a local folder picker (macOS-only, as on a headless Mac); strict-credential approvals come with UnmanagedCredentialGuard
    // @port ACAppDelegate.handleCompromise(_: CompromiseEvent) h=e4f537275a5a956e @a0266d0e
    func handleCompromise(_ event: CompromiseEvent) async {
        let pid = event.profileID
        guard let profile = profileStore.loadAll().first(where: { $0.id == pid }) else { return }
        // The workspace's opt-out: the proxy refused the request and recorded
        // it; no question, no pause.
        if profile.disableExfiltrationAlerts { return }
        // One question at a time per workspace (a retried leak fires again).
        guard compromiseAsking.insert(pid).inserted else { return }
        defer { compromiseAsking.remove(pid) }
        guard let id = runningVMID(of: pid), let machine = live[id]?.machine else { return }
        do { try await machine.pause() } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': compromise: pause failed (\(error))\n".utf8))
        }
        let (title, message) = Self.compromiseQuestion(event, workspace: profile.name)
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': compromise: VM paused at \(Date()); asking \(PendingPromptBroker.hasLiveListener() ? "the client" : "nobody (no client watching: shut down)")\n".utf8))
        let choice = await PendingPromptBroker.shared.askAsync(
            profileID: pid, title: title, message: message,
            buttons: ["Shut down", "Block", "Allow"], fallback: 0, timeout: 180)
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': compromise: answer \(choice) at \(Date()) (a client watching: \(PendingPromptBroker.hasLiveListener()))\n".utf8))
        switch choice {
        case 2:
            // The user vouches for the destination: the credential may go
            // there for the rest of the session (cleared at teardown).
            let hosts = Array(Set(event.leaks.map(\.observedHost)))
            mitm?.swapper.allowSessionHosts(hosts, for: pid)
            for host in hosts {
                BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "credential.exfiltration_allowed",
                                                    eventData: ["observed_host": .string(host), "scope": .string("session")])
            }
            try? await machine.resume()
        case 1:
            // Just that request (already refused); a retry asks again.
            try? await machine.resume()
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
            "• \($0.fakeTokenPreview) (\($0.credentialDisplayName)): meant for \($0.declaredHost), sent to \($0.observedHost)"
        }
        return ("“\(workspace)” tried to send a credential to the wrong host",
                "The VM is paused. Bromure blocked the request:\n" + lines.joined(separator: "\n")
                + "\nAllow trusts this destination for the rest of this session (the credential will be sent there). "
                + "Block stops just this request. Shutting the VM down is the safest choice.")
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
        guard let profile = Self.workspace(key) else { return .error(404, "workspace not found") }
        switch action {
        case "clear":
            let url = Self.compromiseMarkURL(profile, store: profileStore)
            guard FileManager.default.fileExists(atPath: url.path) else { return ControlResponse(200, ["ok": true]) }
            try? FileManager.default.removeItem(at: url)
            try? Data("clear".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("compromise.resolved"), options: .atomic)
            BACEventEmitter.shared.emitDetached(profileID: profile.id, eventType: "vm.compromise_cleared",
                                                eventData: ["reason": .string("false alarm")])
            return ControlResponse(200, ["ok": true])
        case "wipe":
            return .error(501, "wiping a compromised workspace isn't on Linux yet: clear the mark (a false alarm) or remove the workspace")
        default:
            return .error(400, "action must be wipe or clear")
        }
    }
}
