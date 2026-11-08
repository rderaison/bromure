import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// TEMPORARY, with DaemonSandboxGuard.swift: a workspace asking for a
    /// guest protection this server can't stage yet isn't started (409,
    /// naming it), rather than booted without it.
    @Suite("Unenforceable sandbox refused (temporary)", .serialized)
    struct SandboxGuardTests {
        @Test func eachProtectionIsNamed() {
            var p = Profile(name: "plain", tool: .claude, authMode: .token)
            #expect(Daemon.unenforceableProtections(p).isEmpty, "a plain workspace starts")
            p.networkPolicy = "version: 1\nnetwork_policies: {}\n"
            #expect(Daemon.unenforceableProtections(p).isEmpty, "network rules only: enforced on the host")
            p.strictSandbox = true
            #expect(Daemon.unenforceableProtections(p) == ["the strict sandbox"])
            p.strictSandbox = false
            p.networkPolicy = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\n"
            #expect(Daemon.unenforceableProtections(p).contains("an OpenShell filesystem_policy"))
            p.networkPolicy = "version: 1\nprocess:\n  run_as_user: sandbox\n"
            let process = Daemon.unenforceableProtections(p)
            #expect(process.contains("OpenShell process rules") && process.contains("the strict sandbox"),
                    "a process section implies strict (effectiveStrictSandbox): \(process)")
            p.networkPolicy = ""
            for mode in [KernelSentryMode.bestEffort, .hard] {
                p.kernelSentry = mode
                #expect(Daemon.unenforceableProtections(p) == ["the kernel sentry (\(mode.rawValue))"], "any mode")
            }
        }

        @Test func aStartIsRefusedWith409() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            var p = Profile(name: "strict-one", tool: .claude, authMode: .token)
            p.strictSandbox = true
            p.kernelSentry = .hard
            p = try ProfileStore().save(p)
            let rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            try await d.registerForTesting(rec)
            let r = await d.start(rec)
            #expect(r.status == 409, "\(r.body)")
            #expect("\(r.body)".contains("the strict sandbox") && "\(r.body)".contains("the kernel sentry (hard)"), "\(r.body)")
            #expect(await d.registry.find(rec.id)?.state == .stopped, "still stopped")
            await d.shutdown()
        }
    }
}
