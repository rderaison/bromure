import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

// MARK: - TURN over TLS (turns:, 5349) behind a blocking loopback fd

/// The TURN client legs are built on blocking POSIX fds — `STUNTCP.send`/`read`
/// for the control transactions, and the RFC 6062 data leg is spliced raw into
/// the local sshd. Rather than make all of that TLS-aware, this wraps ONE TLS
/// connection to the relay behind a `socketpair`: the caller gets a plain fd it
/// reads/writes exactly like a TCP socket, and two pump threads move bytes
/// between that fd and an `NWConnection` whose TLS the system terminates —
/// validating turn.bromure.io's public certificate against the system trust
/// store. One tunnel per TURN connection: the control leg and each data leg.
///
/// Threading: the `NWConnection` queue only runs tiny signalling closures; every
/// blocking read/write happens on a dedicated thread, so a slow local consumer
/// backs up the socketpair buffer without ever stalling the connection (no queue
/// coupling, no deadlock). The two pump threads retain the connection, so it
/// stays alive until both directions end.
enum TurnTLSTunnel {
    /// Open a TLS connection to `host:port` and return a blocking fd whose bytes
    /// are transparently TLS'd to the server. nil on connect/handshake failure
    /// within `timeout`. The caller owns the returned fd (close to tear down).
    static func connect(host: String, port: Int, timeout: TimeInterval) -> Int32? {
        guard port > 0, port <= 65535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        var sp: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sp) == 0 else { return nil }
        let localFD = sp[0]      // handed to the caller (raw STUN/splice I/O)
        let pumpFD = sp[1]       // owned by the pump threads

        // Bound a stalled connection so a wedged send/receive can't leak the
        // pump threads + fds + TLS socket for the default multi-minute RTO: a
        // stalled (unacked) send is dropped after connectionDropTime, and
        // keepalive errors a silently-dead peer in ~30s. On a healthy relay the
        // SSH tunnel's own traffic keeps it well short of these.
        let tcp = NWProtocolTCP.Options()
        tcp.connectionDropTime = 30
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let queue = DispatchQueue(label: "io.bromure.p2p.turns")

        // Wait out the TLS handshake (bounded). `settled` makes the first
        // terminal state win, so a late .cancelled can't flip a good result.
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var established = false
        var settled = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                lock.lock(); if !settled { settled = true; established = true }; lock.unlock()
                gate.signal()
            case .failed, .cancelled:
                lock.lock(); if !settled { settled = true }; lock.unlock()
                gate.signal()
            default:
                break
            }
        }
        conn.start(queue: queue)

        let waited = gate.wait(timeout: .now() + timeout)
        lock.lock(); let up = established; lock.unlock()
        guard waited == .success, up else {
            conn.cancel()
            Darwin.close(localFD); Darwin.close(pumpFD)
            return nil
        }

        // Each pump thread gets its OWN dup of the pump end, so neither ever
        // closes a descriptor the other still reads/writes. Sharing one fd let
        // the downlink close(pumpFD) while the uplink was parked in a send and
        // about to loop back to read(pumpFD) — by then the fd number could be
        // reused by an unrelated socket, and the uplink would read its bytes.
        // With dups the kernel frees the socket only once BOTH dups close, and
        // shutdown() on either dup still wakes a peer blocked on the socket.
        let upFD = dup(pumpFD)
        let downFD = dup(pumpFD)
        Darwin.close(pumpFD)
        guard upFD >= 0, downFD >= 0 else {
            if upFD >= 0 { Darwin.close(upFD) }
            if downFD >= 0 { Darwin.close(downFD) }
            conn.cancel(); Darwin.close(localFD)
            return nil
        }
        startUplink(conn, upFD)
        startDownlink(conn, downFD)
        return localFD
    }

    /// Local fd → TLS. Blocking read on a dedicated thread; each chunk is sent
    /// and awaited (natural backpressure). On exit it cancels the connection and
    /// shuts down its own dup — SHUT_RDWR on the shared socket wakes the downlink
    /// whether it's blocked in a write or a receive — then closes only that dup.
    private static func startUplink(_ conn: NWConnection, _ fd: Int32) {
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32768)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { break }                     // caller closed / error → done
                let sem = DispatchSemaphore(value: 0)
                var failed = false
                conn.send(content: Data(buf[0..<n]),
                          completion: .contentProcessed { err in
                              if err != nil { failed = true }
                              sem.signal()
                          })
                sem.wait()
                if failed { break }
            }
            conn.send(content: nil, isComplete: true, completion: .idempotent)  // best-effort FIN
            conn.cancel()
            Darwin.shutdown(fd, SHUT_RDWR)   // wake a downlink blocked writing/reading the socket
            Darwin.close(fd)                 // only this thread's dup
        }
    }

    /// TLS → local fd. Receive on a dedicated thread (the callback only hands the
    /// chunk back via the semaphore, so the NWConnection queue never blocks), and
    /// blocking-write it to the socketpair. On exit it cancels the connection and
    /// shuts down its own dup — waking a uplink blocked in read(upFD) on the same
    /// socket — then closes only that dup.
    private static func startDownlink(_ conn: NWConnection, _ fd: Int32) {
        Thread.detachNewThread {
            while true {
                let sem = DispatchSemaphore(value: 0)
                var chunk: Data?
                var done = false
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data, _, isComplete, error in
                    chunk = data
                    if isComplete || error != nil { done = true }
                    sem.signal()
                }
                sem.wait()
                if let chunk, !chunk.isEmpty, !writeAll(fd, chunk) { done = true }
                if done { break }
            }
            conn.cancel()
            Darwin.shutdown(fd, SHUT_RDWR)   // unblock the uplink's read on the shared socket
            Darwin.close(fd)                 // only this thread's dup
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0, rem = raw.count
            while rem > 0 {
                let w = Darwin.write(fd, base.advanced(by: off), rem)
                if w <= 0 { return false }
                off += w; rem -= w
            }
            return true
        }
    }
}
