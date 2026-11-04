#if os(macOS)
import Foundation
import SandboxEngine
#if canImport(Darwin)
import Darwin
#endif

// The LAN-side types the load balancer and the announcer share
// (KubeLANAnnouncer.swift keeps the announcer, with typealiases to these).

/// A published LAN service port.
struct KubeLANPortKey: Hashable {
    let port: UInt16
    let udp: Bool
}

struct KubeLANTarget: Equatable {
    let nodeID: UUID
    /// The node's LAN address (the guest-side relay connects from here).
    let nodeIP: String
    let nodePort: UInt16
    /// TCP relay header: "<node ip>:<nodePort>".
    var tcpTarget: String { "\(nodeIP):\(nodePort)" }
}

enum KubeLANPublishError: LocalizedError {
    case tapUnavailable
    case inUse(String)
    var errorDescription: String? {
        switch self {
        case .tapUnavailable: return "bridged networking isn't available on this Mac"
        case .inUse(let who): return "already answered by \(who) on the LAN"
        }
    }
}

// MARK: - UDP over a vsock relay

/// All UDP toward one node rides a single vsock relay ("UDP <node ip>\n"
/// header; the guest relay keeps a socket per (srcIP, srcPort, dstPort)
/// connected to <node ip>:<dstPort> and frames replies back):
///
///   frame = [u16 bodyLen][u32 srcIP][u16 srcPort][u16 dstPort][payload]
///
/// Same framing as the fat-client `UDPChannel`, minus its SSH plumbing.
/// Dials lazily on the first datagram (queued meanwhile); a dropped relay
/// closes the channel so the next datagram re-dials.
final class KubeUDPRelay: @unchecked Sendable {
    typealias Reply = (_ srcIP: UInt32, _ srcPort: UInt16, _ dstPort: UInt16, _ payload: ArraySlice<UInt8>) -> Void

    private let dial: () -> Int32?
    private let onReply: Reply
    private let onClosed: (Int32) -> Void
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var rfd: Int32 = -1
    private var connecting = false
    private var closed = false
    private var pending: [[UInt8]] = []

    init(dial: @escaping () -> Int32?, onReply: @escaping Reply, onClosed: @escaping (Int32) -> Void) {
        self.dial = dial
        self.onReply = onReply
        self.onClosed = onClosed
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func send(srcIP: UInt32, srcPort: UInt16, dstPort: UInt16, payload: ArraySlice<UInt8>) {
        let frame = Self.frame(srcIP: srcIP, srcPort: srcPort, dstPort: dstPort, payload: payload)
        lock.lock()
        if closed { lock.unlock(); return }
        if rfd >= 0 {
            let fd = rfd; lock.unlock()
            writeFrame(fd, frame)
            return
        }
        pending.append(frame)
        if pending.count > 256 { pending.removeFirst(pending.count - 256) }
        let startDial = !connecting
        connecting = true
        lock.unlock()
        if startDial { dialAsync() }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let fd = rfd; rfd = -1
        lock.unlock()
        if fd >= 0 { writeLock.lock(); Darwin.close(fd); writeLock.unlock() }
        onClosed(fd)
    }

    private func writeFrame(_ fd: Int32, _ frame: [UInt8]) {
        writeLock.lock(); _ = writeAll(fd, frame); writeLock.unlock()
    }

    private func dialAsync() {
        Thread.detachNewThread { [weak self] in
            let fd = self?.dial() ?? -1
            guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
            self.lock.lock()
            if self.closed || fd < 0 {
                self.connecting = false
                self.closed = true
                self.lock.unlock()
                if fd >= 0 { Darwin.close(fd) }
                self.onClosed(-1)
                return
            }
            self.rfd = fd
            let queued = self.pending; self.pending = []
            self.lock.unlock()
            for f in queued { self.writeFrame(fd, f) }
            self.readLoop(fd)
        }
    }

    private func readLoop(_ fd: Int32) {
        var acc = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            acc.append(contentsOf: buf[0..<n])
            while acc.count >= 2 {
                let bodyLen = (Int(acc[0]) << 8) | Int(acc[1])
                guard acc.count >= 2 + bodyLen else { break }
                let body = Array(acc[2..<(2 + bodyLen)])
                acc.removeFirst(2 + bodyLen)
                guard body.count >= 8 else { continue }
                onReply(UtunPacket.u32(body, 0), UtunPacket.u16(body, 4), UtunPacket.u16(body, 6), body[8...])
            }
        }
        lock.lock()
        let alive = !closed
        if alive { closed = true; rfd = -1 }
        lock.unlock()
        if alive {
            writeLock.lock(); Darwin.close(fd); writeLock.unlock()
            onClosed(fd)
        }
    }

    static func frame(srcIP: UInt32, srcPort: UInt16, dstPort: UInt16, payload: ArraySlice<UInt8>) -> [UInt8] {
        let bodyLen = 8 + payload.count
        var f = [UInt8](); f.reserveCapacity(2 + bodyLen)
        f.append(UInt8(bodyLen >> 8)); f.append(UInt8(bodyLen & 0xff))
        f.append(UInt8(srcIP >> 24)); f.append(UInt8((srcIP >> 16) & 0xff))
        f.append(UInt8((srcIP >> 8) & 0xff)); f.append(UInt8(srcIP & 0xff))
        f.append(UInt8(srcPort >> 8)); f.append(UInt8(srcPort & 0xff))
        f.append(UInt8(dstPort >> 8)); f.append(UInt8(dstPort & 0xff))
        f.append(contentsOf: payload)
        return f
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int {
        var off = 0
        bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while off < bytes.count {
                let n = Darwin.write(fd, base + off, bytes.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
        return off
    }
}

/// A vsock relay into `nodeID` with `header`, waited for on the caller's
/// thread (the opener runs on the main queue); the host fd, or -1.
enum KubeLANRelay {
    /// Open a vsock relay synchronously from a non-main thread (the VZ
    /// connect runs on main; we wait up to 20 s for its completion).
    static func open(_ opener: @escaping (UUID, String, @escaping @Sendable (Int32) -> Void) -> Void,
                          nodeID: UUID, header: String) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        let box = FDBox()
        DispatchQueue.main.async {
            opener(nodeID, header) { fd in box.fd = fd; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 20)
        return box.fd
    }

    final class FDBox: @unchecked Sendable { var fd: Int32 = -1 }
}

#endif
