import Foundation
import Virtualization

/// Accepts a vsock connection from the guest on the inference port (8446)
/// and pumps it straight to the host loopback engine (127.0.0.1:<port>).
///
/// This is the host end of Path 1 (§2.2): the in-VM bridge listens on
/// 127.0.0.1:11434, forwards over vsock 8446, and we splice that to the
/// engine on loopback. Per-VM and loopback-only — the engine never binds
/// anything but 127.0.0.1, and no other VM on the subnet can reach it.
/// Same raw-TCP-pump shape as the python bridge's other forwards.
final class InferenceListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let enginePort: Int
    init(enginePort: Int) { self.enginePort = enginePort }

    @available(macOS, deprecated: 10.15)
    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        let port = enginePort
        Thread.detachNewThread {
            InferenceVsockBridge.pump(vsockFD: fd, host: "127.0.0.1", port: port)
        }
        return true
    }
}

enum InferenceVsockBridge {
    /// Connect a loopback TCP socket to the engine and pump both
    /// directions until either side closes. Blocking; runs on its own
    /// thread per connection.
    static func pump(vsockFD: Int32, host: String, port: Int) {
        let tcp = socket(AF_INET, SOCK_STREAM, 0)
        if tcp < 0 { close(vsockFD); return }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        _ = inet_pton(AF_INET, host, &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 { close(tcp); close(vsockFD); return }

        let group = DispatchGroup()
        oneWay(from: vsockFD, to: tcp, group: group)
        oneWay(from: tcp, to: vsockFD, group: group)
        group.wait()
        close(tcp)
        close(vsockFD)
    }

    private static func oneWay(from: Int32, to: Int32, group: DispatchGroup) {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(from, &buf, buf.count)
                if n <= 0 { break }
                let ok = buf.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    var off = 0
                    while off < n {
                        let w = write(to, base + off, n - off)
                        if w <= 0 { return false }
                        off += w
                    }
                    return true
                }
                if !ok { break }
            }
            shutdown(to, Int32(SHUT_WR))
        }
    }
}
