import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ACLinux
import SandboxEngine

/// Fusion on the Linux proxy: its toggle and config per workspace, the
/// step's gates (live legs reach real providers, so the run itself isn't
/// exercised here), the route and /vms's fields.
extension DaemonGlobalSuites {
    @Suite("Fusion (Linux wiring)", .serialized)
    struct FusionLinuxTests {
        static let config = Fusion.Config(legs: [.claude, .codex], judgeProvider: .claude, judgeModel: "judge",
                                          authModes: [.claude: .token, .codex: .token], legModels: [:],
                                          localLegModel: nil, judgeLocal: false, localEngineBase: nil,
                                          localEngineKey: nil, ompProvider: .default)

        @Test func theToggleAndConfigArePerWorkspaceAndTheStepIsGated() async throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let a = UUID(), b = UUID()
            #expect(!proxy.fusionEngaged(for: a) && proxy.fusionConfig(for: a) == nil)
            proxy.setFusionConfig(Self.config, for: a)
            proxy.setFusionEngaged(true, for: a)
            #expect(proxy.fusionEngaged(for: a) && proxy.fusionConfig(for: a) != nil)
            #expect(!proxy.fusionEngaged(for: b) && proxy.fusionConfig(for: b) == nil, "another workspace's are its own")
            let turn = Data(#"POST /v1/messages HTTP/1.1\#r\#nHost: api.anthropic.com\#r\#nContent-Length: 2\#r\#n\#r\#n{}"#.utf8)
            // Not engaged: the turn goes on as usual.
            if case .notRun = await RequestReader.fusionAnswer(turn, proxy: proxy, profileID: b, host: "api.anthropic.com", port: 443, trace: nil) {} else {
                Issue.record("ran while not engaged")
            }
            // Engaged, but this proxy dials no real upstream (e2e): never run.
            proxy.refusesRealUpstreams = true
            if case .notRun = await RequestReader.fusionAnswer(turn, proxy: proxy, profileID: a, host: "api.anthropic.com", port: 443, trace: nil) {} else {
                Issue.record("ran in e2e mode")
            }
            proxy.clearFusionEngaged(for: a)
            #expect(!proxy.fusionEngaged(for: a) && proxy.fusionConfig(for: a) != nil, "a stop clears the toggle, not the config")
            proxy.clearFusionConfig(for: a)
            #expect(proxy.fusionConfig(for: a) == nil)
        }

        @Test func theRouteNeedsARunningConfigurableWorkspace() async throws {
            let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let r = await d.fusionRoute(rec, .object(["engaged": .bool(true)]))
            #expect(r.status == 409, "not running: \(r.body)")
            await d.shutdown()
        }

        @Test func theLegEndpointsFollowTheConfig() {
            var c = Self.config
            #expect(Set(RequestReader.fusionLegEndpoints(c).map(\.key)) == ["api.anthropic.com:443", "api.openai.com:443"])
            c.legs = [.codex, .grok, .kimi]
            c.authModes = [.codex: .subscription, .grok: .subscription, .kimi: .token]
            c.judgeProvider = .grok
            #expect(Set(RequestReader.fusionLegEndpoints(c).map(\.key))
                    == ["chatgpt.com:443", "cli-chat-proxy.grok.com:443", "api.moonshot.ai:443"])
            // A local leg or judge: the user's external engine, on its own scheme and port.
            c.legs = [.claude, .codex]
            c.authModes = [.claude: .token, .codex: .local]
            c.judgeLocal = true
            c.localEngineBase = "http://engine.example.test:8000/v1"
            let legs = RequestReader.fusionLegEndpoints(c)
            #expect(legs.contains(FusionLeg(host: "engine.example.test", port: 8000, tls: false)))
            #expect(!legs.contains { $0.host == "api.openai.com" }, "a local codex leg isn't the cloud one")
            c.localEngineBase = nil
            #expect(!RequestReader.fusionLegEndpoints(c).contains { $0.host == InferenceService.engineHost }, "not the on-host engine")
        }

        @Test func eligibilityComesBeforeTheLegsAndARefusedLegMakesFusionStepAside() async throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let pid = UUID()
            proxy.setFusionConfig(Self.config, for: pid)
            proxy.setFusionEngaged(true, for: pid)
            // The firewall denies every leg (no name is even looked up).
            proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                       egressPolicy: try EgressPolicy.parse("default deny")), for: pid)
            if case .success = await proxy.checkFusionLeg(FusionLeg(host: "api.openai.com", port: 443, tls: true), profileID: pid) {
                Issue.record("a denied leg passed")
            }
            let turn = Data(#"POST /v1/messages HTTP/1.1\#r\#nHost: api.anthropic.com\#r\#nContent-Length: 2\#r\#n\#r\#n{}"#.utf8)
            guard case .notRun = await RequestReader.fusionAnswer(turn, proxy: proxy, profileID: pid, host: "api.anthropic.com", port: 443, trace: nil) else {
                Issue.record("ran with a refused leg"); return
            }
            #expect(proxy.fusionRefusalsLogged.withLockedValue { $0.count } == 1, "logged once")
            _ = await RequestReader.fusionAnswer(turn, proxy: proxy, profileID: pid, host: "api.anthropic.com", port: 443, trace: nil)
            #expect(proxy.fusionRefusalsLogged.withLockedValue { $0.count } == 1, "not again for the same leg")
            // Not a messages POST: not eligible, nothing checked or logged.
            proxy.fusionRefusalsLogged.withLockedValue { $0 = [] }
            let other = Data(#"GET /v1/models HTTP/1.1\#r\#nHost: api.anthropic.com\#r\#n\#r\#n"#.utf8)
            _ = await RequestReader.fusionAnswer(other, proxy: proxy, profileID: pid, host: "api.anthropic.com", port: 443, trace: nil)
            #expect(proxy.fusionRefusalsLogged.withLockedValue { $0.isEmpty })
        }

        @Test func aRunsSessionPinsItsHTTPLegsAndStillOpensWebSockets() async throws {
            let ip = try #require(Daemon.primaryIPv4(), "a host address")
            let http = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
            defer { http.stop() }
            let ws = try WSUpstream(host: ip, reply: { _ in [WSFrame.encode(opcode: WSFrame.text, payload: Data("pong".utf8), masked: false)] })
            defer { ws.stop() }
            let addr = try #require(OpenShellPolicy.IPAddress(ip))
            // This run checked the http leg (named by an unresolvable host): its address only.
            let cls = try #require(FusionPinnedProtocol.acquire(["engine.example.test:\(http.port)": [addr]]))
            defer { cls.release() }
            let session = URLSession(configuration: RequestReader.fusionSessionConfiguration(cls))
            defer { session.finishTasksAndInvalidate() }
            var req = URLRequest(url: URL(string: "http://engine.example.test:\(http.port)/v1/chat")!)
            req.timeoutInterval = 10
            let (data, resp) = try await session.data(for: req)
            #expect((resp as? HTTPURLResponse)?.statusCode == 200 && String(decoding: data, as: UTF8.self) == "hello")
            #expect(http.received.withLockedValue { $0 }.contains("Host: engine.example.test:\(http.port)"), "dialled to the checked address, Host the name")
            // An unchecked host on this session: not dialled.
            do {
                var other = URLRequest(url: URL(string: "https://unchecked.example.test/x")!)
                other.timeoutInterval = 5
                _ = try await session.data(for: other)
                Issue.record("an unchecked host was dialled")
            } catch {
                #expect((error as? URLError)?.code == .cannotConnectToHost, "\(error)")
            }
            // The WebSocket leg's protocol is still the session's (the defaults come after the pinned one).
            let task = session.webSocketTask(with: URL(string: "ws://\(ip):\(ws.port)/codex")!)
            task.resume()
            try await task.send(.string("ping"))
            if case .string(let s) = try await task.receive() { #expect(s == "pong") } else { Issue.record("no text reply") }
            task.cancel(with: .normalClosure, reason: nil)
        }

        /// A leg's 3xx is its answer: the place it points to (another
        /// user's port, a metadata address) is never dialled.
        @Test func aLegsRedirectIsntFollowed() async throws {
            let ip = try #require(Daemon.primaryIPv4(), "a host address")
            let elsewhere = try RawUpstream(host: "127.0.0.1", reply: "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nsecret")
            defer { elsewhere.stop() }
            let engine = try RawUpstream(host: ip, reply: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(elsewhere.port)/x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            defer { engine.stop() }
            let addr = try #require(OpenShellPolicy.IPAddress(ip))
            let cls = try #require(FusionPinnedProtocol.acquire(["engine.example.test:\(engine.port)": [addr]]))
            defer { cls.release() }
            let session = URLSession(configuration: RequestReader.fusionSessionConfiguration(cls))
            defer { session.finishTasksAndInvalidate() }
            var req = URLRequest(url: URL(string: "http://engine.example.test:\(engine.port)/v1/chat")!)
            req.timeoutInterval = 10
            let (data, resp) = try await session.data(for: req)
            #expect((resp as? HTTPURLResponse)?.statusCode == 302 && data.isEmpty)
            #expect(engine.received.withLockedValue { $0 }.hasPrefix("GET /v1/chat HTTP/1.1\r\nHost: engine.example.test:\(engine.port)\r\n"))
            #expect(elsewhere.received.withLockedValue { $0 }.isEmpty, "the redirect wasn't followed")
        }

        /// A stopped loader's dial goes: the connection closed, the call
        /// cancelled.
        @Test func aCancelledDialStops() async throws {
            let ip = try #require(Daemon.primaryIPv4(), "a host address")
            let silent = try RawUpstream(host: ip, reply: "")
            defer { silent.stop() }
            let addr = try #require(OpenShellPolicy.IPAddress(ip))
            var req = URLRequest(url: URL(string: "http://engine.example.test:\(silent.port)/v1/chat")!)
            req.httpMethod = "POST"
            let call = Task { try await PinnedHTTPS.sendPlain(req, to: addr, timeout: 60) }
            for _ in 0..<200 where silent.received.withLockedValue({ $0 }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!silent.received.withLockedValue { $0 }.isEmpty, "the request went")
            call.cancel()
            await #expect(throws: CancellationError.self) { _ = try await call.value }
            for _ in 0..<200 where silent.closed.withLockedValue({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(silent.closed.withLockedValue { $0 } == 1, "the connection closed")
        }

        @Test func hostFieldBracketsAnIPv6Literal() {
            #expect(NIOMTLSHTTPClient.hostField("::1", port: 8080, defaultPort: 80) == "[::1]:8080")
            #expect(NIOMTLSHTTPClient.hostField("fe80::1", port: 443) == "[fe80::1]")
            #expect(NIOMTLSHTTPClient.hostField("engine.example.test", port: 80, defaultPort: 80) == "engine.example.test")
            #expect(NIOMTLSHTTPClient.hostField("engine.example.test", port: 443, defaultPort: 80) == "engine.example.test:443")
        }

        @Test func eachRunHasItsOwnSlot() {
            var held: [FusionPinnedProtocol.Type] = []
            for i in 0..<FusionPinnedProtocol.slots.count {
                guard let c = FusionPinnedProtocol.acquire(["h\(i):443": []]) else { Issue.record("slot \(i)"); break }
                held.append(c)
            }
            #expect(FusionPinnedProtocol.acquire([:]) == nil, "all taken: Fusion steps aside")
            #expect(held[0].addresses(for: "h1:443").isEmpty && held[1].addresses(for: "h1:443").isEmpty)
            for c in held { c.release() }
            #expect(FusionPinnedProtocol.acquire([:]).map { $0.release(); return true } == true)
        }

        @Test("the collected reply is what Fusion wrote, in order")
        func collectedReply() throws {
            let c = CollectedReply()
            try c.write(Data("HTTP/1.1 200 OK\r\n".utf8))
            try c.write(Data("\r\n".utf8))
            #expect(String(decoding: c.data, as: UTF8.self) == "HTTP/1.1 200 OK\r\n\r\n")
        }
    }
}
