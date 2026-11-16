import Foundation
import Testing
@testable import bromure_ac

/// "Web browser loses internet connection?": the remote workspace's browser
/// pane reaches the remote subnet through the host's SOCKS forwarder; its
/// accept loop stopped on any error but EINTR (a peer resetting
/// mid-handshake, a moment's fd shortage) -- over a listener left open, so
/// every later connection queued unanswered: ERR_PROXY_CONNECTION_FAILED
/// until the app restarted.
@Suite("Fat-client forwarders: accept loops survive transient failures")
struct FatForwardAcceptTests {
    @Test("Only a closed listener ends the loop")
    func policy() {
        #expect(FatForward.acceptFailure(ECONNABORTED) == .retry)
        #expect(FatForward.acceptFailure(EINTR) == .retry)
        #expect(FatForward.acceptFailure(EMFILE) == .backoff)
        #expect(FatForward.acceptFailure(ENFILE) == .backoff)
        #expect(FatForward.acceptFailure(ENOBUFS) == .backoff)
        #expect(FatForward.acceptFailure(EBADF) == .stop)
        #expect(FatForward.acceptFailure(EINVAL) == .stop)
    }

    @Test("A real listener: connections are taken; closing it ends the loop")
    func realListener() async throws {
        let (lfd, port) = FatForward.listenEphemeral()
        try #require(lfd >= 0)
        let accepted = Task.detached { () -> Int in
            var n = 0
            while let c = FatForward.acceptConnection(lfd, label: "test") { n += 1; Darwin.close(c) }
            return n
        }
        for _ in 0..<3 {
            let c = socket(AF_INET, SOCK_STREAM, 0)
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = in_port_t(UInt16(port).bigEndian)
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(c, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            #expect(rc == 0)
            Darwin.close(c)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        // shutdown wakes the parked accept; close then makes it EBADF/EINVAL.
        Darwin.shutdown(lfd, SHUT_RDWR)
        Darwin.close(lfd)
        #expect(await accepted.value == 3)
    }

    @Test("The loops use the shared accept; the handshake has a deadline; the pane can restart its browser")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func src(_ f: String) throws -> String {
            try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/" + f), encoding: .utf8)
        }
        let fwd = try src("FatClientForward.swift")
        #expect(!fwd.contains("if cfd < 0 { if errno == EINTR { continue }; break }"))
        #expect(fwd.components(separatedBy: "acceptConnection(lfd").count - 1 == 3)
        #expect(fwd.contains("setReadTimeout(cfd, seconds: 15)"))
        #expect(fwd.contains("setReadTimeout(cfd, seconds: 0)\n        splice(cfd, rfd)"))
        #expect(try src("BrowserPane.swift").contains("if let restart = model.onRestart {"))
        #expect(try src("UnifiedSessionWindow.swift").contains("m.onRestart = { [weak self] in self?.rebootBrowser(for: id) }"))
        #expect(try src("FatClientController.swift").contains("m.onRestart = { [weak self] in self?.rebootBrowser(for: id) }"))
    }
}
