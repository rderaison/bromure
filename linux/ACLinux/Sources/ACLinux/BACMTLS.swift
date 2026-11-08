import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// The install's mTLS client for Bromure's cloud (event ingest, HTTP trace
/// ingest, egress-IP heartbeat; macOS: URLSession + BACMTLSDelegate
/// presenting the org-CA leaf). Linux's URLSession can't present a client
/// certificate, so the request goes out over NIO + NIOSSL with the leaf
/// BACEnrollment stored (its PEM, and its key from the secret store). No
/// leaf (not enrolled, or the cert not issued yet): the request fails and
/// nothing leaves the host.
// @port-skip linux-only: the Linux side of CloudMTLSClient.swift's BACMTLS seam
enum BACMTLS {
    // @port-skip linux-only: BACMTLS seam
    static func makeClient(timeout: TimeInterval) -> BACMTLSClient {
        NIOMTLSHTTPClient(timeout: timeout, identity: { try BACMTLSIdentity.current() },
                          extraRoots: testRoots())
    }

    /// The cached identity dropped (a leaf rotation, an unenroll).
    // @port-skip linux-only: BACMTLS seam
    static func purgeIdentity() { BACMTLSIdentity.purge() }

    /// Debug builds, VM e2e only: also trust the test CA in
    /// `BROMURE_AC_TEST_ROOTS` (the ingest stand-in's). A release build
    /// trusts the system's roots only.
    // @port-skip linux-only: e2e hook of the Linux mTLS client
    static func testRoots() -> [NIOSSLCertificate] {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["BROMURE_AC_TEST_ROOTS"],
              let pem = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return (try? NIOSSLCertificate.fromPEMBytes(Array(pem.utf8))) ?? []
        #else
        return []
        #endif
    }
}

/// The install's leaf and key for NIOSSL (macOS: BACMTLSIdentity's
/// SecIdentity), built from BACEnrollmentStore on first use and cached
/// until purged.
// @port-skip linux-only: BACMTLSIdentity's material, as NIOSSL takes it
enum BACMTLSIdentity {
    struct Material { let chain: [NIOSSLCertificate]; let key: NIOSSLPrivateKey }

    enum Failure: Error, CustomStringConvertible {
        case missingMaterial, invalidCertificate, invalidPrivateKey
        // @port-skip linux-only: BACMTLSIdentity.Error's texts
        var description: String {
            switch self {
            case .missingMaterial: return "BAC leaf cert or private key not found"
            case .invalidCertificate: return "Stored leaf cert is not a valid PEM"
            case .invalidPrivateKey: return "Stored leaf private key could not be parsed"
            }
        }
    }

    private static let cache = NIOLockedValueBox<Material?>(nil)

    // @port-skip linux-only: BACMTLSIdentity.current
    static func current() throws -> Material {
        try cache.withLockedValue { cached in
            if let cached { return cached }
            guard let pem = BACEnrollmentStore.loadLeafCertPem(),
                  let serial = BACEnrollmentStore.loadLeafSerial(),
                  let keyDER = BACEnrollmentStore.loadLeafPrivateKey(serialHex: serial) else { throw Failure.missingMaterial }
            guard let chain = try? NIOSSLCertificate.fromPEMBytes(Array(pem.utf8)), !chain.isEmpty else {
                throw Failure.invalidCertificate
            }
            // Stored as PKCS#1 RSAPrivateKey DER (BoringSSL reads it as is).
            guard let key = try? NIOSSLPrivateKey(bytes: Array(keyDER), format: .der) else { throw Failure.invalidPrivateKey }
            let m = Material(chain: chain, key: key)
            cached = m
            return m
        }
    }

    // @port-skip linux-only: BACMTLSIdentity.purge
    static func purge() { cache.withLockedValue { $0 = nil } }
}

/// An HTTPS client presenting a client certificate: one HTTP/1.1 request
/// per connection (`Connection: close`), the response read whole. The
/// server is verified against the system's roots (plus `extraRoots`).
// @port-skip linux-only: URLSession with a client-certificate delegate, on NIO + NIOSSL
final class NIOMTLSHTTPClient: BACMTLSClient, @unchecked Sendable {
    let timeout: TimeInterval
    let identity: @Sendable () throws -> BACMTLSIdentity.Material
    let extraRoots: [NIOSSLCertificate]
    private let open = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])
    private let closed = NIOLockedValueBox(false)

    // @port-skip linux-only: the mTLS client's HTTP/1.1 framing
    init(timeout: TimeInterval, identity: @escaping @Sendable () throws -> BACMTLSIdentity.Material,
         extraRoots: [NIOSSLCertificate] = []) {
        self.timeout = timeout
        self.identity = identity
        self.extraRoots = extraRoots
    }

    struct Refused: Error, CustomStringConvertible {
        let description: String
    }

    // @port-skip linux-only: URLSession.dataTask on NIO
    func send(_ req: URLRequest, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        let done = NIOLockedValueBox(false)
        let finish: @Sendable (Data?, URLResponse?, Error?) -> Void = { d, r, e in
            guard done.withLockedValue({ let was = $0; $0 = true; return !was }) else { return }
            DispatchQueue.global(qos: .utility).async { completion(d, r, e) }
        }
        guard !closed.withLockedValue({ $0 }) else { return finish(nil, nil, Refused(description: "the client is shut down")) }
        guard let url = req.url, url.scheme?.lowercased() == "https", let host = url.host else {
            return finish(nil, nil, Refused(description: "mTLS needs an https URL"))
        }
        let material: BACMTLSIdentity.Material
        do { material = try identity() } catch { return finish(nil, nil, error) }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateChain = material.chain.map { .certificate($0) }
        tls.privateKey = .privateKey(material.key)
        tls.applicationProtocols = ["http/1.1"]
        if !extraRoots.isEmpty {
            tls.additionalTrustRoots = [.certificates(extraRoots)]
        }
        let context: NIOSSLContext
        do { context = try NIOSSLContext(configuration: tls) } catch { return finish(nil, nil, error) }
        let port = url.port ?? 443
        let head = Self.requestBytes(req, url: url, host: host, port: port)
        let collector = ResponseCollector()
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let deadline = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) { [weak self] in
            finish(nil, nil, URLError(.timedOut))
            self?.closeAll(matching: collector)
        }
        ClientBootstrap(group: loop)
            .connectTimeout(.milliseconds(Int64(timeout * 1000)))
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    let sni = (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
                    try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: sni))
                    try ch.pipeline.syncOperations.addHandler(collector)
                }
            }
            .connect(host: host, port: port)
            .whenComplete { [weak self] r in
                switch r {
                case .failure(let e):
                    deadline.cancel()
                    finish(nil, nil, e)
                case .success(let ch):
                    self?.open.withLockedValue { $0[ObjectIdentifier(collector)] = ch }
                    collector.onDone = { bytes, error in
                        deadline.cancel()
                        self?.open.withLockedValue { _ = $0.removeValue(forKey: ObjectIdentifier(collector)) }
                        if let error { return finish(nil, nil, error) }
                        guard let (resp, body) = Self.parse(bytes, url: url) else {
                            return finish(nil, nil, URLError(.badServerResponse))
                        }
                        finish(body, resp, nil)
                    }
                    var buf = ch.allocator.buffer(capacity: head.count)
                    buf.writeBytes(head)
                    ch.writeAndFlush(buf).whenFailure { e in finish(nil, nil, e); ch.close(promise: nil) }
                }
            }
    }

    // @port-skip linux-only: URLSession.invalidateAndCancel / finishTasksAndInvalidate
    func shutdown(cancelling: Bool) {
        closed.withLockedValue { $0 = true }
        guard cancelling else { return }
        for ch in open.withLockedValue({ $0.values }) { ch.close(promise: nil) }
    }

    // @port-skip linux-only: the mTLS client's HTTP/1.1 framing
    private func closeAll(matching collector: ResponseCollector) {
        open.withLockedValue { $0.removeValue(forKey: ObjectIdentifier(collector)) }?.close(promise: nil)
    }

    /// The request as it goes on the wire.
    // @port-skip linux-only: the mTLS client's HTTP/1.1 framing
    static func requestBytes(_ req: URLRequest, url: URL, host: String, port: Int) -> [UInt8] {
        var target = url.path.isEmpty ? "/" : url.path
        if let q = url.query { target += "?" + q }
        let body = req.httpBody ?? Data()
        var head = "\(req.httpMethod ?? "GET") \(target) HTTP/1.1\r\nHost: \(port == 443 ? host : "\(host):\(port)")\r\n"
        for (k, v) in req.allHTTPHeaderFields ?? [:] {
            switch k.lowercased() {
            case "host", "content-length", "connection", "transfer-encoding": continue
            default: head += "\(k): \(v)\r\n"
            }
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + Array(body)
    }

    /// A whole response: its HTTPURLResponse and body (chunked decoded).
    // @port-skip linux-only: the mTLS client's HTTP/1.1 framing
    static func parse(_ raw: [UInt8], url: URL) -> (HTTPURLResponse, Data)? {
        let data = Data(raw)
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ")
        guard status.count >= 2, let code = Int(status[1]) else { return nil }
        var fields: [String: String] = [:]
        for l in lines { if let c = l.firstIndex(of: ":") { fields[String(l[..<c])] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
        let (_, body) = HTTPRequestFraming.responseStatusAndBody(data)
        guard let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: fields) else { return nil }
        return (resp, body)
    }
}

/// Reads a response until the server closes (or its Content-Length is in).
// @port-skip linux-only: NIO plumbing of the mTLS client
final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var onDone: (([UInt8], Error?) -> Void)?
    private var bytes: [UInt8] = []
    private var finished = false

    // @port-skip linux-only: NIO plumbing of the mTLS client
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let b = buf.readBytes(length: buf.readableBytes) { bytes += b }
        if let need = Self.completeLength(bytes), bytes.count >= need {
            done(nil)
            context.close(promise: nil)
        }
    }

    // @port-skip linux-only: NIO plumbing of the mTLS client
    func channelInactive(context: ChannelHandlerContext) { done(nil) }

    // @port-skip linux-only: NIO plumbing of the mTLS client
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A close without close_notify after a whole response is fine.
        if let e = error as? NIOSSLError, case .uncleanShutdown = e, !bytes.isEmpty { return done(nil) }
        done(error)
        context.close(promise: nil)
    }

    // @port-skip linux-only: the mTLS client's HTTP/1.1 framing
    private func done(_ error: Error?) {
        guard !finished else { return }
        finished = true
        onDone?(bytes, error)
    }

    /// The total length once the head and a Content-Length are in; nil
    /// otherwise (read to the close).
    // @port-skip linux-only: the mTLS client's HTTP/1.1 framing
    static func completeLength(_ b: [UInt8]) -> Int? {
        let data = Data(b)
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).lowercased()
        for l in head.components(separatedBy: "\r\n") where l.hasPrefix("content-length:") {
            if let n = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) {
                return end.upperBound - data.startIndex + n
            }
        }
        return nil
    }
}
