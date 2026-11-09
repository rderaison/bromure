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
/// `extraRoots`). HTTP/1.1, one request, no redirect followed.
// @port-skip linux-only: a pinned dial for a request the daemon makes itself (macOS: URLSession, unchecked)
enum PinnedHTTPS {
    struct Refused: Error, CustomStringConvertible { let description: String }

    // @port-skip linux-only: see PinnedHTTPS
    static func send(_ req: URLRequest, to address: OpenShellPolicy.IPAddress, extraRoots: [NIOSSLCertificate] = [],
                     timeout: TimeInterval = 10) async throws -> (HTTPURLResponse, Data) {
        guard let url = req.url, url.scheme?.lowercased() == "https", let host = url.host else {
            throw Refused(description: "a pinned request needs an https URL")
        }
        let port = url.port ?? 443
        guard let head = NIOMTLSHTTPClient.requestBytes(req, url: url, host: host, port: port) else {
            throw Refused(description: "a header name or value carries CR or LF")
        }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.applicationProtocols = ["http/1.1"]
        if !extraRoots.isEmpty { tls.additionalTrustRoots = [.certificates(extraRoots)] }
        let context = try NIOSSLContext(configuration: tls)
        let target = try SocketAddress(ipAddress: "\(address)", port: port)
        let sni = (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let collector = ResponseCollector()
        let channel = try await ClientBootstrap(group: loop)
            .connectTimeout(.milliseconds(Int64(timeout * 1000)))
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: sni))
                    try ch.pipeline.syncOperations.addHandler(collector)
                }
            }
            .connect(to: target).get()
        let done = NIOLockedValueBox(false)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<(HTTPURLResponse, Data), Error>) in
            func finish(_ r: Result<(HTTPURLResponse, Data), Error>) {
                guard done.withLockedValue({ let was = $0; $0 = true; return !was }) else { return }
                c.resume(with: r)
            }
            let deadline = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
                finish(.failure(URLError(.timedOut)))
                channel.close(promise: nil)
            }
            collector.onDone = { bytes, error in
                deadline.cancel()
                if let error { return finish(.failure(error)) }
                guard let parsed = NIOMTLSHTTPClient.parse(bytes, url: url) else { return finish(.failure(URLError(.badServerResponse))) }
                finish(.success(parsed))
            }
            var buf = channel.allocator.buffer(capacity: head.count)
            buf.writeBytes(head)
            channel.writeAndFlush(buf).whenFailure { e in finish(.failure(e)); channel.close(promise: nil) }
        }
    }
}
