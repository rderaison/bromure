import Foundation
import Testing
@testable import ACLinux

/// The detectors' models on Linux: fetched into this user's own models dir
/// (the one the classifiers load from), never by a test.
@Suite("Detector models: per user, fetched only by a real daemon")
struct DetectorModelsTests {
    @Test func onlyADaemonFromItsEnvironmentFetches() {
        let coded = DaemonConfig(stateDir: "/s", runtimeDir: "/r", imageDir: "/i", agentdPath: "/a")
        #expect(!coded.fetchesModels, "a config made in code (tests') never fetches")
        #expect(DaemonConfig.fromEnvironment(["HOME": "/h"]).fetchesModels)
        #expect(!DaemonConfig.fromEnvironment(["HOME": "/h", "BROMURE_MODELS_FETCH": "0"]).fetchesModels)
    }

    /// Downloaded where they're loaded from: this user's data dir.
    @Test func theyLandWhereTheClassifiersLook() async {
        let source = await PromptInjectionClassifier.shared.modelDirectory.path
        let rules = await PromptInjectionClassifier.claudeMd.modelDirectory.path
        #expect(PromptInjectionModels.directory(for: .promptGuard).path == source)
        #expect(PromptInjectionModels.directory(for: .claudeMdGuard).path == rules)
        #expect(PromptInjectionModels.modelsRoot.path.hasPrefix(NSHomeDirectory()) || ProcessInfo.processInfo.environment["XDG_DATA_HOME"] != nil)
    }

    @Test func aFullDiskIsRefusedUpFront() {
        #expect(DiskSpace.requiredBytes(forWriting: 100) == 100 + DiskSpace.safetyMarginBytes)
        #expect(DiskSpace.freeBytes(at: URL(fileURLWithPath: "/nonexistent/deep/leaf")) != nil, "walks up to an existing ancestor")
    }
}
