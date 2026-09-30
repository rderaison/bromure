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
}
