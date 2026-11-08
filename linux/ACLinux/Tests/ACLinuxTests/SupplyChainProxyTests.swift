import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing
@testable import ACLinux
import SandboxEngine

extension DaemonGlobalSuites {
/// The supply-chain policy on the Linux proxy (macOS: driveTLS's
/// supply-chain block), through a RequestReader to a local stand-in for the
/// npm registry (the name pinned, never looked up or dialed). OSV,
/// socket.dev and PyPI stay off: no test reaches a real host. In the
/// serialized parent: the consent tests set ConsentPrompt.chooseForTesting.
@Suite("Supply chain on the proxy", .serialized)
struct SupplyChainProxyTests {
    /// A guest socket on a RequestReader for `host` (plain HTTP).
    final class Guest {
        let fd: Int32
        let channel: Channel
        init(proxy: MitmProxy, pid: UUID, host: String) async throws {
            var sv: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sv) == 0 else { throw POSIXError(.EIO) }
            fd = sv[0]
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let pinned = [OpenShellPolicy.IPAddress("203.0.113.9")!]
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { $0.pipeline.addHandler(RequestReader(proxy: proxy, profileID: pid, host: host,
                                                                          port: 80, tls: false, pinned: pinned)) }
                .withConnectedSocket(sv[1]).get()
        }
        func send(_ s: String) { _ = s.utf8CString.withUnsafeBufferPointer { Glibc.send(fd, $0.baseAddress, $0.count - 1, Int32(MSG_NOSIGNAL)) } }
        /// Everything until the proxy closes.
        func readAll() -> Data {
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            return out
        }
        func close() { channel.close(promise: nil); Glibc.close(fd) }
    }

    /// A registry stand-in: records each request, answers `reply(path)`
    /// (`pauseAfter`: that many bytes, then the rest 300 ms later).
    final class Registry: @unchecked Sendable {
        let requests = NIOLockedValueBox<[String]>([])
        let channel: Channel
        var port: Int { channel.localAddress!.port! }
        init(host: String, pauseAfter: Int? = nil, reply: @escaping @Sendable (String) -> Data) throws {
            let requests = self.requests
            channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { $0.pipeline.addHandler(Handler(requests, reply, pauseAfter: pauseAfter)) }
                .bind(host: host, port: 0).wait()
        }
        func stop() { channel.close(promise: nil) }
        final class Handler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer
            let requests: NIOLockedValueBox<[String]>
            let reply: @Sendable (String) -> Data
            let pauseAfter: Int?
            var buf = ""
            init(_ r: NIOLockedValueBox<[String]>, _ reply: @escaping @Sendable (String) -> Data, pauseAfter: Int? = nil) {
                requests = r; self.reply = reply; self.pauseAfter = pauseAfter
            }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var b = unwrapInboundIn(data)
                buf += b.readString(length: b.readableBytes) ?? ""
                guard buf.contains("\r\n\r\n") else { return }
                requests.withLockedValue { $0.append(buf) }
                let path = buf.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let data = reply(path)
                if let n = pauseAfter, n < data.count {
                    context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: data.prefix(n))), promise: nil)
                    context.eventLoop.scheduleTask(in: .milliseconds(300)) {
                        context.writeAndFlush(self.wrapOutboundOut(context.channel.allocator.buffer(bytes: data.dropFirst(n))))
                            .whenComplete { _ in context.close(promise: nil) }
                    }
                    return
                }
                context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: data)))
                    .whenComplete { _ in context.close(promise: nil) }
            }
        }
    }

    static func response(_ body: Data, type: String) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }

    /// demo: 1.0.0 (2020) and 2.0.0 (published just now).
    static func packument() -> Data {
        let now = ISO8601DateFormatter().string(from: Date())
        return try! JSONSerialization.data(withJSONObject: [
            "name": "demo", "dist-tags": ["latest": "2.0.0"],
            "versions": [
                "1.0.0": ["name": "demo", "version": "1.0.0",
                          "dist": ["integrity": "sha512-OLD", "tarball": "https://registry.npmjs.org/demo/-/demo-1.0.0.tgz"]],
                "2.0.0": ["name": "demo", "version": "2.0.0",
                          "dist": ["integrity": "sha512-NEW", "tarball": "https://registry.npmjs.org/demo/-/demo-2.0.0.tgz"]],
            ],
            "time": ["created": "2020-01-01T00:00:00.000Z", "modified": now,
                     "1.0.0": "2020-01-01T00:00:00.000Z", "2.0.0": now],
        ])
    }

    static func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/npm-postinstall-fixture.tgz"))
    }

    static func body(_ r: Data) -> Data { r.range(of: Data("\r\n\r\n".utf8)).map { Data(r[$0.upperBound...]) } ?? Data() }

    /// A proxy whose workspace has `policy`, its routes to `registry`.
    static func setUp(_ policy: SupplyChainPolicy, pauseAfter: Int? = nil, reply: @escaping @Sendable (String) -> Data) throws
        -> (MitmProxy, UUID, Registry, String) {
        let dir = try shortTempDir()
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        proxy.setSupplyChainPolicy(policy, for: pid)
        let ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always refused)")
        let registry = try Registry(host: ip, pauseAfter: pauseAfter, reply: reply)
        proxy.routeAllTo = (ip, registry.port)
        return (proxy, pid, registry, dir)
    }

    /// The age gate on a packument: npm's abbreviated one is asked for in
    /// full (it carries publish times), uncompressed, and the version
    /// published just now is gone from what the guest resolves against.
    @Test func aPackumentLosesItsTooFreshVersion() async throws {
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: true, ageGateDays: 2)) { _ in
            Self.response(Self.packument(), type: "application/json")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo HTTP/1.1\r\nHost: registry.npmjs.org\r\nAccept: application/vnd.npm.install-v1+json\r\nAccept-Encoding: gzip\r\n\r\n")
        let reply = g.readAll()
        let seen = registry.requests.withLockedValue { $0 }.first?.lowercased() ?? ""
        #expect(seen.contains("accept: application/json") && seen.contains("accept-encoding: identity"), "\(seen)")
        let doc = try #require(try? JSONSerialization.jsonObject(with: Self.body(reply)) as? [String: Any],
                               "\(String(decoding: reply.prefix(300), as: UTF8.self))")
        let versions = (doc["versions"] as? [String: Any]).map { Array($0.keys) } ?? []
        #expect(versions == ["1.0.0"], "\(versions)")
    }

    /// The publish-time backstop: a tarball of a version too fresh is
    /// refused (451) before anything goes upstream.
    @Test func aTooFreshTarballIsRefusedBeforeItsFetched() async throws {
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: true, ageGateDays: 2)) { _ in
            Self.response(Data("tarball".utf8), type: "application/octet-stream")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        await proxy.publishTimeCache.record(ecosystem: "npm", name: "demo", versions: [("2.0.0", Date())])
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo/-/demo-2.0.0.tgz HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n")
        let reply = String(decoding: g.readAll(), as: UTF8.self)
        #expect(reply.hasPrefix("HTTP/1.1 451 ") && reply.contains("policy requires 2 days"), "\(reply.prefix(300))")
        #expect(registry.requests.withLockedValue { $0 }.isEmpty, "nothing went upstream")
    }

    /// The script strip: a real tarball's postinstall is gone from what the
    /// guest gets, and it's still a valid archive.
    @Test func aTarballLosesItsInstallScripts() async throws {
        let tgz = try Self.fixture()
        #expect(NPMRegistryTransforms.inspectTarball(rawResponse: Self.response(tgz, type: "application/octet-stream")).result == .stripped)
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: false, stripInstallScripts: true)) { _ in
            Self.response(tgz, type: "application/octet-stream")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo/-/demo-1.0.0.tgz HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n")
        let reply = g.readAll()
        #expect(String(decoding: reply.prefix(15), as: UTF8.self) == "HTTP/1.1 200 OK")
        #expect(NPMRegistryTransforms.inspectTarball(rawResponse: reply).result == .noScripts, "stripped: no install scripts left")
    }

    /// npm ci's bypass prompt: nobody can answer on this host, so the
    /// lockfile-pinned install is refused, before it goes upstream.
    @Test func npmCiIsRefusedWhenNobodyCanAllowIt() async throws {
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: false, lockfilePrompt: true)) { _ in
            Self.response(Data("tarball".utf8), type: "application/octet-stream")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo/-/demo-1.0.0.tgz HTTP/1.1\r\nHost: registry.npmjs.org\r\nnpm-command: ci\r\n\r\n")
        let reply = String(decoding: g.readAll(), as: UTF8.self)
        #expect(reply.hasPrefix("HTTP/1.1 451 ") && reply.contains("lockfile-pinned"), "\(reply.prefix(300))")
        #expect(registry.requests.withLockedValue { $0 }.isEmpty)
    }

    /// A reply read whole is passed to the rewrite only when it's whole: cut
    /// short of its length or its last chunk, or read up to an unclean
    /// close, it's refused (as URLSession throws on macOS).
    @Test func onlyAWholeReplyIsRewritten() {
        let ok = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let plain = Self.whole(RequestReader.supplyChainPlain(ok, cleanClose: false)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(plain.hasSuffix("\r\n\r\n{}") && plain.contains("Content-Length: 2") && plain.contains("Connection: close"), "\(plain)")
        #expect(RequestReader.supplyChainPlain(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}".utf8), cleanClose: true) == nil)
        #expect(RequestReader.supplyChainPlain(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n".utf8), cleanClose: true) == nil)
        let untilClose = Data("HTTP/1.1 200 OK\r\n\r\n{}".utf8)
        #expect(RequestReader.supplyChainPlain(untilClose, cleanClose: false) == nil)
        #expect(RequestReader.supplyChainPlain(untilClose, cleanClose: true) != nil)
        #expect(RequestReader.supplyChainPlain(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n".utf8), cleanClose: true) == nil)
        #expect(RequestReader.supplyChainPlain(Data("HTTP/1.1 200 OK\r\nContent-Length: 2, 3\r\n\r\n{}x".utf8), cleanClose: true) == nil)
    }

    static func whole(_ r: RequestReader.SupplyChainReply?) -> Data? {
        if case .whole(let d)? = r { return d }
        return nil
    }

    /// A reply without a body (HEAD's, 204, 304) goes on as it is, and an
    /// empty body with a coding is just empty: never a 502.
    @Test func aBodilessReplyGoesThrough() throws {
        let notModified = Data("HTTP/1.1 304 Not Modified\r\nETag: x\r\n\r\n".utf8)
        guard case .bodiless(let r)? = RequestReader.supplyChainPlain(notModified, cleanClose: false) else {
            Issue.record("304 not passed through"); return
        }
        #expect(String(decoding: r, as: UTF8.self).hasPrefix("HTTP/1.1 304 "))
        let head = Data("HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n".utf8)
        guard case .bodiless(let h)? = RequestReader.supplyChainPlain(head, cleanClose: false, head: true) else {
            Issue.record("HEAD's reply not passed through"); return
        }
        #expect(String(decoding: h, as: UTF8.self).contains("Content-Length: 1234"))
        let empty = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n".utf8)
        let e = String(decoding: try #require(Self.whole(RequestReader.supplyChainPlain(empty, cleanClose: true))), as: UTF8.self)
        #expect(e.contains("Content-Length: 0") && !e.lowercased().contains("content-encoding"), "\(e)")
    }

    /// With the daemon's budget full, a reply waits for room instead of a
    /// 502 (npm fetches many packuments at once).
    @Test func aFullBudgetMakesAReplyWaitNotFail() async throws {
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: true, ageGateDays: 2)) { _ in
            Self.response(Self.packument(), type: "application/json")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let budget = ResponseRelay.supplyChainBudget, holder = budget.ticket()
        let taken = budget.limit - budget.total
        #expect(budget.reserve(taken, for: holder), "the whole budget held, by an older holder")
        let release = Task { try await Task.sleep(for: .milliseconds(400)); budget.finish(holder) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n")
        let reply = g.readAll()
        _ = try await release.value
        #expect(String(decoding: reply.prefix(15), as: UTF8.self) == "HTTP/1.1 200 OK", "\(String(decoding: reply.prefix(200), as: UTF8.self))")
        #expect(budget.total == 0, "everything given back")
    }

    /// Every Content-Encoding line counts: gzip then identity is gzip.
    @Test func everyCodingLineCounts() throws {
        let gz = try #require(Data(base64Encoded: "H4sIAAAAAAAAA6tWykvMTVWyUkpJzc1X0lGqULIyrOUCAF+WXL0WAAAA"))
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Encoding: identity\r\nContent-Length: \(gz.count)\r\n\r\n".utf8) + gz
        let plain = try #require(Self.whole(RequestReader.supplyChainPlain(raw, cleanClose: true)))
        let text = String(decoding: plain, as: UTF8.self)
        #expect(!text.lowercased().contains("content-encoding") && text.contains("\"name\""), "\(text)")
    }

    /// The upstream gone mid-body: the guest gets a 502, never a cut packument
    /// passed off as whole.
    @Test func aCutReplyIsA502() async throws {
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: true)) { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4000\r\n\r\n{\"name\":\"demo\"".utf8)
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n")
        let reply = String(decoding: g.readAll(), as: UTF8.self)
        #expect(reply.hasPrefix("HTTP/1.1 502 "), "\(reply.prefix(300))")
    }

    /// The fetch event goes once, when the rewrite is released, whichever
    /// way the request ended (refused later in the chain, its upstream
    /// unreachable, or answered), as macOS's defer emits it.
    @Test func theFetchEventGoesOnceWhateverTheEnd() {
        let count = NIOLockedValueBox(0)
        do { _ = SupplyChainRewrite(rewrite: { $0 }, done: { count.withLockedValue { $0 += 1 } }) }
        #expect(count.withLockedValue { $0 } == 1)
    }

    /// npm ci's bypass asked of the client through the consent broker:
    /// allowed once, the lockfile-pinned tarball goes up as it is.
    @Test func npmCiGoesThroughWhenTheClientAllowsIt() async throws {
        ConsentPrompt.chooseForTesting.withLockedValue { $0 = { _ in 1 } }   // "Allow once"
        defer { ConsentPrompt.chooseForTesting.withLockedValue { $0 = nil } }
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: false, lockfilePrompt: true)) { _ in
            Self.response(Data("tarball".utf8), type: "application/octet-stream")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo/-/demo-1.0.0.tgz HTTP/1.1\r\nHost: registry.npmjs.org\r\nnpm-command: ci\r\n\r\n")
        let reply = g.readAll()
        #expect(Self.body(reply) == Data("tarball".utf8), "\(String(decoding: reply.prefix(200), as: UTF8.self))")
        #expect(registry.requests.withLockedValue { $0 }.count == 1)
    }

    /// Depi's stand-in: TLS under Depi's name, signed by a test CA the proxy
    /// trusts; every connection is routed to it.
    static func depiRig(_ policy: SupplyChainPolicy, reply: String) throws -> (MitmProxy, UUID, MTLSServer, String) {
        let ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always refused)")
        let dir = try shortTempDir()
        let ca = try TestCA("test Depi CA")
        let server = try MTLSServer(host: ip, leaf: try ca.leaf(DepiRegistry.host, dns: [DepiRegistry.host], client: false),
                                    clientCA: nil, reply: reply)
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true), extraRoots: [ca.nio])
        proxy.routeAllTo = (ip, server.port)
        let pid = UUID()
        proxy.setSupplyChainPolicy(policy, for: pid)
        return (proxy, pid, server, dir)
    }

    /// Depi as the package filter: an npm request is redialled to Depi
    /// (TLS, its name) with the workspace's key as its Bearer token (the
    /// guest's token never leaves) and Depi's name as its Host, and the
    /// metadata rewrite still applies on top.
    @Test func depiReRoutesWithTheWorkspacesKey() async throws {
        let reply = String(decoding: Self.response(Self.packument(), type: "application/json"), as: UTF8.self)
        let (proxy, pid, server, dir) = try Self.depiRig(SupplyChainPolicy(ageGateEnabled: true, packageFilter: .depi,
                                                                           depiAPIKey: "depi-test-key"), reply: reply)
        defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo HTTP/1.1\r\nHost: registry.npmjs.org\r\nAuthorization: Bearer guest-token\r\n\r\n")
        let got = g.readAll()
        let seen = server.lastRequest.value
        #expect(seen.contains("Authorization: Bearer depi-test-key") && !seen.contains("guest-token"), "\(seen)")
        #expect(seen.contains("Host: \(DepiRegistry.host)") && !seen.contains("Host: registry.npmjs.org"), "\(seen)")
        let doc = try? JSONSerialization.jsonObject(with: Self.body(got)) as? [String: Any]
        #expect((doc?["versions"] as? [String: Any]).map { Array($0.keys) } == ["1.0.0"], "the age gate on top")
    }

    /// Depi rejecting the key: the guest gets Depi's self-explanatory
    /// answer, even for a request the policy doesn't otherwise rewrite.
    @Test func depisAuthFailureIsExplained() async throws {
        let (proxy, pid, server, dir) = try Self.depiRig(SupplyChainPolicy(ageGateEnabled: false, packageFilter: .depi,
                                                                           depiAPIKey: "depi-test-key"),
                                                         reply: "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /-/whoami HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n")
        let reply = String(decoding: g.readAll(), as: UTF8.self)
        #expect(reply.contains("X-Bromure-Block: depi-auth"), "\(reply.prefix(400))")
    }

    /// A key without Depi chosen as the filter: not re-routed.
    @Test func aDepiKeyAloneDoesntReRoute() async throws {
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: false, packageFilter: .socketDev,
                                                                           depiAPIKey: "depi-test-key")) { _ in
            Self.response(Data("{}".utf8), type: "application/json")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /-/whoami HTTP/1.1\r\nHost: registry.npmjs.org\r\nAuthorization: Bearer guest-token\r\n\r\n")
        _ = g.readAll()
        let seen = registry.requests.withLockedValue { $0 }.first ?? ""
        #expect(seen.contains("guest-token") && !seen.contains("depi-test-key"), "\(seen)")
    }

    /// With the policy off, a package fetch is only recorded: it goes up and
    /// comes back as it was.
    @Test func withThePolicyOffAFetchGoesThroughAsItWas() async throws {
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: false)) { _ in
            Self.response(Self.packument(), type: "application/json")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo HTTP/1.1\r\nHost: registry.npmjs.org\r\nAccept: application/vnd.npm.install-v1+json\r\n\r\n")
        let reply = g.readAll()
        #expect(registry.requests.withLockedValue { $0 }.first?.contains("vnd.npm.install-v1+json") == true, "not rewritten")
        let doc = try? JSONSerialization.jsonObject(with: Self.body(reply)) as? [String: Any]
        #expect((doc?["versions"] as? [String: Any])?.count == 2)
    }
}
}

extension DaemonGlobalSuites.SupplyChainProxyTests {
    /// The budget: what fits is kept; past it only the oldest reply holding
    /// any gets more; what's already in memory is counted whatever the room.
    @Test func theOldestHolderAlwaysGoesOn() {
        let b = SupplyChainBudget(limit: 100)
        let old = b.ticket(), young = b.ticket(), new = b.ticket(), newer = b.ticket()
        #expect(b.reserve(60, for: young) && b.reserve(30, for: old))
        #expect(!b.reserve(20, for: young), "full: a younger holder waits")
        #expect(!b.reserve(5, for: new), "and so does a reply holding nothing")
        #expect(b.reserve(20, for: old) && b.total == 110, "the head goes on past the limit")
        b.finish(old)
        #expect(b.total == 60)
        #expect(b.reserve(20, for: young), "the head now: the oldest holding or waiting")
        #expect(!b.reserve(5, for: newer), "room, but a reply before it waits: in line")
        #expect(b.reserve(5, for: new), "first in line gets the room")
        #expect(b.reserve(5, for: newer))
        b.add(500, for: newer)
        #expect(b.holding(newer) == 505, "what's in memory is counted whatever the room")
        b.hold(10, for: newer)
        #expect(b.holding(newer) == 10)
        for t in [young, new, newer] { b.finish(t) }
        #expect(b.total == 0)
        // A ticket that gave everything back without finishing doesn't hold the line.
        let stale = b.ticket(), next = b.ticket()
        #expect(b.reserve(100, for: stale)); b.release(100, for: stale)
        #expect(b.reserve(100, for: next) && b.reserve(1, for: next), "next is the head")
        b.finish(next)
        let since = Date().addingTimeInterval(-100)
        #expect(b.idle(since: since) < 1, "a finish is progress")
        b.rewriting(true)
        #expect(b.idle(since: since, now: Date().addingTimeInterval(1000)) == 0, "never idle while a rewrite is under way")
        b.rewriting(false)
    }

    /// A reply read whole with its chunks in one batch while the budget is
    /// full: the rest wait in order behind the first, on one timer, even
    /// when room comes before that timer, and the reply is whole, whether
    /// room comes before the end or the upstream closes first.
    @Test(arguments: [false, true])
    func chunksOfOneBatchWaitInOrder(closesFirst: Bool) async throws {
        let budget = ResponseRelay.supplyChainBudget, holder = budget.ticket()
        let taken = budget.limit - budget.total
        #expect(budget.reserve(taken, for: holder))
        let body = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        let loop = NIOAsyncTestingEventLoop()
        let guest = NIOAsyncTestingChannel(loop: loop)
        let relay = ResponseRelay(guest: guest, profileID: UUID(), injected: .init(), capture: nil, upgrade: false,
                                  host: "registry.npmjs.org", supplyChain: SupplyChainRewrite(rewrite: { $0 }, done: {}))
        let up = try await NIOAsyncTestingChannel(handler: relay, loop: loop)
        try await up.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        try await guest.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 2))
        let parts = [raw.prefix(1000), raw.dropFirst(1000).prefix(1000), raw.dropFirst(2000)]
        // The first waits; room comes before its timer, as the rest of the
        // batch arrives: they mustn't get ahead of it.
        try await up.writeInbound(up.allocator.buffer(bytes: parts[0]))
        if !closesFirst { budget.finish(holder) }
        for p in parts.dropFirst() { try await up.writeInbound(up.allocator.buffer(bytes: p)) }
        await loop.advanceTime(by: .milliseconds(120))
        try await up.close()
        if closesFirst { budget.finish(holder) }
        var out = Data()
        for _ in 0..<200 {
            if let b = try await guest.readOutbound(as: ByteBuffer.self) { out.append(contentsOf: b.readableBytesView); break }
            try await Task.sleep(for: .milliseconds(10))
            await loop.run()
        }
        #expect(out.starts(with: Data("HTTP/1.1 200 ".utf8)), "\(String(decoding: out.prefix(200), as: UTF8.self))")
        #expect(out.suffix(body.count) == body, "every chunk, in order")
        for _ in 0..<100 where budget.total != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(budget.total == 0)
    }

    /// gzip of `data` (header, raw deflate, CRC-32, size).
    static func gzip(_ data: Data) throws -> Data {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        crc ^= 0xFFFF_FFFF
        let le = { (v: UInt32) in Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
        return Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]) + (try #require(NPMRegistryTransforms.deflateRaw(data)))
            + le(crc) + le(UInt32(truncatingIfNeeded: data.count))
    }

    /// Five large replies at once, together past the budget: the oldest
    /// goes on past it, gives its share back, and every one completes.
    /// Compressed, they all fit raw; their decoded copies wait for room
    /// before they're made (only the head's goes past the limit).
    @Test(arguments: [false, true])
    func fiveLargeRepliesAllComplete(gzipped: Bool) async throws {
        let budget = ResponseRelay.supplyChainBudget
        let prior = budget.limit
        budget.limit = 2 << 20
        defer { budget.limit = prior }
        // A 12 MB packument (more than the sockets buffer, so a waiting
        // reply really stops reading): five are thirty times the budget.
        var doc = try #require(try JSONSerialization.jsonObject(with: Self.packument()) as? [String: Any])
        doc["readme"] = String(repeating: "x", count: 12_000_000)
        let big = try JSONSerialization.data(withJSONObject: doc)
        // Each sent in two halves: all five hold part of the budget at once.
        let gz = try Self.gzip(big)
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: true, ageGateDays: 2), pauseAfter: 1_000_000) { _ in
            gzipped ? Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: \(gz.count)\r\nConnection: close\r\n\r\n".utf8) + gz
                : Self.response(big, type: "application/json")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        var guests: [Guest] = []
        for _ in 0..<5 { guests.append(try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")) }
        defer { for g in guests { g.close() } }
        for g in guests { g.send("GET /demo HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n") }
        // What the budget holds stays near its limit plus the head's copies
        // (its raw, decoded and rewritten forms: about 3 × 12 MB; a
        // compressed one's decoded room is the cap until it's decoded).
        let peak = Task.detached { () -> Int in
            var m = 0
            for _ in 0..<400 { m = max(m, budget.total); try? await Task.sleep(for: .milliseconds(5)) }
            return m
        }
        let replies = await withTaskGroup(of: Data.self) { group in
            for fd in guests.map(\.fd) {
                group.addTask {
                    var out = Data(), buf = [UInt8](repeating: 0, count: 65536)
                    while case let n = recv(fd, &buf, buf.count, 0), n > 0 { out.append(contentsOf: buf[0..<n]) }
                    return out
                }
            }
            var all: [Data] = []
            for await r in group { all.append(r) }
            return all
        }
        for r in replies {
            #expect(String(decoding: r.prefix(15), as: UTF8.self) == "HTTP/1.1 200 OK", "\(String(decoding: r.prefix(200), as: UTF8.self))")
            #expect(r.count > 12_000_000, "whole")
        }
        let top = await peak.value
        let head = gzipped ? ResponseRelay.supplyChainCap + 2 * big.count : 3 * big.count
        #expect(top <= (2 << 20) + head + (1 << 20), "peak \(top)")
        for _ in 0..<100 where budget.total != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(budget.total == 0, "everything given back")
    }

    /// An upstream that stops sending mid-reply: refused (502) once nothing
    /// came for the read-whole idle time, its share given back.
    @Test func aStalledReplyIsRefused() async throws {
        let prior = ResponseRelay.supplyChainReadIdle.withLockedValue { $0 }
        ResponseRelay.supplyChainReadIdle.withLockedValue { $0 = 0.1 }
        defer { ResponseRelay.supplyChainReadIdle.withLockedValue { $0 = prior } }
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: true, ageGateDays: 2), pauseAfter: 100) { _ in
            Self.response(Self.packument(), type: "application/json")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
        defer { g.close() }
        g.send("GET /demo HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n")
        let reply = String(decoding: g.readAll(), as: UTF8.self)
        #expect(reply.hasPrefix("HTTP/1.1 502 ") && reply.contains("stalled"), "\(reply.prefix(300))")
        for _ in 0..<100 where ResponseRelay.supplyChainBudget.total != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ResponseRelay.supplyChainBudget.total == 0)
    }
}

extension DaemonGlobalSuites.SupplyChainProxyTests {
    /// A finished connection lets go of its handlers: the request reader,
    /// the reply's relay and the supply-chain rewrite (whose release emits
    /// the fetch event) are all freed.
    @Test func aFinishedConnectionsHandlersAreFreed() async throws {
        final class Weak: @unchecked Sendable {
            weak var reader: RequestReader?; weak var relay: ResponseRelay?; weak var rewrite: SupplyChainRewrite?
            var sawRelay = false, sawRewrite = false
        }
        let seen = Weak()
        let (proxy, pid, registry, dir) = try Self.setUp(SupplyChainPolicy(ageGateEnabled: true, ageGateDays: 2)) { _ in
            Self.response(Self.packument(), type: "application/json")
        }
        defer { registry.stop(); try? FileManager.default.removeItem(atPath: dir) }
        ResponseRelay.madeForTesting.withLockedValue { $0 = { r in
            guard r.profileID == pid else { return }
            seen.relay = r; seen.rewrite = r.supplyChain
            seen.sawRelay = true; seen.sawRewrite = r.supplyChain != nil
        } }
        defer { ResponseRelay.madeForTesting.withLockedValue { $0 = nil } }
        do {
            let g = try await Guest(proxy: proxy, pid: pid, host: "registry.npmjs.org")
            seen.reader = try await g.channel.pipeline.handler(type: RequestReader.self).get()
            g.send("GET /demo HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n")
            let reply = g.readAll()
            #expect(String(decoding: reply.prefix(15), as: UTF8.self) == "HTTP/1.1 200 OK")
            g.close()
        }
        #expect(seen.sawRelay && seen.sawRewrite, "the relay and its rewrite were seen")
        for _ in 0..<200 where seen.reader != nil || seen.relay != nil || seen.rewrite != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.reader == nil, "the request reader was freed")
        #expect(seen.relay == nil, "the relay was freed")
        #expect(seen.rewrite == nil, "the rewrite was released (its fetch event went)")
    }
}
