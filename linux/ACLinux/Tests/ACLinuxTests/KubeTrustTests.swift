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
    /// The last request it read, as it read it.
    let lastRequest = NIOLockedValueBoxShim("")
    var port: Int { channel.localAddress!.port! }

    /// `clientCA` nil: no client certificate asked for (a public API).
    /// `reply`: sent as it is to every request, instead of "kube ok".
    init(host: String, leaf: (String, String), clientCA: NIOSSLCertificate?, reply: String? = nil) throws {
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(leaf.0.utf8)).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leaf.1.utf8), format: .pem)))
        if let clientCA {
            cfg.certificateVerification = .noHostnameVerification
            cfg.trustRoots = .certificates([clientCA])
        }
        let ctx = try NIOSSLContext(configuration: cfg)
        let counter = connections, last = lastRequest
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                counter.mutate { $0 += 1 }
                return ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandlers([NIOSSLServerHandler(context: ctx),
                                                                Responder(reply: reply, last: last)])
                }
            }
            .bind(host: host, port: 0).wait()
    }

    func stop() { try? channel.close().wait() }

    final class Responder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let reply: String?
        let last: NIOLockedValueBoxShim<String>
        init(reply: String?, last: NIOLockedValueBoxShim<String>) { self.reply = reply; self.last = last }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            // The Authorization the upstream got, echoed (none: just "kube ok").
            var req = unwrapInboundIn(data)
            let text = req.readString(length: req.readableBytes) ?? ""
            last.mutate { $0 = text }
            let auth = text.split(separator: "\r\n").first { $0.lowercased().hasPrefix("authorization:") }
                .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
            let body = auth.map { "kube ok auth=\($0)" } ?? "kube ok"
            let r = reply ?? "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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
    let path: String
    let method: String
    let body: String
    let headers: String
    let tls: NIOSSLContext
    let done: EventLoopPromise<String>
    var buf = ""
    var tunneled = false

    init(target: String, path: String = "/api", method: String = "GET", body: String = "", headers: String = "",
         tls: NIOSSLContext, done: EventLoopPromise<String>) {
        self.target = target; self.path = path; self.method = method; self.body = body
        self.headers = headers; self.tls = tls; self.done = done
    }

    static func get(_ listener: String, target: String, proxyCA: NIOSSLCertificate, path: String = "/api",
                    method: String = "GET", body: String = "", headers: String = "") throws -> String {
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.trustRoots = .certificates([proxyCA])
        cfg.certificateVerification = .noHostnameVerification
        let ctx = try NIOSSLContext(configuration: cfg)
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let done = loop.makePromise(of: String.self)
        let ch = try ClientBootstrap(group: loop)
            .channelInitializer {
                $0.pipeline.addHandler(GuestClient(target: target, path: path, method: method, body: body,
                                                   headers: headers, tls: ctx, done: done))
            }
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
            string: "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n\(headers)"
                + (body.isEmpty ? "" : "Content-Length: \(body.utf8.count)\r\n") + "\r\n\(body)")), promise: nil)
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

/// Calls that issue a credential, through the proxy: the guest gets fakes,
/// the host keeps the real values (macOS: driveTLS's CredentialMint step).
/// The upstream is a local TLS server every connection is routed to,
/// presenting the API's name under a test CA the proxy trusts.
@Suite("Credential minting through the proxy", .serialized)
struct CredentialMintProxyTests {
    fileprivate struct Rig {
        let dir: String, proxy: MitmProxy, listener: MitmListener, server: MTLSServer
        let pid = UUID()
        init(host: String, reply: String) throws {
            guard let ip = Daemon.primaryIPv4() else { throw KubeRig.RigSkip() }
            dir = try shortTempDir()
            let ca = try TestCA("test public CA")
            server = try MTLSServer(host: ip, leaf: try ca.leaf(host, dns: [host], client: false), clientCA: nil, reply: reply)
            proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true), extraRoots: [ca.nio])
            proxy.routeAllTo = (ip, server.port)
            listener = try proxy.serve(udsPath: dir + "/vm.sock", profileID: pid, fdStoreName: "cm-\(pid)")
        }
        func get(_ target: String, path: String) throws -> String {
            try GuestClient.get(HybridVsockListener.path(uds: dir + "/vm.sock", port: MitmProxy.vsockPort),
                                target: target, proxyCA: proxy.caNIO, path: path)
        }
        func request(_ target: String, path: String, method: String = "GET", body: String = "",
                     headers: String) throws -> String {
            try GuestClient.get(HybridVsockListener.path(uds: dir + "/vm.sock", port: MitmProxy.vsockPort),
                                target: target, proxyCA: proxy.caNIO, path: path, method: method, body: body, headers: headers)
        }
        func getWith(_ target: String, path: String, headers: String) throws -> String {
            try GuestClient.get(HybridVsockListener.path(uds: dir + "/vm.sock", port: MitmProxy.vsockPort),
                                target: target, proxyCA: proxy.caNIO, path: path, headers: headers)
        }
        func stop() { server.stop(); listener.stop(); try? FileManager.default.removeItem(atPath: dir) }
    }

    static let real = "dop_v1_" + String(repeating: "5e", count: 32)
    static func chunked(_ body: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n0\r\n\r\n"
    }

    @Test func aRegistryTokenTheVMFetchesReachesItAsAFakeAndIsKept() async throws {
        let auth = Data("\(Self.real):\(Self.real)".utf8).base64EncodedString()
        let rig = try Rig(host: "api.digitalocean.com",
                          reply: Self.chunked(#"{"auths":{"registry.digitalocean.com":{"auth":"\#(auth)"}}}"#))
        defer { rig.stop() }
        let saved = NIOLockedValueBoxShim<[MintedCredential]>([])
        let pid = rig.pid
        rig.proxy.credentialMinter.sink = { p, m in if p == pid { saved.mutate { $0.append(m) } } }

        let out = try rig.get("api.digitalocean.com:443", path: "/v2/registry/docker-credentials")
        #expect(out.hasPrefix("HTTP/1.1 200"), "got \(out.prefix(120))")
        #expect(!out.contains(Self.real) && !out.contains(auth), "the real token never reaches the guest")
        let fake = MintedCredential.bearerFake(for: Self.real, salt: rig.proxy.fakeTokenSalt)
        #expect(out.contains(Data("\(fake):\(fake)".utf8).base64EncodedString()), "the guest's docker config holds the fake")
        #expect(!out.lowercased().contains("transfer-encoding"), "de-chunked, framed by its length")
        #expect(rig.server.lastRequest.value.lowercased().contains("accept-encoding: identity"))
        #expect(saved.value.map(\.secret) == [Self.real] && saved.value.first?.hosts == ["registry.digitalocean.com"],
                "the host keeps it, for the workspace")
        // And the fake goes back out as the real token, to the registry only.
        let push = Data("GET /v2/ HTTP/1.1\r\nHost: registry.digitalocean.com\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8)
        let swapped = await rig.proxy.swapper.swap(rawRequest: push, host: "registry.digitalocean.com", port: 443, profileID: pid)
        #expect(String(decoding: swapped.modified, as: UTF8.self).contains("Bearer \(Self.real)"))
        let elsewhere = await rig.proxy.swapper.swap(rawRequest: push, host: "example.com", port: 443, profileID: pid)
        #expect(!String(decoding: elsewhere.modified, as: UTF8.self).contains(Self.real))
    }

    /// Interim 1xx heads before the final response (URLSession consumes
    /// them on macOS) must not carry the real credential past the rewrite.
    static let interims = ["HTTP/1.1 100 Continue\r\n\r\n",
                           "HTTP/1.1 103 Early Hints\r\nLink: </x.css>; rel=preload\r\n\r\n"]

    @Test func aMintReplyAfterInterimHeadsIsStillRewritten() throws {
        let auth = Data("\(Self.real):\(Self.real)".utf8).base64EncodedString()
        let final = Self.chunked(#"{"auths":{"registry.digitalocean.com":{"auth":"\#(auth)"}}}"#)
        for interim in Self.interims {
            let rig = try Rig(host: "api.digitalocean.com", reply: interim + final)
            defer { rig.stop() }
            let out = try rig.request("api.digitalocean.com:443", path: "/v2/registry/docker-credentials",
                                      headers: "Expect: 100-continue\r\n")
            #expect(!out.contains(Self.real) && !out.contains(auth), "\(interim.prefix(16)): the real token reached the guest")
            let fake = MintedCredential.bearerFake(for: Self.real, salt: rig.proxy.fakeTokenSalt)
            #expect(out.hasPrefix("HTTP/1.1 200") && out.contains(Data("\(fake):\(fake)".utf8).base64EncodedString()),
                    "\(interim.prefix(16)): \(out.prefix(120))")
            #expect(!rig.server.lastRequest.value.lowercased().contains("expect:"), "no Expect upstream")
        }
    }

    /// What follows an interim head must be a head itself.
    @Test func finalResponseSkipsInterimHeadsOnly() {
        let final = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        let f = { (s: String) in HTTPRequestFraming.finalResponse(Data(s.utf8)).map { String(decoding: $0, as: UTF8.self) } }
        #expect(f("HTTP/1.1 100 Continue\r\n\r\n" + final) == final)
        #expect(f("HTTP/1.1 100 Continue\r\n\r\nxyz" + final) == nil, "junk after a 1xx: no final response")
        #expect(f("not http at all") == "not http at all", "no interim head: as it is (the rewrite refuses it)")
        #expect(f("HTTP/1.1 101 Switching Protocols\r\n\r\n") == nil)
        #expect(f("HTTP/1.1 103 Early Hints\r\n\r\n") == nil, "interim heads only")
    }

    @Test func junkAfterAnInterimHeadIsNotPassedOn() throws {
        let auth = Data("\(Self.real):\(Self.real)".utf8).base64EncodedString()
        let final = Self.chunked(#"{"auths":{"registry.digitalocean.com":{"auth":"\#(auth)"}}}"#)
        let rig = try Rig(host: "api.digitalocean.com", reply: "HTTP/1.1 100 Continue\r\n\r\nX" + final)
        defer { rig.stop() }
        let out = try rig.get("api.digitalocean.com:443", path: "/v2/registry/docker-credentials")
        #expect(out.hasPrefix("HTTP/1.1 502") && !out.contains(Self.real) && !out.contains(auth), "\(out.prefix(120))")
    }

    @Test func aMintCallAnsweredWithAProtocolSwitchIsRefused() throws {
        let rig = try Rig(host: "api.digitalocean.com",
                          reply: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n\(Self.real)")
        defer { rig.stop() }
        let out = try rig.request("api.digitalocean.com:443", path: "/v2/registry/docker-credentials",
                                  headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
        #expect(out.hasPrefix("HTTP/1.1 502") && !out.contains(Self.real), "\(out.prefix(120))")
        #expect(!rig.server.lastRequest.value.lowercased().contains("upgrade:"), "no Upgrade upstream")
    }

    /// A sign-in's token exchange the host captures: the same 1xx hole.
    @Test func aSignInExchangeAfterInterimHeadsIsStillCaptured() throws {
        let tokens = #"{"access_token":"REAL-ACCESS","refresh_token":"REAL-REFRESH"}"#
        let final = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(tokens.utf8.count)\r\n\r\n" + tokens
        for (reply, expectKept) in [(Self.interims[0] + final, true), (Self.interims[1] + final, true),
                                    ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n" + tokens, false)] {
            let rig = try Rig(host: "auth.openai.com", reply: reply)
            defer { rig.stop() }
            let kept = SignInCapture.response(status: 200, reason: "OK", json: ["kept": "on the host"])
            rig.proxy.captures.arm(SignInCapture(profileID: rig.pid, hosts: ["auth.openai.com"], pathPrefix: "/oauth/token",
                                                 handle: { status, body in
                status == 200 && String(decoding: body, as: UTF8.self).contains("REAL-ACCESS") ? kept : nil
            }))
            let out = try rig.request("auth.openai.com:443", path: "/oauth/token", method: "POST", body: "grant_type=authorization_code&code=c",
                                   headers: "Expect: 100-continue\r\nContent-Type: application/x-www-form-urlencoded\r\n")
            #expect(!out.contains("REAL-ACCESS") && !out.contains("REAL-REFRESH"), "\(reply.prefix(16)): real tokens reached the guest")
            #expect(expectKept ? out.contains("on the host") : out.contains("bromure_not_kept"), "\(reply.prefix(16)): \(out.prefix(140))")
        }
    }

    @Test func aCallThatIssuesAnUnswappableCredentialIsRefusedBeforeItGoesOut() throws {
        let rig = try Rig(host: "iam.amazonaws.com", reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nno")
        defer { rig.stop() }
        let out = try rig.get("iam.amazonaws.com:443", path: "/?Action=CreateLoginProfile&UserName=a&Password=b")
        #expect(out.hasPrefix("HTTP/1.1 403"), "got \(out.prefix(120))")
        #expect(out.contains("iam:CreateLoginProfile"))
        #expect(rig.server.connections.value == 0, "nothing reached the upstream")
    }

    @Test func aReplyStillCompressedIsNotPassedOn() throws {
        let rig = try Rig(host: "api.digitalocean.com",
                          reply: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 8\r\nConnection: close\r\n\r\n\u{1f}\u{8b}xxxxxx")
        defer { rig.stop() }
        let out = try rig.get("api.digitalocean.com:443", path: "/v2/registry/docker-credentials")
        #expect(out.hasPrefix("HTTP/1.1 502"), "got \(out.prefix(120))")
        #expect(out.contains("creates a credential"))
    }

    /// What the proxy mints is saved with the workspace, expired ones past
    /// retention dropped. (No secret here: the store puts secrets in the
    /// process-wide vault, which another suite reconfigures; the VM e2e
    /// shows the secret kept across a restart.)
    @Test @MainActor func aMintedCredentialIsSavedWithItsWorkspace() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ProfileStore(rootDir: URL(fileURLWithPath: dir, isDirectory: true))
        var p = try store.save(Profile(name: "minted", tool: .claude, authMode: .token))
        p.mintedCredentials = [MintedCredential(kind: .bearer, source: "old", hosts: ["a.example"], secret: "",
                                                createdAt: Date(timeIntervalSinceNow: -400 * 86400),
                                                expiresAt: Date(timeIntervalSinceNow: -365 * 86400))]
        _ = try store.update(p)
        let m = MintedCredential(kind: .bearer, source: "DigitalOcean registry token",
                                 hosts: ["registry.digitalocean.com"], secret: "", createdAt: Date())
        Daemon.saveMintedCredential(m, profileID: p.id, store: store)
        let back = try #require(ProfileStore(rootDir: URL(fileURLWithPath: dir, isDirectory: true)).loadAll().first { $0.id == p.id })
        #expect(back.mintedCredentials.map(\.source) == ["DigitalOcean registry token"], "the long-expired one pruned")
        #expect(back.mintedCredentials.first?.hosts == ["registry.digitalocean.com"])
        #expect(!FileManager.default.fileExists(atPath: dir + "/\(p.id.uuidString)/secrets.enc"), "the vault untouched")
        Daemon.saveMintedCredential(m, profileID: UUID(), store: store)     // an unknown workspace: nothing
        #expect(store.loadAll().count == 1)
    }

    /// A credential minted in an earlier boot is in the next one's swap map
    /// (macOS's launch and restage add MintedCredential.tokenEntries).
    @Test func aCredentialMintedEarlierIsSwappedAfterAReboot() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        var p = Profile(name: "minted", tool: .claude, authMode: .token)
        p.mintedCredentials = [MintedCredential(kind: .bearer, source: "DigitalOcean registry token",
                                                hosts: ["registry.digitalocean.com"], secret: Self.real, createdAt: Date())]
        _ = await Daemon.kubeconfig(for: p, plan: Daemon.makeSessionTokenPlan(for: p, mitm: proxy), live: false, mitm: proxy)
        let fake = MintedCredential.bearerFake(for: Self.real, salt: proxy.fakeTokenSalt)
        #expect(proxy.swapper.entries(for: p.id).contains { $0.fake == fake && $0.real == Self.real && $0.host == "registry.digitalocean.com" })
    }
}

/// AWS on a Linux server: the guest's credential_process helper gets the
/// workspace's key id and a fake secret over vsock 8445, and the proxy
/// re-signs its SigV4 requests with the real one (macOS: MitmEngine's
/// AWSCredentialServer, AWSCredsListenerDelegate and AWSResigner).
@Suite("AWS credentials and re-signing", .serialized)
struct AWSProxyTests {
    static let akid = "AKIAIOSFODNN7EXAMPLE"
    static let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    /// The guest's side of Firecracker's hybrid vsock: a connection to
    /// `<v.sock>_8445`, read to EOF.
    static func readHelper(_ path: String) -> String? {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in let b = Array(path.utf8); p.copyBytes(from: b); p[b.count] = 0 }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
        return String(decoding: out, as: UTF8.self)
    }

    @Test func theHelperGetsTheKeyIdAndAFakeSecretOverVsock() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = AWSCredentialServer(consent: ConsentBroker())
        let pid = UUID()
        server.setCredentials(AWSCredentials(accessKeyID: Self.akid, secretAccessKey: Self.secret, region: "us-east-1"), for: pid)
        let l = try VsockFDListener.awsCreds(udsPath: dir + "/v.sock", fdStoreName: "aws-test", stored: nil, profileID: pid, server: server)
        defer { FDStore.remove("aws-test") }
        let json = try #require(Self.readHelper(dir + "/v.sock_8445"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["Version"] as? Int == 1 && obj["AccessKeyId"] as? String == Self.akid)
        #expect((obj["SecretAccessKey"] as? String)?.isEmpty == false && !json.contains(Self.secret), "never the real secret")
        #expect(Self.readHelper(dir + "/v.sock_8445") != nil, "each run of the helper is answered")
        l.stop()
        usleep(100_000)
        #expect(Self.readHelper(dir + "/v.sock_8445") == nil, "stopped: nothing listens")
        #expect(!FileManager.default.fileExists(atPath: dir + "/v.sock_8445"))
    }

    static let guestAuth = "AWS4-HMAC-SHA256 Credential=\(akid)/20261105/us-east-1/sts/aws4_request, "
        + "SignedHeaders=host;x-amz-date, Signature=" + String(repeating: "0", count: 64)
    static let headers = "Authorization: \(guestAuth)\r\nX-Amz-Date: 20261105T120000Z\r\n"

    @Test func aSigV4RequestGoesOutReSignedWithTheRealKey() throws {
        let rig = try CredentialMintProxyTests.Rig(host: "sts.amazonaws.com",
                                                   reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        defer { rig.stop() }
        rig.proxy.awsCreds.setCredentials(AWSCredentials(accessKeyID: Self.akid, secretAccessKey: Self.secret,
                                                         region: "us-east-1"), for: rig.pid)
        let out = try rig.getWith("sts.amazonaws.com:443", path: "/?Action=GetCallerIdentity&Version=2011-06-15", headers: Self.headers)
        #expect(out.hasPrefix("HTTP/1.1 200"), "got \(out.prefix(160))")
        let up = rig.server.lastRequest.value
        let auth = up.split(separator: "\r\n").first { $0.lowercased().hasPrefix("authorization:") }.map(String.init) ?? ""
        #expect(auth.contains("Credential=\(Self.akid)/"), "signed as the workspace's key: \(auth)")
        #expect(!auth.contains(String(repeating: "0", count: 64)), "with a signature the host computed, not the guest's")
        #expect(!up.contains(Self.secret))
        // Framed as URLSession frames it on macOS (the resigner leaves these to it).
        let head = up.components(separatedBy: "\r\n\r\n")[0].lowercased().components(separatedBy: "\r\n")
        #expect(head.filter { $0.hasPrefix("host:") } == ["host: sts.amazonaws.com"], "one Host, the signed name: \(head)")
        #expect(head.contains("content-length: 0") && head.contains("connection: close"))
        // A guest's Expect: 100-continue isn't carried into the re-signed request.
        _ = try rig.getWith("sts.amazonaws.com:443", path: "/?Action=GetCallerIdentity&Version=2011-06-15",
                            headers: Self.headers + "Expect: 100-continue\r\n")
        #expect(!rig.server.lastRequest.value.lowercased().contains("expect:"))
    }

    /// As on macOS: a workspace with no AWS keys at all gets its request
    /// through as it signed it (AWS answers InvalidClientTokenId, which says
    /// more than a refusal here); nothing real was in it.
    @Test func withoutKeysForTheWorkspaceTheRequestGoesAsTheGuestSignedIt() throws {
        let rig = try CredentialMintProxyTests.Rig(host: "sts.amazonaws.com",
                                                   reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        defer { rig.stop() }
        _ = try rig.getWith("sts.amazonaws.com:443", path: "/?Action=GetCallerIdentity&Version=2011-06-15", headers: Self.headers)
        #expect(rig.server.lastRequest.value.contains(Self.guestAuth), "unchanged")
    }

    /// A key the VM minted (STS) is the credential server's again whenever
    /// the map is installed -- a launch, a live refresh, a restarted daemon's
    /// taken-back workspace -- so it's re-signed with its own secret, not
    /// the workspace's base keys, and refused once expired.
    @Test func aMintedKeyIsRegisteredWithTheMap() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        var p = Profile(name: "minted-aws", tool: .claude, authMode: .token)
        p.mintedCredentials = [
            MintedCredential(kind: .sigV4, source: "sts:AssumeRole", hosts: ["sts.amazonaws.com"],
                             accessKeyID: "ASIAMINTEDLIVE000001", secret: "minted-secret", sessionToken: "tok",
                             expiresAt: Date().addingTimeInterval(3600)),
            MintedCredential(kind: .sigV4, source: "sts:GetSessionToken", hosts: ["sts.amazonaws.com"],
                             accessKeyID: "ASIAMINTEDGONE000002", secret: "old", sessionToken: "tok",
                             expiresAt: Date().addingTimeInterval(-60)),
        ]
        if case .none = proxy.awsCreds.minted(accessKeyID: "ASIAMINTEDLIVE000001", host: "sts.amazonaws.com", profileID: p.id) {} else {
            Issue.record("registered before any map")
        }
        _ = await Daemon.liveKubeconfig(for: p, mitm: proxy)          // what start's refresh runs per workspace
        guard case .material(let c, _) = proxy.awsCreds.minted(accessKeyID: "ASIAMINTEDLIVE000001", host: "sts.amazonaws.com",
                                                                 profileID: p.id) else {
            Issue.record("the live minted key isn't registered"); return
        }
        #expect(c.secretAccessKey == "minted-secret")
        if case .expired = proxy.awsCreds.minted(accessKeyID: "ASIAMINTEDGONE000002", host: "sts.amazonaws.com", profileID: p.id) {} else {
            Issue.record("an expired minted key must answer expired (a 403), not fall back to the base keys")
        }
    }

    /// A malformed SigV4 header is answered here, not sent.
    @Test func aMalformedSignatureIsAnsweredBeforeItGoesOut() throws {
        let rig = try CredentialMintProxyTests.Rig(host: "sts.amazonaws.com",
                                                   reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        defer { rig.stop() }
        rig.proxy.awsCreds.setCredentials(AWSCredentials(accessKeyID: Self.akid, secretAccessKey: Self.secret,
                                                         region: "us-east-1"), for: rig.pid)
        let out = try rig.getWith("sts.amazonaws.com:443", path: "/", headers: "Authorization: AWS4-HMAC-SHA256 nonsense\r\n")
        #expect(out.hasPrefix("HTTP/1.1 502"), "got \(out.prefix(160))")
        #expect(rig.server.connections.value == 0)
    }
}

/// A credential whose value is a 1Password `op://` reference: resolved on
/// the host under the plan's stable fake (macOS: MitmEngine.opRefresher,
/// started at launch and restage). `op read` stands in through the
/// refresher's own test seam.
@Suite("1Password references on the host", .serialized)
@MainActor
struct OnePasswordRefreshTests {
    @Test func aReferenceIsResolvedOnTheHostUnderTheGuestsFake() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let reads = NIOLockedValueBoxShim<[String]>([])
        proxy.opRefresher = OnePasswordRefresher(read: { ref in reads.mutate { $0.append(ref) }; return "sk_live_resolved\n" })
        var p = Profile(name: "op", tool: .claude, authMode: .token)
        p.manualTokens = [ManualToken(name: "stripe", realValue: "op://vault/stripe/credential",
                                      envVarName: "STRIPE_API_KEY", hostFilters: ["api.stripe.com"])]
        let plan = Daemon.makeSessionTokenPlan(for: p, mitm: proxy)
        let planned = try #require(plan.tokenMap().entries.first { $0.host == "api.stripe.com" })
        _ = await Daemon.kubeconfig(for: p, plan: plan, live: false, mitm: proxy)
        for _ in 0..<150 where !proxy.swapper.entries(for: p.id).contains(where: { $0.real == "sk_live_resolved" }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let installed = proxy.swapper.entries(for: p.id).filter { $0.host == "api.stripe.com" }
        #expect(installed.contains { $0.real == "sk_live_resolved" && $0.fake == planned.fake },
                "resolved (newline trimmed) under the fake the guest holds: \(installed.map(\.real))")
        #expect(!installed.contains { $0.real.contains("op://") }, "the reference never goes out as the credential")
        #expect(reads.value == ["op://vault/stripe/credential"], "op read once, now (then every 120 s)")
        proxy.clearKube(for: p.id)
    }

    @Test func aWorkspaceWithoutReferencesNeverRunsOp() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let reads = NIOLockedValueBoxShim(0)
        proxy.opRefresher = OnePasswordRefresher(read: { _ in reads.mutate { $0 += 1 }; return "x" })
        var p = Profile(name: "plain", tool: .claude, authMode: .token)
        p.manualTokens = [ManualToken(name: "t", realValue: "plain-secret", envVarName: "T", hostFilters: ["api.example.com"])]
        _ = await Daemon.kubeconfig(for: p, plan: Daemon.makeSessionTokenPlan(for: p, mitm: proxy), live: false, mitm: proxy)
        try await Task.sleep(for: .milliseconds(200))
        #expect(reads.value == 0)
        #expect(proxy.swapper.entries(for: p.id).contains { $0.real == "plain-secret" })
    }
}

/// api_key.env, macOS's builder shared: the plan's fakes under their env
/// vars, never a real value.
@Suite("Guest credential environment")
struct GuestEnvTests {
    /// Through the daemon's writer: the shared lines, always cooperative
    /// (no transparent interception on Linux), the VM subnet and the
    /// cluster addresses off the proxy, the registries for dockerd.
    @Test func theDaemonWritesAWorkspacesProxyEnv() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let meta = URL(fileURLWithPath: dir + "/meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        var p = Profile(name: "strict", tool: .claude, authMode: .token)
        p.strictSandbox = true
        p.environmentVariables = [EnvironmentVariable(name: "MY_FLAG", value: "on")]
        try await d.writeProxyMeta(meta, profile: p, tokenPlan: nil, extraNoProxy: ["192.168.64.7"],
                                   registries: ["192.168.64.9:5000"])
        let env = try String(contentsOf: meta.appendingPathComponent("proxy.env"), encoding: .utf8)
        #expect(env.contains("export HTTPS_PROXY=http://127.0.0.1:\(Daemon.guestProxyPort)"), "always cooperative")
        #expect(env.contains("192.168.64.0/24") && env.contains("192.168.64.7"))
        #expect(env.contains("export MY_FLAG='on'") && env.contains("export BROMURE_REGISTRY='192.168.64.9:5000'"))
        #expect(try String(contentsOf: meta.appendingPathComponent("docker-registries.txt"), encoding: .utf8) == "192.168.64.9:5000\n")
        await d.shutdown()
    }

    @Test func manualTokensAndAPIKeysAreExportedAsFakes() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        var p = Profile(name: "env", tool: .claude, authMode: .token)
        p.apiKey = "sk-ant-api03-REAL-KEY-not-for-the-guest"
        p.manualTokens = [ManualToken(name: "stripe", realValue: "sk_live_REAL", envVarName: "STRIPE_API_KEY",
                                      hostFilters: ["api.stripe.com"])]
        let plan = Daemon.makeSessionTokenPlan(for: p, mitm: proxy)
        let text = SessionDisk.apiKeyEnvLines(profile: p, tokenPlan: plan, registrationMode: false).joined(separator: "\n")
        let stripeFake = try #require(plan.manualEnvExports.first { $0.0 == "STRIPE_API_KEY" }?.1)
        #expect(text.contains("export STRIPE_API_KEY='\(stripeFake)'"))
        #expect(text.contains("export ANTHROPIC_API_KEY='\(plan.fakeForAnthropic() ?? "")'"))
        #expect(!text.contains("REAL"), "no real value: \(text)")
        #expect(text.contains("export BROMURE_AC_TOOL=claude"))
    }
}

/// The SSH agent on a Linux server (macOS's SSHAgentServer, shared): the
/// guest's /tmp/bromure-agent.sock reaches it over vsock 8444; the
/// workspace's key is listed and signs, and its seed never leaves the host.
@Suite("SSH agent over vsock", .serialized)
struct SSHAgentVsockTests {
    /// One agent request over the guest's side of hybrid vsock; the reply's body.
    static func roundTrip(_ path: String, _ msg: Data) -> Data? {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in let b = Array(path.utf8); p.copyBytes(from: b); p[b.count] = 0 }
        guard withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }) == 0 else { return nil }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let framed = u32(UInt32(msg.count)) + msg
        guard framed.withUnsafeBytes({ write(fd, $0.baseAddress, framed.count) }) == framed.count else { return nil }
        var head = [UInt8](repeating: 0, count: 4)
        guard read(fd, &head, 4) == 4 else { return nil }
        let n = Int(head[0]) << 24 | Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
        var body = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while body.count < n { let r = read(fd, &buf, min(buf.count, n - body.count)); if r <= 0 { break }; body.append(contentsOf: buf[0..<r]) }
        return body.count == n ? body : nil
    }
    static func u32(_ v: UInt32) -> Data { Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    static func str(_ d: Data) -> Data { u32(UInt32(d.count)) + d }
    static func take(_ d: Data, _ i: inout Int) -> Data {
        let n = Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]); i += 4
        defer { i += n }; return d.subdata(in: i..<(i + n))
    }

    @Test func theWorkspacesKeyIsListedAndSignsOverVsock() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let agent = SSHAgentServer(consent: ConsentBroker())
        let key = Curve25519.Signing.PrivateKey()
        let pid = UUID(), other = UUID()
        let ak = AgentKey(comment: "bromure-ac", publicKey: key.publicKey.rawRepresentation, seed: key.rawRepresentation,
                          requireApproval: false, consentCredentialID: nil)
        agent.setKeys([ak], for: pid)
        agent.setKeys([AgentKey(comment: "someone else", publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                                seed: Data(count: 32), requireApproval: false, consentCredentialID: nil)], for: other)
        let l = try VsockFDListener.sshAgent(udsPath: dir + "/v.sock", fdStoreName: "ssh-test", stored: nil, profileID: pid, agent: agent)
        defer { l.stop(); FDStore.remove("ssh-test") }
        let path = dir + "/v.sock_8444"

        let ids = try #require(Self.roundTrip(path, Data([11])))          // REQUEST_IDENTITIES
        #expect(ids.first == 12, "IDENTITIES_ANSWER")
        var i = 1
        let count = Int(ids[i]) << 24 | Int(ids[i + 1]) << 16 | Int(ids[i + 2]) << 8 | Int(ids[i + 3]); i += 4
        #expect(count == 1, "only this workspace's key")
        let blob = Self.take(ids, &i)
        #expect(blob == ak.publicKeyBlob)

        let data = Data("challenge-\(UUID())".utf8)
        let resp = try #require(Self.roundTrip(path, Data([13]) + Self.str(blob) + Self.str(data) + Self.u32(0)))
        #expect(resp.first == 14, "SIGN_RESPONSE")
        var j = 1
        let sigBlob = Self.take(resp, &j)
        var k = 0
        #expect(Self.take(sigBlob, &k) == Data("ssh-ed25519".utf8))
        let sig = Self.take(sigBlob, &k)
        #expect(key.publicKey.isValidSignature(sig, for: data), "signed with the workspace's key")
    }

    @Test func aWorkspacesKeyFileIsLoaded() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ProfileStore(rootDir: URL(fileURLWithPath: dir, isDirectory: true))
        let p = try store.save(Profile(name: "ssh", tool: .claude, authMode: .token))
        #expect(Daemon.loadAgentKeys(for: p, store: store).isEmpty, "no key: none")
        let key = Curve25519.Signing.PrivateKey()
        let agentDir = store.profileDirectory(for: p).appendingPathComponent("agent", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        try (key.rawRepresentation + key.publicKey.rawRepresentation).write(to: agentDir.appendingPathComponent("id_ed25519.raw"))
        let keys = Daemon.loadAgentKeys(for: p, store: store)
        #expect(keys.count == 1 && keys.first?.publicKey == key.publicKey.rawRepresentation && keys.first?.seed == key.rawRepresentation)
        try Data(count: 10).write(to: agentDir.appendingPathComponent("id_ed25519.raw"))
        #expect(Daemon.loadAgentKeys(for: p, store: store).isEmpty, "malformed: none")
    }
}
