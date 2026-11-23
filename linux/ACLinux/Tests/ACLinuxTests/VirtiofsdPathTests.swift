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

    @Test func passtTheSameWay() {
        let exe = "/usr/lib/bromure-ac/bin/bromure-ac"
        #expect(MachineConfig.resolveHelper("passt", env: nil, executable: exe, system: "/usr/bin/passt",
                                            isExecutable: { $0 == "/usr/lib/bromure-ac/bin/passt" }) == "/usr/lib/bromure-ac/bin/passt")
        #expect(MachineConfig.resolveHelper("passt", env: nil, executable: exe, system: "/usr/bin/passt",
                                            isExecutable: { $0 == "/usr/lib/bromure-ac/bin/virtiofsd" }) == "/usr/bin/passt")
        #expect(MachineConfig.resolveHelper("passt", env: "/p", executable: exe, system: "/usr/bin/passt",
                                            isExecutable: { _ in true }) == "/p")
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

@Suite("Daemon on a packaged server")
struct PackagedDaemonTests {
    @Test func firecrackerTheSameWayAsTheOtherHelpers() {
        let exe = "/usr/lib/bromure-ac/bin/bromure-ac"
        #expect(MachineConfig.resolveHelper("firecracker", env: nil, executable: exe, system: "/root/.local/share/bromure-ac/bin/firecracker",
                                            isExecutable: { $0 == "/usr/lib/bromure-ac/bin/firecracker" }) == "/usr/lib/bromure-ac/bin/firecracker")
        #expect(MachineConfig.resolveHelper("firecracker", env: nil, executable: "/home/u/.build/debug/bromure-ac",
                                            system: "/home/u/.local/share/bromure-ac/bin/firecracker", isExecutable: { _ in false })
                == "/home/u/.local/share/bromure-ac/bin/firecracker")
    }

    @Test func rootStartingADaemonByHandOnAMultiUserServerIsRefused() {
        let refusal = MultiUserAdmin.rootDaemonRefusal(euid: 0, multiUser: true, underSystemd: false)
        #expect(refusal?.contains("sudo bromure-ac admin add --existing <user>") == true)
        #expect(refusal?.contains("systemctl status bromure-ac@<user>") == true)
        #expect(MultiUserAdmin.rootDaemonRefusal(euid: 0, multiUser: true, underSystemd: true) == nil, "a unit's")
        #expect(MultiUserAdmin.rootDaemonRefusal(euid: 1000, multiUser: true, underSystemd: false) == nil, "a user's own")
        #expect(MultiUserAdmin.rootDaemonRefusal(euid: 0, multiUser: false, underSystemd: false) == nil, "a single-user install")
    }
}
