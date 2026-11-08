import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// TEMPORARY, with DaemonSandboxGuard.swift: a workspace asking for a
    /// guest protection this server can't stage yet isn't started (409,
    /// naming it), rather than booted without it.
    @Suite("Unenforceable sandbox refused (temporary)", .serialized)
    struct SandboxGuardTests {
        @Test func onlyTheSentryIsRefused() {
            var p = Profile(name: "plain", tool: .claude, authMode: .token)
            #expect(Daemon.unenforceableProtections(p).isEmpty, "a plain workspace starts")
            // Staged since writeSandboxFiles: the strict sandbox, the spec.
            p.strictSandbox = true
            p.networkPolicy = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\nprocess:\n  run_as_user: sandbox\n"
            #expect(Daemon.unenforceableProtections(p).isEmpty, "strict and a confining spec start")
            for mode in [KernelSentryMode.bestEffort, .hard] {
                p.kernelSentry = mode
                #expect(Daemon.unenforceableProtections(p) == ["the kernel sentry (\(mode.rawValue))"], "any sentry mode")
            }
        }

        @Test func aStartIsRefusedWith409() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            var p = Profile(name: "sentry-one", tool: .claude, authMode: .token)
            p.strictSandbox = true
            p.kernelSentry = .hard
            p = try ProfileStore().save(p)
            let rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            try await d.registerForTesting(rec)
            let r = await d.start(rec)
            #expect(r.status == 409, "\(r.body)")
            #expect("\(r.body)".contains("the kernel sentry (hard)") && !"\(r.body)".contains("strict"), "\(r.body)")
            #expect(await d.registry.find(rec.id)?.state == .stopped, "still stopped")
            await d.shutdown()
        }

        /// A VM taken back running isn't stopped, but its workspace's
        /// unstaged protection is said: on the Security Timeline as a
        /// degraded sandbox (and loudly in the daemon log).
        @Test func anAdoptedVMIsReportedUnprotected() async throws {
            var p = Profile(name: "adopted-sentry", tool: .claude, authMode: .token)
            p.strictSandbox = true
            p.kernelSentry = .bestEffort
            let rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            Daemon.warnUnenforceableAdopted(rec, profile: p)
            var seen: [SecurityTimeline.Event] = []
            for _ in 0..<100 {
                seen = await MainActor.run { SecurityTimeline.shared.allEvents.filter { $0.profileID == p.id } }
                if !seen.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!seen.isEmpty, "on the Security Timeline")
            // Nothing for a workspace that asks for nothing.
            let plain = Profile(name: "adopted-plain", tool: .claude, authMode: .token)
            Daemon.warnUnenforceableAdopted(RepairMarksTests.stopped(plain.id.uuidString.lowercased()), profile: plain)
            try await Task.sleep(for: .milliseconds(300))
            #expect(await MainActor.run { SecurityTimeline.shared.allEvents.filter { $0.profileID == plain.id }.isEmpty })
        }
    }
}
