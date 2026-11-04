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
            // The Authorization the upstream got, echoed (none: just "kube ok").
            var req = unwrapInboundIn(data)
            let text = req.readString(length: req.readableBytes) ?? ""
            let auth = text.split(separator: "\r\n").first { $0.lowercased().hasPrefix("authorization:") }
                .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
            let body = auth.map { "kube ok auth=\($0)" } ?? "kube ok"
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
    let headers: String
    let tls: NIOSSLContext
    let done: EventLoopPromise<String>
    var buf = ""
    var tunneled = false

    init(target: String, headers: String = "", tls: NIOSSLContext, done: EventLoopPromise<String>) {
        self.target = target; self.headers = headers; self.tls = tls; self.done = done
    }

    static func get(_ listener: String, target: String, proxyCA: NIOSSLCertificate, headers: String = "") throws -> String {
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.trustRoots = .certificates([proxyCA])
        cfg.certificateVerification = .noHostnameVerification
        let ctx = try NIOSSLContext(configuration: cfg)
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let done = loop.makePromise(of: String.self)
        let ch = try ClientBootstrap(group: loop)
            .channelInitializer { $0.pipeline.addHandler(GuestClient(target: target, headers: headers, tls: ctx, done: done)) }
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
            string: "GET /api HTTP/1.1\r\nHost: \(host)\r\n\(headers)\r\n")), promise: nil)
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
    func get(asB: Bool = false, headers: String = "") throws -> String {
        try GuestClient.get(HybridVsockListener.path(uds: dir + (asB ? "/vmb.sock" : "/vm.sock"), port: MitmProxy.vsockPort),
                            target: target, proxyCA: proxy.caNIO, headers: headers)
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
        #expect(out.contains("X-Bromure-Upstream-Error: the TLS certificate for \(rig.ip) is signed by a CA the host running Bromure AC does not trust"), "macOS's reason: \(out.prefix(400))")
    }

    @Test func caWithoutClientCertificateIsRefusedByTheServer() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        rig.pin(identity: nil)
        let out = try rig.get()
        // TLS 1.3: the proxy's side of the handshake completes (the server's
        // certificate chained to the pinned CA), then the server refuses the
        // missing client certificate and the guest's connection just closes.
        // Not the untrusted-CA 502 an unpinned dial gets: the server's
        // refusal, after the proxy trusted it, as a lost or failed handshake.
        #expect(out.hasPrefix("HTTP/1.1 502") && !out.contains("kube ok"), "got: \(out.prefix(300))")
        #expect(!out.contains("signed by a CA the host running Bromure AC does not trust"), "the pinned CA was trusted: \(out.prefix(400))")
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

@Suite("Upstream errors")
struct UpstreamErrorTests {
    @Test func classesAsMacOSGroupsThem() {
        #expect(UpstreamFailure(ProxyDestinationUnresolved(host: "x.invalid", port: 443)) == .unresolved)
        #expect(UpstreamFailure(IOError(errnoCode: ECONNREFUSED, reason: "connect")) == .cannotConnect)
        #expect(UpstreamFailure(IOError(errnoCode: EHOSTUNREACH, reason: "connect")) == .cannotConnect)
        #expect(UpstreamFailure(IOError(errnoCode: ETIMEDOUT, reason: "connect")) == .timedOut)
        #expect(UpstreamFailure(ChannelError.connectTimeout(.seconds(15))) == .timedOut)
        #expect(UpstreamFailure(IOError(errnoCode: ECONNRESET, reason: "read")) == .lost)
        #expect(UpstreamFailure(ChannelError.eof) == .lost)
        #expect(UpstreamFailure(NIOSSLError.uncleanShutdown) == .lost)
        #expect(UpstreamFailure(NIOSSLExtraError.failedToValidateHostname) == .untrusted)
        #expect(UpstreamFailure(NIOSSLError.handshakeFailed(.syscallError)) == .handshake)
        struct Odd: Error {}
        #expect(UpstreamFailure(Odd()) == .other)
        let d = describeUpstreamError(IOError(errnoCode: ECONNREFUSED, reason: "connect"), host: "h.example")
        #expect(d.reason == "the host running Bromure AC could not connect to h.example" && !d.isTrust)
        #expect(!d.body.contains("Errno") && !d.body.contains("connect)"), "no library text: \(d.body)")
    }

    @Test func theGuestNeverSeesLibraryText() throws {
        // A real failed handshake (an untrusted private CA): the 502 names
        // the class, not BoringSSL's error stack or a source path.
        let rig = try KubeRig(); defer { rig.stop() }
        let out = try rig.get()
        #expect(out.hasPrefix("HTTP/1.1 502"))
        for leak in ["BoringSSL", "handshake.cc", ".build", "/home/", "sslError", "NIOSSL"] {
            #expect(!out.contains(leak), "\(leak) in: \(out.prefix(600))")
        }
        #expect(out.contains("trust store"), "the trust advice: \(out.prefix(600))")
    }

    @Test func aRefusedConnectIsSaidSo() throws {
        let rig = try KubeRig(); defer { rig.stop() }
        let port = rig.server.port
        rig.server.stop()   // nothing listens there now
        let out = try GuestClient.get(HybridVsockListener.path(uds: rig.dir + "/vm.sock", port: MitmProxy.vsockPort),
                                      target: "\(rig.ip):\(port)", proxyCA: rig.proxy.caNIO)
        #expect(out.hasPrefix("HTTP/1.1 502")
                && out.contains("X-Bromure-Upstream-Error: the host running Bromure AC could not connect to \(rig.ip)"),
                "got: \(out.prefix(400))")
    }
}

/// A kubeconfig whose user is an exec plugin: the poller runs it on the
/// host and the guest's fake goes out as its token.
@Suite("Kube exec plugins", .serialized)
struct KubeExecPluginTests {
    /// A stand-in plugin: an ExecCredential whose token names its argument
    /// and its run count (counted in `dir/count`).
    static func plugin(in dir: String) throws -> String {
        let path = dir + "/kube-plugin.sh"
        try """
        #!/bin/sh
        n=$(cat \(dir)/count 2>/dev/null || echo 0); n=$((n + 1)); echo $n > \(dir)/count
        printf '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"real-%s-%s"}}' "$1" "$n"
        """.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    static func runs(_ dir: String) -> Int {
        Int((try? String(contentsOfFile: dir + "/count", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// The workspace's kubeconfig step through the daemon's own code: at
    /// launch its plan then the kubeconfig (Daemon.kubeconfig), on a live
    /// refresh the refresh's per-workspace body (Daemon.liveKubeconfig).
    /// The exec contexts in force after it.
    @MainActor
    fileprivate static func install(_ rig: KubeRigHandle, args: [String], live: Bool) async -> (yaml: String, contexts: [KubeconfigMaterializer.ExecContext]) {
        var p = Profile(name: "kt", tool: .claude, authMode: .local)
        p.id = rig.rig.pid
        p.kubeconfigs = [KubeconfigEntry(id: rig.entry, name: "lab", serverURL: "https://\(rig.rig.target)",
                                         namespace: "default",
                                         auth: .execPlugin(command: rig.plugin, args: args, refreshSeconds: 60))]
        let proxy = rig.rig.proxy
        let yaml = live ? await Daemon.liveKubeconfig(for: p, mitm: proxy)
            : await Daemon.kubeconfig(for: p, plan: Daemon.makeSessionTokenPlan(for: p, mitm: proxy), live: false, mitm: proxy)
        return (yaml ?? "", proxy.kubeExecContexts(for: p.id))
    }

    /// The real token in the map for `fake`, once the poller wrote it.
    @MainActor fileprivate static func real(_ rig: KubeRig, _ fake: String, wait: Double = 5) async -> String? {
        let end = Date().addingTimeInterval(wait)
        while Date() < end {
            if let e = rig.proxy.swapper.entries(for: rig.pid).first(where: { $0.fake == fake }), !e.real.isEmpty { return e.real }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test @MainActor func thePluginsTokenGoesOutUnderTheFake() async throws {
        let h = try KubeRigHandle(); defer { h.rig.stop() }
        let mat = await Self.install(h, args: ["a"], live: false)
        let fake = try #require(mat.contexts.first?.fakeToken)
        #expect(mat.yaml.contains("token: \(fake)") && !mat.yaml.contains("real-"), "the guest's kubeconfig has the fake only")
        #expect(await Self.real(h.rig, fake) == "real-a-1", "the poller ran the plugin once, at once")
        let out = try h.rig.get(headers: "Authorization: Bearer \(fake)\r\n")
        #expect(out.hasSuffix("kube ok auth=Bearer real-a-1"), "the upstream got the plugin's token: \(out.suffix(200))")

        // A live refresh (the daemon's refresh path: a cluster came or went)
        // with the plugin unchanged: the same fake, and at once -- not a
        // plugin tick later -- the same real token going out, no second run.
        let again = await Self.install(h, args: ["a"], live: true)
        #expect(again.contexts.first?.fakeToken == fake)
        let right = try h.rig.get(headers: "Authorization: Bearer \(fake)\r\n")
        #expect(right.hasSuffix("auth=Bearer real-a-1"), "the refresh kept the fetched token: \(right.suffix(200))")
        #expect(h.rig.proxy.swapper.entries(for: h.rig.pid).first { $0.fake == fake }?.real == "real-a-1")
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.runs(h.rig.dir) == 1)

        // Its arguments changed: a new fake, the plugin run again.
        let changed = await Self.install(h, args: ["b"], live: true)
        let fakeB = try #require(changed.contexts.first?.fakeToken)
        #expect(fakeB != fake)
        #expect(await Self.real(h.rig, fakeB) == "real-b-2")
        #expect(try h.rig.get(headers: "Authorization: Bearer \(fakeB)\r\n").hasSuffix("auth=Bearer real-b-2"))

        // The VM stops: no poller left for it.
        h.rig.proxy.clearKube(for: h.rig.pid)
        #expect(h.rig.proxy.execPoller.entries(for: h.rig.pid).isEmpty)
        #expect(h.rig.proxy.kubeExecContexts(for: h.rig.pid).isEmpty)
    }

    @Test @MainActor func aFailingPluginNeverSendsARealToken() async throws {
        let h = try KubeRigHandle(failing: true); defer { h.rig.stop() }
        let mat = await Self.install(h, args: ["a"], live: false)
        let fake = try #require(mat.contexts.first?.fakeToken)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await Self.real(h.rig, fake, wait: 0.5) == nil, "no token: the placeholder stays empty")
        let out = try h.rig.get(headers: "Authorization: Bearer \(fake)\r\n")
        #expect(!out.contains("real-"), "got: \(out.suffix(200))")
    }
}

/// A rig (the proxy's own roots, no client certificate: a bearer-token API
/// server) and a plugin for it.
private struct KubeRigHandle {
    let rig: KubeRig
    let plugin: String
    let entry = UUID()
    init(failing: Bool = false) throws {
        rig = try KubeRig(publicRoots: true)
        if failing {
            let path = rig.dir + "/kube-plugin.sh"
            try "#!/bin/sh\necho 'no credentials' >&2\nexit 1\n".write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
            plugin = path
        } else {
            plugin = try KubeExecPluginTests.plugin(in: rig.dir)
        }
    }
}
