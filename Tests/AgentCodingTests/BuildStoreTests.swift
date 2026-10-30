import Foundation
import Testing
@testable import bromure_ac

@Suite("Builds")
struct BuildStoreTests {
    func build(_ name: String, daysOld: Double) -> BuildStore.Build {
        let dir = URL(fileURLWithPath: "/tmp/builds/\(name)", isDirectory: true)
        return BuildStore.Build(name: name, url: dir, appURL: dir.appendingPathComponent("Bromure Agentic Coding.app"),
                                info: nil, createdAt: Date(timeIntervalSinceNow: -daysOld * 86400))
    }

    @Test("prune keeps stable, stable.prev, running builds and the newest prod-*")
    func pruneCandidates() {
        let builds = [
            build("devbuild-00", daysOld: 10), build("devbuild-01", daysOld: 5), build("devbuild-02", daysOld: 1),
            build("devbuild-03", daysOld: 0.5), build("prod-5.3.0", daysOld: 20), build("prod-5.4.0", daysOld: 3),
        ]
        let drop = BuildStore.pruneCandidates(builds, stable: "devbuild-02", previous: "devbuild-01",
                                              running: ["devbuild-03"])
        #expect(drop.map(\.name).sorted() == ["devbuild-00", "prod-5.3.0"])
    }

    @Test("prune with no roles set keeps only what runs and the newest prod-*")
    func pruneNoRoles() {
        let builds = [build("a", daysOld: 2), build("prod-1.0.0", daysOld: 1)]
        #expect(BuildStore.pruneCandidates(builds, stable: nil, previous: nil, running: []).map(\.name) == ["a"])
        #expect(BuildStore.pruneCandidates(builds, stable: nil, previous: nil, running: ["a"]).isEmpty)
    }

    @Test("A path is a build too; a bad name is refused")
    func resolve() {
        #expect(throws: BuildStore.Failure.self) { try BuildStore.build(named: "") }
        #expect(throws: BuildStore.Failure.self) { try BuildStore.build(named: "/nonexistent/Nothing.app") }
    }
}
