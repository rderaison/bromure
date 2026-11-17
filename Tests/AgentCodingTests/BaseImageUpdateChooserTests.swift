import Foundation
import Testing
@testable import bromure_ac

/// After a base-image install the user picks, per workspace, Update (its disk
/// is reset onto the new base at its next boot, unasked) or Keep (the drift
/// prompt's "No" for that base) — and the launch restore waits for it.
@Suite("Base image update chooser")
struct BaseImageUpdateChooserTests {
    private static func src(_ path: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("every workspace is listed: running, restoring, idle, then those with nothing to decide; Keep by default")
    func rows() {
        let ids = (0..<5).map { _ in UUID() }
        let rows = BaseImageUpdateChoice.rows([
            .init(id: ids[0], name: "zeta", baseAtClone: "201", hasDisk: true),
            .init(id: ids[1], name: "alpha", baseAtClone: "201", hasDisk: true),
            .init(id: ids[2], name: "beta", baseAtClone: "201", hasDisk: true),
            .init(id: ids[3], name: "fresh", baseAtClone: nil, hasDisk: false),
            .init(id: ids[4], name: "already", baseAtClone: "201.1", hasDisk: true),
        ], newBase: "201.1", running: [ids[0]], restoring: [ids[2]])
        #expect(rows.map(\.name) == ["zeta", "beta", "alpha", "already", "fresh"])
        #expect(rows.map(\.state) == [.running, .restoring, .idle, .current, .current])
        #expect(rows.allSatisfy { !$0.update })
        #expect(rows.filter(\.decides).count == 3)
    }

    @MainActor
    @Test("Update resets the disk at the next boot without asking; Keep silences the drift prompt for this base")
    func answers() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chooser-\(UUID().uuidString)", isDirectory: true)
        let delegate = ACAppDelegate(
            imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp), headless: true)
        var p = Profile(name: "w", tool: .claude, authMode: .token)
        p.baseImageVersionAtClone = "201"
        try delegate.store.save(p)
        let disk = delegate.store.diskURL(for: p)
        try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: disk.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: delegate.store.profileDirectory(for: p)) }
        func stored() throws -> Profile { try #require(delegate.store.loadAll().first { $0.id == p.id }) }

        // Before any answer: the drift prompt is due, no silent reset.
        #expect(delegate.baseImageUpgradeOfferDue(try stored(), current: "201.1"))
        #expect(!delegate.acceptedBaseImageUpgradeDue(try stored(), current: "201.1"))

        // Update: no prompt; the next boot resets, for this base only.
        delegate.recordBaseImageUpdateChoice(profileID: p.id, current: "201.1", update: true)
        #expect(!delegate.baseImageUpgradeOfferDue(try stored(), current: "201.1"))
        #expect(delegate.acceptedBaseImageUpgradeDue(try stored(), current: "201.1"))
        #expect(!delegate.acceptedBaseImageUpgradeDue(try stored(), current: "201.2"), "a later base asks again")
        #expect(delegate.baseImageUpgradeOfferDue(try stored(), current: "201.2"))

        // Keep: the drift prompt's "No" for this base, the Update undone.
        delegate.recordBaseImageUpdateChoice(profileID: p.id, current: "201.1", update: false)
        #expect(!delegate.baseImageUpgradeOfferDue(try stored(), current: "201.1"))
        #expect(!delegate.acceptedBaseImageUpgradeDue(try stored(), current: "201.1"))
        #expect(try stored().baseImageUpgradeDeclinedFor == "201.1")

        // An accepted update on a workspace without a disk (or already on the
        // base) has nothing to reset.
        delegate.recordBaseImageUpdateChoice(profileID: p.id, current: "201.1", update: true)
        try FileManager.default.removeItem(at: disk)
        #expect(!delegate.acceptedBaseImageUpgradeDue(try stored(), current: "201.1"))
    }

    @Test("the answer survives a save and reload")
    func codable() throws {
        var p = Profile(name: "w", tool: .claude, authMode: .token)
        p.baseImageUpgradeAcceptedFor = "201.1"
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(back.baseImageUpgradeAcceptedFor == "201.1")
    }

    @Test("the restore waits for the image check; the check asks, installs, then chooses")
    func ordering() throws {
        let app = try Self.src("Sources/AgentCoding/BromureAC.swift")
        #expect(app.contains("await self?.launchImageCheck?.value\n                self?.restoreAtLaunch()"))
        #expect(app.contains("launchImageCheck = Task { @MainActor in"))
        let check = try #require(app.range(of: "launchImageCheck = Task { @MainActor in"))
        let body = String(app[check.lowerBound...].prefix(3000))
        let install = try #require(body.range(of: "await self.installTask?.value"))
        let choose = try #require(body.range(of: "await self.chooseWorkspacesForNewBase(after)"))
        #expect(install.lowerBound < choose.lowerBound)
        // The silent reset comes before the drift question in launch().
        let reset = try #require(app.range(of: "if acceptedBaseImageUpgradeDue(profile, current: currentBaseVersion)"))
        let drift = try #require(app.range(of: "if !preflightResolved, baseImageUpgradeOfferDue(profile, current: currentBaseVersion)"))
        #expect(reset.lowerBound < drift.lowerBound)
    }

    @Test("the list has room for its rows (a bare ScrollView collapses to nothing in a sheet)")
    func listHeight() {
        #expect(BaseImageUpdateChooserView.listHeight(rows: 1) >= 30)
        #expect(BaseImageUpdateChooserView.listHeight(rows: 3) == CGFloat(3 * 30 + 2 * 6))
        #expect(BaseImageUpdateChooserView.listHeight(rows: 40) == BaseImageUpdateChooserView.listHeight(rows: 12))
    }

    @Test("peeking at the restore plan leaves it for the restore to take")
    func peek() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peek-\(UUID().uuidString)").appendingPathComponent("restore-at-launch.json")
        let plan = LaunchRestorePlan.make(running: [(UUID(), "w")], sessions: [])
        LaunchRestorePlan.save(plan, to: url)
        #expect(LaunchRestorePlan.peek(at: url)?.workspaces.map(\.name) == ["w"])
        #expect(LaunchRestorePlan.take(from: url) != nil)
        #expect(LaunchRestorePlan.peek(at: url) == nil)
    }
}
