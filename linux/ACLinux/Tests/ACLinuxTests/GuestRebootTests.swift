import Foundation
import Testing
@testable import ACLinux

/// The guest kernel's last reboot line on the serial console: a reboot
/// (the VM is booted again) or a power-off (the VM is ended).
@Suite("Guest reboot and power-off from the console")
struct GuestRebootTests {
    func log(_ text: String) throws -> String {
        let dir = try shortTempDir()
        let path = dir + "/serial.log"
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func theKernelsLastWordDecides() throws {
        let restart = try log("boot…\nrb login: [FAILED] Failed unmounting home-ubuntu.mount\n[    8.21] reboot: Restarting system\n")
        #expect(Daemon.kernelSaidRestart(serialLog: restart) && !Daemon.kernelSaidPowerDown(serialLog: restart))
        let off = try log("[  12.0] reboot: Power down\n")
        #expect(Daemon.kernelSaidPowerDown(serialLog: off) && !Daemon.kernelSaidRestart(serialLog: off))
        // Firecracker on x86 has no ACPI power-off: the kernel halts instead.
        let halted = try log("[    7.10] reboot: Power off not available: System halted instead\n")
        #expect(Daemon.kernelSaidPowerDown(serialLog: halted) && !Daemon.kernelSaidRestart(serialLog: halted))
        // An earlier line is overruled by the last one.
        let both = try log("[ 1.0] reboot: Restarting system\n…\n[ 9.0] reboot: Power down\n")
        #expect(Daemon.kernelSaidPowerDown(serialLog: both) && !Daemon.kernelSaidRestart(serialLog: both))
        // Neither said (a running guest, a crash), or no log: neither.
        let none = try log("Ubuntu 24.04.5 LTS rb ttyS0\nrb login:\n")
        #expect(!Daemon.kernelSaidRestart(serialLog: none) && !Daemon.kernelSaidPowerDown(serialLog: none))
        #expect(!Daemon.kernelSaidRestart(serialLog: "/nonexistent/serial.log"))
        // Only the tail counts: a line far back is a previous boot's.
        let old = try log("[ 1.0] reboot: Power down\n" + String(repeating: "console noise\n", count: 1000))
        #expect(!Daemon.kernelSaidPowerDown(serialLog: old))
        // An adopted VM's log read from where this daemon took it back: an
        // earlier boot's last word (appended by an older daemon) isn't this one's.
        let earlier = "[ 9.0] reboot: Power down\n"
        let adopted = try log(earlier + "Ubuntu 24.04.5 LTS rb ttyS0\n")
        #expect(Daemon.kernelSaidPowerDown(serialLog: adopted), "the whole log says it")
        #expect(!Daemon.kernelSaidPowerDown(serialLog: adopted, from: UInt64(earlier.utf8.count)), "not past adoption")
        for p in [restart, off, halted, both, none, old, adopted] { try? FileManager.default.removeItem(atPath: (p as NSString).deletingLastPathComponent) }
    }
}
