import Foundation
import NIOConcurrencyHelpers
import Glibc

/// Imported SSH keys (macOS: the editor's "Import key…" and "Add keys from a
/// host ssh-agent"): a key file copied into the workspace's host-only
/// `agent/imported/`, its passphrase in the encrypted vault, ssh-add'ed at
/// launch into the workspace's own ssh-agent process, which the shared
/// SSHAgentServer forwards the guest's requests to; or a key picked out of
/// a host agent, forwarded there alone. Each key's "ask before use" gate is
/// the agent server's.

/// Imported keys' passphrases (macOS: the Keychain's generic-password items
/// under the same service and account), as vault items.
enum PassphraseKeychain {
    private static let service = "io.bromure.agentic-coding.ssh-key-passphrases"

    // @port PassphraseKeychain.static account(profileID: UUID, filename: String) h=0d587d6a5efe0bcc @fa9bef09
    private static func account(profileID: UUID, filename: String) -> String {
        "\(profileID.uuidString)/\(filename)"
    }

    // @port PassphraseKeychain.static set(passphrase: String, profileID: UUID, filename: String) h=d36301383587e0c2 @fa9bef09
    static func set(passphrase: String, profileID: UUID, filename: String) throws {
        try VaultItems.set(Data(passphrase.utf8), service: service, account: account(profileID: profileID, filename: filename))
    }

    // @port PassphraseKeychain.static get(profileID: UUID, filename: String) h=3ec40f2cf4592b0d @fa9bef09
    static func get(profileID: UUID, filename: String) -> String? {
        guard let data = try? VaultItems.get(service: service, account: account(profileID: profileID, filename: filename)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // @port PassphraseKeychain.static delete(profileID: UUID, filename: String) h=70a3e74a7b9b2fbf @fa9bef09
    static func delete(profileID: UUID, filename: String) {
        VaultItems.delete(service: service, account: account(profileID: profileID, filename: filename))
    }
}

/// One workspace's own `ssh-agent -D -a <socket>` (macOS: PrivateSSHAgent):
/// an agent signs for every key it holds, so each workspace has its own,
/// its keys gone with it. Spawned as a ChildProcess (a clean signal mask:
/// Foundation's Process passed on the pool thread's, SIGTERM blocked, and
/// lost the exits), its socket in the daemon's 0700 runtime directory,
/// named after the daemon's pid so a later daemon can tell a gone one's.
// @port-skip linux-only: PrivateSSHAgent over ChildProcess, in the runtime directory
final class WorkspaceSSHAgent: Sendable {
    let socketPath: String
    private let process: ChildProcess

    // partial: WorkspaceSSHAgent over ChildProcess in the runtime dir (0700)
    // @port PrivateSSHAgent.init(label: String) h=0b00695be4a0e34b @db93af68
    init(directory: String, label: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = (directory as NSString).appendingPathComponent("bromure-ac-agent-\(getpid())-\(label).sock")
        try? FileManager.default.removeItem(atPath: path)
        let p = try ChildProcess(name: "ssh-agent", executable: "/usr/bin/ssh-agent", arguments: ["-D", "-a", path],
                                 logPath: "/dev/null")
        try p.start()
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline { usleep(10_000) }
        guard FileManager.default.fileExists(atPath: path) else {
            p.signal(SIGKILL)
            throw MachineError.invalidConfig("ssh-agent failed to bind \(path)")
        }
        socketPath = path
        process = p
    }

    /// Its keys die with it.
    // @port PrivateSSHAgent.terminate() h=f373b1716b689b98 @db93af68
    func terminate() {
        _ = process.signal(SIGTERM)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // @port-skip linux-only: tests
    var exitStatus: Int32? { process.exitStatus }

    /// Its process id (what a host-agent connection's peer is checked against).
    // @port-skip linux-only: see WorkspaceSSHAgent
    var pid: Int32 { process.pid }

    /// The workspace agents a gone daemon left (one that crashed, or was
    /// restarted): an `ssh-agent -a …/bromure-ac-agent-<pid>-<label>.sock`
    /// whose <pid> isn't us and no longer runs, with its socket. Another
    /// live daemon's (the same user's test daemons, a second instance) are
    /// never touched (macOS's reapOrphans kills every match: one app per
    /// user). `processes`: pid and argv of every process.
    // @port-skip linux-only: see WorkspaceSSHAgent
    static func orphans(_ processes: [(pid: pid_t, argv: [String])], ourPID: pid_t = getpid(),
                        alive: (pid_t) -> Bool) -> [(pid: pid_t, socket: String)] {
        processes.compactMap { p in
            guard (p.argv.first.map { ($0 as NSString).lastPathComponent } ?? "") == "ssh-agent",
                  let a = p.argv.firstIndex(of: "-a"), a + 1 < p.argv.count,
                  let owner = ownerPID(ofSocket: p.argv[a + 1]), owner != ourPID, !alive(owner) else { return nil }
            return (p.pid, p.argv[a + 1])
        }
    }

    /// The daemon pid in an agent socket's name (bromure-ac-agent-<pid>-<label>.sock).
    // @port-skip linux-only: see orphans
    static func ownerPID(ofSocket path: String) -> pid_t? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("bromure-ac-agent-"), name.hasSuffix(".sock") else { return nil }
        return pid_t(name.dropFirst("bromure-ac-agent-".count).prefix { $0 != "-" })
    }

    /// SIGTERM a gone daemon's agents (their keys die with them) and drop
    /// their sockets. Run once at the proxy's start, before any agent of
    /// ours (macOS: the engine's reapOrphans).
    // partial: reaps by socket owner PID liveness via /proc, not pgrep
    // @port PrivateSSHAgent.static reapOrphans() h=74de724600ba98cb @db93af68
    static func reapOrphansOfGoneDaemons() {
        func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
        var processes: [(pid: pid_t, argv: [String])] = []
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
            guard let pid = pid_t(entry), let argv = ProcFS.argv(pid) else { continue }
            processes.append((pid, argv))
        }
        let found = orphans(processes, alive: alive)
        for o in found {
            kill(o.pid, SIGTERM)
            try? FileManager.default.removeItem(atPath: o.socket)
        }
        if !found.isEmpty {
            FileHandle.standardError.write(Data("[mitm] reaped \(found.count) ssh-agent(s) of a gone bromure-ac daemon\n".utf8))
        }
    }
}

extension MitmProxy {
    /// This workspace's ssh-agent socket, spawning the agent on first use.
    /// nil only if ssh-agent itself failed to start — never another
    /// workspace's socket.
    // partial: a WorkspaceSSHAgent in the daemon's runtime directory (macOS: a PrivateSSHAgent in the temporary one)
    // @port MitmEngine.sshAgentSocket(for: UUID) h=ebaaccbc1be48941 @79b2d8c0
    func sshAgentSocket(for profileID: UUID) -> String? {
        sshAgents.withLockedValue { agents in
            if let existing = agents[profileID] { return existing.socketPath }
            do {
                // 8 hex chars keeps the socket path inside sun_path's 108 bytes.
                let label = String(profileID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
                let agent = try WorkspaceSSHAgent(directory: sshAgentDirectory.withLockedValue { $0 }, label: label)
                agents[profileID] = agent
                HostAgentClient.register(socketPath: agent.socketPath, for: profileID)
                return agent.socketPath
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] ssh-agent spawn failed for profile \(profileID.uuidString.prefix(8)): \(error)\n".utf8))
                return nil
            }
        }
    }

    /// Ask a workspace's agent to drop its own key (SSH_AGENTC_REMOVE_IDENTITY)
    /// before it goes: best effort, as macOS does; terminating the agent is
    /// what guarantees the key is gone.
    // @port ACAppDelegate.removeKeyFromHostAgent(publicKey: Data, profileID: UUID) h=0d8a0944bfd349b5 @4bd8405e
    static func removeKeyFromHostAgent(publicKey: Data, profileID: UUID) {
        guard let host = HostAgentClient.client(for: profileID) else { return }
        let blob = OpenSSHKeyFormat.ed25519PublicBlob(publicKey: publicKey)
        // SSH_AGENTC_REMOVE_IDENTITY = 18; payload = ssh-string(blob).
        var msg = Data([18])
        var len = UInt32(blob.count).bigEndian
        msg.append(Data(bytes: &len, count: 4))
        msg.append(blob)
        _ = host.request(msg)
    }

    /// Kill one workspace's agent — its keys exist only in that process,
    /// so this is what makes them unreachable at session end.
    // @port MitmEngine.terminateSSHAgent(for: UUID) h=2aea26d842f5ee90 @79b2d8c0
    func terminateSSHAgent(for profileID: UUID) {
        let agent = sshAgents.withLockedValue { $0.removeValue(forKey: profileID) }
        HostAgentClient.unregister(profileID: profileID)
        agent?.terminate()
    }

    /// The pids of the workspaces' agents this proxy runs.
    // @port-skip linux-only: the host-agent peer check
    var sshAgentPIDs: Set<Int32> { sshAgents.withLockedValue { Set($0.values.map(\.pid)) } }

    /// A host-agent connection reaching one of this proxy's own workspace
    /// agents (its peer's pid, SO_PEERCRED), or a peer it can't tell: refused
    /// (HostAgentClient.refusesHostAgentPeer), at every connect — a symlink
    /// repointed after the import, or a profile saved before the check,
    /// would otherwise let a workspace sign with a sibling's keys.
    // @port-skip linux-only: the host-agent peer check
    func refusesHostAgentPeer(_ fd: Int32) -> Bool {
        var cred = LANPeerCred()
        var len = socklen_t(MemoryLayout<LANPeerCred>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0 else { return true }
        return sshAgentPIDs.contains(cred.pid)
    }

    /// The daemon's stop: every workspace's agent at once.
    // @port MitmEngine.terminateAllSSHAgents() h=0ecfdb04a0e7ce28 @79b2d8c0
    func terminateAllSSHAgents() {
        let all = sshAgents.withLockedValue { a in defer { a.removeAll() }; return a }
        for (pid, agent) in all {
            HostAgentClient.unregister(profileID: pid)
            agent.terminate()
        }
    }
}

extension Daemon {
    /// The workspace's keys into the agents at launch (or a taken-back VM's,
    /// whose agent died with the previous daemon): its own key in process
    /// and in its ssh-agent, the imported ones ssh-add'ed there (their
    /// passphrases from the vault), each imported key's gate, and the keys
    /// picked out of host agents (macOS: launch's agent block).
    // @port-skip linux-only: the agent block of ACAppDelegate.launch, for a Linux launch and a re-adoption
    func loadWorkspaceSSHKeys(_ profile: Profile) async {
        guard let mitm else { return }
        let store = profileStore
        let keys = Self.loadAgentKeys(for: profile, store: store)
        mitm.sshAgent.setKeys(keys, for: profile.id)
        // The gates first: the agent is reachable from the guest as soon as
        // it's registered (a taken-back VM runs), so no imported key may be
        // in it, even for a moment, before its "ask before use" applies.
        mitm.sshAgent.setImportedKeyApprovals(Self.importedKeyApprovals(profile), for: profile.id)
        mitm.sshAgent.setHostAgentKeys(Self.hostAgentKeys(profile), for: profile.id)
        Self.sshAgentRegisteredForTesting.withLockedValue { $0 }?(profile.id)
        let askpassDir = config.runtimeDir
        let needsAgent = !keys.isEmpty || profile.importedSSHKeys.contains { !$0.isFromHostAgent }
        if needsAgent, let socket = mitm.sshAgentSocket(for: profile.id) {
            let dir = store.profileDirectory(for: profile)
            await Task.detached {
                for key in keys {
                    Self.addKeyToHostAgent(seed: key.seed, publicKey: key.publicKey,
                                           comment: "bromure-ac:\(profile.name)", agentSocket: socket)
                }
                Self.loadImportedSSHKeys(for: profile, profileDirectory: dir, agentSocket: socket, askpassDir: askpassDir)
            }.value
        }
    }

    /// Tests: called once the gates are set, before the agent is made or
    /// any key goes into it.
    static let sshAgentRegisteredForTesting = NIOLockedValueBox<(@Sendable (UUID) -> Void)?>(nil)

    /// What a crash during an ssh-add or ssh-keygen left: its askpass
    /// script (a passphrase in it) in the runtime directory. Swept at
    /// start, before any import or launch.
    // @port-skip linux-only: the askpass scripts' sweep (macOS's live in a temporary directory the OS clears)
    nonisolated static func sweepAskpassScripts(in dir: String) {
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            where entry.hasPrefix("askpass-") && (entry.hasSuffix(".sh") || entry.hasSuffix(".sh.used")) {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(entry))
        }
    }

    /// Why a host agent socket may not be used: one of this daemon's own
    /// (a workspace's private agent: another workspace would sign with its
    /// keys past its gates), or, on a shared server, one under a directory
    /// the daemon's sandbox hides (ProtectHome, PrivateTmp).
    // @port-skip linux-only: host-agent sockets on a server
    func hostAgentSocketRefusal(_ socket: String) -> String? {
        guard let path = HostAgentClient.resolveHostSocket(socket) else { return nil }
        return Self.hostAgentSocketRefusal(path: path, ownDirectories: [config.runtimeDir, mitm?.sshAgentDirectory.withLockedValue { $0 }].compactMap { $0 },
                                           multiUser: config.multiUser)
    }

    // @port-skip linux-only: see hostAgentSocketRefusal
    nonisolated static func hostAgentSocketRefusal(path: String, ownDirectories: [String], multiUser: Bool) -> String? {
        // A relative path would connect relative to the daemon's cwd.
        guard path.hasPrefix("/") else { return "\(path) isn't an absolute path" }
        let real = ((path as NSString).resolvingSymlinksInPath as NSString).standardizingPath
        let own = ownDirectories.map { (($0 as NSString).resolvingSymlinksInPath as NSString).standardizingPath }
        for dir in own where real == dir || real.hasPrefix(dir + "/") {
            return "\(path) is one of this server's own agents, not a host agent"
        }
        if multiUser, ["/home", "/tmp", "/run/user"].contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
            return "a shared server's daemon can't see \(path) (its sandbox hides /home, /tmp and /run/user): use an agent socket outside them"
        }
        return nil
    }

    /// Add the per-profile key to the workspace's private ssh-agent, from
    /// stdin (`ssh-add -`): in memory only, never a file.
    // partial: the agent socket is the caller's (macOS looks it up here)
    // @port ACAppDelegate.addKeyToHostAgent(seed: Data, publicKey: Data, comment: String, profileID: UUID) h=2b3910cd19102fb5 @2134fc7a
    nonisolated static func addKeyToHostAgent(seed: Data, publicKey: Data, comment: String, agentSocket: String) {
        let pem = OpenSSHKeyFormat.ed25519PEM(seed: seed, publicKey: publicKey, comment: comment)
        do {
            _ = try sshTool("/usr/bin/ssh-add", ["-"], env: ["SSH_AUTH_SOCK": agentSocket], input: pem, timeout: 15)
        } catch {
            FileHandle.standardError.write(Data("[mitm] ssh-add failed: \(error)\n".utf8))
        }
    }

    /// An OpenSSH tool run to completion (ChildProcess: Foundation's Process
    /// lost short-lived children's exits here), with `env` added to the
    /// daemon's environment through env(1) — paths only, never a secret:
    /// a passphrase goes through an askpass file, key bytes through stdin.
    // partial: ssh-add bounded by sshTool's timeout: 15
    // @port ACAppDelegate.static runBounded(_: Process, seconds: TimeInterval) h=ceeb73afee10097e @d3ebbda2
    nonisolated static func sshTool(_ tool: String, _ arguments: [String], env: [String: String],
                                    input: Data?, timeout: TimeInterval) throws -> Data {
        try ChildProcess.capture("/usr/bin/env", env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + [tool] + arguments,
                                 input: input ?? Data(), timeout: timeout)
    }

    /// ssh-add each of the profile's imported key files into its agent.
    // partial: the agent socket and directories are the caller's
    // @port ACAppDelegate.loadImportedSSHKeys(for: Profile) h=67ed87709dce47af @2134fc7a
    nonisolated static func loadImportedSSHKeys(for profile: Profile, profileDirectory: URL, agentSocket: String, askpassDir: String) {
        let importedDir = profileDirectory.appendingPathComponent("agent/imported", isDirectory: true)
        for key in profile.importedSSHKeys where !key.isFromHostAgent {
            let path = importedDir.appendingPathComponent(key.filename).path
            guard !key.filename.isEmpty, FileManager.default.fileExists(atPath: path) else {
                FileHandle.standardError.write(Data("[mitm] imported key '\(key.label)' missing on disk (\(path))\n".utf8))
                continue
            }
            sshAddImportedKey(path: path, label: key.label,
                              passphrase: key.hasPassphrase ? PassphraseKeychain.get(profileID: profile.id, filename: key.filename) : nil,
                              agentSocket: agentSocket, askpassDir: askpassDir)
        }
    }

    /// `ssh-add <path>` into the agent, the passphrase through SSH_ASKPASS
    /// (answered once: a wrong one isn't offered again). The askpass script
    /// is made 0700 in the daemon's own 0700 runtime directory (never a
    /// shared /tmp, where it would be readable for a moment), and goes
    /// right after.
    // partial: the askpass script lives in the daemon's runtime dir, created 0700 (macOS: the temporary directory, chmod after); spawned through sshTool
    // @port ACAppDelegate.sshAddImportedKey(path: String, label: String, passphrase: String?, agentSocket: String) h=22d847d746e4f5f3 @2134fc7a
    nonisolated static func sshAddImportedKey(path: String, label: String, passphrase: String?, agentSocket: String, askpassDir: String) {
        let askpass = (askpassDir as NSString).appendingPathComponent("askpass-\(UUID().uuidString).sh")
        defer {
            try? FileManager.default.removeItem(atPath: askpass)
            try? FileManager.default.removeItem(atPath: askpass + ".used")
        }
        guard FileManager.default.createFile(atPath: askpass, contents: Data(askpassScript(passphrase: passphrase).utf8),
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)]) else {
            FileHandle.standardError.write(Data("[mitm] ssh-add (imported '\(label)'): no askpass in \(askpassDir)\n".utf8))
            return
        }
        do {
            _ = try sshTool("/usr/bin/ssh-add", [path],
                            env: ["SSH_AUTH_SOCK": agentSocket, "SSH_ASKPASS": askpass, "DISPLAY": ":0", "SSH_ASKPASS_REQUIRE": "force"],
                            input: nil, timeout: 15)
            FileHandle.standardError.write(Data("[mitm] added imported key '\(label)'\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[mitm] ssh-add (imported '\(label)') failed: \(error)\n".utf8))
        }
    }

    /// The askpass ssh-add runs for an imported key: the passphrase (when
    /// there is one) on its first call, a refusal after.
    // @port ACAppDelegate.static askpassScript(passphrase: String?) h=5df54a7a6bd2a6d4 @2134fc7a
    nonisolated static func askpassScript(passphrase: String?) -> String {
        guard let pass = passphrase, !pass.isEmpty else { return "#!/bin/sh\nexit 1\n" }
        let escaped = pass.replacingOccurrences(of: "'", with: "'\\''")
        return "#!/bin/sh\n[ -e \"$0.used\" ] && exit 1\n: > \"$0.used\"\nprintf '%s\\n' '\(escaped)'\n"
    }

    /// The imported keys whose signing asks first, by public-key blob.
    // @port ACAppDelegate.static importedKeyApprovals(_: Profile) h=d2d68597f99ddb7d @2134fc7a
    nonisolated static func importedKeyApprovals(_ profile: Profile) -> [Data: SSHAgentServer.ImportedApproval] {
        var approvals: [Data: SSHAgentServer.ImportedApproval] = [:]
        for k in profile.importedSSHKeys where k.requireApproval {
            guard let blob = sshPublicKeyBlob(fromOpenSSHText: k.publicKeyText) else { continue }
            approvals[blob] = SSHAgentServer.ImportedApproval(label: k.label, consentCredentialID: ConsentCredentialID.sshKey(k.id.uuidString))
        }
        return approvals
    }

    /// A running session's gates after a live edit: the saved profile's,
    /// plus every gate it holds for a key taken off the list (still loaded
    /// in the agent until the restart: it stays gated).
    // @port ACAppDelegate.static liveImportedKeyApprovals(running: [Data:SSHAgentServer.ImportedApproval], to: Profile) h=17368f6ffa533cfa @2134fc7a
    nonisolated static func liveImportedKeyApprovals(running: [Data: SSHAgentServer.ImportedApproval],
                                                     to new: Profile) -> [Data: SSHAgentServer.ImportedApproval] {
        var approvals = importedKeyApprovals(new)
        let listed = Set(new.importedSSHKeys.compactMap { sshPublicKeyBlob(fromOpenSSHText: $0.publicKeyText) })
        for (blob, a) in running where !listed.contains(blob) { approvals[blob] = a }
        return approvals
    }

    /// Host-agent keys the VM may see and sign with: blob → socket.
    // @port ACAppDelegate.static hostAgentKeys(_: Profile) h=94dcca148da25d07 @2134fc7a
    nonisolated static func hostAgentKeys(_ profile: Profile) -> [Data: String] {
        var keys: [Data: String] = [:]
        for k in profile.importedSSHKeys {
            guard let socket = k.hostAgentSocket, let blob = sshPublicKeyBlob(fromOpenSSHText: k.publicKeyText) else { continue }
            keys[blob] = socket
        }
        return keys
    }

    // @port ACAppDelegate.static sshPublicKeyBlob(fromOpenSSHText: String) h=3596519a56678c9b @2134fc7a
    // partial: instance wrapper of the static already ported
    // @port ACAppDelegate.sshPublicKeyBlob(fromOpenSSHText: String) h=ac937290c8c25624 @d3ebbda2
    nonisolated static func sshPublicKeyBlob(fromOpenSSHText text: String) -> Data? {
        let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first?.trimmingCharacters(in: .whitespaces) ?? ""
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }

    /// Copy a private key file into the workspace's host-only
    /// `agent/imported/` (renamed: a UUID prefix), its `.pub` beside it
    /// (copied, or derived with ssh-keygen), the passphrase into the vault.
    // partial: the passphrase goes to the vault (macOS: the Keychain); ssh-keygen gets it through SSH_ASKPASS, not argv; the public key is always derived (a given or sibling one only checked against it), and a key it can't read is refused
    // @port ACAppDelegate.importSSHKey(at: URL, passphrase: String?, label: String, for: Profile) h=f6470b0a6c91eaec @2134fc7a
    /// `savePassphrase` false: the caller saves it (on its own task, whose
    /// vault it is).
    /// `keyBytes`/`publicKey`: the file's contents as the client read them
    /// (a shared server's daemon can't see the user's /home), `sourceURL`
    /// then only naming it.
    nonisolated static func importSSHKey(at sourceURL: URL, passphrase: String?, label: String,
                                         for profile: Profile, profileDirectory: URL, askpassDir: String,
                                         savePassphrase: Bool = true, keyBytes: Data? = nil,
                                         publicKey: String? = nil) throws -> ImportedSSHKey {
        let importedDir = profileDirectory.appendingPathComponent("agent/imported", isDirectory: true)
        try FileManager.default.createDirectory(at: importedDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let basename = "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let dst = importedDir.appendingPathComponent(basename)
        guard let bytes = keyBytes ?? FileManager.default.contents(atPath: sourceURL.path) else {
            throw SSHKeyImportError("can't read \(sourceURL.path)")
        }
        guard FileManager.default.createFile(atPath: dst.path, contents: bytes,
                                             attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw SSHKeyImportError("can't write \(dst.path)")
        }
        // What the client says the public key is (sent, or the .pub beside
        // the file), only ever checked: the gates key on the blob, so it's
        // always the one the private key itself gives (ssh-keygen -y).
        var claimed = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for pubURL in [URL(fileURLWithPath: sourceURL.path + ".pub"), sourceURL.deletingPathExtension().appendingPathExtension("pub")]
            where keyBytes == nil && claimed.isEmpty {
            if let s = try? String(contentsOf: pubURL, encoding: .utf8) { claimed = s.trimmingCharacters(in: .whitespacesAndNewlines); break }
        }
        let trimmed = passphrase ?? ""
        func refuse(_ why: String) -> SSHKeyImportError {
            try? FileManager.default.removeItem(at: dst)
            return SSHKeyImportError(why)
        }
        guard let pubText = derivePublicKey(dst.path, passphrase: trimmed, askpassDir: askpassDir),
              let derivedBlob = sshPublicKeyBlob(fromOpenSSHText: pubText) else {
            throw refuse("not a private key ssh-keygen can read\(trimmed.isEmpty ? " (does it need a passphrase?)" : " with that passphrase")")
        }
        if !claimed.isEmpty, sshPublicKeyBlob(fromOpenSSHText: claimed) != derivedBlob {
            throw refuse("the public key given isn't this private key's")
        }
        try? pubText.appending("\n").write(to: importedDir.appendingPathComponent(basename + ".pub"), atomically: true, encoding: .utf8)
        if !trimmed.isEmpty, savePassphrase {
            do { try PassphraseKeychain.set(passphrase: trimmed, profileID: profile.id, filename: basename) } catch {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.removeItem(at: importedDir.appendingPathComponent(basename + ".pub"))
                throw error
            }
        }
        return ImportedSSHKey(label: label.isEmpty ? sourceURL.lastPathComponent : label, filename: basename,
                              publicKeyText: pubText, hasPassphrase: !trimmed.isEmpty)
    }

    /// The public key of a private key file (`ssh-keygen -y`), its
    /// passphrase through SSH_ASKPASS: never on a command line, which other
    /// users of the server can read.
    // @port-skip linux-only: importSSHKey's ssh-keygen -y step without the passphrase in argv
    nonisolated static func derivePublicKey(_ path: String, passphrase: String, askpassDir: String) -> String? {
        let askpass = (askpassDir as NSString).appendingPathComponent("askpass-\(UUID().uuidString).sh")
        defer {
            try? FileManager.default.removeItem(atPath: askpass)
            try? FileManager.default.removeItem(atPath: askpass + ".used")
        }
        guard FileManager.default.createFile(atPath: askpass, contents: Data(askpassScript(passphrase: passphrase).utf8),
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)]) else { return nil }
        guard let out = try? sshTool("/usr/bin/ssh-keygen", ["-y", "-f", path],
                                     env: ["SSH_ASKPASS": askpass, "DISPLAY": ":0", "SSH_ASKPASS_REQUIRE": "force"],
                                     input: nil, timeout: 15) else { return nil }
        let derived = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return derived.isEmpty ? nil : derived
    }

    struct SSHKeyImportError: Error, CustomStringConvertible {
        let description: String
        // @port-skip linux-only: the import route's error
        init(_ d: String) { description = d }
    }

    /// The keys a host ssh-agent holds, as ImportedSSHKeys ready to add:
    /// nothing copied, `hostAgentSocket` points signing back at the agent.
    // @port ACAppDelegate.static listHostAgentKeys(socket: String) h=ae5fe98fb47024e3 @e5645631
    nonisolated static func listHostAgentKeys(socket: String) throws -> [ImportedSSHKey] {
        guard let path = HostAgentClient.resolveHostSocket(socket) else {
            throw SSHKeyImportError("SSH_AUTH_SOCK isn't set for the daemon: name the agent's socket")
        }
        guard FileManager.default.fileExists(atPath: path) else { throw SSHKeyImportError("No agent socket at \(path).") }
        return HostAgentClient(socketPath: path, timeout: 10, hostAgent: true).identities().compactMap { ident in
            guard ident.blob.count > 4 else { return nil }
            let n = ident.blob.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard n > 0, 4 + n <= ident.blob.count,
                  let type = String(data: ident.blob.subdata(in: 4..<(4 + n)), encoding: .utf8) else { return nil }
            let comment = ident.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            return ImportedSSHKey(label: comment.isEmpty ? type : comment, filename: "",
                                  publicKeyText: "\(type) \(ident.blob.base64EncodedString())" + (comment.isEmpty ? "" : " \(comment)"),
                                  hostAgentSocket: socket)
        }
    }

    /// Remove an imported key's file, `.pub` and vault passphrase.
    // @port ACAppDelegate.removeImportedSSHKey(_: ImportedSSHKey, for: Profile) h=8862938c66b6210d @2134fc7a
    nonisolated static func removeImportedSSHKey(_ key: ImportedSSHKey, for profile: Profile, profileDirectory: URL) {
        // A host-agent key has no file (filename "" would name the whole
        // imported/ dir) — the agent keeps it.
        guard !key.isFromHostAgent, !key.filename.isEmpty, !key.filename.contains("/"),
              key.filename != ".", key.filename != ".." else { return }
        let importedDir = profileDirectory.appendingPathComponent("agent/imported", isDirectory: true)
        try? FileManager.default.removeItem(at: importedDir.appendingPathComponent(key.filename))
        try? FileManager.default.removeItem(at: importedDir.appendingPathComponent(key.filename + ".pub"))
        if key.hasPassphrase { PassphraseKeychain.delete(profileID: profile.id, filename: key.filename) }
    }

    /// A workspace's imported keys as a client lists them (no secret: the
    /// passphrase stays in the vault).
    // @port-skip linux-only: the key list of the editor's Credentials pane, over the control API
    static func sshKeyRows(_ p: Profile) -> JSONValue {
        .array(p.importedSSHKeys.map { k in
            var o: [String: JSONValue] = ["id": .string(k.id.uuidString), "label": .string(k.label),
                                          "publicKey": .string(k.publicKeyText), "hasPassphrase": .bool(k.hasPassphrase),
                                          "requireApproval": .bool(k.requireApproval)]
            if let s = k.hostAgentSocket { o["hostAgentSocket"] = .string(s) }
            return .object(o)
        })
    }

    /// `/profiles/<workspace>/ssh-keys…` (macOS: the editor's Credentials
    /// pane; a server has none): GET lists; POST `{path, keyData?,
    /// publicKey?, label?, passphrase?, requireApproval?}` imports a key
    /// file (its bytes as the client read them, else `path` on this server);
    /// POST `{hostAgentSocket, publicKey?, requireApproval?}` adds a host
    /// agent's keys (the one whose public key is given, else all); POST
    /// `host-agent {socket}` lists an agent's keys; POST `<id>
    /// {requireApproval}` sets a key's gate; DELETE `<id>` removes one. A
    /// running workspace's gates follow at once; added or removed keys load
    /// at its next boot (as macOS's restart diff).
    // @port-skip linux-only: the editor's imported-key actions over the control API
    func sshKeysRoute(_ prof: Profile, method: String, sub: [String], body: JSONValue) async -> ControlResponse {
        let store = profileStore
        let dir = store.profileDirectory(for: prof)
        /// `change` applied to the stored copy's keys as they are now, and
        /// saved (ProfileWrites); false from it: no such key there.
        func saved(_ change: (inout [ImportedSSHKey]) -> Bool) async -> ControlResponse {
            var found = true
            let after: Profile?
            do { after = try ProfileWrites.edit(prof.id, store: store) { found = change(&$0.importedSSHKeys); return found } } catch {
                return .error(500, "Couldn't save '\(prof.name)': \(error)")
            }
            guard let after else { return .error(404, "No workspace '\(prof.name)'") }
            guard found else { return .error(404, "No such key") }
            if let id = await runningVMID(of: prof.id) { _ = scheduleLiveRefresh(id) }
            return ControlResponse(200, ["ok": true, "keys": Self.sshKeyRows(after)])
        }
        let p = prof
        switch (method, sub.count > 1 ? sub[1] : "") {
        case ("GET", ""):
            return ControlResponse(200, ["keys": Self.sshKeyRows(p)])
        case ("POST", "host-agent"):
            let socket = body["socket"]?.stringValue ?? ""
            if let why = hostAgentSocketRefusal(socket) { return .error(400, why) }
            do {
                let keys = try await Task.detached { try Self.listHostAgentKeys(socket: socket) }.value
                return ControlResponse(200, ["keys": .array(keys.map { .object(["label": .string($0.label), "publicKey": .string($0.publicKeyText)]) })])
            } catch { return .error(400, "\(error)") }
        case ("POST", ""):
            let approve = body["requireApproval"] == .bool(true)
            if let socket = body["hostAgentSocket"]?.stringValue {
                if let why = hostAgentSocketRefusal(socket) { return .error(400, why) }
                let want = body["publicKey"]?.stringValue.flatMap { Self.sshPublicKeyBlob(fromOpenSSHText: $0) }
                let found: [ImportedSSHKey]
                do { found = try await Task.detached { try Self.listHostAgentKeys(socket: socket) }.value } catch {
                    return .error(400, "\(error)")
                }
                let have = Set(p.importedSSHKeys.compactMap { Self.sshPublicKeyBlob(fromOpenSSHText: $0.publicKeyText) })
                let picked = found.filter { k in
                    guard let blob = Self.sshPublicKeyBlob(fromOpenSSHText: k.publicKeyText), !have.contains(blob) else { return false }
                    return want.map { $0 == blob } ?? true
                }
                guard !picked.isEmpty else {
                    return .error(404, want == nil ? "The agent holds no key this workspace hasn't got" : "The agent doesn't hold that key")
                }
                let adding = picked.map { var k = $0; k.requireApproval = approve; return k }
                return await saved { keys in
                    // Not one added meanwhile.
                    let now = Set(keys.compactMap { Self.sshPublicKeyBlob(fromOpenSSHText: $0.publicKeyText) })
                    keys += adding.filter { Self.sshPublicKeyBlob(fromOpenSSHText: $0.publicKeyText).map { !now.contains($0) } ?? false }
                    return true
                }
            }
            guard let path = body["path"]?.stringValue, !path.isEmpty else { return .error(400, "path or hostAgentSocket required") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            // The key's bytes as the CLI read them (the caller's own file),
            // else the daemon reads `path` itself.
            var keyBytes: Data?
            if let b64 = body["keyData"]?.stringValue {
                guard let d = Data(base64Encoded: b64), !d.isEmpty, d.count <= 64 << 10 else {
                    return .error(400, "keyData isn't a key file (base64, at most 64 KiB)")
                }
                keyBytes = d
            }
            let publicKey = body["publicKey"]?.stringValue
            let label = body["label"]?.stringValue ?? ""
            let passphrase = body["passphrase"]?.stringValue
            let askpassDir = config.runtimeDir
            let imported: ImportedSSHKey
            do {
                // The file work off the actor; the passphrase into the vault
                // here, on this task.
                var key = try await Task.detached {
                    try Self.importSSHKey(at: url, passphrase: passphrase, label: label, for: prof, profileDirectory: dir,
                                          askpassDir: askpassDir, savePassphrase: false, keyBytes: keyBytes, publicKey: publicKey)
                }.value
                if key.hasPassphrase, let passphrase {
                    do { try PassphraseKeychain.set(passphrase: passphrase, profileID: prof.id, filename: key.filename) } catch {
                        Self.removeImportedSSHKey(ImportedSSHKey(label: key.label, filename: key.filename, publicKeyText: ""),
                                                  for: prof, profileDirectory: dir)
                        throw error
                    }
                }
                key.requireApproval = approve
                imported = key
            } catch { return .error(400, "Couldn't import \(url.path): \(error)") }
            let r = await saved { $0.append(imported); return true }
            if r.status != 200 { Self.removeImportedSSHKey(imported, for: p, profileDirectory: dir) }
            return r
        case ("POST", let id):
            guard let i = p.importedSSHKeys.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                return .error(404, "No such key")
            }
            guard case .bool(let approve)? = body["requireApproval"] else { return .error(400, "requireApproval required") }
            let keyID = p.importedSSHKeys[i].id
            return await saved { keys in
                guard let j = keys.firstIndex(where: { $0.id == keyID }) else { return false }
                keys[j].requireApproval = approve
                return true
            }
        case ("DELETE", let id) where !id.isEmpty:
            guard let i = p.importedSSHKeys.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                return .error(404, "No such key")
            }
            let keyID = p.importedSSHKeys[i].id
            var removed: ImportedSSHKey?
            let r = await saved { keys in
                guard let j = keys.firstIndex(where: { $0.id == keyID }) else { return false }
                removed = keys.remove(at: j)
                return true
            }
            if r.status == 200, let removed { Self.removeImportedSSHKey(removed, for: p, profileDirectory: dir) }
            return r
        default:
            return .error(405, "Method not allowed")
        }
    }
}
