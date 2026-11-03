import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Register hides a proxy-down failure behind a generic
/// retry". A Register click refused before a run began (no proxy) answered
/// 409 "couldn't start registration (one may be in flight)" — the in-flight
/// body — and the fat client ignored the body for "You can try again", which
/// can't succeed until the proxy is up.
@Suite("Register says why the host refused to start a sign-in")
struct RegisterRefusalTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    /// One request over the control socket; the status code and JSON body.
    private func post(_ socketPath: String, _ path: String, _ body: [String: Any]) throws -> (Int, [String: Any]) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(ok == 0)
        let json = try JSONSerialization.data(withJSONObject: body)
        let head = "POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        let req = Data(head.utf8) + json
        _ = req.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: reply, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
        let bodyText = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any] ?? [:]
        return (status, obj)
    }

    @Test("POST /subscriptions/register: a refusal is a 409 carrying the host's reason; a start is a 202 with the run id")
    func route() async throws {
        let path = NSTemporaryDirectory() + "rr-\(UUID().uuidString.prefix(6)).sock"
        let server = ACAutomationServer(unixSocketPath: path)
        let proxyDown = "The Bromure proxy isn't running, so the sign-in can't be captured."
        server.onBeginRegistration = { provider, _ in
            guard provider == "claude" else { return proxyDown }
            MainActor.assumeIsolated { _ = RemoteRegistrationBroker.shared.begin(provider: "Claude") }
            return nil
        }
        server.start()
        defer { server.stop(); unlink(path) }
        try await Task.sleep(for: .milliseconds(200))
        let refused = try await Task.detached { try post(path, "/subscriptions/register", ["provider": "codex"]) }.value
        #expect(refused.0 == 409)
        #expect(refused.1["error"] as? String == proxyDown)
        #expect(refused.1["registration"] == nil)
        let started = try await Task.detached { try post(path, "/subscriptions/register", ["provider": "claude"]) }.value
        #expect(started.0 == 202 && started.1["ok"] as? Bool == true)
        #expect((started.1["registration"] as? String).flatMap(UUID.init(uuidString:)) != nil)
        await MainActor.run { RemoteRegistrationBroker.shared.finish(success: false) }
    }

    @Test("the host hands back the synchronous refusal; the client shows the reply's reason")
    func wiring() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let begin = try #require(ac.range(of: "server.onBeginRegistration = { [weak self] provider, profileID in"))
        let body = ac[begin.upperBound...].prefix(2200)
        #expect(body.contains("if case .finished(false, let message) = event { refused = message }"))
        // Only the synchronous refusal: the host notice for an older client stays.
        #expect(body.contains("self.claudeRegistration?.onEvent = nil"))
        #expect(body.contains("return refused ?? RemoteRegistrationBroker.shared.ended?.message"))
        let server = try Self.src("Sources/AgentCoding/AutomationServer.swift")
        #expect(!server.contains("one may be in flight"))
        let fc = try Self.src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("let why = (resp?.json[\"error\"] as? String).flatMap { $0.isEmpty ? nil : $0 }"))
    }
}
