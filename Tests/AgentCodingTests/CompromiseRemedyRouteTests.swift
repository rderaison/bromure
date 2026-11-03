import Foundation
import Testing
@testable import bromure_ac

/// A workspace marked compromised (the red triangle) only offered "Wipe and
/// Launch" from Start, and nothing from a fat client when that prompt went
/// unanswered. The sidebar now offers "Wipe and Restore…" and "Clear
/// Compromised Mark…" (a false alarm), which a fat client sends to its
/// server as POST /profiles/{id}/compromised.
@Suite("Compromised workspace: wipe or clear from the sidebar")
struct CompromiseRemedyRouteTests {
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

    @Test("POST /profiles/{id}/compromised reaches the handler, with the action; a refusal is a 409 with its reason")
    func route() async throws {
        let path = NSTemporaryDirectory() + "cr-\(UUID().uuidString.prefix(6)).sock"
        let server = ACAutomationServer(unixSocketPath: path)
        let seen = NSMutableArray()
        server.onCompromise = { key, action in
            seen.add("\(key) \(action)")
            return action == "clear" ? ["ok": true] : ["ok": false, "error": "Shut the workspace down first"]
        }
        server.start()
        defer { server.stop(); unlink(path) }
        try await Task.sleep(for: .milliseconds(200))
        let id = UUID().uuidString
        let cleared = try await Task.detached { try post(path, "/profiles/\(id)/compromised", ["action": "clear"]) }.value
        #expect(cleared.0 == 200 && cleared.1["ok"] as? Bool == true)
        let refused = try await Task.detached { try post(path, "/profiles/\(id)/compromised", ["action": "wipe"]) }.value
        #expect(refused.0 == 409 && (refused.1["error"] as? String)?.hasPrefix("Shut the workspace down") == true)
        #expect(seen as? [String] == ["\(id) clear", "\(id) wipe"])
    }

    @Test("the confirmation names the workspace and says what each choice keeps")
    @MainActor func prompts() {
        let wipe = ACAppDelegate.compromiseActionParts(.wipe, name: "ark-ws")
        #expect(wipe.title.contains("ark-ws") && wipe.message.contains("project folders"))
        let clear = ACAppDelegate.compromiseActionParts(.clear, name: "ark-ws")
        #expect(clear.title.contains("ark-ws") && clear.message.contains("false alarm"))
    }
}
