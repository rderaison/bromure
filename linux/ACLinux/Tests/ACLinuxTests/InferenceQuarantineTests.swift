import Foundation
import Glibc
import Testing
@testable import ACLinux

/// The model bridge (vsock 8446) of a quarantined workspace: a connection
/// is refused (closed before it reaches the repair proxy), never under
/// the channel's initializer.
@Suite("Model bridge under quarantine")
struct InferenceQuarantineTests {
    @Test func aConnectionIsRefusedWhileQuarantined() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = UUID()
        let listener = try InferenceBridgeListener(udsPath: dir + "/v.sock", fdStoreName: "llm-test", stored: nil, profileID: pid)
        defer { listener.stop() }
        WorkspaceQuarantine.shared.set(true, for: pid)
        defer { WorkspaceQuarantine.shared.set(false, for: pid) }
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in listener.path.utf8.enumerated() { p[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(rc == 0)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 16)
        #expect(recv(fd, &buf, buf.count, 0) == 0, "closed by the bridge, nothing relayed")
    }
}
