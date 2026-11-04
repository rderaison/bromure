import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import SwiftASN1
import Testing
import X509
@testable import ACLinux

/// A throwaway PKI: a CA, and leaves it signs (server or client).
private struct TestCA {
    let cert: Certificate
    let key: P256.Signing.PrivateKey
    var pem: String { try! cert.serializeAsPEM().pemString }
    var nio: NIOSSLCertificate { try! NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem) }

    init(_ name: String) throws {
        key = P256.Signing.PrivateKey()
        let dn = try DistinguishedName { CommonName(name) }
        cert = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-60), notValidAfter: Date().addingTimeInterval(3600),
            issuer: dn, subject: dn, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: .init(key))
    }

    /// (certificate PEM, key PEM) for `cn`, with these SANs.
    func leaf(_ cn: String, dns: [String] = [], ip: String? = nil, client: Bool) throws -> (String, String) {
        let k = P256.Signing.PrivateKey()
        var sans: [GeneralName] = dns.map { .dnsName($0) }
        if let ip { sans.append(.ipAddress(ASN1OctetString(contentBytes: ArraySlice(ip.split(separator: ".").map { UInt8($0)! })))) }
        let c = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(k.publicKey),
            notValidBefore: Date().addingTimeInterval(-60), notValidAfter: Date().addingTimeInterval(3600),
            issuer: cert.subject, subject: try DistinguishedName { CommonName(cn) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                try ExtendedKeyUsage([client ? .clientAuth : .serverAuth])
                if !sans.isEmpty { SubjectAlternativeNames(sans) }
            },
            issuerPrivateKey: .init(key))
        return (try c.serializeAsPEM().pemString, k.pemRepresentation)
    }
}

/// An API server stand-in: TLS with `leaf`, a client certificate signed by
/// `clientCA` required; answers any request "kube ok" and counts connections.
private final class MTLSServer: @unchecked Sendable {
    let channel: Channel
    let connections = NIOLockedValueBoxShim(0)
    var port: Int { channel.localAddress!.port! }

    /// `clientCA` nil: no client certificate asked for (a public API).
    init(host: String, leaf: (String, String), clientCA: NIOSSLCertificate?) throws {
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(leaf.0.utf8)).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leaf.1.utf8), format: .pem)))
        if let clientCA {
            cfg.certificateVerification = .noHostnameVerification
            cfg.trustRoots = .certificates([clientCA])
        }
        let ctx = try NIOSSLContext(configuration: cfg)
        let counter = connections
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                counter.mutate { $0 += 1 }
                return ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandlers([NIOSSLServerHandler(context: ctx), Responder()])
                }
            }
            .bind(host: host, port: 0).wait()
    }

    func stop() { try? channel.close().wait() }

    final class Responder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let body = "kube ok"
            let r = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(channel.allocator.buffer(string: r)))
                .whenComplete { _ in channel.close(promise: nil) }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}

/// A guest's request through the proxy listener: CONNECT, TLS to the
/// proxy's leaf, one GET; everything the guest reads back.
private final class GuestClient: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let target: String
    let tls: NIOSSLContext
    let done: EventLoopPromise<String>
    var buf = ""
    var tunneled = false

    init(target: String, tls: NIOSSLContext, done: EventLoopPromise<String>) {
        self.target = target; self.tls = tls; self.done = done
    }

    static func get(_ listener: String, target: String, proxyCA: NIOSSLCertificate) throws -> String {
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.trustRoots = .certificates([proxyCA])
        cfg.certificateVerification = .noHostnameVerification
        let ctx = try NIOSSLContext(configuration: cfg)
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let done = loop.makePromise(of: String.self)
        let ch = try ClientBootstrap(group: loop)
            .channelInitializer { $0.pipeline.addHandler(GuestClient(target: target, tls: ctx, done: done)) }
            .connect(unixDomainSocketPath: listener).wait()
        loop.scheduleTask(in: .seconds(20)) { done.succeed("TIMEOUT"); ch.close(promise: nil) }
        return try done.futureResult.wait()
    }

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
            string: "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data)
        buf += b.readString(length: b.readableBytes) ?? ""
        guard !tunneled, buf.contains("\r\n\r\n") else { return }
        guard buf.hasPrefix("HTTP/1.1 200") else { done.succeed("CONNECT: " + buf); context.close(promise: nil); return }
        tunneled = true
        buf = ""
        try! context.pipeline.syncOperations.addHandler(try! NIOSSLClientHandler(context: tls, serverHostname: nil),
                                                         position: .first)
        let host = target.split(separator: ":").first.map(String.init) ?? target
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(
            string: "GET /api HTTP/1.1\r\nHost: \(host)\r\n\r\n")), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) { done.succeed(buf) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// The proxy, two workspaces' listeners (A's is the one used unless
/// said), and an mTLS API server on the host's own LAN address (loopback
/// is a blocked destination), always dialed by that IP literal.
private struct KubeRig {
    let dir: String
    let proxy: MitmProxy
    let listener: MitmListener
    let listenerB: MitmListener
    let pid = UUID()
    let pidB = UUID()
    let ip: String
    let clusterCA: TestCA
    let clientCA: TestCA
    let server: MTLSServer
    var target: String { "\(ip):\(server.port)" }

    /// The API server's certificate: an IP SAN of the dialed address, of
    /// another address, or none (DNS names only).
    enum SAN { case dialed, other(String), none }

    /// `publicRoots`: the cluster CA stands in for a public root (trusted
    /// by the proxy's own context, nothing pinned) and the server asks for
    /// no client certificate: the path of every non-kube IP-literal upstream.
    init(dns: [String] = ["kubernetes"], san: SAN = .dialed, publicRoots: Bool = false) throws {
        guard let ip = Daemon.primaryIPv4() else { throw RigSkip() }
        self.ip = ip
        dir = try shortTempDir()
        let cluster = try TestCA("test cluster CA"), clients = try TestCA("test client CA")
        clusterCA = cluster
        clientCA = clients
        proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true),
                              extraRoots: publicRoots ? [cluster.nio] : [])
        listener = try proxy.serve(udsPath: dir + "/vm.sock", profileID: pid, fdStoreName: "kt-\(pid)")
        listenerB = try proxy.serve(udsPath: dir + "/vmb.sock", profileID: pidB, fdStoreName: "kt-\(pidB)")
        let sanIP: String? = switch san { case .dialed: ip; case .other(let o): o; case .none: nil }
        let leaf = try cluster.leaf("apiserver", dns: dns, ip: sanIP, client: false)
        server = try MTLSServer(host: ip, leaf: leaf, clientCA: publicRoots ? nil : clients.nio)
    }

    func client() throws -> (String, String) { try clientCA.leaf("system:admin", client: true) }

    /// One request as workspace A (or B), to the server by its IP literal.
    func get(asB: Bool = false) throws -> String {
        try GuestClient.get(HybridVsockListener.path(uds: dir + (asB ? "/vmb.sock" : "/vm.sock"), port: MitmProxy.vsockPort),
                            target: target, proxyCA: proxy.caNIO)
    }

    func pin(host: String? = nil, ca: String? = nil, identity: (String, String)?, consent: String? = nil) {
        let h = host ?? target
        proxy.kubeTrust.replaceAll(
            identities: identity.map { [(host: h, certPEM: $0.0, keyPEM: $0.1,
                                         consentCredentialID: consent, consentDisplayName: consent)] } ?? [],
            cas: [(pem: ca ?? clusterCA.pem, host: h)], for: pid)
    }

    func stop() {
        server.stop()
        listener.stop()
        listenerB.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    struct RigSkip: Error {}
}

@Suite("Kube upstream trust", .serialized)
struct KubeUpstreamTrustTests {
    @Test func pinnedCAAndClientCertificate() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        rig.pin(identity: try rig.client())
        let out = try rig.get()
        #expect(out.hasPrefix("HTTP/1.1 200") && out.hasSuffix("kube ok"), "got: \(out.prefix(300))")
    }

    @Test func nothingPinnedFailsClosed() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        let out = try rig.get()
        #expect(out.hasPrefix("HTTP/1.1 502"), "system roots must not trust the private cluster: \(out.prefix(300))")
    }

    @Test func caWithoutClientCertificateIsRefusedByTheServer() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        rig.pin(identity: nil)
        let out = try rig.get()
        // TLS 1.3: the proxy's side of the handshake completes (the server's
        // certificate chained to the pinned CA), then the server refuses the
        // missing client certificate and the guest's connection just closes.
        // (Unpinned, the proxy's own handshake fails first: its 502.)
        #expect(out.isEmpty, "the server requires a client certificate: \(out.prefix(300))")
        #expect(rig.server.connections.value == 1, "the pinned handshake reached the server")
    }

    @Test func anotherPortsMaterialIsNotUsed() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        rig.pin(host: "\(rig.ip):\(rig.server.port + 1)", identity: try rig.client())
        #expect(try rig.get().hasPrefix("HTTP/1.1 502"))
        rig.pin(host: rig.ip, identity: try rig.client())   // the bare host is :443's
        #expect(try rig.get().hasPrefix("HTTP/1.1 502"))
    }

    @Test func pinnedCAStillBindsTheHostName() throws {
        // https://<IP>:<port>, the usual imported-kubeconfig shape: a sibling
        // leaf under the pinned CA with DNS names only is refused. (Without
        // the address binding it passes: the chain is good, the client
        // certificate too -- see the mutation check in the patch.)
        let rig = try KubeRig(dns: ["etcd.internal", "kubelet"], san: .none); defer { rig.stop() }
        #expect(rig.ip.split(separator: ".").count == 4 && rig.ip.split(separator: ".").allSatisfy { UInt8($0) != nil }, "dialed by IP literal")
        rig.pin(identity: try rig.client())
        let out = try rig.get()
        #expect(out.hasPrefix("HTTP/1.1 502"), "a DNS-only sibling certificate under the same CA: \(out.prefix(300))")
        #expect(!out.contains("kube ok"))
    }

    @Test func pinnedCAAndAnotherAddressesCertificateIsRefused() throws {
        // A sibling leaf for another node's address: refused for this one.
        let rig = try KubeRig(san: .other("10.99.99.99")); defer { rig.stop() }
        rig.pin(identity: try rig.client())
        let out = try rig.get()
        #expect(out.hasPrefix("HTTP/1.1 502") && !out.contains("kube ok"), "got: \(out.prefix(300))")
    }

    @Test func pinnedCAAndTheDialedAddressesCertificate() throws {
        // The same rig with the right IP SAN: the positive control.
        let rig = try KubeRig(dns: ["etcd.internal"], san: .dialed); defer { rig.stop() }
        rig.pin(identity: try rig.client())
        let out = try rig.get()
        #expect(out.hasPrefix("HTTP/1.1 200") && out.hasSuffix("kube ok"), "got: \(out.prefix(300))")
    }

    @Test func anIPLiteralUpstreamUnderTheProxysOwnRootsIsBoundToo() throws {
        // Not kube: an upstream reached by IP literal through the proxy's own
        // trust (the test's root standing in for a public one). The right
        // address passes, a trusted certificate for another name doesn't.
        let ok = try KubeRig(san: .dialed, publicRoots: true); defer { ok.stop() }
        let good = try ok.get()
        #expect(good.hasPrefix("HTTP/1.1 200") && good.hasSuffix("kube ok"), "got: \(good.prefix(300))")
        let bad = try KubeRig(dns: ["www.example.com"], san: .none, publicRoots: true); defer { bad.stop() }
        let out = try bad.get()
        #expect(out.hasPrefix("HTTP/1.1 502") && !out.contains("kube ok"), "a publicly trusted cert for another name: \(out.prefix(300))")
        let other = try KubeRig(san: .other("10.99.99.99"), publicRoots: true); defer { other.stop() }
        #expect(try other.get().hasPrefix("HTTP/1.1 502"), "another address's IP SAN")
    }

    @Test func oneWorkspacesMaterialNeverServesAnother() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        rig.pin(identity: try rig.client())   // A's
        #expect(try rig.get().hasSuffix("kube ok"))
        let b = try rig.get(asB: true)
        #expect(b.hasPrefix("HTTP/1.1 502") && !b.contains("kube ok"), "B dialed with A's CA or certificate: \(b.prefix(300))")
        #expect(rig.proxy.kubeTrust.endpoint(for: rig.ip, port: rig.server.port, profileID: rig.pidB) == nil)
        // B's own (a CA only) doesn't replace A's.
        rig.proxy.kubeTrust.replaceAll(identities: [], cas: [(pem: rig.clusterCA.pem, host: rig.target)], for: rig.pidB)
        #expect(try rig.get().hasSuffix("kube ok"), "A keeps its certificate")
        #expect(rig.proxy.kubeTrust.endpoint(for: rig.ip, port: rig.server.port, profileID: rig.pidB)?.identity == nil)
        rig.proxy.kubeTrust.clearAll(for: rig.pid)
        #expect(rig.proxy.kubeTrust.endpoint(for: rig.ip, port: rig.server.port, profileID: rig.pidB) != nil, "clearing A leaves B's")
    }

    @Test func consentGatedCertificateWithNobodyToAskIsDenied() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        rig.pin(identity: try rig.client(), consent: "kube-test-cred")
        let out = try rig.get()
        #expect(out.hasPrefix("HTTP/1.1 403") && out.contains("client-certificate use denied"), "got: \(out.prefix(300))")
        #expect(rig.server.connections.value == 0, "a denied certificate never dials")
    }

    @Test func badCAKeepsThePreviousAndClearDropsAll() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        let id = try rig.client()
        rig.pin(identity: id)
        #expect(try rig.get().hasSuffix("kube ok"))
        rig.pin(ca: "not a certificate", identity: id)
        #expect(try rig.get().hasSuffix("kube ok"), "an unparsable CA keeps the endpoint's previous one")
        rig.proxy.kubeTrust.clearAll(for: rig.pid)
        #expect(try rig.get().hasPrefix("HTTP/1.1 502"), "the VM's material is gone")
    }

    @Test func aKeyThatIsntTheCertificatesIsLeftOut() throws {
        let ca = try TestCA("t"), (cert, _) = try ca.leaf("a", client: true), (_, other) = try ca.leaf("b", client: true)
        let t = KubeUpstreamTrust()
        let pid = UUID()
        t.replaceAll(identities: [(host: "k.example:6443", certPEM: cert, keyPEM: other, consentCredentialID: nil,
                                   consentDisplayName: nil)],
                     cas: [(pem: ca.pem, host: "k.example:6443")], for: pid)
        let e = t.endpoint(for: "k.example", port: 6443, profileID: pid)
        #expect(e != nil && e?.identity == nil && e?.pinned == true)
        #expect(t.endpoint(for: "k.example", port: 443, profileID: pid) == nil)
        t.replaceAll(identities: [], cas: [(pem: "garbage", host: "new.example")], for: UUID())
        #expect(t.endpoint(for: "new.example", port: 443, profileID: pid) == nil, "a new host whose CA doesn't parse stays unpinned")
    }
}
