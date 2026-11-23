@testable import ACLinux
import Foundation
import Testing

/// Which virtiofsd a VM's shares get, and what a failed one says.
@Suite("virtiofsd binary")
struct VirtiofsdPathTests {
    @Test func theEnvironmentWins() {
        #expect(MachineConfig.resolveVirtiofsd(env: "/opt/v", executable: "/usr/lib/bromure-ac/bin/bromure-ac",
                                               isExecutable: { _ in true }) == "/opt/v")
    }

    @Test func thePackagedOneBesideTheExecutable() {
        #expect(MachineConfig.resolveVirtiofsd(env: nil, executable: "/usr/lib/bromure-ac/bin/bromure-ac",
                                               isExecutable: { $0 == "/usr/lib/bromure-ac/bin/virtiofsd" })
                == "/usr/lib/bromure-ac/bin/virtiofsd")
    }

    @Test func elseTheSystems() {
        #expect(MachineConfig.resolveVirtiofsd(env: "", executable: "/home/u/.build/release/bromure-ac",
                                               isExecutable: { _ in false }) == "/usr/libexec/virtiofsd")
        #expect(MachineConfig.resolveVirtiofsd(env: nil, executable: nil, isExecutable: { _ in true }) == "/usr/libexec/virtiofsd")
    }

    @Test func theErrorCarriesVirtiofsdsOwnWords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vfs-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/virtiofsd-setup.log"
        // Ubuntu 24.04's virtiofsd 1.10, given --migration-mode (its output, verbatim but the usage line).
        let usage = "Usage: virtiofsd <" + String(repeating: "--option <OPTION>|", count: 60) + ">"
        try "Error: unexpected argument '--migration-mode' found\n\n\(usage)\n\nFor more information, try '--help'.\n"
            .write(toFile: log, atomically: true, encoding: .utf8)
        let words = FirecrackerMachine.lastWords(log, binary: "/usr/libexec/virtiofsd")
        #expect(words == "/usr/libexec/virtiofsd: Error: unexpected argument '--migration-mode' found")
        try "starting\nlistening\nbye\nlast\n".write(toFile: log, atomically: true, encoding: .utf8)
        #expect(FirecrackerMachine.lastWords(log, binary: "/v") == "/v: listening | bye | last")
        let e = MachineError.virtiofsdNotReady("setup", words).description
        #expect(e.hasPrefix("virtiofsd for 'setup' did not come up: /usr/libexec/virtiofsd: "))
        #expect(e.contains("--migration-mode"))
        #expect(FirecrackerMachine.lastWords(dir + "/none.log", binary: "/x") == "(/x: no output)")
        #expect(MachineError.virtiofsdNotReady("s").description == "virtiofsd for 's' did not come up")
    }
}
