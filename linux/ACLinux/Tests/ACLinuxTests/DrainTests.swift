import Foundation
import Testing
@testable import ACLinux

/// A stopping daemon ends each running VM as macOS's quit does.
@Suite("Daemon stop: drained by close action")
struct DrainTests {
    static func rec(_ name: String) -> VMRecord {
        VMRecord(id: UUID().uuidString.lowercased(), name: name, machine: "fc", cid: 3, mac: "02:00:00:00:00:01", state: .running,
                 ip: nil, cpus: 1, memoryMiB: 512, createdAt: Date(), bootedAt: nil, statePath: nil)
    }

    @Test func eachVMEndsAsItsCloseActionSays() {
        let suspend = Self.rec("s"), shut = Self.rec("d"), ask = Self.rec("a"), bg = Self.rec("b")
        var node = Self.rec("node"); node.kube = UUID().uuidString
        var signIn = Self.rec("reg"); signIn.registration = true
        var rescue = Self.rec("rescue"); rescue.rescueFor = suspend.id
        let noProfile = Self.rec("gone")
        let actions: [String: Profile.CloseAction] = [suspend.id: .suspend, shut.id: .shutdown, ask.id: .ask, bg.id: .background]
        let plan = Daemon.drainPlan([suspend, shut, ask, bg, node, signIn, rescue, noProfile]) { r in
            actions[r.id].map { a in var p = Profile(name: r.name, tool: .claude, authMode: .token); p.closeAction = a; return p }
        }
        #expect(plan.map { "\($0.0.name)=\($0.1)" } == ["s=suspend", "d=shutdown", "a=suspend", "b=suspend", "node=suspend"],
                "a sign-in, a rescue and a VM without its workspace are killed after")
    }

    @Test func aClusterMachineGetsAMinuteToPowerOff() {
        var node = Self.rec("node"); node.kube = UUID().uuidString
        #expect(Daemon.shutdownGrace(node) == .seconds(60))
        #expect(Daemon.shutdownGrace(Self.rec("w")) == .seconds(20))
    }
}

/// A fat client's forward to an address no VM leases (a MetalLB
/// LoadBalancer IP): relayed through a node of the cluster that owns it.
@Suite("Forwards to LoadBalancer addresses")
struct LoadBalancerRelayTests {
    @Test func theClustersNodeRelaysItsRange() {
        let ws = DrainTests.rec("ws")
        var a = DrainTests.rec("a-1"); a.kube = "AAAA"
        var b = DrainTests.rec("b-1"); b.kube = "bbbb"
        let ranges = [(cluster: "aaaa", range: "192.168.64.200-192.168.64.210"), (cluster: "BBBB", range: "192.168.64.220-192.168.64.230")]
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.225", running: [ws, a, b], ranges: ranges)?.name == "b-1")
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.205", running: [ws, a, b], ranges: ranges)?.name == "a-1")
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.99", running: [ws, a, b], ranges: ranges)?.name == "a-1", "any node")
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.99", running: [ws], ranges: ranges)?.name == "ws", "any VM")
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.99", running: [], ranges: ranges) == nil)
        let g = "192.168.64.1"
        #expect(Daemon.isGuestAddress("192.168.64.99", cidr: "192.168.64.0/24", gateway: g))
        #expect(!Daemon.isGuestAddress("10.0.0.1", cidr: "192.168.64.0/24", gateway: g))
        #expect(!Daemon.isGuestAddress("192.168.64.1", cidr: "192.168.64.0/24", gateway: g), "the gateway")
        #expect(!Daemon.isGuestAddress("192.168.64.0", cidr: "192.168.64.0/24", gateway: g), "the network")
        #expect(!Daemon.isGuestAddress("192.168.64.255", cidr: "192.168.64.0/24", gateway: g), "the broadcast")
        #expect(!Daemon.isGuestAddress("192.168.64.9", cidr: "bogus", gateway: g))
    }
}

extension DaemonGlobalSuites {
    /// A guest that can't be reached is named by its VM's state (macOS:
    /// guestUnavailableError): the file explorer says "The VM is off".
    @Suite("Guest unavailable wording", .serialized)
    struct GuestUnavailableTests {
        @Test func theErrorNamesTheVMsState() async throws {
            let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let pid = try #require(UUID(uuidString: rec.id))
            do { _ = try await d.guestExec(profileID: pid, command: "true"); Issue.record("ran") }
            catch { #expect("\(error)".contains("The VM is off")) }
            var s = rec; s.state = .suspended
            try await d.registerForTesting(s)
            do { _ = try await d.guestExec(profileID: pid, command: "true"); Issue.record("ran") }
            catch { #expect("\(error)".contains("The VM is suspended")) }
            await d.shutdown()
        }
    }
}

extension DaemonGlobalSuites {
    /// The default SSH key (macOS: made at launch): in the daemon's state
    /// directory, once, and the template carries its public key.
    @Suite("Default SSH key", .serialized)
    struct DefaultSSHKeyTests {
        @Test func theKeyIsMadeOnceAndTheTemplateCarriesIt() throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let before = DefaultSSHKey.directoryOverride
            defer { DefaultSSHKey.directoryOverride = before }
            let store = ProfileStore(rootDir: URL(fileURLWithPath: dir + "/profiles", isDirectory: true))
            Daemon.bootstrapDefaultSSHKey(stateDir: dir, store: store)
            #expect(DefaultSSHKey.directoryURL.path == dir + "/default-ssh")
            let pub = try DefaultSSHKey.publicKeyText()
            #expect(pub.hasPrefix("ssh-ed25519 "))
            #expect(store.loadTemplate().sshPublicKey == pub)
            var st = stat()
            #expect(stat(dir + "/default-ssh", &st) == 0 && st.st_mode & 0o077 == 0, "owner-only")
            Daemon.bootstrapDefaultSSHKey(stateDir: dir, store: store)
            #expect(try DefaultSSHKey.publicKeyText() == pub, "made once")
        }
    }
}

extension DaemonGlobalSuites {
    /// A new user's first workspace (macOS: ensureFirstWorkspace): its name,
    /// its agent, and never when there's one already.
    @Suite("First workspace", .serialized)
    struct FirstWorkspaceTests {
        @Test func itsNameAndAgentAreMacOSs() {
            #expect(Daemon.nextDefaultProfileName(existing: []) == "Default workspace")
            #expect(Daemon.nextDefaultProfileName(existing: ["default workspace", "Default workspace 2"]) == "Default workspace 3")
            let p = Profile(name: "x", tool: .claude, authMode: .subscription)
            #expect(Daemon.firstWorkspaceAgent(p, ready: []) == (.claude, .subscription), "nothing set up: Claude Code")
            #expect(Daemon.firstWorkspaceAgent(p, ready: [.claude, .codex]) == (.claude, .subscription))
            #expect(Daemon.firstWorkspaceAgent(p, ready: [.grok, .codex]) == (.codex, .subscription))
            #expect(Daemon.firstWorkspaceAgent(p, ready: [.omp]) == (.omp, .token), "omp has no subscription")
        }

        @Test func aUserWithAWorkspaceGetsNone() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()   // one workspace VM registered
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let before = await d.records.count
            await d.ensureFirstWorkspace(freshState: true)
            #expect(await d.records.count == before)
            #expect(FileManager.default.fileExists(atPath: dir + "/state/first-workspace"), "once: not again after")
            await d.shutdown()
        }
    }
}

/// Workspaces named as macOS takes them: exactly, by name in any case, or
/// by a unique id prefix (dashes ignored).
@Suite("Workspace lookup as macOS's")
struct LookupTests {
    @Test func aVMIsFoundByCaseOrPrefix() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var reg = VMRegistry(path: dir + "/vms.json")
        var a = DrainTests.rec("Web"); a.id = "abcdef12-0000-4000-8000-000000000001"
        var b = DrainTests.rec("api"); b.id = "abcdef99-0000-4000-8000-000000000002"
        try reg.upsert(a); try reg.upsert(b)
        #expect(reg.find("web")?.id == a.id, "the name in any case")
        #expect(reg.find("abcdef1")?.id == a.id, "a unique prefix")
        #expect(reg.find("ABCDEF990000")?.id == b.id, "dashes and case ignored")
        #expect(reg.find("abcdef") == nil, "ambiguous")
        #expect(reg.find("") == nil)
        #expect(reg.find(a.shortId)?.id == a.id)
    }

    /// macOS's order: the full id, then the name, then the short id; past
    /// exact matches, never a sign-in or rescue machine.
    @Test func theNameBeatsAnotherVMsShortIDAndSignInsArentGuessed() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var reg = VMRegistry(path: dir + "/vms.json")
        var a = DrainTests.rec("x"); a.id = "cafe0001-0000-4000-8000-000000000001"
        var b = DrainTests.rec("cafe0001"); b.id = "beef0002-0000-4000-8000-000000000002"
        var signIn = DrainTests.rec("reg"); signIn.id = "dead0003-0000-4000-8000-000000000003"; signIn.registration = true
        try reg.upsert(a); try reg.upsert(b); try reg.upsert(signIn)
        #expect(reg.find("cafe0001")?.id == b.id, "a name before another VM's short id")
        #expect(reg.find("dead") == nil, "a sign-in isn't found by a prefix")
        #expect(reg.findExact(signIn.id)?.id == signIn.id, "only exactly")
        #expect(reg.findExact("cafe") == nil)
    }

    /// A snapshot taken with other shared folders isn't resumed (macOS: its
    /// configuration fingerprint).
    @Test func aSnapshotsFoldersMustStillMatch() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try Daemon.writeSnapshotShares(["/srv/a", "/srv/b"], dir: dir)
        let saved = Daemon.readSnapshotShares(dir: dir)
        #expect(saved == ["/srv/a", "/srv/b"])
        #expect(Daemon.snapshotSharesDrift(saved: saved, now: ["/srv/a", "/srv/b"]) == nil)
        #expect(Daemon.snapshotSharesDrift(saved: saved, now: ["/srv/a"]) != nil)
        #expect(Daemon.snapshotSharesDrift(saved: nil, now: ["/srv/a"]) == nil, "an older snapshot: let through")
        // What's recorded is what the VM was launched with, not the stored list.
        var c = MachineConfig(name: "m", kernel: "/k", initrd: "/i", cmdline: "console=ttyS0", baseImage: "/b", overlay: "/o.raw", vsockCID: 7, runDirectory: "/r")
        c.shares = [.init(tag: "bromure-meta", hostPath: "/m", readOnly: true), .init(tag: "share-1", hostPath: "/srv/a"),
                    .init(tag: "bromure-outbox", hostPath: "/o"), .init(tag: "share-2", hostPath: "/srv/b")]
        #expect(Daemon.launchedShares(c) == ["/srv/a", "/srv/b"])
    }
}

/// The classifiers stay resident only for what a running workspace's
/// policy needs (macOS: ClassifierLifecycle).
@Suite("Classifier lifecycle")
struct ClassifierLifecycleTests {
    @Test func whatTheRunningWorkspacesNeed() {
        var a = Profile(name: "a", tool: .claude, authMode: .token)
        var b = Profile(name: "b", tool: .claude, authMode: .token)
        a.pii.enabled = true
        b.promptInjection.detectRulesInjection = true
        b.promptInjection.detectSourceInjection = false
        let n = LinuxClassifierLifecycle.needs(for: [a, b])
        #expect(n.pii == a.pii.isActive && n.rulesInjection && !n.sourceInjection)
        #expect(LinuxClassifierLifecycle.needs(for: []) == .init(), "nothing running: nothing needed")
    }
}

extension DaemonGlobalSuites {
    /// A stop asked for while the VM boots is kept and done once it's up
    /// (macOS: BootsInFlight.deferStop / takeStop), not refused.
    @Suite("Stop during a boot", .serialized)
    struct StopDuringBootTests {
        @Test func aStopDuringABootIsDeferred() async throws {
            let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            await d.markStartingForTesting(rec.id, true)
            let r = await d.deleteVM(rec, action: "suspend")
            #expect(r.status == 202 && r.body["deferred"] == .bool(true))
            #expect(await d.takeStop(rec.id) == "suspend")
            #expect(await d.takeStop(rec.id) == nil, "taken once")
            await d.markStartingForTesting(rec.id, false)
            #expect(await d.deferStop(rec.id, action: "shutdown") == false, "no boot under way")
            await d.shutdown()
        }
    }
}

/// The build's metadata from the stamp beside the binary (macOS: Info.plist).
@Suite("Build info")
struct BuildInfoTests {
    @Test func theStampIsReadAndAnUnstampedBinaryIsDev() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try #"{"version":"v5.5","build":"Jenkins #7","commit":"abcd1234","date":"","extra":3}"#
            .write(toFile: dir + "/b.json", atomically: true, encoding: .utf8)
        #expect(BuildInfo.read(dir + "/b.json") == ["version": "v5.5", "build": "Jenkins #7", "commit": "abcd1234"])
        #expect(BuildInfo.read(dir + "/none.json").isEmpty)
        #expect(BuildInfo.dictionary["version"] != nil, "always a version (linux-dev unstamped)")
    }
}


/// A forced restage (a sign-in's) restarts agents only for an edit it
/// carries along; otherwise only profile edits and the Models refresh do.
@Suite("Live refresh restarts")
struct LiveRestartTests {
    @Test func aForcedRestageRestartsOnlyForAPendingEdit() {
        var applied = Profile(name: "w", tool: .claude, authMode: .token)
        applied.id = UUID()
        #expect(Daemon.restartsAgents(asked: true, applied: applied, stored: applied))
        #expect(!Daemon.restartsAgents(asked: false, applied: applied, stored: applied), "nothing pending: a sign-in's restage")
        var edited = applied
        edited.apiKey = "test-placeholder-value"
        #expect(Daemon.liveSteps(from: applied, to: edited).restage, "an edit that needs a restage")
        #expect(Daemon.restartsAgents(asked: false, applied: applied, stored: edited), "carried by the forced restage: restarted")
        #expect(!Daemon.restartsAgents(asked: false, applied: nil, stored: edited), "unknown (taken back): not taken for an edit")
    }
}
