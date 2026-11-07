import Foundation
import Testing
@testable import bromure_ac

@Suite("Pinned upstream dialer")
struct UpstreamPinningTests {
    func rewrite(_ head: String, _ target: String) -> String {
        String(decoding: PinnedUpstreamDialer.originForm(Data(head.utf8), target: target), as: UTF8.self)
    }

    @Test("Plain HTTP reaches the origin in origin-form, one request per connection")
    func originForm() {
        let out = rewrite("POST http://10.1.2.3:8000/mcp?x=1 HTTP/1.1\r\nHost: 10.1.2.3:8000\r\nProxy-Connection: keep-alive\r\n"
                          + "Connection: keep-alive\r\nContent-Length: 2\r\n\r\n{}", "http://10.1.2.3:8000/mcp?x=1")
        #expect(out.hasPrefix("POST /mcp?x=1 HTTP/1.1\r\n"))
        #expect(out.contains("Host: 10.1.2.3:8000\r\n") && out.contains("Content-Length: 2\r\n"))
        #expect(!out.lowercased().contains("proxy-connection") && !out.contains("keep-alive"))
        #expect(out.hasSuffix("Connection: close\r\n\r\n{}"))
        #expect(rewrite("GET http://h HTTP/1.1\r\nHost: h\r\n\r\n", "http://h").hasPrefix("GET / HTTP/1.1\r\n"))
        #expect(rewrite("GET http://h?q=1 HTTP/1.1\r\nHost: h\r\n\r\n", "http://h?q=1").hasPrefix("GET /?q=1 HTTP/1.1\r\n"))
    }

    /// A port nothing listens on, on 127.0.0.1 (bound, then closed).
    private func closedPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var sa = sockaddr_in(); sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        close(fd)
        return Int(UInt16(bigEndian: sa.sin_port))
    }

    /// e2e 27.1 failed on a bare "502, Content-Length: 0": the pinned dialer
    /// couldn't reach the upstream (it had gone silent) and said nothing, and
    /// a refused CONNECT surfaced only as "CFNetwork error 310". Both now say
    /// which address failed and why.
    @Test("a failed pinned connect says which address failed and why; the 502 and CFNetwork 310 carry it")
    func failuresSayWhy() async throws {
        let port = closedPort()
        do {
            _ = try UpstreamPinning.connect([.v4(UInt32(0x7F000001))], port: port)
            Issue.record("connected to a closed port")
        } catch MitmError.upstreamFailed(let why) {
            #expect(why.contains("127.0.0.1"), "\(why)")
            #expect(why.lowercased().contains("refused"), "\(why)")
        }
        #expect(UpstreamPinning.connectFailure([], port: 80, failures: []).contains("no validated address"))

        // Through the dialer, as URLSession uses it for plain HTTP.
        let dialer = try PinnedUpstreamDialer(host: "dead.test", port: port, addresses: [.v4(UInt32(0x7F000001))])
        defer { dialer.shutdownListener() }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = dialer.proxyDictionary
        var req = URLRequest(url: URL(string: "http://dead.test:\(port)/")!)
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 502)
        let header = http.value(forHTTPHeaderField: "X-Bromure-Upstream-Error") ?? ""
        #expect(header.lowercased().contains("refused"), "\(header)")
        #expect(String(decoding: data, as: UTF8.self).contains("could not connect to dead.test"))
        // Noted on THIS dialer, for the proxy's own 502 (URLSession reports
        // it as CFNetwork 306/310).
        let noted = try #require(dialer.lastFailure)
        #expect(noted.hasPrefix("dead.test:\(port): "))
        let err = NSError(domain: kCFErrorDomainCFNetwork as String, code: 310)
        let d = describeUpstreamError(err, host: "dead.test", dialerFailure: noted)
        #expect(d.reason.contains(noted), "\(d.reason)")
        #expect(PinnedUpstreamDialer.headerSafe("a\r\nb") == "a  b")
    }

    /// A local origin answering one request (enough for a successful dial).
    private func origin() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var sa = sockaddr_in(); sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        Thread.detachNewThread {
            let c = accept(fd, nil, nil)
            var buf = [UInt8](repeating: 0, count: 4096); _ = read(c, &buf, buf.count)
            let r = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
            _ = r.withCString { write(c, $0, strlen($0)) }
            close(c); close(fd)
        }
        return Int(UInt16(bigEndian: sa.sin_port))
    }

    private func get(_ dialer: PinnedUpstreamDialer, _ url: String) async throws -> Int {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = dialer.proxyDictionary
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 10
        let (_, resp) = try await URLSession(configuration: cfg).data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// Finding: the reason store was process-wide, keyed by host:port and
    /// never cleared, so a later request -- or another workspace's -- read an
    /// old or unrelated failure (with that request's resolved addresses) in
    /// its 502. Each request's dialer keeps its own, cleared by a success.
    @Test("a dialer's failure is its own request's, and a successful dial clears it")
    func failureIsPerRequest() async throws {
        let dead = closedPort()
        let failing = try PinnedUpstreamDialer(host: "same.test", port: dead, addresses: [.v4(UInt32(0x7F000001))])
        defer { failing.shutdownListener() }
        #expect(try await get(failing, "http://same.test:\(dead)/") == 502)
        #expect(failing.lastFailure != nil)
        // Another request to the same host:port, its own dialer: nothing stale.
        let other = try PinnedUpstreamDialer(host: "same.test", port: dead, addresses: [.v4(UInt32(0x7F000001))])
        defer { other.shutdownListener() }
        #expect(other.lastFailure == nil)
        // The same dialer dialing successfully forgets the earlier failure.
        let live = origin()
        let reused = try PinnedUpstreamDialer(host: "ok.test", port: live, addresses: [.v4(UInt32(0x7F000001))],
                                              others: { _, _ in [.v4(UInt32(0x7F000001))] })
        defer { reused.shutdownListener() }
        #expect(try await get(reused, "http://gone.test:\(dead)/") == 502)
        #expect(reused.lastFailure?.hasPrefix("gone.test:") == true)
        #expect(try await get(reused, "http://ok.test:\(live)/") == 200)
        #expect(reused.lastFailure == nil)
        // No dialer reason: the generic one, never another request's.
        let d = describeUpstreamError(NSError(domain: kCFErrorDomainCFNetwork as String, code: 310), host: "same.test")
        #expect(d.reason == "the host running Bromure AC could not connect to same.test")
    }
}
