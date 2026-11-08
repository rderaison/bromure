import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// `POST /vms/<id>/type` (macOS: ACAutomationServer.handleType): every
    /// reply is marked "typeRoute"; a bad body is 400; a VM that can't be
    /// asked (unknown, or not running) is "unreachable", not a 404 a client
    /// would take for an older server.
    @Suite("Type route", .serialized)
    struct TypeRouteTests {
        @Test func edges() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
            try await d.registerForTesting(rec)
            let target: JSONValue = ["ref": ["index": ["_0": 0]], "foreground": ["shell": [:]]]
            func obj(_ r: ControlResponse) -> [String: JSONValue] {
                if case .object(let o) = r.body { return o }
                return [:]
            }
            let bad = await d.vmRoute("POST", "/vms/\(rec.id)/type", ["text": "hi"])
            #expect(bad.status == 400 && obj(bad)["typeRoute"] == .bool(true))
            let stopped = await d.vmRoute("POST", "/vms/\(rec.id)/type", ["text": "hi", "target": target])
            #expect(stopped.status == 200 && obj(stopped)["unreachable"] == .bool(true) && obj(stopped)["typeRoute"] == .bool(true))
            let unknown = await d.vmRoute("POST", "/vms/nope/type", ["text": "hi", "target": target])
            #expect(unknown.status == 200 && obj(unknown)["unreachable"] == .bool(true))
            #expect(await d.vmRoute("POST", "/vms/nope/exec", [:]).status == 404, "other routes still 404")
            await d.shutdown()
        }
    }
}
