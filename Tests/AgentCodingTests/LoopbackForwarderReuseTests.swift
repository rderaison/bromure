import Foundation
import Testing
@testable import bromure_ac

/// A sign-in's loopback forwarder holds its host port until its relay closes
/// (or, abandoned, for its whole lifetime). A second sign-in on that port --
/// Codex always calls back on 1455; ac-e2e 33.5 reuses one port 40 times --
/// failed to bind ("couldn't bind 127.0.0.1:<port>") and, in the app, left
/// the OLD forwarder relaying the browser's callback into the old workspace.
/// Every site now goes through `forPort`, which retargets a live forwarder.
@Suite("Loopback forwarders: one per port, handed to the newest sign-in")
struct LoopbackForwarderReuseTests {
    static let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }

    @Test("no site binds a second forwarder for a port; a superseded relay can't stop the new one")
    func wiring() throws {
        let fwd = try Self.src("Sources/AgentCoding/LoopbackCallbackForwarder.swift")
        let forPort = try #require(fwd.range(of: "static func forPort("))
        let body = fwd[forPort.upperBound...].prefix(900)
        let owner = try #require(body.range(of: "guard owns(live.socketDevice, socketDevice) else {"))
        let retarget = try #require(body.range(of: "live.retarget(browserResponse: browserResponse)"))
        #expect(owner.lowerBound < retarget.lowerBound)
        let bind = try #require(body.range(of: "LoopbackCallbackForwarder(port: port"))
        #expect(retarget.lowerBound < bind.lowerBound)
        #expect(fwd.contains("if gen == generation { stop() }"))
        #expect(fwd.contains("let gen = generation, response = browserResponseOverride"))
        #expect(!fwd.contains("self?.relayFinished()"))
        // The workspace is fixed for the listener's life: retarget can't move it.
        #expect(!fwd.contains("self.socketDevice = socketDevice\n        browserResponseOverride"))
        #expect(!fwd.contains("func retarget(socketDevice"))
        #expect(fwd.components(separatedBy: "self.socketDevice = ").count == 2)   // init only
        for file in ["Sources/AgentCoding/BromureAC.swift", "Sources/AgentCoding/ClaudeRegistrationCoordinator.swift"] {
            let s = try Self.src(file)
            #expect(!s.contains("LoopbackCallbackForwarder(port"), "\(file) binds its own forwarder")
            #expect(!s.contains("LoopbackCallbackForwarder(\n"), "\(file) binds its own forwarder")
            // Through forPort -- directly, or the app's refusal gate.
            #expect(s.contains("LoopbackCallbackForwarder.forPort(") || s.contains("loopbackCallbackRefusal("))
        }
    }

    /// Finding (CWE-441): "A guest URL retargets another workspace's OAuth
    /// loopback forwarder". Any guest names a loopback port in a URL it opens;
    /// `forPort` handed it the live listener another workspace's sign-in was
    /// waiting on. Only the owning VM's own device may reuse it.
    @Test("only the workspace a listener relays into may reuse it")
    func ownership() {
        let a = NSObject(), b = NSObject()
        #expect(LoopbackCallbackForwarder.owns(a, a))
        #expect(!LoopbackCallbackForwarder.owns(a, b))          // another workspace
        #expect(!LoopbackCallbackForwarder.owns(nil, b))        // its workspace is gone: not adopted
    }

    /// Finding (CWE-441): "A refused loopback port still opens the sign-in,
    /// so another workspace receives the OAuth code". forPort refused, but the
    /// callers opened the authorize page anyway: the browser's redirect then
    /// reached the listener that holds the port -- another workspace's.
    @Test("a refused port never opens the sign-in page; a stopped VM lets its port go")
    func refusalBlocksTheOpen() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let reg = try Self.src("Sources/AgentCoding/ClaudeRegistrationCoordinator.swift")
        // Every guest-page open asks first, and returns when refused.
        for (name, text, open) in [("workspace", ac, "Self.openGuestRelayedURL(url)"),
                                   ("registration", reg, "ACAppDelegate.openGuestRelayedURL(url)")] {
            let gate = try #require(text.range(of: "loopbackCallbackRefusal(for: url, device: sandbox?.socketDevice")
                                    ?? text.range(of: "loopbackCallbackRefusal(\n                    for: url, device: sandbox?.socketDevice"),
                                    "\(name) doesn't ask")
            let after = text[gate.upperBound...]
            let ret = try #require(after.range(of: "return\n"))
            let opened = try #require(after.range(of: open))
            #expect(ret.lowerBound < opened.lowerBound, "\(name) opens before it gives up")
        }
        // Nobody else binds or reuses a callback listener (the debug sim aside).
        #expect(!reg.contains("LoopbackCallbackForwarder.forPort("))
        #expect(ac.components(separatedBy: "LoopbackCallbackForwarder.forPort(").count == 3)   // the gate + loopback-sim
        // A stopped VM's listeners stop with it; a workspace-less one frees its port.
        let unreg = try #require(ac.range(of: "func unregisterSession(_ id: Profile.ID) {"))
        let body = ac[unreg.upperBound...].prefix(500)
        let stop = try #require(body.range(of: "stopLoopbackForwarders(of: dev)"))
        let remove = try #require(body.range(of: "runningSessions.removeValue(forKey: id)"))
        #expect(stop.lowerBound < remove.lowerBound)
        let fwd = try Self.src("Sources/AgentCoding/LoopbackCallbackForwarder.swift")
        #expect(fwd.contains("for f in forwarders where f.isRunning && !f.hasWorkspace { f.stop() }"))
    }

    /// Finding (CWE-459): "A refused workspace sign-in stays in flight, so
    /// retry is blocked for five minutes".
    @Test("a refused workspace sign-in is ended (capture disarmed, retry free), not only reported")
    func refusedSignInEnds() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let gate = try #require(ac.range(of: "if let refused = self.loopbackCallbackRefusal(for: url, device: sandbox?.socketDevice) {"))
        let branch = ac[gate.upperBound...].prefix(900)
        #expect(branch.contains("self.endProxySignIn(signIn, success: false, message: refused)"))
        #expect(!branch.contains("signIn.onEvent?(.finished"))
        let ss = try Self.src("Sources/AgentCoding/SessionSignIn.swift")
        let end = try #require(ss.range(of: "func endProxySignIn(_ s: ProxySignIn, success: Bool, message: String?) {"))
        let body = ss[end.upperBound...].prefix(600)
        for step in ["s.finished = true", "s.timeout?.cancel()", "signInCaptures.disarm(profileID: s.profileID)",
                     "proxySignIns[s.profileID] = nil"] {
            #expect(body.contains(step), "endProxySignIn no longer does \(step)")
        }
    }

    /// Finding (CWE-441): "Sign-in refusal ignores a [::1] redirect, so the
    /// other workspace still receives the OAuth code". The gate only knew
    /// 127.0.0.1 and localhost; a [::1] redirect (the forwarder listens there
    /// too) had no port, so no ownership check, and the page opened.
    @Test("every loopback spelling a browser follows is a callback port; nothing else is",
          arguments: ["http://127.0.0.1:1455/cb", "http://localhost:1455/cb", "http://[::1]:1455/cb",
                      "http://[0:0:0:0:0:0:0:1]:1455/cb", "http://[::ffff:127.0.0.1]:1455/cb",
                      "http://127.1:1455/cb", "http://2130706433:1455/cb", "http://0x7f000001:1455/cb",
                      "http://127.0.0.2:1455/cb", "http://0.0.0.0:1455/cb", "http://[::]:1455/cb",
                      "http://LOCALHOST.:1455/cb", "http://app.localhost:1455/cb",
                      "http://[::1%25lo0]:1455/cb"])
    @MainActor
    func loopbackRedirects(redirect: String) throws {
        var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        c.queryItems = [URLQueryItem(name: "client_id", value: "x"), URLQueryItem(name: "redirect_uri", value: redirect)]
        #expect(ACAppDelegate.loopbackCallbackPort(from: try #require(c.url)) == 1455, "\(redirect)")
    }

    @Test("a public or LAN redirect, or none, has no callback port",
          arguments: ["https://example.com:1455/cb", "http://192.168.1.4:1455/cb", "http://[fe80::1]:1455/cb",
                      "http://10.0.0.1:1455/cb", "http://notlocalhost:1455/cb", "http://[::2]:1455/cb",
                      "http://[::ffff:10.0.0.1]:1455/cb", "http://127.0.0.1/cb"])
    @MainActor
    func notLoopbackRedirects(redirect: String) throws {
        var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        c.queryItems = [URLQueryItem(name: "redirect_uri", value: redirect)]
        #expect(ACAppDelegate.loopbackCallbackPort(from: try #require(c.url)) == nil, "\(redirect)")
        #expect(ACAppDelegate.loopbackCallbackPort(from: URL(string: "https://auth.openai.com/oauth/authorize")!) == nil)
    }

    /// The same narrow parsing guarded the guest-URL open itself: a direct
    /// `http://0x7f000001:…` (no redirect) is this Mac's loopback too.
    @Test("a guest URL to loopback in any spelling never opens in the real browser",
          arguments: ["http://0x7f000001:8080/", "http://127.1:8080/", "http://2130706433/", "http://[::1%25lo0]:8080/",
                      "http://[::ffff:127.0.0.1]/", "http://0.0.0.0:8080/", "http://10.1/"])
    func directLoopbackOpenRefused(url: String) throws {
        #expect(!ACAppDelegate.opensInRealBrowser(try #require(URL(string: url))), "\(url)")
    }

    @Test("a public page still opens")
    func publicOpens() throws {
        #expect(ACAppDelegate.opensInRealBrowser(try #require(URL(string: "https://auth.openai.com/oauth/authorize?x=1"))))
        #expect(ACAppDelegate.opensInRealBrowser(try #require(URL(string: "https://8.8.8.8/"))))
    }

    /// Finding (CWE-441): "A one-family loopback bind is treated as owning
    /// the OAuth port, so the page still opens". Another program on
    /// 127.0.0.1:<port> left ::1 free; the forwarder took ::1 and the gate
    /// opened the page -- the browser's 127.0.0.1 redirect went to the other.
    @Test("a port held on one loopback family isn't ours, even with the other free")
    func oneFamilyTakenIsNotOwned() throws {
        typealias F = LoopbackCallbackForwarder
        // Someone else listens on 127.0.0.1:<free port>.
        let other = socket(AF_INET, SOCK_STREAM, 0)
        #expect(other >= 0)
        defer { close(other) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(other, sa, len) == 0 && listen(other, 1) == 0 && getsockname(other, sa, &len) == 0
            }
        }
        #expect(bound)
        let port = UInt16(bigEndian: addr.sin_port)

        let v4 = F.listenLoopback(family: AF_INET, port: port)
        let v6 = F.listenLoopback(family: AF_INET6, port: port)
        #expect(v4 == .taken)
        if case .bound(let fd) = v6 { close(fd) }                  // ::1 was free (dual-stack host)
        #expect(!F.owns([v4, v6]))                                 // one family taken: not ours

        #expect(F.owns([.bound(3), .bound(4)]))
        #expect(F.owns([.bound(3), .unavailable]))                 // an IPv4- or IPv6-only host
        #expect(!F.owns([.unavailable, .unavailable]))
        #expect(!F.owns([.taken, .unavailable]))
    }
}
