import Foundation
import NIOCore
import Testing
@testable import ACLinux

/// The local-model repair proxy listens on a unix socket in the user's own
/// runtime dir, never on a loopback TCP port another account could reach.
@Suite("Repair proxy: its unix socket", .serialized)
struct RepairProxySocketTests {
    @Test func theSocketIsItsOwnersAndAnswers() throws {
        let dir = "/tmp/rp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = Daemon.repairProxySocketPath(runtimeDir: dir)
        #expect(path == dir + "/inference-repair.sock")
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        let fd = Daemon.listenUnix(path)
        #expect(fd >= 0, "a stale file replaced")
        defer { close(fd) }
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFSOCK && st.st_mode & 0o777 == 0o600)
        let c = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        defer { close(c) }
        let addr = try SocketAddress(unixDomainSocketPath: path)
        let rc = addr.withSockAddr { connect(c, $0, socklen_t($1)) }
        #expect(rc == 0, "it accepts its owner")
    }

    @Test func aTooLongPathIsRefused() {
        #expect(Daemon.listenUnix("/tmp/" + String(repeating: "x", count: 120)) == -1)
    }

    @Test func bridgesAndTheMITMDialTheSocketOnceSet() throws {
        let before = Daemon.repairProxySocket.withLockedValue { $0 }
        defer { Daemon.repairProxySocket.withLockedValue { $0 = before } }
        Daemon.repairProxySocket.withLockedValue { $0 = "/run/bromure-ac/u/bromure-ac/inference-repair.sock" }
        #expect(Daemon.repairProxyTarget()?.pathname == "/run/bromure-ac/u/bromure-ac/inference-repair.sock")
        Daemon.repairProxySocket.withLockedValue { $0 = nil }
        #expect(Daemon.repairProxyTarget()?.ipAddress == "127.0.0.1", "a daemon that set none: its loopback port")
    }
}
