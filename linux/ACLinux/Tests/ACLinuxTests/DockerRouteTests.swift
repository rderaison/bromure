import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// `POST /vms/<id>/docker` (macOS: automationDockerCommand): refused for
    /// a VM that isn't running; a verb becomes a whole `cmd-*.txt` in the
    /// outbox, and "watch" the `.docker-watch` marker.
    @Suite("Docker route", .serialized)
    struct DockerRouteTests {
        @Test func refusedWhenStoppedAndTheOutboxFiles() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
            try await d.registerForTesting(rec)
            let r = await d.vmRoute("POST", "/vms/\(rec.id)/docker", ["action": "binfmt"])
            #expect(r.status == 409)
            let outbox = await d.vmDir(rec.id) + "/outbox"
            try FileManager.default.createDirectory(atPath: outbox, withIntermediateDirectories: true)
            #expect(await d.sendGuestCommand("docker-stop abc", vmID: rec.id))
            let files = try FileManager.default.contentsOfDirectory(atPath: outbox)
            let cmd = try #require(files.first { $0.hasPrefix("cmd-") && $0.hasSuffix(".txt") })
            #expect(try String(contentsOfFile: outbox + "/" + cmd, encoding: .utf8) == "docker-stop abc\n")
            await d.setDockerWatch(true, vmID: rec.id)
            #expect(FileManager.default.fileExists(atPath: outbox + "/.docker-watch"))
            await d.setDockerWatch(false, vmID: rec.id)
            #expect(!FileManager.default.fileExists(atPath: outbox + "/.docker-watch"))
            await d.shutdown()
        }
    }
}
