import AppKit

/// The agent host as a bromure.io device. Enrolled, it holds the device
/// channel (an outbound WebSocket) and answers connection offers with TURN
/// relay candidates only (`P2PBroker.relayOnly`), and the relay leg — which
/// this Mac dials out to — is spliced into the loopback-only sshd. Nothing
/// ever connects in. Clients authenticate with the account's device keys,
/// synced into authorized_keys the way bromure-ac's Remote Access does.
@MainActor
final class P2PAccount {
    static let shared = P2PAccount()

    /// The URL scheme bromure.io's enroll page hands the code back to when
    /// it was opened with `app=agent-host` (bromure:// belongs to Bromure AC).
    static let urlScheme = "bromure-agent-host"
    static let accountKeyMarker = "bromure-account:"
    /// Where a Bromure AC on this Mac finds the handoff we started, so it can
    /// pass on a `bromure://enroll` link that landed on it instead.
    static var pendingStateFile: URL { AgentHostPaths.support.appendingPathComponent("pending-enroll-state") }

    private(set) var lastError: String?
    /// The account's servers this Mac can attach to (online, not itself).
    private(set) var servers: [DeviceInfo] = []
    private(set) var enrolling = false
    private var syncTimer: Timer?
    private var keysObserver: NSObjectProtocol?
    private var sshPort = 0

    var identity: P2PIdentity? { P2PIdentity.current() }

    static var isAgentHostDevice: Bool {
        if case .found(let rec) = DeviceIdentityStore.load() { return rec.capability == "agent-host" }
        return false
    }
    var isEnrolled: Bool { identity != nil }
    var deviceName: String { ControlServer.machineName }

    func start(sshPort: Int) {
        self.sshPort = sshPort
        P2PBroker.relayOnly = true
        guard isEnrolled else { return }
        P2PBroker.shared.startServing(sshPort: sshPort)
        startKeySync()
        AgentHostLog.log("p2p: serving (relay only) as device \(identity?.installId ?? "?")")
    }

    // MARK: Enrollment

    /// Open bromure.io's device handoff; it comes back as
    /// `bromure-agent-host://enroll?code=…&state=…`.
    func beginSignIn() {
        let state = UUID().uuidString
        try? state.write(to: Self.pendingStateFile, atomically: true, encoding: .utf8)
        lastError = nil
        var comps = URLComponents(string: "https://bromure.io/app/enroll")!
        comps.queryItems = [
            URLQueryItem(name: "capability", value: "agent-host"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "app", value: "agent-host"),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    /// A handed-back link (URL scheme), or one pasted by hand. A link with a
    /// `state` must be the handoff we started.
    func complete(_ raw: String) {
        guard let link = EnrollLink(parsing: raw) else {
            lastError = "That isn't an enrollment link or code."
            return
        }
        if let state = URLComponents(string: raw)?.queryItems?.first(where: { $0.name == "state" })?.value {
            let pending = (try? String(contentsOf: Self.pendingStateFile, encoding: .utf8)) ?? ""
            guard state == pending else {
                AgentHostLog.log("p2p: ignored an enroll link we didn't start")
                return
            }
        }
        try? FileManager.default.removeItem(at: Self.pendingStateFile)
        // A re-enroll replaces the device: drop the old one's channel first,
        // so serving comes back up as the new one.
        P2PBroker.shared.stopServing()
        enrolling = true
        let name = deviceName
        Task {
            let result = await P2PEnroll.enroll(link: link, deviceName: name)
            enrolling = false
            switch result {
            case .success(let r):
                lastError = nil
                AgentHostLog.log("p2p: enrolled as device \(r.record.deviceId)")
                start(sshPort: sshPort)
            case .failure(let e):
                lastError = "Sign-in failed: \(e)"
                AgentHostLog.log("p2p: enroll failed: \(e)")
            }
            NotificationCenter.default.post(name: SessionEngine.didChange, object: nil)
        }
    }

    func signOut() {
        if let (client, bearer) = ControlPlaneClient.current() {
            Task { _ = try? await client.setServerMode(bearer: bearer, enabled: false) }
        }
        P2PBroker.shared.stopServing()
        syncTimer?.invalidate(); syncTimer = nil
        if let keysObserver { NotificationCenter.default.removeObserver(keysObserver) }
        keysObserver = nil
        DeviceIdentityStore.erase()
        UserDefaults.standard.removeObject(forKey: "p2p.published")
        servers = []
        RemoteAccessServer.shared.setManagedKeys(marker: Self.accountKeyMarker, lines: [])
    }

    // MARK: Account keys

    func refreshServers() {
        guard let (client, bearer) = ControlPlaneClient.current() else { return }
        Task {
            guard let devices = try? await client.listDevices(bearer: bearer) else { return }
            // Other Bromure Sidecar Macs aren't servers: nothing to attach to.
            servers = devices.filter { !$0.isSelf && !$0.revoked && $0.online && !$0.isAgentHost }
        }
    }

    private func startKeySync() {
        syncKeys()
        refreshServers()
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            MainActor.assumeIsolated { P2PAccount.shared.syncKeys(); P2PAccount.shared.refreshServers() }
        }
        if keysObserver == nil {
            keysObserver = NotificationCenter.default.addObserver(
                forName: .bromureAccountKeysChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { P2PAccount.shared.syncKeys() }
            }
        }
    }

    /// Authorize the account's device keys (Bromure AC on your other Macs,
    /// phones, iPads), and publish this Mac's client key and login: the key
    /// is how the account's servers let it attach (MachineLinker).
    func syncKeys() {
        guard let (client, bearer) = ControlPlaneClient.current(), let key = ClientKey.publicLine else { return }
        // Servers only restrict a key whose device bromure.io knows as an
        // `agent-host`; one enrolled otherwise (an enroll page from before
        // that capability) would publish a key servers trust fully — so it
        // publishes nothing and can't attach remotely.
        guard Self.isAgentHostDevice else {
            lastError = "Enrolled without the agent-host capability — sign out and sign in again to attach to servers."
            return
        }
        let user = NSUserName()
        // Per device: a re-enrollment is a new device, whose key isn't up yet.
        let device = identity?.installId ?? ""
        let published = device + " " + user + " " + key
        let publish = UserDefaults.standard.string(forKey: "p2p.published") != published
        Task {
            if publish {
                do {
                    try await client.uploadSSHKey(bearer: bearer, sshPublicKey: key, sshUsername: user)
                    UserDefaults.standard.set(published, forKey: "p2p.published")
                } catch {
                    AgentHostLog.log("p2p: publishing the login failed: \(error)")
                }
            }
            guard let keys = try? await client.listSSHKeys(bearer: bearer) else { return }
            let lines: [String] = keys.compactMap { k in
                let p = k.sshPublicKey.split(separator: " ").map(String.init)
                guard p.count >= 2 else { return nil }
                return "\(p[0]) \(p[1]) \(k.authorizedKeysComment)"
            }
            RemoteAccessServer.shared.setManagedKeys(marker: Self.accountKeyMarker, lines: lines)
        }
    }
}
