import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

@Suite("Base image stamps")
struct BaseImageStampTests {
    @Test("a same-major rebuild bumps a dot-revision; a new major, or none on disk, writes the version fresh")
    func nextStamp() {
        #expect(InterimBake.majorVersion(of: "201") == "201")
        #expect(InterimBake.majorVersion(of: "201.3") == "201")
        #expect(InterimBake.nextStamp(priorStamp: nil, bundled: "201") == "201")
        #expect(InterimBake.nextStamp(priorStamp: " ", bundled: "201") == "201")
        #expect(InterimBake.nextStamp(priorStamp: "201\n", bundled: "201") == "201.1")
        #expect(InterimBake.nextStamp(priorStamp: "201.1", bundled: "201") == "201.2")
        #expect(InterimBake.nextStamp(priorStamp: "200.7", bundled: "201") == "201")
        #expect(InterimBake.nextStamp(priorStamp: "201.x", bundled: "201") == "201.1")
    }
}

extension DaemonGlobalSuites {
    /// The drift offer at a workspace's cold boot (macOS: launch's drift
    /// check, resolveRemoteLaunchPrompts): asked once a newer base is on
    /// disk; "Yes" resets the system disk, "No" holds for that base,
    /// "Remind me later" for a day; an unattended start boots as-is.
    @Suite("Base image drift", .serialized)
    struct BaseImageDriftTests {
        struct Setup {
            let d: Daemon, rec: VMRecord, profile: Profile, dir: String, disk: String
        }

        /// A stopped workspace cloned from base 201, with 201.1 on disk.
        static func setup(recorded: String? = "201", current: String = "201.1") async throws -> Setup {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            var p = Profile(name: "drifted", tool: .claude, authMode: .token)
            p.baseImageVersionAtClone = recorded
            p = try ProfileStore().save(p)
            let key = p.id.uuidString.lowercased()
            var rec = RepairMarksTests.stopped(key)
            rec.name = "drifted"
            try await d.registerForTesting(rec)
            try FileManager.default.createDirectory(atPath: dir + "/image", withIntermediateDirectories: true)
            try (current + "\n").write(toFile: dir + "/image/base.version", atomically: true, encoding: .utf8)
            let vm = await d.vmDir(key)
            try FileManager.default.createDirectory(atPath: vm, withIntermediateDirectories: true)
            try Data("disk".utf8).write(to: URL(fileURLWithPath: vm + "/disk.raw"))
            // The launch itself stops here: no Firecracker in unit tests.
            Daemon.launchHookForTesting.withLockedValue { $0 = { _ in throw CancellationError() } }
            return Setup(d: d, rec: rec, profile: p, dir: dir, disk: vm + "/disk.raw")
        }

        static func teardown(_ s: Setup, prior: URL?) async {
            Daemon.launchHookForTesting.withLockedValue { $0 = nil }
            Daemon.driftAnswerForTesting.withLockedValue { $0 = nil }
            ProfileStore.defaultRootDir = prior
            await s.d.shutdown()
            try? FileManager.default.removeItem(atPath: s.dir)
        }

        static func answering(_ index: Int, count: NIOLockedValueBox<Int>) {
            Daemon.driftAnswerForTesting.withLockedValue { $0 = { _ in count.withLockedValue { $0 += 1 }; return index } }
        }

        static func stored(_ id: UUID) -> Profile? { ProfileStore().loadAll().first { $0.id == id } }

        @Test func yesResetsTheSystemDiskAndTheStartGoesOn() async throws {
            let prior = ProfileStore.defaultRootDir
            let s = try await Self.setup()
            let asked = NIOLockedValueBox(0)
            Self.answering(0, count: asked)
            let r = await s.d.start(s.rec)
            #expect(asked.withLockedValue { $0 } == 1)
            #expect(!FileManager.default.fileExists(atPath: s.disk), "the next boot clones base v201.1")
            #expect(!"\(r.body)".contains("base image"), "on to the launch: \(r.body)")
            await Self.teardown(s, prior: prior)
        }

        @Test func noHoldsForThatBaseAndKeepsTheDisk() async throws {
            let prior = ProfileStore.defaultRootDir
            let s = try await Self.setup()
            let asked = NIOLockedValueBox(0)
            Self.answering(1, count: asked)
            _ = await s.d.start(s.rec)
            #expect(FileManager.default.fileExists(atPath: s.disk))
            #expect(Self.stored(s.profile.id)?.baseImageUpgradeDeclinedFor == "201.1")
            _ = await s.d.start(s.rec)
            #expect(asked.withLockedValue { $0 } == 1, "not asked again for 201.1")
            // A newer base: asked again.
            try "201.2\n".write(toFile: s.dir + "/image/base.version", atomically: true, encoding: .utf8)
            _ = await s.d.start(s.rec)
            #expect(asked.withLockedValue { $0 } == 2)
            await Self.teardown(s, prior: prior)
        }

        @Test func remindMeLaterHoldsForADay() async throws {
            let prior = ProfileStore.defaultRootDir
            let s = try await Self.setup()
            let asked = NIOLockedValueBox(0)
            Self.answering(2, count: asked)
            _ = await s.d.start(s.rec)
            let p = try #require(Self.stored(s.profile.id))
            let until = try #require(p.baseImageUpgradeRemindAfter)
            #expect(abs(until.timeIntervalSinceNow - 86_400) < 60)
            #expect(p.baseImageUpgradeDeclinedFor == nil)
            #expect(FileManager.default.fileExists(atPath: s.disk))
            _ = await s.d.start(s.rec)
            #expect(asked.withLockedValue { $0 } == 1)
            await Self.teardown(s, prior: prior)
        }

        @Test func anUnattendedStartIsNotAskedAndBootsAsIs() async throws {
            let prior = ProfileStore.defaultRootDir
            let s = try await Self.setup()
            let asked = NIOLockedValueBox(0)
            Self.answering(0, count: asked)
            _ = await s.d.start(s.rec, unattended: true)
            #expect(asked.withLockedValue { $0 } == 0)
            #expect(FileManager.default.fileExists(atPath: s.disk))
            await Self.teardown(s, prior: prior)
        }

        @Test func noOfferOnTheSameBaseOrWithoutADiskOrARecord() async throws {
            let prior = ProfileStore.defaultRootDir
            for (recorded, current, disk) in [("201.1", "201.1", true), ("201", "201.1", false), (nil, "201.1", true)] as [(String?, String, Bool)] {
                let s = try await Self.setup(recorded: recorded, current: current)
                if !disk { try FileManager.default.removeItem(atPath: s.disk) }
                let asked = NIOLockedValueBox(0)
                Self.answering(0, count: asked)
                _ = await s.d.start(s.rec)
                #expect(asked.withLockedValue { $0 } == 0, "\(String(describing: recorded)) \(current) disk \(disk)")
                await Self.teardown(s, prior: prior)
            }
        }

        @Test func oneQuestionPerWorkspaceAndYesWaitsForADiskInUse() async throws {
            let prior = ProfileStore.defaultRootDir
            let s = try await Self.setup()
            let release = NIOLockedValueBox(false), entered = NIOLockedValueBox(false)
            Daemon.driftAnswerForTesting.withLockedValue { $0 = { _ in
                entered.withLockedValue { $0 = true }
                while !release.withLockedValue({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
                return 0
            } }
            let first = Task { await s.d.start(s.rec) }
            while !entered.withLockedValue({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
            let second = await s.d.start(s.rec)
            #expect(second.status == 409 && "\(second.body)".contains("question up"), "\(second.body)")
            // A start under way meanwhile has the disk: "Yes" isn't carried out.
            await s.d.markStartingForTesting(s.rec.id, true)
            release.withLockedValue { $0 = true }
            let r = await first.value
            #expect(r.status == 409 && (r.body["error"]?.stringValue ?? "").contains("wasn't upgraded"), "\(r.body)")
            #expect(FileManager.default.fileExists(atPath: s.disk))
            await s.d.markStartingForTesting(s.rec.id, false)
            await Self.teardown(s, prior: prior)
        }

        @Test func theCloneStampAndTheResetEventRecordTheBase() async throws {
            let prior = ProfileStore.defaultRootDir
            let s = try await Self.setup(recorded: nil, current: "201.3")
            await s.d.stampBaseImageVersionAtClone(try #require(await s.d.readCurrentBaseVersion()), profileID: s.profile.id)
            #expect(Self.stored(s.profile.id)?.baseImageVersionAtClone == "201.3")
            await Self.teardown(s, prior: prior)
        }

        @Test func thePromptsWordsAreMacOSs() {
            let (title, message) = Daemon.driftPromptParts(recorded: "201", current: "201.1")
            #expect(title == "A newer base image is available.")
            #expect(message.hasPrefix("This workspace runs base v201; v201.1 is on disk. Upgrade it now?"))
            #expect(Daemon.baseImageUpgradeButtons == ["Yes, upgrade", "No", "Remind me later"])
        }
    }
}
