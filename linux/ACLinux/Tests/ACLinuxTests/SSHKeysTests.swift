import Foundation
import Glibc
import Testing
@testable import ACLinux

/// Imported SSH keys on Linux (macOS: the editor's import, the Keychain's
/// passphrases, the per-workspace ssh-agent): passphrases in the vault, a
/// gone daemon's agents reaped (never a live one's), a key file imported
/// and its public key derived without the passphrase on a command line,
/// ssh-add'ed into a real agent with it, and the route a client drives.
@Suite("Imported SSH keys", .serialized)
struct SSHKeysTests {
    static func withVault(_ body: (String) async throws -> Void) async rethrows {
        let dir = "/tmp/acl-vault-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await SecretsVault.$bound.withValue(.init(directory: dir, environment: ["BROMURE_VAULT_KEY_SOURCE": "file"])) {
            try await body(dir)
        }
    }

    /// An ed25519 key made by ssh-keygen (a fixture passphrase, or none),
    /// without its .pub when `keepPub` is false.
    static func makeKey(_ dir: String, passphrase: String, keepPub: Bool = false) throws -> (path: String, pub: String) {
        let path = dir + "/id_test_\(UUID().uuidString.prefix(6))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", "ed25519", "-N", passphrase, "-C", "fixture", "-f", path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if !keepPub { try FileManager.default.removeItem(atPath: path + ".pub") }
        return (path, pub)
    }

    @Test func passphrasesAreVaultItems() async throws {
        try await Self.withVault { dir in
            let pid = UUID()
            #expect(PassphraseKeychain.get(profileID: pid, filename: "k1") == nil)
            try PassphraseKeychain.set(passphrase: "fixture-pass", profileID: pid, filename: "k1")
            #expect(PassphraseKeychain.get(profileID: pid, filename: "k1") == "fixture-pass")
            #expect(PassphraseKeychain.get(profileID: UUID(), filename: "k1") == nil, "per workspace")
            // Sealed on disk, never the passphrase itself.
            let blobs = FileManager.default.enumerator(atPath: dir)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".blob") } ?? []
            #expect(blobs.count == 1)
            let raw = try #require(FileManager.default.contents(atPath: dir + "/" + blobs[0]))
            #expect(raw.range(of: Data("fixture-pass".utf8)) == nil)
            PassphraseKeychain.delete(profileID: pid, filename: "k1")
            #expect(PassphraseKeychain.get(profileID: pid, filename: "k1") == nil)
        }
    }

    @Test func onlyAGoneDaemonsAgentsAreReaped() {
        let tmp = NSTemporaryDirectory()
        let procs: [(pid: pid_t, argv: [String])] = [
            (10, ["/usr/bin/ssh-agent", "-D", "-a", tmp + "bromure-ac-agent-111-aaaaaaaa.sock"]),   // gone daemon
            (11, ["/usr/bin/ssh-agent", "-D", "-a", tmp + "bromure-ac-agent-222-bbbbbbbb.sock"]),   // a live one's
            (12, ["/usr/bin/ssh-agent", "-D", "-a", tmp + "bromure-ac-agent-333-cccccccc.sock"]),   // ours
            (13, ["/bin/sh", "-c", "ssh-agent -a \(tmp)bromure-ac-agent-111-x.sock"]),              // not an agent
            (14, ["/usr/bin/ssh-agent", "-D", "-a", tmp + "someone-else.sock"]),                    // not ours at all
        ]
        let found = WorkspaceSSHAgent.orphans(procs, ourPID: 333, alive: { $0 == 222 })
        #expect(found.map(\.pid) == [10])
        #expect(found.first?.socket == tmp + "bromure-ac-agent-111-aaaaaaaa.sock")
        #expect(WorkspaceSSHAgent.ownerPID(ofSocket: "/x/bromure-ac-agent-42-abc.sock") == 42)
        #expect(WorkspaceSSHAgent.ownerPID(ofSocket: "/x/other-42-abc.sock") == nil)
    }

    @Test func aKeyIsImportedLoadedAndRemoved() async throws {
        try await Self.withVault { _ in
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let (src, pub) = try Self.makeKey(dir, passphrase: "fixture-pass")
            let profile = Profile(name: "keys", tool: .claude, authMode: .token)
            let pdir = URL(fileURLWithPath: dir + "/profile", isDirectory: true)
            let key = try Daemon.importSSHKey(at: URL(fileURLWithPath: src), passphrase: "fixture-pass", label: "work",
                                              for: profile, profileDirectory: pdir, askpassDir: dir)
            #expect(key.label == "work" && key.hasPassphrase && !key.isFromHostAgent)
            #expect(key.publicKeyText == pub, "derived with ssh-keygen -y (the passphrase through askpass)")
            let copied = pdir.appendingPathComponent("agent/imported/" + key.filename).path
            let mode = (try FileManager.default.attributesOfItem(atPath: copied)[.posixPermissions] as? NSNumber)?.intValue
            #expect(mode == 0o600)
            #expect(PassphraseKeychain.get(profileID: profile.id, filename: key.filename) == "fixture-pass")
            #expect(!FileManager.default.fileExists(atPath: dir + "/askpass-") , "no askpass left behind")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("askpass-") }.isEmpty)

            // ssh-add'ed into a real agent with the vault's passphrase.
            let agent = try WorkspaceSSHAgent(directory: dir + "/agents", label: String(UUID().uuidString.prefix(8)).lowercased())
            defer { agent.terminate() }
            var p = profile
            p.importedSSHKeys = [key]
            Daemon.loadImportedSSHKeys(for: p, profileDirectory: pdir, agentSocket: agent.socketPath, askpassDir: dir)
            let blobs = HostAgentClient(socketPath: agent.socketPath, timeout: 5).identities().map(\.blob)
            #expect(blobs == [Daemon.sshPublicKeyBlob(fromOpenSSHText: pub)].compactMap { $0 }, "the agent holds it")

            // A wrong passphrase isn't offered twice, and the key isn't added.
            let wrong = try WorkspaceSSHAgent(directory: dir + "/agents", label: String(UUID().uuidString.prefix(8)).lowercased())
            defer { wrong.terminate() }
            Daemon.sshAddImportedKey(path: copied, label: "work", passphrase: "not-it", agentSocket: wrong.socketPath, askpassDir: dir)
            #expect(HostAgentClient(socketPath: wrong.socketPath, timeout: 5).identities().isEmpty)

            // Terminated, the agent (and the key in it) is gone.
            agent.terminate()
            for _ in 0..<200 where agent.exitStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(agent.exitStatus != nil, "the agent ended")

            Daemon.removeImportedSSHKey(key, for: p, profileDirectory: pdir)
            #expect(!FileManager.default.fileExists(atPath: copied))
            #expect(PassphraseKeychain.get(profileID: profile.id, filename: key.filename) == nil, "out of the vault")
        }
    }

    @Test func theGatesAndHostAgentKeysFollowTheProfile() throws {
        let blobKey = "ssh-ed25519 " + Data("blob-one".utf8).base64EncodedString() + " one"
        var p = Profile(name: "gates", tool: .claude, authMode: .token)
        p.importedSSHKeys = [ImportedSSHKey(label: "one", filename: "f1", publicKeyText: blobKey, requireApproval: true),
                             ImportedSSHKey(label: "hw", filename: "", publicKeyText: "ssh-ed25519 " + Data("blob-hw".utf8).base64EncodedString(),
                                            hostAgentSocket: "/run/agent.sock")]
        #expect(Daemon.importedKeyApprovals(p).keys.map { String(decoding: $0, as: UTF8.self) } == ["blob-one"])
        #expect(Daemon.hostAgentKeys(p) == [Data("blob-hw".utf8): "/run/agent.sock"])
        // A key taken off while running stays gated.
        let running = Daemon.importedKeyApprovals(p)
        var q = p
        q.importedSSHKeys.removeFirst()
        #expect(Daemon.liveImportedKeyApprovals(running: running, to: q).count == 1)
        #expect(Daemon.liveSteps(from: p, to: q).importedKeys && !Daemon.liveSteps(from: p, to: p).importedKeys)
    }
}

extension DaemonGlobalSuites {
    /// `/profiles/<workspace>/ssh-keys`: import (the passphrase into the
    /// vault), list (no secret), the gate, remove (file and vault entry go);
    /// a deleted workspace's passphrases leave the vault.
    @Suite("ssh-keys route", .serialized)
    struct SSHKeysRouteTests {
        @Test func importListGateRemove() async throws {
            try await SSHKeysTests.withVault { _ in
                try await VMRunTests.withStore { d, dir in
                    let store = ProfileStore()
                    let p = try store.save(Profile(name: "keyed", tool: .claude, authMode: .token))
                    var vm = RepairMarksTests.stopped(p.id.uuidString.lowercased())
                    vm.name = "keyed"
                    try await d.registerForTesting(vm)
                    let (src, pub) = try SSHKeysTests.makeKey(dir, passphrase: "fixture-pass", keepPub: true)
                    let imported = await d.sshKeysRoute(p, method: "POST", sub: ["ssh-keys"],
                                                        body: ["path": .string(src), "label": "work", "passphrase": "fixture-pass"])
                    #expect(imported.status == 200, "\(imported.body)")
                    guard case .array(let rows)? = imported.body["keys"], let row = rows.first else { Issue.record("no keys"); return }
                    #expect(row["publicKey"]?.stringValue == pub && row["hasPassphrase"] == .bool(true))
                    #expect(!"\(imported.body)".contains("fixture-pass"), "the passphrase never comes back")
                    let saved = try #require(store.loadAll().first { $0.id == p.id })
                    let key = try #require(saved.importedSSHKeys.first)
                    #expect(PassphraseKeychain.get(profileID: p.id, filename: key.filename) == "fixture-pass")

                    let id = try #require(row["id"]?.stringValue)
                    let gated = await d.sshKeysRoute(saved, method: "POST", sub: ["ssh-keys", id], body: ["requireApproval": true])
                    #expect(gated.status == 200)
                    #expect(store.loadAll().first { $0.id == p.id }?.importedSSHKeys.first?.requireApproval == true)
                    #expect(await d.sshKeysRoute(saved, method: "POST", sub: ["ssh-keys"], body: ["path": .string(dir + "/nope")]).status == 400)

                    let now = try #require(store.loadAll().first { $0.id == p.id })
                    let removed = await d.sshKeysRoute(now, method: "DELETE", sub: ["ssh-keys", id], body: .null)
                    #expect(removed.status == 200 && removed.body["keys"] == .array([]))
                    #expect(PassphraseKeychain.get(profileID: p.id, filename: key.filename) == nil)

                    // A workspace deleted with a key: its passphrase goes too.
                    let again = await d.sshKeysRoute(now, method: "POST", sub: ["ssh-keys"],
                                                     body: ["path": .string(src), "passphrase": "fixture-pass"])
                    #expect(again.status == 200)
                    let k2 = try #require(store.loadAll().first { $0.id == p.id }?.importedSSHKeys.first)
                    let deleted = await d.workspaceRoute("DELETE", "/profiles/keyed", .null)
                    #expect(deleted?.status == 200)
                    #expect(PassphraseKeychain.get(profileID: p.id, filename: k2.filename) == nil)
                }
            }
        }
    }
}
