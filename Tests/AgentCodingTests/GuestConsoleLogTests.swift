import Foundation
import Testing
@testable import bromure_ac

// B47: the guest serial console goes to a per-VM file; only trouble reaches
// the app log, prefixed with the workspace. B48: the host lists the virtiofs
// tags it attached so the guest can skip absent fstab slots.
@Suite("Guest console → app log filter")
struct GuestConsoleLogTests {

    @Test("login prompts and boot chatter stay out of the app log")
    func chatterDropped() {
        for line in ["qa-security login: ", "Ubuntu 24.04.5 LTS daily hvc0",
                     "root: clean, 158915/1540096 files, 1706798/6159872 blocks", ""] {
            #expect(UbuntuSandboxVM.consoleLineForAppLog(line, name: "QA") == nil)
        }
    }

    @Test("failures are forwarded, prefixed, colour stripped")
    func failuresForwarded() {
        let raw = "[\u{1B}[0;1;31mFAILED\u{1B}[0m] Failed to mount \u{1B}[0;1;39mhome-ubuntu.mount\u{1B}[0m - /home/ubuntu."
        #expect(UbuntuSandboxVM.consoleLineForAppLog(raw, name: "Daily")
                == "[guest Daily] [FAILED] Failed to mount home-ubuntu.mount - /home/ubuntu.")
        #expect(UbuntuSandboxVM.consoleLineForAppLog("Kernel panic - not syncing: VFS", name: "x") != nil)
        #expect(UbuntuSandboxVM.consoleLineForAppLog("/dev/vda2: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.", name: "x") != nil)
    }

    @Test("virtiofs tag markers are rewritten per boot")
    func tagMarkers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UbuntuSandboxVM.writeVirtiofsTagMarkers(["bromure-home", "share-1", "share-2"], in: dir)
        UbuntuSandboxVM.writeVirtiofsTagMarkers(["share-1"], in: dir)
        let listed = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent(UbuntuSandboxVM.virtiofsTagMarkerDir).path)
        #expect(listed == ["share-1"])
    }
}

// B46: the classifiers stay resident only for running workspaces that use them.
@Suite("Classifier lifecycle needs")
struct ClassifierLifecycleTests {
    @Test("needs follow the running workspaces' policies")
    func needs() {
        var a = Profile(name: "a", tool: .claude, authMode: .token)
        var b = Profile(name: "b", tool: .claude, authMode: .token)
        #expect(ClassifierLifecycle.needs(for: [a, b]) == .init())
        a.pii.enabled = true
        b.promptInjection.detectRulesInjection = true
        let n = ClassifierLifecycle.needs(for: [a, b])
        #expect(n.pii && n.rulesInjection && !n.sourceInjection)
        #expect(ClassifierLifecycle.needs(for: []) == .init())
    }

    @Test("an unloaded classifier reports nothing to release")
    func unloadNoop() async {
        #expect(await PIIDetector().unloadIfIdle(0) == false)
    }
}

