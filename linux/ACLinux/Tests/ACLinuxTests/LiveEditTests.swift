import Foundation
import Testing
@testable import ACLinux

/// The suites that set the daemon's process-global test state: the
/// profiles' root (ProfileStore.defaultRootDir, which the daemon's
/// profileStore reads) and Daemon.launchHookForTesting. One at a time, or
/// one's daemon reads another's profiles or launches through its hook.
@Suite(.serialized) struct DaemonGlobalSuites {}

extension DaemonGlobalSuites {
    /// A running workspace's edit applied without a reboot (Daemon.liveRefresh,
    /// macOS's applyLiveSessionRefresh → pushLiveCredentials): which steps an
    /// edit needs, and the restage through the daemon's own code on a
    /// workspace's record: the swap map merged, the guest's files rewritten
    /// with stand-ins only, and the counters agentd and the shells watch.
    @Suite("Live edits of a running workspace", .serialized)
    struct LiveEditTests {
        static let realA = "sk-" + "ant-api03-REAL-A-not-for-the-guest"
        static let realB = "sk-" + "ant-api03-REAL-B-not-for-the-guest"
        static let realStripe = "sk_" + "live_REAL-stripe-not-for-the-guest"

        @Test func whichStepsAnEditNeeds() {
            var old = Profile(name: "w", tool: .claude, authMode: .token)
            old.apiKey = Self.realA
            #expect(Daemon.liveSteps(from: nil, to: old) == .init(), "unknown (a restarted daemon): everything")
            #expect(Daemon.liveSteps(from: old, to: old) == .init(routing: false, sshGate: false, restage: false))
            func steps(_ edit: (inout Profile) -> Void) -> Daemon.LiveSteps {
                var new = old
                edit(&new)
                return Daemon.liveSteps(from: old, to: new)
            }
            // Cosmetic and trace-only edits: nothing (the trace is the edit host's).
            #expect(steps { $0.name = "renamed" } == .init(routing: false, sshGate: false, restage: false))
            #expect(steps { $0.traceLevel = .activity } == .init(routing: false, sshGate: false, restage: false))
            // A credential, a variable, a policy: the restage only.
            #expect(steps { $0.apiKey = Self.realB } == .init(routing: false, sshGate: false, restage: true))
            #expect(steps { $0.environmentVariables = [EnvironmentVariable(name: "X", value: "1")] }
                        == .init(routing: false, sshGate: false, restage: true))
            #expect(steps { $0.manualTokens = [ManualToken(name: "s", realValue: Self.realStripe, envVarName: "S", hostFilters: [])] }
                        == .init(routing: false, sshGate: false, restage: true))
            #expect(steps { $0.promptInjection.detectSourceInjection.toggle() }.restage)
            // The SSH key's gate: the agent only.
            #expect(steps { $0.sshKeyRequiresApproval.toggle() } == .init(routing: false, sshGate: true, restage: false))
            // The local engine: the route, and the restage (its env and files).
            #expect(steps { $0.localEngineAPIKey = "k" } == .init(routing: true, sshGate: false, restage: true))
            #expect(steps { $0.activeModelID = "some/model" }.routing)
        }

        /// The staging a launch and a refresh share: Claude's stand-in key is
        /// pre-approved in the seed's spec (as macOS's finalizeHomeSeed call),
        /// so its "use this API key?" prompt never blocks a session.
        @Test func theSeedPreApprovesClaudesStandIn() throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            var p = Profile(name: "seed", tool: .claude, authMode: .token)
            p.apiKey = Self.realA
            let plan = Daemon.makeSessionTokenPlan(for: p, mitm: proxy)
            let fake = try #require(plan.fakeForAnthropic())
            let meta = URL(fileURLWithPath: dir + "/meta", isDirectory: true)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
            try Daemon.writeCredentialFiles(p, plan: plan, registration: false, meta: meta, kubeYAML: nil,
                                            store: ProfileStore(rootDir: URL(fileURLWithPath: dir + "/profiles", isDirectory: true)),
                                            seedStandIns: { _, _ in })
            let spec = try String(contentsOf: meta.appendingPathComponent("home-seed/claude-settings.spec.json"), encoding: .utf8)
            #expect(spec.contains("\"approvedApiKeySuffix\" : \"\(fake.suffix(20))\""), "\(spec)")
            let files = Self.tree(meta)
            #expect(!files.contains("REAL") && files.contains("export ANTHROPIC_API_KEY='\(fake)'"))
        }

        /// Every file under `dir`, as text.
        static func tree(_ dir: URL) -> String {
            let fm = FileManager.default
            var out = ""
            for case let url as URL in fm.enumerator(at: dir, includingPropertiesForKeys: nil) ?? FileManager.DirectoryEnumerator() {
                if let d = fm.contents(atPath: url.path) { out += String(decoding: d, as: UTF8.self) + "\n" }
            }
            return out
        }

        static func counter(_ meta: URL, _ name: String) -> Int {
            Int((try? String(contentsOf: meta.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }

        @Test func aRefreshRestagesWithStandInsOnlyAndKeepsTheRunningAgentsOld() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let prior = ProfileStore.defaultRootDir
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            defer { ProfileStore.defaultRootDir = prior }
            let proxy = await d.mitm
            let mitm = try #require(proxy, "the test daemon has its proxy")

            func token(_ real: String) -> [ManualToken] {
                [ManualToken(name: "stripe", realValue: real, envVarName: "STRIPE_API_KEY", hostFilters: ["api.stripe.com"])]
            }
            var p = Profile(name: "live", tool: .claude, authMode: .token)
            p.apiKey = Self.realA
            p.manualTokens = token(Self.realStripe)
            p.gitHTTPSCredentials = [GitHTTPSCredential(host: "github.com", username: "u", token: "ghp_REAL-git-not-for-the-guest")]
            p = try ProfileStore().save(p)
            let rec = RepairMarksTests.stopped(p.id.uuidString)
            try await d.registerForTesting(rec)
            let meta = URL(fileURLWithPath: await d.vmDir(rec.id) + "/meta", isDirectory: true)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)

            // First refresh (nothing known): the whole restage.
            await d.applyLiveRefresh(rec)
            let oldFake = try #require(await d.stagedStripeFake(p.id))
            var files = Self.tree(meta)
            #expect(!files.contains("REAL"), "no real value in the meta share or the seed")
            #expect(files.contains("export STRIPE_API_KEY='\(oldFake)'"), "api_key.env has the stand-in")
            #expect(files.contains("github.com"), "the seed has the git credential (as a stand-in)")
            #expect(files.contains("export HTTPS_PROXY=http://127.0.0.1:\(Daemon.guestProxyPort)"), "proxy.env rewritten")
            #expect(Self.counter(meta, "seed.generation") == 1 && Self.counter(meta, "env.generation") == 1)
            #expect(mitm.swapper.entries(for: p.id).contains { $0.fake == oldFake && $0.real == Self.realStripe })

            // A cosmetic edit: nothing restaged, no counter moves.
            p.name = "live-renamed"
            p = try ProfileStore().update(p)
            await d.applyLiveRefresh(rec)
            #expect(Self.counter(meta, "seed.generation") == 1 && Self.counter(meta, "env.generation") == 1)

            // The token changes: a new stand-in for new shells, the old one still
            // swapped for the running agent; the guest never sees either real value.
            p.manualTokens = token(Self.realB)
            p = try ProfileStore().update(p)
            await d.applyLiveRefresh(rec)
            let newFake = try #require(await d.stagedStripeFake(p.id))
            #expect(newFake != oldFake)
            files = Self.tree(meta)
            #expect(!files.contains("REAL"), "no real value after the edit either")
            #expect(files.contains("export STRIPE_API_KEY='\(newFake)'") && !files.contains(oldFake))
            #expect(Self.counter(meta, "seed.generation") == 2 && Self.counter(meta, "env.generation") == 2)
            let map = mitm.swapper.entries(for: p.id)
            #expect(map.contains { $0.fake == newFake && $0.real == Self.realB }, "the new stand-in swaps for the new value")
            #expect(map.contains { $0.fake == oldFake && $0.real == Self.realStripe }, "the running agent's keeps working")
            #expect(map.contains { $0.host == "github.com" && $0.real.contains("ghp_REAL") }, "an unchanged credential stays")

            // A forced restage (a sign-in: a credential exists, the profile is
            // as it was): the counters move with no edit.
            await d.applyLiveRefresh(rec, force: true)
            #expect(Self.counter(meta, "seed.generation") == 3 && Self.counter(meta, "env.generation") == 3)
            await d.applyLiveRefresh(rec)
            #expect(Self.counter(meta, "env.generation") == 3, "and an unforced one with no edit doesn't")

            // The guardrails, applied with it.
            p.guardrails.github = .destructive
            p = try ProfileStore().update(p)
            await d.applyLiveRefresh(rec)
            #expect(mitm.guardrailsConfig(for: p.id)?.github == .destructive)
            await MainActor.run { mitm.clearKube(for: p.id) }
            await d.shutdown()
        }

        /// A restage that failed (here: its meta share isn't a directory) isn't
        /// recorded as applied: the next refresh, with no edit since, does it.
        @Test func aFailedRestageIsDoneAgainNextTime() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let prior = ProfileStore.defaultRootDir
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            defer { ProfileStore.defaultRootDir = prior }
            var p = Profile(name: "fail", tool: .claude, authMode: .token)
            p.manualTokens = [ManualToken(name: "s", realValue: Self.realStripe, envVarName: "S", hostFilters: ["api.stripe.com"])]
            p = try ProfileStore().save(p)
            let rec = RepairMarksTests.stopped(p.id.uuidString)
            try await d.registerForTesting(rec)
            let vm = await d.vmDir(rec.id)
            try FileManager.default.createDirectory(atPath: vm, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: vm + "/meta", contents: Data("not a directory".utf8))
            await d.applyLiveRefresh(rec)
            try FileManager.default.removeItem(atPath: vm + "/meta")
            let meta = URL(fileURLWithPath: vm + "/meta", isDirectory: true)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
            await d.applyLiveRefresh(rec)              // no edit since: the restage is still owed
            #expect(Self.counter(meta, "env.generation") == 1 && Self.counter(meta, "seed.generation") == 1)
            let proxy = await d.mitm
            if let proxy { await MainActor.run { proxy.clearKube(for: p.id) } }
            await d.shutdown()
        }
    }
}

extension Daemon {
    /// The STRIPE_API_KEY stand-in the workspace's plan gives now.
    func stagedStripeFake(_ pid: UUID) async -> String? {
        guard let mitm, let raw = existingProfile(for: RepairMarksTests.stopped(pid.uuidString)) else { return nil }
        let plan = Self.makeSessionTokenPlan(for: await stagedProfile(raw), mitm: mitm)
        return plan.manualEnvExports.first { $0.0 == "STRIPE_API_KEY" }?.1
    }
}
