import Foundation
import Glibc
import Testing
@testable import ACLinux

/// The P2P device channel (shared DeviceChannel over swift-corelibs'
/// URLSessionWebSocketTask) against a server with bromure.io's presence
/// rules: it pings, and terminates a client that doesn't answer. A server
/// that stays "offline" on bromure.io while its daemon runs is this failing.
@Suite("Device channel presence", .serialized)
struct DeviceChannelPresenceTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ws_presence_server.py").path

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func theChannelAnswersTheServersPingsAndStays() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wsp-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // ChildProcess, not Foundation's Process: on Linux that one hands the
        // child a blocked SIGTERM (terminate() does nothing), and a server
        // left running holds `swift test`'s output pipe open: the run hangs.
        let server = try ChildProcess(name: "ws-presence", executable: "/usr/bin/python3",
                                      arguments: ["-I", Self.fixture, dir + "/port", dir + "/events", "1"],
                                      logPath: dir + "/server.log")
        try server.start()
        defer { _ = server.signal(SIGKILL) }
        var port = ""
        for _ in 0..<100 where port.isEmpty {
            port = (try? String(contentsOfFile: dir + "/port", encoding: .utf8)) ?? ""
            if port.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!port.isEmpty, "the test server didn't start")

        let channel = DeviceChannel(endpoint: try ControlPlaneEndpoint(base: "http://127.0.0.1:\(port)/api"), token: "t0k")
        channel.connect()
        try await Task.sleep(for: .seconds(6))
        let events = ((try? String(contentsOfFile: dir + "/events", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        channel.close()
        #expect(events.first == "open Bearer t0k", "the bearer on the upgrade: \(events.prefix(3))")
        // bromure.io reads this server's release from the upgrade's User-Agent.
        #expect(events.dropFirst().first == "agent \(ControlPlaneClient.userAgent)", "\(events.prefix(3))")
        let pings = events.filter { $0 == "ping" }.count, pongs = events.filter { $0 == "pong" }.count
        #expect(pings >= 4, "\(events)")
        #expect(pongs >= pings - 1, "every server ping answered (one may be in flight): \(pings) pings, \(pongs) pongs")
        #expect(!events.contains("terminate"), "terminated for a missed pong: \(events)")
        #expect(events.filter { $0.hasPrefix("open") }.count == 1, "one connection, not a reconnect loop: \(events)")
    }
}
