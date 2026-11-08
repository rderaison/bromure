import Foundation
import Testing
@testable import ACLinux

/// /state's ordering stamps and grid (macOS: buildStateSnapshot's
/// generation/epoch, noteMutation, gridLayout without a window).
@Suite("State stamps")
struct StateStampsTests {
    static func generation(_ d: Daemon) async -> Double? {
        guard case .object(let o) = await d.state().body, case .number(let g)? = o["generation"] else { return nil }
        return g
    }

    @Test func aMutationMovesTheGenerationAGetDoesnt() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        guard case .object(let o) = await d.state().body else { Issue.record("no state"); return }
        #expect(o["epoch"] == .string(StateGeneration.epoch))
        #expect(o["gridLayout"] == ["cells": .array([])])
        let g0 = try #require(await Self.generation(d))
        _ = await d.handle(ControlRequest(method: "GET", path: "/vms", body: .object([:])))
        _ = await d.handle(ControlRequest(method: "POST", path: "/vms/nope/exec", body: .object([:])))
        // Other suites' requests move it too (it's process-wide): read it
        // around ours.
        let before = StateGeneration.current
        _ = await d.handle(ControlRequest(method: "POST", path: "/grid-layout", body: .object([:])))
        #expect(StateGeneration.current >= before + 2, "bumped as it starts and as it answers")
        #expect(try #require(await Self.generation(d)) >= g0 + 2)
        #expect(!StateGeneration.isMutating("GET", path: "/vms") && !StateGeneration.isMutating("POST", path: "/vms/x/exec?y=1"))
        #expect(StateGeneration.isMutating("POST", path: "/profiles") && StateGeneration.isMutating("DELETE", path: "/vms/x"))
        // The stamps aren't a change to push: they're left out of what's
        // compared (other suites' requests can move the rest meanwhile).
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let sections = Daemon.comparableSections(await d.state().body, enc)
        #expect(sections["generation"] == nil && sections["epoch"] == nil && sections["vms"] != nil)
        await d.shutdown()
    }
}
