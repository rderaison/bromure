import Foundation
import Testing
@testable import ACLinux
import NIOCore
import NIOPosix

extension DaemonGlobalSuites {
    /// A workspace's model routing in the Linux proxy (macOS: MitmEngine's
    /// routing contexts, HTTPProxy's routing step, short-circuit and local
    /// auth swap; applyRouting; automationSetRouting).
    @Suite("Model routing", .serialized)
    struct ModelRoutingTests {
        @Test func theDecisionTheShortCircuitAndTheAuth() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let mitm = try #require(await d.mitm)
            let pid = UUID()
            // No routing: the sentinel local (in clear, to the repair proxy), the rest as asked.
            let sentinel = mitm.route(host: "Bromure.LLM", port: 443, tls: true, profileID: pid)
            #expect(sentinel.local && !sentinel.tls && sentinel.host == "127.0.0.1" && sentinel.port == InferenceService.repairProxyPort)
            let cloud = mitm.route(host: "api.anthropic.com", port: 443, tls: true, profileID: pid)
            #expect(!cloud.local && cloud.tls && cloud.host == "api.anthropic.com")
            // Local, with Claude local: its real host to the engine; another provider's not.
            mitm.setRouting(.local, modelLabel: "qwen", localCloudHosts: ["anthropic.com"], for: pid)
            #expect(mitm.route(host: "api.anthropic.com", port: 443, tls: true, profileID: pid).local)
            #expect(!mitm.route(host: "api.openai.com", port: 443, tls: true, profileID: pid).local)
            #expect(!mitm.route(host: "api.anthropic.com", port: 443, tls: true, profileID: UUID()).local, "another workspace's")
            // Short-circuit: Claude's management calls and telemetry, not its LLM calls.
            #expect(mitm.localShortCircuit(host: "api.anthropic.com", path: "/api/oauth/profile", profileID: pid) != nil)
            #expect(mitm.localShortCircuit(host: "api.anthropic.com", path: "/v1/messages", profileID: pid) == nil)
            #expect(mitm.localShortCircuit(host: "statsig.anthropic.com", path: "/v1/rgstr", profileID: pid) != nil)
            let reply = String(decoding: mitm.localShortCircuit(host: "o1.ingest.sentry.io", path: "/x", profileID: pid) ?? Data(), as: UTF8.self)
            #expect(reply.hasPrefix("HTTP/1.1 200 OK") && reply.hasSuffix("\r\n\r\n{}"))
            // A mixed workspace (Claude on the cloud): its management calls go out.
            mitm.setRouting(.local, modelLabel: "qwen", localCloudHosts: ["openai.com"], for: pid)
            #expect(mitm.localShortCircuit(host: "api.anthropic.com", path: "/api/oauth/profile", profileID: pid) == nil)
            #expect(!mitm.route(host: "api.anthropic.com", port: 443, tls: true, profileID: pid).local)
            // Cloud: nothing short-circuited, nothing rerouted.
            mitm.setRouting(.cloud, modelLabel: "qwen", localCloudHosts: ["anthropic.com"], for: pid)
            #expect(mitm.localShortCircuit(host: "api.statsig.com", path: "/", profileID: pid) == nil)
            #expect(!mitm.route(host: "api.anthropic.com", port: 443, tls: true, profileID: pid).local)
            // Gone with the workspace's policies.
            mitm.setRouting(.local, modelLabel: "qwen", localCloudHosts: ["anthropic.com"], for: pid)
            mitm.clearWorkspacePolicies(pid)
            #expect(!mitm.route(host: "api.anthropic.com", port: 443, tls: true, profileID: pid).local)

            // The engine's auth: the cloud key (stand-in or real) out, the per-VM key in.
            let fakeKey = "sk-" + "ant-api03-" + String(repeating: "x", count: 20)
            let req = Data("POST /v1/messages HTTP/1.1\r\nHost: api.anthropic.com\r\nx-api-key: \(fakeKey)\r\nAuthorization: Bearer real\r\nContent-Length: 2\r\n\r\n{}".utf8)
            let out = String(decoding: MitmProxy.engineAuth(req, profileID: pid), as: UTF8.self)
            #expect(!out.contains(fakeKey) && !out.contains("Bearer real"))
            #expect(out.contains("Authorization: Bearer \(EngineKey.perVM(profileID: pid))") && out.hasSuffix("\r\n\r\n{}"))
            // A per-VM key already there (the sentinel path): kept as is.
            let mine = Data("POST /v1/messages HTTP/1.1\r\nHost: bromure.llm\r\nAuthorization: Bearer \(EngineKey.perVM(profileID: pid))\r\n\r\n".utf8)
            #expect(MitmProxy.engineAuth(mine, profileID: pid) == mine)
            await d.shutdown()
        }

        /// applyRouting: effectiveModelRouting (a local route with no local
        /// agent stays cloud) and the local agents' hosts.
        @Test func applyRoutingAsMacOS() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let mitm = try #require(await d.mitm)
            var local = Profile(name: "l", tool: .claude, authMode: .local)
            local.modelRouting = .local
            local.activeModelID = "qwen3:32b"
            await d.applyRouting(staged: local)
            let ctx = try #require(mitm.routingContext(for: local.id))
            #expect(ctx.routing == .local && ctx.localModelLabel == "qwen3:32b" && ctx.isLocalProviderHost("api.anthropic.com"))
            // Through the launch's staging (the global models overlaid), as the daemon does.
            var raw = Profile(name: "r", tool: .claude, authMode: .local)
            raw.modelRouting = .local
            raw.activeModelID = "e2e-model"
            raw.localEngineURL = "http://127.0.0.1:9"
            let staged = await d.stagedProfile(raw)
            await d.applyRouting(for: raw)
            let rctx = try #require(mitm.routingContext(for: raw.id))
            #expect(rctx.routing == .local, "staged: still local")
            // The launch overlay enables every agent: omp on a key, Anthropic
            // its default, claims anthropic.com, so a local Claude's real host
            // isn't rerouted (it reaches the engine through the sentinel), as
            // on macOS (localProviderCloudHosts, shared).
            #expect(!rctx.isLocalProviderHost("api.anthropic.com"))
            var codex = Profile(name: "c", tool: .codex, authMode: .local)
            codex.modelRouting = .local
            codex.activeModelID = "e2e-model"
            await d.applyRouting(for: codex)
            #expect(mitm.routingContext(for: codex.id)?.isLocalProviderHost("api.openai.com") == true, "nobody else claims OpenAI")
            var sub = Profile(name: "s", tool: .claude, authMode: .subscription)
            sub.modelRouting = .local
            await d.applyRouting(staged: sub)
            #expect(mitm.routingContext(for: sub.id)?.routing == .cloud, "no local agent: never rerouted")
            // The routes: a VM that isn't running answers 409.
            let rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
            try await d.registerForTesting(rec)
            #expect(await d.vmRoute("POST", "/vms/\(rec.id)/routing", ["mode": "local"]).status == 409)
            #expect(await d.vmRoute("POST", "/vms/\(rec.id)/fusion", ["engaged": true]).status == 409)
            await d.shutdown()
        }

        /// One decision per request: the plan carries it (the dial, the
        /// engine's auth and the PII step follow it); an upgrade to a
        /// rerouted host is dialled for real, as macOS's WebSocket path.
        @Test func thePlanCarriesTheDecision() async throws {
            let dir = try shortTempDir()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let pid = UUID()
            proxy.setRouting(.local, modelLabel: "m", localCloudHosts: ["openai.com"], for: pid)
            func plan(_ raw: String) async -> (local: Bool, out: String)? {
                var trace: RequestReader.Trace?
                let p = await RequestReader.rewrite(Data(raw.utf8), proxy: proxy, profileID: pid, host: "api.openai.com", port: 443,
                                                    tls: true, session: proxy.strictSession(of: pid), trace: &trace)
                guard case .forward(let out, _, _, _, _, _, _, _, _, let local, _, _, _) = p else { return nil }
                return (local, String(decoding: out, as: UTF8.self))
            }
            let post = try #require(await plan("POST /v1/chat/completions HTTP/1.1\r\nHost: api.openai.com\r\nAuthorization: Bearer cloud-standin\r\nContent-Length: 2\r\n\r\n{}"))
            #expect(post.local && post.out.contains("Authorization: Bearer \(EngineKey.perVM(profileID: pid))") && !post.out.contains("cloud-standin"))
            let ws = try #require(await plan("GET /v1/realtime HTTP/1.1\r\nHost: api.openai.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"))
            #expect(!ws.local, "an upgrade goes to the real host")
            proxy.setRouting(.cloud, modelLabel: "m", localCloudHosts: ["openai.com"], for: pid)
            #expect(try #require(await plan("POST /v1/chat/completions HTTP/1.1\r\nHost: api.openai.com\r\nContent-Length: 2\r\n\r\n{}")).local == false)
        }

        /// The engine key kept only when it's this workspace's; x-api-key
        /// always dropped on a local turn.
        @Test func onlyThisWorkspacesEngineKeyIsKept() {
            let pid = UUID(), other = UUID()
            let theirs = Data("POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer \(EngineKey.perVM(profileID: other))\r\n\r\n".utf8)
            let out = String(decoding: MitmProxy.engineAuth(theirs, profileID: pid), as: UTF8.self)
            #expect(out.contains(EngineKey.perVM(profileID: pid)) && !out.contains(EngineKey.perVM(profileID: other)))
            let mine = Data("POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer \(EngineKey.perVM(profileID: pid))\r\nx-api-key: leftover\r\n\r\n".utf8)
            let kept = String(decoding: MitmProxy.engineAuth(mine, profileID: pid), as: UTF8.self)
            #expect(kept.contains("Authorization: Bearer \(EngineKey.perVM(profileID: pid))") && !kept.lowercased().contains("x-api-key"))
        }

        /// CONNECT: a host served locally isn't looked up; a name with no
        /// answer and no policy is left to the dial, not refused.
        @Test func theConnectCheckLeavesLocalAndUnresolvedNamesToTheDial() throws {
            let dir = try shortTempDir()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let pid = UUID()
            proxy.setRouting(.local, modelLabel: "m", localCloudHosts: ["openai.com"], for: pid)
            #expect(try proxy.checkDestination(host: "api.openai.com", port: 443, profileID: pid, on: loop).wait() == [],
                    "no lookup for a host the engine serves")
            #expect(try proxy.checkDestination(host: "no-such-host-\(UUID().uuidString.prefix(8)).invalid", port: 443,
                                               profileID: pid, on: loop).wait() == [], "left to the dial")
        }
    }
}
