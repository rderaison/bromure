import Foundation
import Testing
@testable import bromure_ac

/// Parsers behind `vm <id> -L` and the dashboard's Listening Ports row. `ss`
/// output shapes covered: plain `-tulnH` (the guest's ports loop), and the
/// sudo `-tulnpH` variant with users:(("name",pid,fd)) process columns.
@Suite("Listening-port parsing")
struct ListeningPortsTests {

    let plain = """
    udp   UNCONN 0      0        127.0.0.53%lo:53        0.0.0.0:*
    tcp   LISTEN 0      4096           0.0.0.0:22        0.0.0.0:*
    tcp   LISTEN 0      511               *:8080             *:*
    tcp   LISTEN 0      4096              [::]:22           [::]:*
    tcp   LISTEN 0      128            [::1]:631          [::]:*
    """

    @Test("Guest ports.txt parse: addresses, ports, scope strip, wildcard, sort")
    func plainParse() {
        let ports = UbuntuSandboxVM.parseListeningPorts(plain)
        #expect(ports.map(\.port) == [22, 22, 53, 631, 8080])
        // %lo scope suffix stripped; `*` normalized to 0.0.0.0.
        #expect(ports.contains(ListeningPort(proto: "udp", addr: "127.0.0.53", port: 53)))
        #expect(ports.contains(ListeningPort(proto: "tcp", addr: "0.0.0.0", port: 8080)))
        // v4 + v6 wildcard both kept (display layers dedupe by port/proto).
        #expect(ports.filter { $0.port == 22 }.count == 2)
    }

    @Test("Loopback classification covers v4, v6, and resolver addresses")
    func loopback() {
        #expect(ListeningPort(proto: "udp", addr: "127.0.0.53", port: 53).isLoopback)
        #expect(ListeningPort(proto: "tcp", addr: "[::1]", port: 631).isLoopback)
        #expect(!ListeningPort(proto: "tcp", addr: "0.0.0.0", port: 22).isLoopback)
        #expect(!ListeningPort(proto: "tcp", addr: "[::]", port: 22).isLoopback)
    }

    @Test("Process names extracted from the sudo -p users:(…) column")
    func processNames() {
        let sudoOut = """
        tcp   LISTEN 0      4096         0.0.0.0:22      0.0.0.0:*    users:(("sshd",pid=735,fd=3))
        tcp   LISTEN 0      511          0.0.0.0:80      0.0.0.0:*    users:(("nginx",pid=91,fd=6),("nginx",pid=92,fd=6))
        udp   UNCONN 0      0      127.0.0.53%lo:53      0.0.0.0:*    users:(("systemd-resolve",pid=456,fd=13))
        """
        let rows = UbuntuSandboxVM.parseListeningPorts(sudoOut)
        #expect(rows.count == 3)
        #expect(rows.first?.port == 22)   // sorted by port
        #expect(rows.first { $0.port == 22 }?.process == "sshd")
        // Duplicate worker names collapse to one.
        #expect(rows.first { $0.port == 80 }?.process == "nginx")
        #expect(rows.first { $0.port == 53 }?.isLoopback == true)
        #expect(rows.first { $0.port == 53 }?.addr == "127.0.0.53")
    }

    @Test("Non-socket junk and headers are ignored")
    func junk() {
        let noisy = "Netid State Recv-Q Send-Q Local Peer\nnonsense\n\n" + plain
        #expect(UbuntuSandboxVM.parseListeningPorts(noisy).count == 5)
        #expect(UbuntuSandboxVM.parseListeningPorts("").isEmpty)
    }
}
