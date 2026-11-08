import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

/// Strict credential mode on the Linux proxy (macOS: HTTPProxy's
/// UnmanagedCredentialGuard step): a credential Bromure didn't issue never
/// leaves the VM; Bromure's stand-ins, tokens the site issued the guest and
/// session approvals do.
@Suite("Strict credentials", .serialized)
struct StrictCredentialsTests {
    static let real = "ghp_" + String(repeating: "A1b2C3d4E5", count: 4).prefix(36)

    static func strict(_ rig: ProxyEgressPolicyTests.Rig, _ on: Bool) {
        var cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [])
        cfg.strictCredentials = on
        rig.proxy.setGuardrailsConfig(cfg, for: rig.pid)
    }

    @Test func aCredentialBromureDidntIssueIsRefusedAndRaised() throws {
        let rig = try ProxyEgressPolicyTests.Rig(); defer { rig.stop() }
        let ip = try #require(Daemon.primaryIPv4())
        let up = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { up.stop() }
        let raised = NIOLockedValueBox<[CompromiseEvent]>([])
        rig.proxy.swapper.setCompromiseHandler { e in raised.withLockedValue { $0.append(e) } }
        let h = "\(ip):\(up.port)"
        let req = "GET http://\(h)/x HTTP/1.1\r\nHost: \(h)\r\nAuthorization: Bearer \(Self.real)\r\n\r\n"
        // Off: through.
        Self.strict(rig, false)
        #expect(try PipelineTests.talk(rig.path(), req).hasPrefix("HTTP/1.1 200"))
        let n0 = up.received.withLockedValue { $0.count }
        // On: refused, nothing upstream, raised with its fingerprint.
        Self.strict(rig, true)
        let out = try PipelineTests.talk(rig.path(), req)
        #expect(out.hasPrefix("HTTP/1.1 451") && out.contains("strict credential mode") && !out.contains(Self.real), "\(out.prefix(160))")
        #expect(up.received.withLockedValue { $0.count } == n0, "nothing went upstream")
        let fps = raised.withLockedValue { $0 }.last?.unmanagedFingerprints ?? []
        #expect(!fps.isEmpty, "raised as a compromise, with the credential's fingerprint")
        // Approved for the session: through.
        UnmanagedCredentialGuard.shared.allowForSession(fps, profileID: rig.pid)
        #expect(try PipelineTests.talk(rig.path(), req).hasPrefix("HTTP/1.1 200"))
        // The workspace's policies cleared (its VM stopped): off, approvals forgotten.
        rig.proxy.clearGuardrailsConfig(for: rig.pid)
        Self.strict(rig, true)
        #expect(try PipelineTests.talk(rig.path(), req).hasPrefix("HTTP/1.1 451"), "the approval ended with the session")
        rig.proxy.clearGuardrailsConfig(for: rig.pid)
    }

    @Test func aStandInAndATokenTheSiteIssuedGoThrough() throws {
        let rig = try ProxyEgressPolicyTests.Rig(); defer { rig.stop() }
        let ip = try #require(Daemon.primaryIPv4())
        defer { rig.proxy.clearGuardrailsConfig(for: rig.pid) }
        Self.strict(rig, true)
        // The site issues the guest a token (a login inside the VM).
        let body = #"{"access_token":"\#(Self.real)"}"#
        let login = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        defer { login.stop() }
        let h = "\(ip):\(login.port)"
        _ = try PipelineTests.talk(rig.path(), "POST http://\(h)/login HTTP/1.1\r\nHost: \(h)\r\nContent-Length: 0\r\n\r\n")
        let api = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { api.stop() }
        let h2 = "\(ip):\(api.port)"
        #expect(try PipelineTests.talk(rig.path(), "GET http://\(h2)/me HTTP/1.1\r\nHost: \(h2)\r\nAuthorization: Bearer \(Self.real)\r\n\r\n")
                    .hasPrefix("HTTP/1.1 200"), "a token this site issued the guest goes back to it")
        // A Bromure stand-in (in the swap map): through.
        let fake = "ghp_" + String(repeating: "Zz9Yy8Xx7W", count: 4).prefix(36)
        rig.proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: String(fake), real: "unused", host: ip)]), for: rig.pid)
        #expect(try PipelineTests.talk(rig.path(), "GET http://\(h2)/s HTTP/1.1\r\nHost: \(h2)\r\nAuthorization: Bearer \(fake)\r\n\r\n")
                    .hasPrefix("HTTP/1.1 200"), "a stand-in isn't unmanaged")
        rig.proxy.swapper.clearMap(for: rig.pid)
    }

    /// Whether `token` now goes through to `ip` (the guard learned it),
    /// asked until it does or 5 s pass: a reply is learned once its
    /// connection closes.
    static func goesThrough(_ rig: ProxyEgressPolicyTests.Rig, _ ip: String, _ token: String, wait: Bool = true) throws -> Bool {
        let api = try RawUpstream(host: ip, reply: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { api.stop() }
        let h = "\(ip):\(api.port)"
        let deadline = Date().addingTimeInterval(wait ? 5 : 0)
        repeat {
            if try PipelineTests.talk(rig.path(), "GET http://\(h)/me HTTP/1.1\r\nHost: \(h)\r\nAuthorization: Bearer \(token)\r\n\r\n", ms: 300)
                .hasPrefix("HTTP/1.1 200") { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    /// The site's reply, through the proxy (a login inside the VM).
    static func issue(_ rig: ProxyEgressPolicyTests.Rig, _ ip: String, reply: String,
                      extra: String = "") throws -> RawUpstream {
        let login = try RawUpstream(host: ip, reply: reply)
        let h = "\(ip):\(login.port)"
        _ = try PipelineTests.talk(rig.path(), "POST http://\(h)/login HTTP/1.1\r\nHost: \(h)\r\n\(extra)Content-Length: 0\r\n\r\n", ms: 300)
        return login
    }

    static func token(_ seed: String) -> String { "ghp_" + String(String(repeating: seed, count: 8).prefix(36)) }

    /// gh auth login's reply, chunked (and asked for uncompressed): learned
    /// from the decoded body, as macOS's URLSession hands it.
    @Test func aChunkedReplysTokenIsLearnedAndTheReplyIsAskedUncompressed() throws {
        let rig = try ProxyEgressPolicyTests.Rig(); defer { rig.stop() }
        let ip = try #require(Daemon.primaryIPv4())
        defer { rig.proxy.clearGuardrailsConfig(for: rig.pid) }
        Self.strict(rig, true)
        let tok = Self.token("Ch1nk")
        let json = #"{"access_token":"\#(tok)","token_type":"bearer"}"#
        let cut = json.index(json.startIndex, offsetBy: 24)     // the token split across two chunks
        let (a, b) = (String(json[..<cut]), String(json[cut...]))
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            + String(a.utf8.count, radix: 16) + "\r\n" + a + "\r\n" + String(b.utf8.count, radix: 16) + "\r\n" + b + "\r\n0\r\n\r\n"
        let login = try Self.issue(rig, ip, reply: reply, extra: "Accept-Encoding: gzip, br\r\n")
        defer { login.stop() }
        let sent = login.received.withLockedValue { $0 }.lowercased()
        #expect(sent.contains("accept-encoding: identity") && !sent.contains("gzip"), "\(sent)")
        #expect(try Self.goesThrough(rig, ip, tok), "the chunked reply's token was learned")
    }

    @Test func aSetCookieIsLearned() throws {
        let rig = try ProxyEgressPolicyTests.Rig(); defer { rig.stop() }
        let ip = try #require(Daemon.primaryIPv4())
        defer { rig.proxy.clearGuardrailsConfig(for: rig.pid) }
        Self.strict(rig, true)
        let tok = Self.token("C00ki")
        let login = try Self.issue(rig, ip, reply: "HTTP/1.1 200 OK\r\nSet-Cookie: session=\(tok); Path=/; HttpOnly\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { login.stop() }
        #expect(try Self.goesThrough(rig, ip, tok))
    }

    /// Every final response is learned from, as macOS learns (a login
    /// redirect sets its cookie on a 302), past any 100 Continue; an encoded
    /// body isn't (nothing here decodes it) but its head is; and only the
    /// first 256 KiB.
    @Test func theFinalResponseIsLearnedWithinItsFirst256KiB() throws {
        let rig = try ProxyEgressPolicyTests.Rig(); defer { rig.stop() }
        let ip = try #require(Daemon.primaryIPv4())
        defer { rig.proxy.clearGuardrailsConfig(for: rig.pid) }
        Self.strict(rig, true)
        func form(_ body: String, status: String = "200 OK", extra: String = "") -> String {
            "HTTP/1.1 \(status)\r\nContent-Type: application/x-www-form-urlencoded\r\n\(extra)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        }
        var ups: [RawUpstream] = []
        defer { ups.forEach { $0.stop() } }
        let redirect = Self.token("R3dir"), refused = Self.token("D3n1d"), continued = Self.token("C0ntd")
        ups.append(try Self.issue(rig, ip, reply: "HTTP/1.1 302 Found\r\nLocation: /home\r\nSet-Cookie: s=\(redirect); Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
        ups.append(try Self.issue(rig, ip, reply: form("access_token=\(refused)", status: "401 Unauthorized")))
        ups.append(try Self.issue(rig, ip, reply: "HTTP/1.1 100 Continue\r\n\r\n" + form("access_token=\(continued)")))
        let encoded = Self.token("Enc0d"), encodedCookie = Self.token("EncCk")
        ups.append(try Self.issue(rig, ip, reply: form("access_token=\(encoded)", extra: "Content-Encoding: gzip\r\nSet-Cookie: e=\(encodedCookie)\r\n")))
        let pad = String(repeating: "x", count: 300 << 10)
        let early = Self.token("E4rly"), late = Self.token("L4te0")
        ups.append(try Self.issue(rig, ip, reply: form("access_token=\(early)&pad=\(pad)")))
        let l = try Self.issue(rig, ip, reply: form("pad=\(pad)&access_token=\(late)"))
        ups.append(l)
        #expect(try Self.goesThrough(rig, ip, redirect), "a 302's cookie")
        #expect(try Self.goesThrough(rig, ip, refused), "a 401's token, as macOS learns it")
        #expect(try Self.goesThrough(rig, ip, continued), "past a 100 Continue")
        #expect(try Self.goesThrough(rig, ip, encodedCookie), "an encoded reply's head")
        #expect(try Self.goesThrough(rig, ip, early), "within the first 256 KiB")
        #expect(try !Self.goesThrough(rig, ip, encoded, wait: false), "not from an encoded body")
        // Learned (or not) once the late connection ended: waited for, then
        // a moment for the proxy's side of the close.
        for _ in 0..<250 where l.closed.withLockedValue({ $0 }) == 0 { Thread.sleep(forTimeInterval: 0.02) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try !Self.goesThrough(rig, ip, late, wait: false), "past the cap")
    }

    /// A reply from a session that ended (the VM stopped, another started)
    /// teaches the new one nothing.
    @Test func aLateReplyFromAnOldSessionIsntLearned() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        var cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [])
        cfg.strictCredentials = true
        proxy.setGuardrailsConfig(cfg, for: pid)
        defer { proxy.clearGuardrailsConfig(for: pid) }
        let old = proxy.strictSession(of: pid)
        proxy.clearGuardrailsConfig(for: pid)              // the stop
        proxy.setGuardrailsConfig(cfg, for: pid)           // the next session
        func reply(_ t: String) -> Data { Data("HTTP/1.1 200 OK\r\nContent-Length: \(t.count + 13)\r\n\r\naccess_token=\(t)".utf8) }
        func refused(_ t: String) -> Bool {
            RequestReader.unmanagedAnswer(Data("GET / HTTP/1.1\r\nHost: api.example\r\nAuthorization: Bearer \(t)\r\n\r\n".utf8),
                                          proxy: proxy, profileID: pid, host: "api.example", session: proxy.strictSession(of: pid)) != nil
        }
        let stale = Self.token("St4le"), fresh = Self.token("Fr3sh")
        proxy.learnIssued(reply(stale), host: "api.example", profileID: pid, session: old)
        proxy.learnIssued(reply(fresh), host: "api.example", profileID: pid, session: proxy.strictSession(of: pid))
        #expect(refused(stale), "the old session's reply was dropped")
        #expect(!refused(fresh), "the current one's was learned")
    }

    /// Off for real once cleared; per workspace; the workspace's AWS key id
    /// and Bromure's subscription placeholders are never unmanaged.
    @Test func clearedWorkspacesAndExemptions() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let a = UUID(), b = UUID()
        var cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [])
        cfg.strictCredentials = true
        func refused(_ value: String, _ pid: UUID, header: String = "Authorization: Bearer") -> Bool {
            RequestReader.unmanagedAnswer(Data("GET / HTTP/1.1\r\nHost: api.example\r\n\(header) \(value)\r\n\r\n".utf8),
                                          proxy: proxy, profileID: pid, host: "api.example", session: proxy.strictSession(of: pid)) != nil
        }
        proxy.setGuardrailsConfig(cfg, for: a)
        defer { proxy.clearGuardrailsConfig(for: a); proxy.clearGuardrailsConfig(for: b) }
        #expect(refused(Self.real, a) && !refused(Self.real, b), "only the workspace that has it on")
        proxy.setGuardrailsConfig(cfg, for: b)
        let fp = UnmanagedCredentialGuard.fingerprint(Self.real)
        UnmanagedCredentialGuard.shared.allowForSession([fp], profileID: a)
        #expect(!refused(Self.real, a) && refused(Self.real, b), "an approval is the workspace's own")
        // The workspace's AWS key id (the guest holds it); another isn't.
        let akid = "AKIA" + "IOSFODNN7EXAMPL1"
        proxy.awsCreds.setCredentials(AWSCredentials(accessKeyID: akid, secretAccessKey: "s", region: "us-east-1"), for: a)
        defer { proxy.awsCreds.clearCredentials(for: a) }
        let sig = "Authorization: AWS4-HMAC-SHA256"
        #expect(!refused("Credential=\(akid)/20261107/us-east-1/s3/aws4_request, Signature=00", a, header: sig))
        #expect(refused("Credential=AKI" + "AZZZZZZZZZZZZZZZ9/20261107/us-east-1/s3/aws4_request, Signature=00", a, header: sig))
        // A subscription placeholder (the live proxy's store: other suites
        // build proxies too, so the one registered in is re-read).
        let bogus = "sk-" + "ant-api03-" + String(repeating: "bOgUs", count: 12)
        #expect(refused(bogus, a), "unknown: unmanaged")
        var exempt = false
        for _ in 0..<5 where !exempt {
            guard let store = SubscriptionProviders.claude?()?.0 else { break }
            store.registerBogusKey(bogus, for: a)
            exempt = !refused(bogus, a)
            store.unregisterBogusKeys(for: a)
        }
        #expect(exempt, "a placeholder Bromure handed the guest isn't unmanaged")
        // Cleared (the VM stopped): off, and its approvals gone.
        proxy.clearGuardrailsConfig(for: a)
        #expect(!UnmanagedCredentialGuard.shared.isEnabled(for: a) && !refused(Self.real, a), "off")
        proxy.setGuardrailsConfig(cfg, for: a)
        #expect(refused(Self.real, a), "on again: the approval didn't survive the clear")
    }

    /// The transparent path (a guest that ignores the proxy) runs the same chain.
    @Test func theTransparentPathRefusesToo() throws {
        let rig = try TransparentInterceptionTests.Rig(); defer { rig.stop() }
        var cfg = GuardrailsConfig(kubernetes: .off, kubeHosts: [])
        cfg.strictCredentials = true
        rig.proxy.setGuardrailsConfig(cfg, for: rig.pid)
        defer { rig.proxy.clearGuardrailsConfig(for: rig.pid) }
        let (guest, app) = try GuestEnd.pair(); defer { close(guest) }
        GuestEnd.send(guest, "GET /x HTTP/1.1\r\nHost: \(rig.ip)\r\nAuthorization: Bearer \(Self.real)\r\n\r\n")
        rig.proxy.acceptTransparentFlow(appFD: app, profileID: rig.pid, destIP: "198.51.100.9", destPort: 80)
        let out = GuestEnd.readAll(guest) ?? "TIMEOUT"
        #expect(out.hasPrefix("HTTP/1.1 451") && out.contains("strict credential mode"), "\(out.prefix(160))")
        #expect(rig.upstream.requests.withLockedValue { $0 }.isEmpty, "nothing went upstream")
    }
}
