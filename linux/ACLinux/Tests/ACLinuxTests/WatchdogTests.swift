import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The agent watchdog on the daemon (macOS: launch's wiring and
    /// handleWatchdogTrip): the mode is the workspace's, a trip in
    /// quarantine mode cuts the VM's port, pauses it and asks.
    @Suite("Agent watchdog", .serialized)
    struct WatchdogTests {
        /// A daemon whose workspace (`mode`) has a stand-in VM, wired.
        static func setUp(_ mode: String) async throws -> (Daemon, String, Profile, FakeCompromiseVM, MAC) {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            var p = Profile(name: "w", tool: .claude, authMode: .token)
            p.watchdogMode = mode
            p = try ProfileStore().save(p)
            // Ids as the daemon makes them (lowercase), with a VM directory.
            let rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            try await d.registerForTesting(rec)
            try FileManager.default.createDirectory(atPath: await d.vmDir(rec.id), withIntermediateDirectories: true)
            let vm = FakeCompromiseVM()
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in (rec.id, vm) } }
            await d.wireWatchdog()
            return (d, dir, p, vm, MAC(InterimSwitch.mac(rec.mac)))
        }

        static func tearDown(_ d: Daemon, _ dir: String, _ prior: URL?) async {
            await d.shutdown()
            AgentWatchdog.shared.onTrip = nil
            AgentWatchdog.shared.modeProvider = { _ in .off }
            Daemon.compromiseVMForTesting.withLockedValue { $0 = nil }
            Daemon.watchdogAnswerForTesting.withLockedValue { $0 = nil }
            ProfileStore.defaultRootDir = prior
            try? FileManager.default.removeItem(atPath: dir)
        }

        /// Enough firewall denials in a minute to trip it (threshold 20).
        static func trip(_ pid: UUID) {
            for i in 0..<AgentWatchdog.threshold {
                AgentWatchdog.shared.observe(profileID: pid, eventType: "egress.firewall",
                                             eventData: ["action": .string("deny"), "host": .string("h\(i).example"), "reason": .string("test")])
            }
        }

        /// Waits (bounded) for the stand-in VM's calls to reach `n`.
        static func calls(_ vm: FakeCompromiseVM, _ n: Int) async -> [String] {
            for _ in 0..<200 where vm.calls.withLockedValue({ $0.count }) < n { try? await Task.sleep(for: .milliseconds(20)) }
            return vm.calls.withLockedValue { $0 }
        }

        static let frame = TestFrames.tcp(to: TestFrames.ip("198.51.100.9"), port: 443, flags: 0x02)

        @Test func releaseRestoresTheNetworkAndResumes() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, dir, p, vm, port) = try await Self.setUp("quarantine")
            let seen = NIOLockedValueBox<(SwitchEgressFirewall.Action, [String])?>(nil)
            Daemon.watchdogAnswerForTesting.withLockedValue {
                $0 = { _ in
                    let action = await d.sw.egress.handle(Self.frame, from: port)
                    #expect(WorkspaceQuarantine.shared.contains(p.id), "every other host channel cut too")
                    seen.withLockedValue { $0 = (action, vm.calls.withLockedValue { $0 }) }
                    return 2
                }
            }
            #expect(AgentWatchdog.shared.modeProvider(p.id) == .quarantine, "the workspace's mode")
            Self.trip(p.id)
            #expect(await Self.calls(vm, 2) == ["pause", "resume"])
            let asked = seen.withLockedValue { $0 }
            #expect(asked?.0 == .consumed && asked?.1 == ["pause"], "asked with the port cut and the VM paused")
            #expect(await d.sw.egress.handle(Self.frame, from: port) != .consumed, "released")
            #expect(!WorkspaceQuarantine.shared.contains(p.id), "and the other channels with it")
            #expect(AgentWatchdog.shared.score(profileID: p.id) == 0, "a fresh window")
            await Self.tearDown(d, dir, prior)
        }

        @Test func keepQuarantinedResumesWithTheNetworkCut() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, dir, p, vm, port) = try await Self.setUp("quarantine")
            Daemon.watchdogAnswerForTesting.withLockedValue { $0 = { _ in 1 } }
            Self.trip(p.id)
            #expect(await Self.calls(vm, 2) == ["pause", "resume"])
            #expect(await d.sw.egress.handle(Self.frame, from: port) == .consumed, "still cut")
            #expect(WorkspaceQuarantine.shared.contains(p.id), "kept: the other channels stay cut")
            // The session's end starts the watchdog over.
            await d.clearWorkspaceProxyState(p.id)
            #expect(!WorkspaceQuarantine.shared.contains(p.id), "the quarantine ends with the session")
            #expect(AgentWatchdog.shared.score(profileID: p.id) == 0)
            await Self.tearDown(d, dir, prior)
        }

        /// A VM's stop clears its quarantine mark (finishStop's
        /// clearWorkspaceProxyState), so a later daemon restart doesn't
        /// re-quarantine a healthy VM.
        @Test func aStopClearsTheQuarantineMark() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, dir, p, vm, _) = try await Self.setUp("quarantine")
            Daemon.watchdogAnswerForTesting.withLockedValue { $0 = { _ in 1 } }
            Self.trip(p.id)
            _ = await Self.calls(vm, 2)
            let mark = Daemon.quarantineMark(await d.vmDir(p.id.uuidString.lowercased()))
            #expect(FileManager.default.fileExists(atPath: mark), "kept quarantined: marked")
            await d.clearWorkspaceProxyState(p.id)
            #expect(!FileManager.default.fileExists(atPath: mark), "the stop clears it")
            await Self.tearDown(d, dir, prior)
        }

        @Test func shutDownNeverResumes() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, dir, p, vm, _) = try await Self.setUp("quarantine")
            let answered = NIOLockedValueBox(false)
            Daemon.watchdogAnswerForTesting.withLockedValue { $0 = { _ in answered.withLockedValue { $0 = true }; return 0 } }
            Self.trip(p.id)
            for _ in 0..<200 where !answered.withLockedValue({ $0 }) { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(200))
            #expect(answered.withLockedValue { $0 } && vm.calls.withLockedValue { $0 } == ["pause"], "paused, never resumed")
            await Self.tearDown(d, dir, prior)
        }

        /// Alert mode records the trip but touches neither the VM nor its
        /// port; off doesn't score at all. A save changes the mode.
        @Test func alertAndOffLeaveTheVMAlone() async throws {
            let prior = ProfileStore.defaultRootDir
            var (d, dir, p, vm, port) = try await Self.setUp("alert")
            Daemon.watchdogAnswerForTesting.withLockedValue { $0 = { _ in Issue.record("asked in alert mode"); return 2 } }
            Self.trip(p.id)
            try? await Task.sleep(for: .milliseconds(300))
            let action = await d.sw.egress.handle(Self.frame, from: port)
            #expect(vm.calls.withLockedValue { $0 }.isEmpty && action != .consumed)
            #expect(AgentWatchdog.shared.score(profileID: p.id) >= AgentWatchdog.threshold, "scored")
            await Self.tearDown(d, dir, prior)
            (d, dir, p, vm, port) = try await Self.setUp("off")
            Self.trip(p.id)
            #expect(AgentWatchdog.shared.score(profileID: p.id) == 0)
            p.watchdogMode = "quarantine"
            try ProfileStore().update(p)
            Daemon.refreshWatchdogModes()
            #expect(AgentWatchdog.shared.modeProvider(p.id) == .quarantine, "re-read from the store")
            await Self.tearDown(d, dir, prior)
        }

        /// The quarantine survives a daemon restart: marked in the VM's
        /// directory, a taken-back VM's port is cut again before it's
        /// attached; a Release or the session's end takes the mark.
        @Test func theQuarantineIsMarkedForARestart() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, dir, p, vm, port) = try await Self.setUp("quarantine")
            let id = p.id.uuidString.lowercased()
            let mark = Daemon.quarantineMark(await d.vmDir(id))
            Daemon.watchdogAnswerForTesting.withLockedValue { $0 = { _ in 1 } }
            Self.trip(p.id)
            #expect(await Self.calls(vm, 2) == ["pause", "resume"])
            #expect(FileManager.default.fileExists(atPath: mark), "marked")
            // A restarted daemon: nothing in memory, the mark on disk.
            await d.sw.egress.setQuarantined(false, for: port)
            let rec = try #require(await d.registry.find(id))
            #expect(await d.readoptQuarantine(rec))
            #expect(await d.sw.egress.handle(Self.frame, from: port) == .consumed, "cut again")
            await d.clearWorkspaceProxyState(p.id)
            #expect(!FileManager.default.fileExists(atPath: mark), "the session's end takes it")
            #expect(await !d.readoptQuarantine(rec))
            await Self.tearDown(d, dir, prior)
        }

        /// A compromise alert and the watchdog's question up at once: the
        /// watchdog's Release neither resumes the VM nor opens its network
        /// while the alert holds it; the alert's answer, last, does both.
        @Test func aReleaseWaitsForACompromiseAlert() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, dir, p, vm, port) = try await Self.setUp("quarantine")
            defer { Daemon.compromiseAnswerForTesting.withLockedValue { $0 = nil } }
            await d.mitm?.swapper.setCompromiseHandler { _ in }
            let alertMayAnswer = NIOLockedValueBox(false), alertAsked = NIOLockedValueBox(false)
            Daemon.compromiseAnswerForTesting.withLockedValue {
                $0 = { _ in
                    alertAsked.withLockedValue { $0 = true }
                    for _ in 0..<500 where !alertMayAnswer.withLockedValue({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
                    return 1                                            // Block
                }
            }
            Daemon.watchdogAnswerForTesting.withLockedValue { $0 = { _ in 2 } }   // Release
            let alert = Task { await d.handleCompromise(DaemonGlobalSuites.CompromiseHandlerTests.event(p.id)) }
            for _ in 0..<200 where !alertAsked.withLockedValue({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
            Self.trip(p.id)
            try await Task.sleep(for: .milliseconds(400))
            #expect(vm.calls.withLockedValue { $0 } == ["pause"], "paused once, not resumed by the Release")
            #expect(await d.sw.egress.handle(Self.frame, from: port) == .consumed, "still cut while the alert is up")
            alertMayAnswer.withLockedValue { $0 = true }
            await alert.value
            #expect(vm.calls.withLockedValue { $0 } == ["pause", "resume"], "the last answer resumes it")
            #expect(await d.sw.egress.handle(Self.frame, from: port) != .consumed, "and the Release opens the network")
            #expect(AgentWatchdog.shared.score(profileID: p.id) == 0, "a fresh window")
            await Self.tearDown(d, dir, prior)
        }

        /// DHCP is IP: a quarantined VM gets no lease (macOS drops it too).
        @Test func aQuarantineDropsDHCP() {
            let rig = FirewallRig()
            let discover = TestFrames.udp(to: 0xFFFF_FFFF, port: 67, sport: 68)
            #expect(!rig.fw.quarantineDrops(discover, from: rig.a))
            rig.fw.setQuarantined(true, for: rig.a)
            #expect(rig.fw.quarantineDrops(discover, from: rig.a))
            let arp = Data(TestFrames.gateway + TestFrames.guest + [0x08, 0x06] + [UInt8](repeating: 0, count: 28))
            #expect(!rig.fw.quarantineDrops(arp, from: rig.a), "ARP still goes")
            let lldp = Data([0x01, 0x80, 0xC2, 0, 0, 0x0E] + TestFrames.guest + [0x88, 0xCC] + [UInt8](repeating: 0, count: 32))
            #expect(rig.fw.quarantineDrops(lldp, from: rig.a), "any other ethertype, on a port the firewall doesn't govern")
        }

        /// A VM whose pause state takes a while to read, or can't be read.
        final class SlowVM: CompromiseVM, @unchecked Sendable {
            let calls = NIOLockedValueBox<[String]>([])
            let state = NIOLockedValueBox<Bool?>(false)
            func pause() async throws { calls.withLockedValue { $0.append("pause") }; state.withLockedValue { if $0 != nil { $0 = true } } }
            func resume() async throws { calls.withLockedValue { $0.append("resume") }; state.withLockedValue { if $0 != nil { $0 = false } } }
            func isPaused() async -> Bool? { try? await Task.sleep(for: .milliseconds(200)); return state.withLockedValue { $0 } }
        }

        /// A question that holds the VM while the last one lets go (during
        /// its pause check) keeps it paused; an unreadable state resumes.
        @Test func aHoldDuringTheLetGoKeepsItPaused() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, dir, _, _, _) = try await Self.setUp("quarantine")
            let vm = SlowVM()
            try await d.holdPause("vm-x", vm)
            let letGo = Task { await d.letGoPause("vm-x", vm) }
            try await Task.sleep(for: .milliseconds(50))
            try await d.holdPause("vm-x", vm)                         // the compromise alert, meanwhile
            await letGo.value
            #expect(!vm.calls.withLockedValue { $0 }.contains("resume"), "still held: not resumed")
            #expect(await d.pauseHolds["vm-x"] == 1)
            await d.letGoPause("vm-x", vm)
            #expect(vm.calls.withLockedValue { $0 }.last == "resume", "the last one resumes it")
            // The API doesn't answer: resumed anyway, never left paused.
            let blind = SlowVM()
            blind.state.withLockedValue { $0 = nil }
            try await d.holdPause("vm-y", blind)
            await d.letGoPause("vm-y", blind)
            #expect(blind.calls.withLockedValue { $0 } == ["pause", "resume"])
            await Self.tearDown(d, dir, prior)
        }

        /// Taken back paused with no quarantine mark: resumed, or stopped if
        /// its workspace was marked compromised; a mark whose workspace is no
        /// longer in quarantine mode goes, and nothing is cut.
        @Test func aPausedVMTakenBackIsResumedOrStopped() async throws {
            let prior = ProfileStore.defaultRootDir
            var (d, dir, p, vm, port) = try await Self.setUp("quarantine")
            let id = p.id.uuidString.lowercased()
            try await vm.pause()
            await d.readoptPaused(id)
            #expect(vm.calls.withLockedValue { $0 } == ["pause", "resume"], "no question up: resumed")
            try await vm.pause()
            Daemon.markCompromised(p, store: ProfileStore())
            await d.readoptPaused(id)
            #expect(vm.calls.withLockedValue { $0 }.last == "pause", "marked compromised: not resumed")
            await Self.tearDown(d, dir, prior)
            (d, dir, p, vm, port) = try await Self.setUp("alert")
            let rec = try #require(await d.registry.find(p.id.uuidString.lowercased()))
            let mark = Daemon.quarantineMark(await d.vmDir(rec.id))
            try Data().write(to: URL(fileURLWithPath: mark))
            #expect(await !d.readoptQuarantine(rec), "alert mode now: not re-applied")
            #expect(!FileManager.default.fileExists(atPath: mark), "and the mark is gone")
            #expect(await d.sw.egress.handle(Self.frame, from: port) != .consumed)
            await Self.tearDown(d, dir, prior)
        }

        /// One watchdog question per VM: a second trip while it's up (a
        /// re-ask racing a trip) asks nothing.
        @Test func oneQuestionPerVM() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, dir, p, _, _) = try await Self.setUp("quarantine")
            let asked = NIOLockedValueBox(0)
            Daemon.watchdogAnswerForTesting.withLockedValue {
                $0 = { _ in asked.withLockedValue { $0 += 1 }; try? await Task.sleep(for: .milliseconds(300)); return 1 }
            }
            async let a: Void = d.quarantineAndAsk(p.id, signals: [])
            async let b: Void = d.quarantineAndAsk(p.id, signals: [])
            _ = await (a, b)
            #expect(asked.withLockedValue { $0 } == 1)
            await Self.tearDown(d, dir, prior)
        }

        /// A daemon that stops clears AgentWatchdog's hooks only if they're
        /// still its own.
        @Test func aStoppingDaemonLeavesAnothersHooks() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d1, dir1, _, _, _) = try await Self.setUp("quarantine")
            let (d2, dir2, p2, _, _) = try await Self.setUp("quarantine")
            await d1.shutdown()
            #expect(AgentWatchdog.shared.onTrip != nil && AgentWatchdog.shared.modeProvider(p2.id) == .quarantine,
                    "d2's hooks stay")
            await Self.tearDown(d2, dir2, prior)
            #expect(AgentWatchdog.shared.onTrip == nil)
            try? FileManager.default.removeItem(atPath: dir1)
        }
    }
}
