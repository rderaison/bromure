import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - UDP over a forward channel (multiplexed per guest)

/// All UDP to one remote guest rides a single `forward-udp` SSH channel, since a
/// fresh ssh process per datagram (DNS!) would be absurd. Each datagram is
/// length-prefixed and carries its flow's return info so the guest relay can send
/// it to `127.0.0.1:<dstPort>` and route the reply back:
///
///   frame = [u16 bodyLen][u32 srcIP][u16 srcPort][u16 dstPort][payload]
///
/// The guest relay keeps a UDP socket per (srcIP, srcPort, dstPort) and frames
/// replies back the same way; we rebuild them into UDP packets for the utun.
final class UDPChannel {
    private let host: RemoteHost
    private let guestIP: UInt32            // the LOCAL dst the process used (reply source)
    private let targetIP: String          // remote address to dial (alias-resolved)
    private let udpDial: (RemoteHost, String) -> Int32?
    private let emit: ([UInt8]) -> Void
    private let onClosed: (UInt32) -> Void

    private let lock = NSLock()
    private var rfd: Int32 = -1
    private var connecting = false
    private var closed = false
    private var pending: [[UInt8]] = []

    init(host: RemoteHost, guestIP: UInt32, targetIP: String,
         udpDial: @escaping (RemoteHost, String) -> Int32?,
         emit: @escaping ([UInt8]) -> Void, onClosed: @escaping (UInt32) -> Void) {
        self.host = host; self.guestIP = guestIP; self.targetIP = targetIP
        self.udpDial = udpDial; self.emit = emit; self.onClosed = onClosed
    }

    func send(srcIP: UInt32, srcPort: UInt16, dstPort: UInt16, payload: ArraySlice<UInt8>) {
        let frame = Self.frame(srcIP: srcIP, srcPort: srcPort, dstPort: dstPort, payload: payload)
        lock.lock()
        if closed { lock.unlock(); return }
        if rfd >= 0 { _ = writeAll(rfd, frame); lock.unlock(); return }
        pending.append(frame)
        if connecting { lock.unlock(); return }
        connecting = true
        lock.unlock()
        dialAsync()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if rfd >= 0 { Darwin.close(rfd); rfd = -1 }
    }

    private func dialAsync() {
        let host = self.host, target = self.targetIP
        Thread.detachNewThread { [weak self] in
            let fd = self?.udpDial(host, target) ?? -1
            guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
            self.lock.lock()
            if self.closed || fd < 0 {
                self.connecting = false; self.lock.unlock()
                if fd >= 0 { Darwin.close(fd) }
                self.onClosed(self.guestIP); return
            }
            self.rfd = fd
            let queued = self.pending; self.pending = []
            self.lock.unlock()
            for f in queued { _ = self.writeAll(fd, f) }
            self.readLoop(fd)
        }
    }

    /// Read length-prefixed reply frames and rebuild them into UDP packets.
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
                let srcIP = UtunPacket.u32(body, 0)
                let srcPort = UtunPacket.u16(body, 4)
                let dstPort = UtunPacket.u16(body, 6)
                // Reply travels guest → process: src = (the local guest addr,
                // dstPort), dst = (the process, srcPort).
                let pkt = UtunPacket.buildUDP(.init(srcIP: guestIP, dstIP: srcIP,
                    srcPort: dstPort, dstPort: srcPort, payload: body[8...]))
                emit(pkt)
            }
        }
        lock.lock(); let alive = !closed; lock.unlock()
        if alive { onClosed(guestIP) }
    }

    private static func frame(srcIP: UInt32, srcPort: UInt16, dstPort: UInt16, payload: ArraySlice<UInt8>) -> [UInt8] {
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
