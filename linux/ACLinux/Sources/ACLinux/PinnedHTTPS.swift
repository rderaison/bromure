import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import SandboxEngine

/// One HTTPS request to an address already checked, never a name looked up
/// again (a DNS answer that changed in between can't redirect it): the TCP
/// connection goes to `address`, the URL's host is the TLS server name and
/// what the certificate is verified against (the system's roots, plus
/// `extraRoots`). HTTP/1.1, one request, no redirect followed, no proxy
/// from the environment (sendPlain: the same without TLS).
// @port-skip linux-only: a pinned dial for a request the daemon makes itself (macOS: URLSession, unchecked)
enum PinnedHTTPS {
    struct Refused: Error, CustomStringConvertible { let description: String }
    /// The connection itself failed: nothing of the request was sent, so
    /// another address may be tried (after any other error it may have
    /// reached the server, and a refresh token isn't sent twice).
    struct ConnectFailed: Error, CustomStringConvertible {
        let underlying: Error
        // @port-skip linux-only: see PinnedHTTPS
        var description: String { "couldn't connect: \(underlying)" }
    }

    /// The request to `address`, within `timeout` overall (connect, TLS,
    /// response): by default the request's own timeoutInterval.
    // @port-skip linux-only: see PinnedHTTPS
    static func send(_ req: URLRequest, to address: OpenShellPolicy.IPAddress, extraRoots: [NIOSSLCertificate] = [],
                     timeout: TimeInterval? = nil) async throws -> (HTTPURLResponse, Data) {
        guard let url = req.url, url.scheme?.lowercased() == "https", let host = url.host else {
            throw Refused(description: "a pinned request needs an https URL")
        }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.applicationProtocols = ["http/1.1"]
        if !extraRoots.isEmpty { tls.additionalTrustRoots = [.certificates(extraRoots)] }
        let context = try NIOSSLContext(configuration: tls)
        let sni = (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
        return try await dial(req, url: url, host: host, port: url.port ?? 443, defaultPort: 443, to: address,
                              timeout: timeout, tls: (context, sni))
    }

    /// The same over plain HTTP (a user's external engine on http): the
    /// raw request to `address`, its Host header the URL's; no redirect
    /// followed, no proxy from the environment.
    // @port-skip linux-only: see PinnedHTTPS
    static func sendPlain(_ req: URLRequest, to address: OpenShellPolicy.IPAddress,
                          timeout: TimeInterval? = nil) async throws -> (HTTPURLResponse, Data) {
        guard let url = req.url, url.scheme?.lowercased() == "http", let host = url.host else {
            throw Refused(description: "a plain pinned request needs an http URL")
        }
        return try await dial(req, url: url, host: host, port: url.port ?? 80, defaultPort: 80, to: address,
                              timeout: timeout, tls: nil)
    }

    /// One request on one connection to `address`; a cancelled task stops
    /// it (the connection closed, the call throwing CancellationError).
    // @port-skip linux-only: see PinnedHTTPS
    private static func dial(_ req: URLRequest, url: URL, host: String, port: Int, defaultPort: Int,
                             to address: OpenShellPolicy.IPAddress, timeout: TimeInterval?,
                             tls: (context: NIOSSLContext, sni: String?)?) async throws -> (HTTPURLResponse, Data) {
        guard let head = NIOMTLSHTTPClient.requestBytes(req, url: url, host: host, port: port, defaultPort: defaultPort) else {
            throw Refused(description: "a header name or value carries CR or LF")
        }
        let total = timeout ?? (req.timeoutInterval > 0 ? req.timeoutInterval : 60)
        let target = try SocketAddress(ipAddress: "\(address)", port: port)
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let result = loop.makePromise(of: (HTTPURLResponse, Data).self)
        let done = NIOLockedValueBox(false)
        @Sendable func finish(_ r: Result<(HTTPURLResponse, Data), Error>) {
            guard done.withLockedValue({ let was = $0; $0 = true; return !was }) else { return }
            result.completeWith(r)
        }
        // One deadline for all of it.
        let deadline = loop.scheduleTask(in: .milliseconds(Int64(total * 1000))) { finish(.failure(URLError(.timedOut))) }
        result.futureResult.whenComplete { _ in deadline.cancel() }
        return try await withTaskCancellationHandler {
            let collector = ResponseCollector()
            // Only the result is awaited, never the connect itself: a
            // cancel (or the deadline) ends the call at once, and a
            // connection that lands after that is closed.
            ClientBootstrap(group: loop)
                .connectTimeout(.milliseconds(Int64(total * 1000)))
                .channelInitializer { ch in
                    ch.eventLoop.makeCompletedFuture {
                        // Before the handshake starts: its failure reaches us.
                        collector.onDone = { bytes, error in
                            if let error { return finish(.failure(error)) }
                            guard let parsed = NIOMTLSHTTPClient.parse(bytes, url: url) else { return finish(.failure(URLError(.badServerResponse))) }
                            finish(.success(parsed))
                        }
                        if let tls {
                            try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls.context, serverHostname: tls.sni))
                        }
                        try ch.pipeline.syncOperations.addHandler(collector)
                    }
                }
                .connect(to: target)
                .whenComplete { connected in
                    switch connected {
                    case .failure(let error):
                        finish(.failure(ConnectFailed(underlying: error)))
                    case .success(let channel):
                        // Already over (cancelled, timed out): closed at once.
                        result.futureResult.whenFailure { _ in channel.close(promise: nil) }
                        var buf = channel.allocator.buffer(capacity: head.count)
                        buf.writeBytes(head)
                        channel.writeAndFlush(buf).whenFailure { e in finish(.failure(e)) }
                    }
                }
            return try await result.futureResult.get()
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }
}
