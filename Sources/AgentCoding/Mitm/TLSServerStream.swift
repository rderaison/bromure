import Foundation
@preconcurrency import Security

/// Server-side TLS termination over an already-connected socket FD,
/// using SecureTransport (SSLContext). Yes, SSLContext is deprecated
/// since macOS 10.15 — but it's the *only* TLS API on macOS that
/// works on a raw socket FD without going through Network.framework's
/// listener path, which doesn't take FDs at all.
///
/// Synchronous read/write API. Each MITM connection runs on its own
/// detached Task, so blocking syscalls inside read/write are fine.
///
/// The `@available(macOS, deprecated: 10.15)` annotation matches the
/// underlying SSLContext APIs so the compiler doesn't double-warn —
/// callers (only `HTTPMitmConnection`) are similarly annotated.
/// The minimal client-side byte stream the MITM request/response pipeline
/// needs: a (possibly no-op) handshake, blocking reads, and whole-buffer
/// writes. Implemented by `TLSServerStream` (HTTPS, :443) and
/// `PlaintextServerStream` (plain HTTP, :80) so `driveTLS` handles both the
/// same way — the only difference is TLS termination vs. raw socket I/O.
/// Outcome of a non-blocking pump read.
enum StreamReadOutcome {
    case bytes(Data)   // decrypted/plain bytes available now
    case wouldBlock    // nothing available yet — poll and retry
    case eof           // peer closed cleanly
}

protocol MitmServerStream: AnyObject {
    func handshake() throws
    func read(maxBytes: Int) throws -> Data
    func write(_ data: Data) throws

    // --- Concurrent-safe pump mode (the WebSocket relay) ---
    // The blocking `read`/`write` above are fine for the sequential
    // request→response path, but the WebSocket pump reads one direction while
    // writing the other CONCURRENTLY on the same underlying stream. For a
    // `TLSServerStream` that means concurrent `SSLRead`/`SSLWrite` on one
    // (non-thread-safe) `SSLContext`, which double-frees its record queue. The
    // pump therefore switches the fd non-blocking and uses these variants,
    // which serialize each SSL call under a per-stream lock and never block
    // while holding it (the caller `poll()`s outside the lock).
    /// The raw socket fd, for `poll()`ing readability/writability.
    var pumpFD: Int32 { get }
    /// Switch the fd to non-blocking. Call once before entering the pump; the
    /// sequential path above must have finished on this stream.
    func setNonBlocking()
    /// One non-blocking read. `SSLRead`/`recv` under the per-stream lock.
    func readNB(maxBytes: Int) throws -> StreamReadOutcome
    /// One non-blocking write. Returns bytes consumed (0 == would block).
    func writeNB(_ data: Data) throws -> Int
}

extension MitmServerStream {
    // Generic fallbacks for streams that don't do fd-backed pumping (e.g. test
    // mocks). The real fd-backed streams override all of these. `readNB`/
    // `writeNB` here just wrap the blocking calls, so a stream that is never
    // actually pumped still satisfies the protocol without special-casing.
    var pumpFD: Int32 { -1 }
    func setNonBlocking() {}
    func readNB(maxBytes: Int) throws -> StreamReadOutcome {
        let d = try read(maxBytes: maxBytes)
        return d.isEmpty ? .eof : .bytes(d)
    }
    func writeNB(_ data: Data) throws -> Int { try write(data); return data.count }
}

/// Cleartext client stream for transparent :80 interception. Same surface as
/// `TLSServerStream`, but reads/writes the socket FD directly — no TLS, so the
/// handshake is a no-op and no forged cert is needed.
final class PlaintextServerStream: MitmServerStream, @unchecked Sendable {
    private let fd: Int32
    /// Bytes already read off the socket (by the proxy's CONNECT/first-line
    /// parse) that must be handed back before we recv() again — e.g. the
    /// forward-proxy plain-HTTP request line `drive()` consumed to classify
    /// it. Drained first-come; empty for the transparent path.
    private var prefix: Data
    init(fd: Int32, prefix: Data = Data()) { self.fd = fd; self.prefix = prefix }
    func handshake() throws {}
    func read(maxBytes: Int) throws -> Data {
        if !prefix.isEmpty {
            let take = prefix.prefix(maxBytes)
            prefix.removeFirst(take.count)
            return Data(take)
        }
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = buf.withUnsafeMutableBytes { p in Darwin.recv(fd, p.baseAddress, maxBytes, 0) }
        if n < 0 { throw MitmError.tlsReadFailed(errno) }
        return Data(buf.prefix(max(0, n)))
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < data.count {
                let w = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if w <= 0 { throw MitmError.tlsWriteFailed(errno) }
                sent += w
            }
        }
    }

    // Pump mode. A raw socket is already safe for concurrent read+write (the
    // kernel serializes each direction), so no lock is needed here — these just
    // surface EAGAIN as `.wouldBlock` so the shared pump loop works uniformly.
    var pumpFD: Int32 { fd }
    func setNonBlocking() { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    func readNB(maxBytes: Int) throws -> StreamReadOutcome {
        if !prefix.isEmpty {
            let take = prefix.prefix(maxBytes); prefix.removeFirst(take.count)
            return .bytes(Data(take))
        }
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, maxBytes, 0) }
        if n > 0 { return .bytes(Data(buf.prefix(n))) }
        if n == 0 { return .eof }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return .wouldBlock }
        throw MitmError.tlsReadFailed(errno)
    }
    func writeNB(_ data: Data) throws -> Int {
        let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
        if n >= 0 { return n }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return 0 }
        throw MitmError.tlsWriteFailed(errno)
    }
}

@available(macOS, deprecated: 10.15, message: "wraps SSLContext deliberately — Network.framework can't take a raw socket FD")
final class TLSServerStream: MitmServerStream, @unchecked Sendable {
    private let fd: Int32
    private let ctx: SSLContext
    /// Serializes every `SSLRead`/`SSLWrite` on `ctx` in pump mode so the two
    /// WebSocket directions can't corrupt SecureTransport's record queue.
    private let ioLock = NSLock()

    init(fd: Int32, identity: SecIdentity) throws {
        self.fd = fd
        guard let ctx = SSLCreateContext(nil, .serverSide, .streamType) else {
            throw MitmError.tlsHandshakeFailed(errSSLInternal)
        }
        self.ctx = ctx

        // I/O callbacks read/write directly from the socket FD via BSD
        // syscalls. SecureTransport hands us the connection ref we
        // gave it via SSLSetConnection.
        var status = SSLSetIOFuncs(ctx, sslReadCallback, sslWriteCallback)
        if status != errSecSuccess { throw MitmError.tlsHandshakeFailed(status) }

        // Stash the FD as an `intptr_t`-sized opaque pointer. The
        // callbacks unpack it back to Int32. Pointer round-trip avoids
        // heap allocation for the connection ref.
        let connectionRef = UnsafeMutableRawPointer(bitPattern: Int(fd))
        status = SSLSetConnection(ctx, connectionRef)
        if status != errSecSuccess { throw MitmError.tlsHandshakeFailed(status) }

        // Present our forged cert as the server identity.
        status = SSLSetCertificate(ctx, [identity] as CFArray)
        if status != errSecSuccess { throw MitmError.tlsHandshakeFailed(status) }
    }

    deinit {
        SSLClose(ctx)
    }

    func handshake() throws {
        while true {
            let status = SSLHandshake(ctx)
            switch status {
            case errSecSuccess:
                return
            case errSSLWouldBlock:
                // Socket isn't drained yet; retry. Our IO funcs use
                // blocking reads, so this should be rare — but
                // SecureTransport occasionally emits it.
                continue
            default:
                throw MitmError.tlsHandshakeFailed(status)
            }
        }
    }

    /// Read up to `maxBytes` decrypted bytes. Returns empty Data on
    /// clean EOF.
    func read(maxBytes: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: maxBytes)
        var got: Int = 0
        let status = buf.withUnsafeMutableBufferPointer { ptr in
            SSLRead(ctx, ptr.baseAddress!, maxBytes, &got)
        }
        switch status {
        case errSecSuccess, errSSLWouldBlock:
            return Data(buf.prefix(got))
        case errSSLClosedGraceful, errSSLClosedNoNotify:
            return Data()
        default:
            throw MitmError.tlsReadFailed(status)
        }
    }

    /// Write all bytes through TLS. Loops on partial writes.
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            let total = data.count
            while sent < total {
                var written: Int = 0
                let status = SSLWrite(ctx,
                                      raw.baseAddress!.advanced(by: sent),
                                      total - sent,
                                      &written)
                if status == errSecSuccess || status == errSSLWouldBlock {
                    sent += written
                    continue
                }
                throw MitmError.tlsWriteFailed(status)
            }
        }
    }

    // Pump mode: non-blocking, lock-serialized single SSL calls.
    var pumpFD: Int32 { fd }
    func setNonBlocking() { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    func readNB(maxBytes: Int) throws -> StreamReadOutcome {
        var buf = [UInt8](repeating: 0, count: maxBytes)
        var got = 0
        ioLock.lock()
        let status = buf.withUnsafeMutableBufferPointer { SSLRead(ctx, $0.baseAddress!, maxBytes, &got) }
        ioLock.unlock()
        switch status {
        case errSecSuccess, errSSLWouldBlock:
            return got > 0 ? .bytes(Data(buf.prefix(got))) : .wouldBlock
        case errSSLClosedGraceful, errSSLClosedNoNotify:
            return .eof
        default:
            throw MitmError.tlsReadFailed(status)
        }
    }
    func writeNB(_ data: Data) throws -> Int {
        var consumed = 0
        var thrown: OSStatus? = nil
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var written = 0
            ioLock.lock()
            let status = SSLWrite(ctx, raw.baseAddress!, data.count, &written)
            ioLock.unlock()
            if status == errSecSuccess || status == errSSLWouldBlock { consumed = written }
            else { thrown = status }
        }
        if let s = thrown { throw MitmError.tlsWriteFailed(s) }
        return consumed
    }
}

/// Client-side TLS over an already-connected upstream socket FD.
/// Mirror of `TLSServerStream` but with `clientSide` role and a
/// peer-domain-name set so SecureTransport sends SNI and validates
/// the upstream cert.
///
/// Used by the HTTP-upgrade fast-path in `HTTPProxy.swift`, where
/// URLSession can't represent the raw 101-Switching-Protocols +
/// bidirectional byte stream that follows.
///
/// `clientIdentity` and `pinnedCA` mirror what `ClientCertChallengeDelegate`
/// does for the URLSession path: without them this path can only reach
/// upstreams that need no mTLS and chain to a system root — which excludes
/// most k8s API servers, and so excluded `kubectl exec`.
@available(macOS, deprecated: 10.15, message: "wraps SSLContext deliberately — Network.framework can't take a raw socket FD")
final class TLSClientStream: @unchecked Sendable {
    private let fd: Int32
    private let ctx: SSLContext
    private let peerName: String
    private let pinnedCA: SecCertificate?
    /// Serializes `SSLRead`/`SSLWrite` on `ctx` in pump mode (see TLSServerStream).
    private let ioLock = NSLock()

    init(fd: Int32, peerName: String,
         clientIdentity: SecIdentity? = nil,
         pinnedCA: SecCertificate? = nil) throws {
        self.fd = fd
        self.peerName = peerName
        self.pinnedCA = pinnedCA
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw MitmError.tlsHandshakeFailed(errSSLInternal)
        }
        self.ctx = ctx

        var status = SSLSetIOFuncs(ctx, sslReadCallback, sslWriteCallback)
        if status != errSecSuccess { throw MitmError.tlsHandshakeFailed(status) }

        let connectionRef = UnsafeMutableRawPointer(bitPattern: Int(fd))
        status = SSLSetConnection(ctx, connectionRef)
        if status != errSecSuccess { throw MitmError.tlsHandshakeFailed(status) }

        // SNI + cert-name validation target. Without this, OpenAI (and
        // most managed CDNs) will hand back a generic cert that fails
        // matching, or refuse the connection entirely.
        status = peerName.withCString { cstr in
            SSLSetPeerDomainName(ctx, cstr, strlen(cstr))
        }
        if status != errSecSuccess { throw MitmError.tlsHandshakeFailed(status) }

        // mTLS: answer the upstream's CertificateRequest with the
        // profile's identity (k8s client-certificate-data, internal
        // mTLS APIs).
        if let clientIdentity {
            status = SSLSetCertificate(ctx, [clientIdentity] as CFArray)
            if status != errSecSuccess { throw MitmError.tlsHandshakeFailed(status) }
        }

        // Pinned CA: stop the handshake after the server cert arrives so
        // `evaluatePinnedServerTrust` can anchor it at the user's cluster
        // CA. Without the break, SecureTransport evaluates against the
        // system trust store and fails a private k8s root outright.
        if pinnedCA != nil {
            status = SSLSetSessionOption(ctx, .breakOnServerAuth, true)
            if status != errSecSuccess { throw MitmError.tlsHandshakeFailed(status) }
        }
    }

    deinit {
        SSLClose(ctx)
    }

    func handshake() throws {
        while true {
            let status = SSLHandshake(ctx)
            switch status {
            case errSecSuccess:
                return
            case errSSLWouldBlock:
                continue
            case errSSLPeerAuthCompleted:
                // The `errSSLServerAuthCompleted` spelling is a C #define
                // alias that doesn't import into Swift. Only reachable with
                // `.breakOnServerAuth`, i.e. when a pinned CA is set.
                // Evaluate, then resume the handshake.
                try evaluatePinnedServerTrust()
                continue
            default:
                throw MitmError.tlsHandshakeFailed(status)
            }
        }
    }

    /// Anchor the upstream's server cert at the pinned cluster CA, using
    /// the same verdict logic as the URLSession path.
    private func evaluatePinnedServerTrust() throws {
        guard let pinnedCA else { return }
        var trust: SecTrust?
        let status = SSLCopyPeerTrust(ctx, &trust)
        guard status == errSecSuccess, let trust else {
            throw MitmError.tlsHandshakeFailed(status)
        }
        guard PinnedClusterTrust.evaluate(trust, ca: pinnedCA, host: peerName) else {
            throw MitmError.tlsHandshakeFailed(errSSLXCertChainInvalid)
        }
    }

    func read(maxBytes: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: maxBytes)
        var got: Int = 0
        let status = buf.withUnsafeMutableBufferPointer { ptr in
            SSLRead(ctx, ptr.baseAddress!, maxBytes, &got)
        }
        switch status {
        case errSecSuccess, errSSLWouldBlock:
            return Data(buf.prefix(got))
        case errSSLClosedGraceful, errSSLClosedNoNotify:
            return Data()
        default:
            throw MitmError.tlsReadFailed(status)
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            let total = data.count
            while sent < total {
                var written: Int = 0
                let status = SSLWrite(ctx,
                                      raw.baseAddress!.advanced(by: sent),
                                      total - sent,
                                      &written)
                if status == errSecSuccess || status == errSSLWouldBlock {
                    sent += written
                    continue
                }
                throw MitmError.tlsWriteFailed(status)
            }
        }
    }

    // Pump mode: non-blocking, lock-serialized single SSL calls (see TLSServerStream).
    var pumpFD: Int32 { fd }
    func setNonBlocking() { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    func readNB(maxBytes: Int) throws -> StreamReadOutcome {
        var buf = [UInt8](repeating: 0, count: maxBytes)
        var got = 0
        ioLock.lock()
        let status = buf.withUnsafeMutableBufferPointer { SSLRead(ctx, $0.baseAddress!, maxBytes, &got) }
        ioLock.unlock()
        switch status {
        case errSecSuccess, errSSLWouldBlock:
            return got > 0 ? .bytes(Data(buf.prefix(got))) : .wouldBlock
        case errSSLClosedGraceful, errSSLClosedNoNotify:
            return .eof
        default:
            throw MitmError.tlsReadFailed(status)
        }
    }
    func writeNB(_ data: Data) throws -> Int {
        var consumed = 0
        var thrown: OSStatus? = nil
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var written = 0
            ioLock.lock()
            let status = SSLWrite(ctx, raw.baseAddress!, data.count, &written)
            ioLock.unlock()
            if status == errSecSuccess || status == errSSLWouldBlock { consumed = written }
            else { thrown = status }
        }
        if let s = thrown { throw MitmError.tlsWriteFailed(s) }
        return consumed
    }
}

// MARK: - SSL I/O callbacks

/// SecureTransport read callback. Invoked with: connection ref (our
/// FD packed as a pointer), buffer to fill, and a pointer to the
/// requested length (which the callback updates with the actual
/// bytes read).
private func sslReadCallback(
    _ connection: SSLConnectionRef,
    _ data: UnsafeMutableRawPointer,
    _ dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = Int32(Int(bitPattern: connection))
    let want = dataLength.pointee
    var got = 0
    while got < want {
        let n = read(fd, data.advanced(by: got), want - got)
        if n > 0 {
            got += n
            continue
        }
        if n == 0 {
            dataLength.pointee = got
            return errSSLClosedGraceful
        }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            dataLength.pointee = got
            return errSSLWouldBlock
        }
        dataLength.pointee = got
        return OSStatus(errno)
    }
    dataLength.pointee = got
    return errSecSuccess
}

private func sslWriteCallback(
    _ connection: SSLConnectionRef,
    _ data: UnsafeRawPointer,
    _ dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = Int32(Int(bitPattern: connection))
    let want = dataLength.pointee
    var sent = 0
    while sent < want {
        let n = write(fd, data.advanced(by: sent), want - sent)
        if n > 0 {
            sent += n
            continue
        }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            dataLength.pointee = sent
            return errSSLWouldBlock
        }
        dataLength.pointee = sent
        return OSStatus(errno)
    }
    dataLength.pointee = sent
    return errSecSuccess
}
