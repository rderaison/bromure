import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import ACLinux
import SandboxEngine

/// The supply-chain policy on the Linux proxy (macOS: driveTLS's
/// supply-chain block), through a RequestReader to a local stand-in for the
/// npm registry (the name pinned, never looked up or dialed). OSV,
/// socket.dev and PyPI stay off: no test reaches a real host.
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

    /// A registry stand-in: records each request, answers `reply(path)`.
    final class Registry: @unchecked Sendable {
        let requests = NIOLockedValueBox<[String]>([])
        let channel: Channel
        var port: Int { channel.localAddress!.port! }
        init(host: String, reply: @escaping @Sendable (String) -> Data) throws {
            let requests = self.requests
            channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { $0.pipeline.addHandler(Handler(requests, reply)) }
                .bind(host: host, port: 0).wait()
        }
        func stop() { channel.close(promise: nil) }
        final class Handler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer
            let requests: NIOLockedValueBox<[String]>
            let reply: @Sendable (String) -> Data
            var buf = ""
            init(_ r: NIOLockedValueBox<[String]>, _ reply: @escaping @Sendable (String) -> Data) { requests = r; self.reply = reply }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var b = unwrapInboundIn(data)
                buf += b.readString(length: b.readableBytes) ?? ""
                guard buf.contains("\r\n\r\n") else { return }
                requests.withLockedValue { $0.append(buf) }
                let path = buf.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: reply(path))))
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
    static func setUp(_ policy: SupplyChainPolicy, reply: @escaping @Sendable (String) -> Data) throws
        -> (MitmProxy, UUID, Registry, String) {
        let dir = try shortTempDir()
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        proxy.setSupplyChainPolicy(policy, for: pid)
        let ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always refused)")
        let registry = try Registry(host: ip, reply: reply)
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
        let plain = RequestReader.supplyChainPlain(ok, cleanClose: false).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(plain.hasSuffix("\r\n\r\n{}") && plain.contains("Content-Length: 2") && plain.contains("Connection: close"), "\(plain)")
        #expect(RequestReader.supplyChainPlain(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}".utf8), cleanClose: true) == nil)
        #expect(RequestReader.supplyChainPlain(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n".utf8), cleanClose: true) == nil)
        let untilClose = Data("HTTP/1.1 200 OK\r\n\r\n{}".utf8)
        #expect(RequestReader.supplyChainPlain(untilClose, cleanClose: false) == nil)
        #expect(RequestReader.supplyChainPlain(untilClose, cleanClose: true) != nil)
        #expect(RequestReader.supplyChainPlain(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n".utf8), cleanClose: true) == nil)
        #expect(RequestReader.supplyChainPlain(Data("HTTP/1.1 200 OK\r\nContent-Length: 2, 3\r\n\r\n{}x".utf8), cleanClose: true) == nil)
    }

    /// Every Content-Encoding line counts: gzip then identity is gzip.
    @Test func everyCodingLineCounts() throws {
        let gz = try #require(Data(base64Encoded: "H4sIAAAAAAAAA6tWykvMTVWyUkpJzc1X0lGqULIyrOUCAF+WXL0WAAAA"))
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Encoding: identity\r\nContent-Length: \(gz.count)\r\n\r\n".utf8) + gz
        let plain = try #require(RequestReader.supplyChainPlain(raw, cleanClose: true))
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

    /// A policy with Depi as its filter says, in the log and on the
    /// Timeline, that Depi's re-route isn't applied here yet.
    @Test func aDepiPolicySaysItsNotAppliedYet() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let before = SupplyChainLog.shared.snapshot().last?.id ?? 0
        proxy.setSupplyChainPolicy(SupplyChainPolicy(packageFilter: .depi, depiAPIKey: "depi-test-key"), for: UUID())
        #expect(SupplyChainLog.shared.snapshot().contains { $0.id > before && $0.message.contains("isn't applied on Linux yet") })
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
