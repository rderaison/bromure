import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

/// "Postinstall steps should be permanently skippable": a user not
/// interested in a step (Hermes) was asked about it at every launch. A step
/// skipped for good is never offered again, nor installed by a new image or
/// a rebuild, until Base Image details installs it.
@Suite("Postinstall steps skipped for good")
struct PostinstallSkipTests {
    private static func defaults() -> UserDefaults {
        let name = "PostinstallSkipTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private static let catalog = ImageCatalog(formatVersion: 1, image: nil, postinstall: [
        PostinstallStep(uuid: "b", seq: 20, description: "Hermes", command: "echo h"),
        PostinstallStep(uuid: "a", seq: 10, description: "Base tools", command: "echo a"),
        PostinstallStep(uuid: "c", seq: 30, description: "gcloud", command: "echo c"),
    ])

    @Test("skip and unskip persist, as a set")
    func store() {
        let skips = PostinstallSkips(defaults: Self.defaults())
        #expect(skips.uuids.isEmpty)
        skips.skip(["b", "c"])
        skips.skip(["b"])
        #expect(skips.uuids == ["b", "c"])
        #expect(skips.contains("b"))
        skips.unskip(["b", "c"])
        #expect(skips.uuids.isEmpty)
        #expect(skips.defaults.object(forKey: PostinstallSkips.defaultsKey) == nil)
    }

    @Test("a skipped step is neither offered nor installed by a new image")
    func filtered() {
        #expect(Self.catalog.baseImageSteps(skipping: ["b"]).map(\.uuid) == ["a", "c"])
        #expect(Self.catalog.pendingBaseImageSteps(appliedUUIDs: ["a"], skipping: ["b"]).map(\.uuid) == ["c"])
        #expect(Self.catalog.pendingBaseImageSteps(appliedUUIDs: ["a", "c"], skipping: ["b"]).isEmpty,
                "nothing left to ask about at launch")
        #expect(Self.catalog.pendingBaseImageSteps(appliedUUIDs: ["a"], skipping: []).map(\.uuid) == ["b", "c"])
    }

    @Test("Base Image details lists every step with where it stands")
    func statusRows() {
        let rows = PostinstallStepStatus.rows(catalog: Self.catalog, applied: ["a"], skipped: ["b"])
        #expect(rows.map(\.id) == ["a", "b", "c"])
        #expect(rows.map(\.state) == [.installed, .skipped, .notInstalled])
        // Applied wins over a stale skip.
        #expect(PostinstallStepStatus.rows(catalog: Self.catalog, applied: ["b"], skipped: ["b"])[1].state == .installed)
    }

    @Test("workspaces: on which base, and what happens next")
    func workspaceRows() {
        let id = { UUID() }
        let rows = BaseImageWorkspaceRow.rows([
            .init(id: id(), name: "e-new", baseAtClone: nil, hasDisk: false, acceptedFor: nil, declinedFor: nil),
            .init(id: id(), name: "a-current", baseAtClone: "201.5", hasDisk: true, acceptedFor: nil, declinedFor: nil),
            .init(id: id(), name: "b-moving", baseAtClone: "201.4", hasDisk: true, acceptedFor: "201.5", declinedFor: nil),
            .init(id: id(), name: "c-kept", baseAtClone: "201.4", hasDisk: true, acceptedFor: nil, declinedFor: "201.5"),
            .init(id: id(), name: "d-older", baseAtClone: "201.3", hasDisk: true, acceptedFor: nil, declinedFor: "201.4"),
        ], current: "201.5")
        #expect(rows.map(\.name) == ["a-current", "b-moving", "c-kept", "d-older", "e-new"])
        #expect(rows.map(\.state) == [.current, .updatesAtNextStart, .kept, .older, .notStarted])
        #expect(rows.map(\.onOlderBase) == [false, true, true, true, false])
    }

    /// Finding "Base Image details hides update choice for workspaces with
    /// no clone-version record": such a disk read "current", and with only
    /// those, "Choose Workspaces to Update…" never showed.
    @Test("a disk with no record of its base is unknown, and the chooser is offered")
    func unrecordedBase() {
        let rows = BaseImageWorkspaceRow.rows([
            .init(id: UUID(), name: "a", baseAtClone: nil, hasDisk: true, acceptedFor: nil, declinedFor: nil),
            .init(id: UUID(), name: "b", baseAtClone: nil, hasDisk: true, acceptedFor: "201.5", declinedFor: nil),
            .init(id: UUID(), name: "c", baseAtClone: nil, hasDisk: true, acceptedFor: nil, declinedFor: "201.5"),
            .init(id: UUID(), name: "d", baseAtClone: nil, hasDisk: false, acceptedFor: nil, declinedFor: nil),
        ], current: "201.5")
        #expect(rows.map(\.state) == [.unknown, .updatesAtNextStart, .kept, .notStarted])
        #expect(rows.contains { $0.onOlderBase })
        // Same decision as the chooser itself: it decides for such a disk.
        let chooser = BaseImageUpdateChoice.rows(
            [.init(id: UUID(), name: "a", baseAtClone: nil, hasDisk: true)],
            newBase: "201.5", running: [], restoring: [])
        #expect(chooser.allSatisfy { $0.decides })
    }

    @Test("the startup prompt offers Skip Permanently, and every install path honors skips")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let remote = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/UbuntuImageManager+Remote.swift"), encoding: .utf8)
        #expect(ac.contains("NSLocalizedString(\"Skip Permanently\""))
        #expect(ac.contains("PostinstallSkips().skip(steps.map(\\.uuid))"))
        #expect(ac.contains("catalog.pendingBaseImageSteps(appliedUUIDs: applied)"))
        #expect(!ac.contains(".sortedSteps"), "base-image installs take baseImageSteps()")
        #expect(!remote.contains(".sortedSteps"))
        #expect(ac.contains("#selector(ACAppDelegate.baseImageDetailsAction(_:))"))
    }
}
