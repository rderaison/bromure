import Foundation
import SandboxEngine
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// TEMPORARY, with DaemonSandboxGuard.swift: a workspace asking for a
    /// guest protection this server can't stage yet isn't started (409,
    /// naming it), rather than booted without it.
    @Suite("Unenforceable sandbox refused", .serialized)
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
                // With a verified catalog for this host's arch, it starts (as on macOS).
                #expect(Daemon.unenforceableProtections(p, sentryCatalog: true).isEmpty)
            }
        }

        /// A separate run_as user together with shared folders isn't started
        /// on a Linux host: the shares stay owned by the workspace user, so
        /// its workload could never write them (linux/VIRTIOFS_DAC.md,
        /// option 6). Said as a combination to undo, not a protection to come.
        @Test func runAsUserWithSharedFoldersIsRefused() {
            let spec = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\nprocess:\n  run_as_user: sandbox\n"
            var p = Profile(name: "runas", tool: .claude, authMode: .token)
            p.networkPolicy = spec
            #expect(Daemon.runAsUserBlockedByShares(p) == nil, "no shared folders: it starts")
            p.folderPaths = ["/srv/projects/app"]
            #expect(Daemon.runAsUserBlockedByShares(p) == "sandbox")
            let refused = Daemon.unenforceableProtections(p)
            #expect(refused == ["run_as_user 'sandbox' is set together with shared folders"], "\(refused)")
            let message = SandboxUnavailable(workspace: "w", missing: refused).description
            #expect(message.contains("'w' isn't started: its policy's run_as_user 'sandbox' is set together with shared folders")
                    && message.contains("Remove run_as_user from the policy, or the workspace's shared folders")
                    && !message.contains("yet"), "\(message)")
            // The workspace user itself isn't a separate user ("ubuntu" fails
            // the strict parse; the guest is handed it anyway, so it's read
            // the guest's way). A numeric other user is.
            for same in ["ubuntu", "1000"] {
                p.networkPolicy = spec.replacingOccurrences(of: "sandbox", with: same)
                #expect(OpenShellSandboxSpec(policyYAML: p.networkPolicy, workdirs: [], strictSandbox: false,
                                             sentry: "off").process != nil, "the guest gets a process section")
                #expect(Daemon.runAsUserBlockedByShares(p) == nil, "\(same)")
            }
            p.networkPolicy = spec.replacingOccurrences(of: "sandbox", with: "999")
            #expect(Daemon.runAsUserBlockedByShares(p) == "999", "a numeric uid")
            // A policy the strict parse refuses elsewhere (an unknown key, a
            // bad rule) still stages its process section: still refused.
            for fault in ["_provider_: x\n", "network_policies: not-a-mapping\n"] {
                p.networkPolicy = spec + fault
                #expect((try? OpenShellPolicy.parse(p.networkPolicy)) == nil, "the strict parse fails: \(fault)")
                #expect(Daemon.runAsUserBlockedByShares(p) == "sandbox", "still refused: \(fault)")
            }
            // A group alone keeps the workspace user's uid, which owns the shares.
            p.networkPolicy = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\nprocess:\n  run_as_group: sandbox\n"
            #expect(Daemon.runAsUserBlockedByShares(p) == nil, "run_as_group only")
            p.networkPolicy = ""
            #expect(Daemon.runAsUserBlockedByShares(p) == nil, "no OpenShell policy")
        }

        /// A VM taken back running with a run_as user and shared folders
        /// isn't reported as unprotected: nothing is missing from its sandbox,
        /// and its guest's own status says the user can't write the shares.
        @Test func anAdoptedRunAsVMWithSharesIsNotReportedUnprotected() async throws {
            var p = Profile(name: "adopted-runas", tool: .claude, authMode: .token)
            p.networkPolicy = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\nprocess:\n  run_as_user: sandbox\n"
            p.folderPaths = ["/srv/projects/app"]
            Daemon.warnUnenforceableAdopted(RepairMarksTests.stopped(p.id.uuidString.lowercased()), profile: p)
            try await Task.sleep(for: .milliseconds(300))
            #expect(await MainActor.run { SecurityTimeline.shared.allEvents.filter { $0.profileID == p.id }.isEmpty })
        }

        /// A sandbox whose guest scripts aren't beside agentd isn't started
        /// either (an installed server that copied agentd alone): the strict
        /// marker without its attestor, a spec without its launcher.
        @Test func aSandboxWithoutItsGuestScriptsIsRefused() throws {
            let setup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../../Sources/AgentCoding/Resources/vm-setup").standardized
            let bare = URL(fileURLWithPath: try shortTempDir(), isDirectory: true)
            defer { try? FileManager.default.removeItem(at: bare) }
            try Data("#!/usr/bin/env python3\n".utf8).write(to: bare.appendingPathComponent("bromure-agentd.py"))
            var p = Profile(name: "plain", tool: .claude, authMode: .token)
            #expect(SessionDisk.missingGuestSandboxScripts(p, setupDir: bare).isEmpty, "a plain workspace needs none")
            p.strictSandbox = true
            #expect(SessionDisk.missingGuestSandboxScripts(p, setupDir: bare)
                    == ["bromure-attestd.py", "bromure-strict.py", "bromure_sandbox_status.py"])
            #expect(SessionDisk.missingGuestSandboxScripts(p, setupDir: setup).isEmpty, "the repo's vm-setup has them")
            p.networkPolicy = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\n"
            #expect(SessionDisk.missingGuestSandboxScripts(p, setupDir: bare)
                    == ["bromure-attestd.py", "bromure-strict.py", "bromure_sandbox_status.py",
                        "bromure-sandboxd", "bromure-sentryd", "bromure_openshell.py", "bromure_idmap.py"])
            #expect(SessionDisk.missingGuestSandboxScripts(p, setupDir: setup).isEmpty)
            let refused = Daemon.unenforceableProtections(p, setupDir: bare)
            #expect(refused.count == 1 && refused[0].hasPrefix("the guest sandbox's scripts bromure-attestd.py, "), "\(refused)")
            #expect(refused[0].hasSuffix(" are missing from \(bare.path)"))
            // Said as an incomplete install, with the fix; not as something Linux lacks.
            let message = SandboxUnavailable(workspace: "w", missing: refused).description
            #expect(message.contains("'w' isn't started: this server's install is incomplete")
                    && message.contains("Re-run the installer") && !message.contains("yet"), "\(message)")
            #expect(Daemon.unenforceableProtections(p, setupDir: setup).isEmpty)
        }

        /// On a server whose agentd stands alone (the test daemon's: no guest
        /// scripts beside it), a strict workspace's start is a 409 naming the
        /// missing scripts, and the VM stays stopped.
        @Test func aStrictStartWithoutTheScriptsIs409() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            var p = Profile(name: "strict-one", tool: .claude, authMode: .token)
            p.strictSandbox = true
            p = try ProfileStore().save(p)
            let rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            try await d.registerForTesting(rec)
            let r = await d.start(rec)
            #expect(r.status == 409, "\(r.body)")
            let error = r.body["error"]?.stringValue ?? ""
            #expect(error.contains("this server's install is incomplete (the guest sandbox's scripts bromure-attestd.py, "
                                   + "bromure-strict.py, bromure_sandbox_status.py are missing from \(dir))"), "\(error)")
            #expect(error.contains("Re-run the installer") && !error.contains("yet"), "\(error)")
            #expect(await d.registry.find(rec.id)?.state == .stopped, "still stopped")
            await d.shutdown()
        }

        @Test func aStartIsRefusedWith409() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            // The guest scripts beside the test daemon's agentd, as installed:
            // only the sentry is refused.
            let setup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../../Sources/AgentCoding/Resources/vm-setup").standardized
            for name in SessionDisk.strictGuestFiles + SessionDisk.specGuestFiles {
                try? FileManager.default.copyItem(at: setup.appendingPathComponent(name),
                                                  to: URL(fileURLWithPath: dir + "/" + name))
            }
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

        /// The start of a workspace whose policy runs as a separate user and
        /// that has shared folders is a 409 that says why and how to fix it,
        /// and the VM stays stopped.
        @Test func aRunAsStartWithSharedFoldersIs409() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            let setup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../../Sources/AgentCoding/Resources/vm-setup").standardized
            for name in SessionDisk.strictGuestFiles + SessionDisk.specGuestFiles {
                try? FileManager.default.copyItem(at: setup.appendingPathComponent(name),
                                                  to: URL(fileURLWithPath: dir + "/" + name))
            }
            let share = dir + "/project"
            try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: true)
            var p = Profile(name: "runas-shares", tool: .claude, authMode: .token)
            p.networkPolicy = "version: 1\nfilesystem_policy:\n  read_only: [/usr]\nprocess:\n  run_as_user: sandbox\n"
            p.folderPaths = [share]
            p = try ProfileStore().save(p)
            let rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            try await d.registerForTesting(rec)
            let r = await d.start(rec)
            #expect(r.status == 409, "\(r.body)")
            let error = r.body["error"]?.stringValue ?? ""
            #expect(error.contains("its policy's run_as_user 'sandbox' is set together with shared folders")
                    && error.contains("Remove run_as_user from the policy"), "\(error)")
            #expect(await d.registry.find(rec.id)?.state == .stopped, "still stopped")
            await d.shutdown()
        }

        /// A VM taken back running isn't stopped, but its workspace's
        /// unstaged protection is said: on the Security Timeline as a
        /// degraded sandbox (and loudly in the daemon log).
        /// A strict VM taken back that booted on an incomplete install (its
        /// meta share has no attestor) is said to run unprotected; one whose
        /// scripts were staged isn't.
        @Test func anAdoptedVMStagedWithoutItsScriptsIsReported() async throws {
            let meta = URL(fileURLWithPath: try shortTempDir(), isDirectory: true)
            defer { try? FileManager.default.removeItem(at: meta) }
            var p = Profile(name: "adopted-strict", tool: .claude, authMode: .token)
            p.strictSandbox = true
            Daemon.warnUnenforceableAdopted(RepairMarksTests.stopped(p.id.uuidString.lowercased()), profile: p, staged: meta)
            var seen: [SecurityTimeline.Event] = []
            for _ in 0..<100 {
                seen = await MainActor.run { SecurityTimeline.shared.allEvents.filter { $0.profileID == p.id } }
                if !seen.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(seen.contains { "\($0)".contains("bromure-attestd.py") }, "\(seen)")
            for name in SessionDisk.strictGuestFiles + [SessionDisk.sandboxStatusModule] {
                try Data("#\n".utf8).write(to: meta.appendingPathComponent(name))
            }
            var q = Profile(name: "adopted-staged", tool: .claude, authMode: .token)
            q.strictSandbox = true
            Daemon.warnUnenforceableAdopted(RepairMarksTests.stopped(q.id.uuidString.lowercased()), profile: q, staged: meta)
            try await Task.sleep(for: .milliseconds(300))
            #expect(await MainActor.run { SecurityTimeline.shared.allEvents.filter { $0.profileID == q.id }.isEmpty })
        }

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
