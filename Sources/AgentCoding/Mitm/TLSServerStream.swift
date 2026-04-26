import Foundation

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
@available(macOS, deprecated: 10.15, message: "wraps SSLContext deliberately — Network.framework can't take a raw socket FD")
final class TLSServerStream: @unchecked Sendable {
    private let fd: Int32
    private let ctx: SSLContext

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
