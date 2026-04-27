import Foundation

/// Tiny synchronous client for an ssh-agent unix socket. Used by
/// `SSHAgentServer` to forward SIGN_REQUESTs and REQUEST_IDENTITIES
/// from the VM into bromure's private ssh-agent — the only host-side
/// agent the VM ever sees.
///
/// The user's launchd `SSH_AUTH_SOCK` is intentionally NOT plumbed
/// through here. Earlier revisions multiplexed it in alongside the
/// private agent; that exposed every key in the user's daily-driver
/// agent (GitHub, work, prod) to the disposable VM with no consent
/// gate. Keys the user wants reachable from the VM now go through
/// the explicit-import flow in the profile UI, which lands the key
/// in `_bromurePrivate` and registers an `ImportedApproval` for
/// per-key consent.
final class HostAgentClient: @unchecked Sendable {
    let socketPath: String

    /// Set by MitmEngine after it spawns the private ssh-agent. Used
    /// as the destination for ssh-add of per-profile keys and as the
    /// only forwarding target for in-VM SIGN_REQUESTs.
    static var _bromurePrivate: HostAgentClient?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Send a single ssh-agent-protocol request frame, return the
    /// response frame (without the 4-byte length prefix). nil on
    /// any I/O failure — caller falls back to its own behaviour.
    func request(_ payload: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sockaddr_un.sun_path is 104 bytes on macOS — stay under that.
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxPath else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            let typed = dest.bindMemory(to: CChar.self)
            for (i, b) in pathBytes.enumerated() { typed[i] = CChar(bitPattern: b) }
            typed[pathBytes.count] = 0
        }
        let connectStatus = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectStatus < 0 { return nil }

        // Frame: 4-byte big-endian length + payload.
        var lenBE = UInt32(payload.count).bigEndian
        let lenData = Data(bytes: &lenBE, count: 4)
        guard writeAll(fd: fd, data: lenData),
              writeAll(fd: fd, data: payload) else { return nil }

        // Read response length, then body.
        guard let lenBuf = readExact(fd: fd, count: 4) else { return nil }
        let respLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard respLen > 0, respLen <= 256 * 1024 else { return nil }
        return readExact(fd: fd, count: respLen)
    }
}

private func writeAll(fd: Int32, data: Data) -> Bool {
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        var sent = 0
        while sent < data.count {
            let n = write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            sent += n
        }
        return true
    }
}

private func readExact(fd: Int32, count: Int) -> Data? {
    var buf = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            read(fd, ptr.baseAddress!.advanced(by: got), count - got)
        }
        if n == 0 { return nil }
        if n < 0 {
            if errno == EINTR { continue }
            return nil
        }
        got += n
    }
    return Data(buf)
}
