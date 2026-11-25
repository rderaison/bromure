import Crypto
import Foundation
import Glibc
import Testing
@testable import ACLinux

/// The ws-relay listener (shared P2P/WSRelay.swift, the web client's way in)
/// on Linux, where it runs over swift-corelibs' URLSessionWebSocketTask and
/// Glibc sockets: a stand-in for bromure.io's relay and for the server's SSH
/// port (Fixtures/ws_relay_server.py), on loopback. What the dialer sends
/// through the relay must reach the SSH port, and its answer must come back,
/// verbatim and in order; either end closing must close the other.
/// (macOS: Tests/AgentCodingTests/WSRelayTests.swift, over Network.framework.)
@Suite("ws-relay listener", .serialized)
struct WSRelayLinuxTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ws_relay_server.py").path
    static let hasPython = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

    /// The fixture, running: its two ports and its event log.
    struct World {
        let dir: String
        let relayPort: Int
        let sshdPort: Int

        var events: [String] {
            ((try? String(contentsOfFile: dir + "/events", encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        /// The events once `match` holds, or nil after `seconds`.
        func wait(_ seconds: Double = 10, for match: ([String]) -> Bool) async -> [String]? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let e = events
                if match(e) { return e }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return nil
        }

        func join(_ id: String, sshPort: Int? = nil) throws {
            WSRelayListener.join(connectionId: id,
                                 endpoint: try ControlPlaneEndpoint(base: "http://127.0.0.1:\(relayPort)"),
                                 bearer: "tok", sshPort: sshPort ?? sshdPort)
        }
    }

    /// Runs `body` against a fresh fixture, stopped afterwards.
    static func withWorld(_ body: (World) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wsr-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // ChildProcess, not Foundation's Process (see DeviceChannelPresenceTests).
        let server = try ChildProcess(name: "ws-relay", executable: "/usr/bin/python3",
                                      arguments: ["-I", fixture, dir + "/ports", dir + "/events"],
                                      logPath: dir + "/server.log")
        try server.start()
        defer { _ = server.signal(SIGKILL) }
        var ports: [Int] = []
        for _ in 0..<100 where ports.count != 2 {
            ports = ((try? String(contentsOfFile: dir + "/ports", encoding: .utf8)) ?? "")
                .split(separator: " ").compactMap { Int($0) }
            if ports.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard ports.count == 2 else {
            Issue.record("the test relay didn't start: \((try? String(contentsOfFile: dir + "/server.log", encoding: .utf8)) ?? "")")
            return
        }
        try await body(World(dir: dir, relayPort: ports[0], sshdPort: ports[1]))
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    /// The fixture's pattern(n).
    static func pattern(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) }) }
    static func id(_ kind: String) -> String { "\(kind)-\(UUID().uuidString)" }
    /// A loopback port nothing listens on.
    static func closedPort() -> Int {
        let (fd, port) = FatForward.listenEphemeral(bindAll: false)
        if fd >= 0 { close(fd) }
        return port
    }

    @Test("refuses malformed connection ids")
    func rejectsMalformed() {
        for id in ["", "..", "a/b", "../../devices", "x?y", "a b"] {
            #expect(!WSRelayListener.isValidConnectionId(id))
        }
        #expect(WSRelayListener.isValidConnectionId("3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
    }

    @Test("splices relay bytes to the local sshd and back", .enabled(if: hasPython))
    func splices() async throws {
        try await Self.withWorld { w in
            let id = Self.id("banner")
            try w.join(id)
            let want = "recv \(id) 19 \(Self.sha(Data("echo:SSH-2.0-test\r\n".utf8)))"
            let events = await w.wait { $0.contains(want) }
            #expect(events != nil, "the sshd's answer never came back through the relay: \(w.events)")
            // The join itself: the grant's relay path, our bearer on the upgrade.
            // (After the sshd connection: no slot is taken at the relay before that.)
            #expect(w.events.prefix(2) == ["sshd-open", "open \(id) /v1/connections/\(id)/relay Bearer tok"],
                    "\(w.events.prefix(2))")
        }
    }

    @Test("a megabyte each way arrives whole and in order", .enabled(if: hasPython))
    func bulk() async throws {
        try await Self.withWorld { w in
            let id = Self.id("bulk")
            try w.join(id)
            let n = 1 << 20
            let want = "recv \(id) \(n + 5) \(Self.sha(Data("echo:".utf8) + Self.pattern(n)))"
            let events = await w.wait(30) { $0.contains(want) }
            #expect(events != nil, "last: \(w.events.suffix(2))")
        }
    }

    @Test("the relay closing closes the sshd connection and frees the connection's slot", .enabled(if: hasPython))
    func relayCloses() async throws {
        try await Self.withWorld { w in
            let id = Self.id("relay-closes")
            try w.join(id)
            let closed = await w.wait { $0.contains("sshd-eof") }
            #expect(closed != nil, "the sshd connection stayed open: \(w.events)")
            // Joining again is possible only once the first one is forgotten;
            // the listener forgets it right after closing the sshd socket.
            var again: [String]?
            for _ in 0..<40 where again == nil {
                try w.join(id)
                again = await w.wait(0.25) { $0.filter { $0.hasPrefix("open \(id) ") }.count == 2 }
            }
            #expect(again != nil, "the same connection couldn't be joined again: \(w.events)")
        }
    }

    @Test("the sshd closing closes the relay", .enabled(if: hasPython))
    func sshdCloses() async throws {
        try await Self.withWorld { w in
            let id = Self.id("sshd-closes")
            try w.join(id)
            let echoed = "recv \(id) 8 \(Self.sha(Data("echo:bye".utf8)))"
            let back = await w.wait { $0.contains(echoed) }
            #expect(back != nil, "\(w.events)")
            let ended = await w.wait { $0.contains("close \(id) 1000") || $0.contains("eof \(id)") }
            #expect(ended != nil, "the relay was left open after the sshd closed: \(w.events)")
        }
    }

    @Test("a text frame ends the session", .enabled(if: hasPython))
    func textFrame() async throws {
        try await Self.withWorld { w in
            let id = Self.id("text")
            try w.join(id)
            let closed = await w.wait { $0.contains("sshd-eof") }
            #expect(closed != nil, "the sshd connection stayed open: \(w.events)")
            let ended = await w.wait { $0.contains("close \(id) 1000") || $0.contains("eof \(id)") }
            #expect(ended != nil, "\(w.events)")
        }
    }

    @Test("no relay slot is taken when the sshd can't be reached", .enabled(if: hasPython))
    func sshdUnreachable() async throws {
        try await Self.withWorld { w in
            let id = Self.id("banner")
            try w.join(id, sshPort: Self.closedPort())
            let joined = await w.wait(1) { !$0.isEmpty }
            #expect(joined == nil, "the relay was joined with no sshd behind it: \(w.events)")
            // And the failed attempt isn't remembered as a live connection.
            try w.join(id)
            let opened = await w.wait { $0.contains { $0.hasPrefix("open \(id) ") } }
            #expect(opened != nil, "\(w.events)")
        }
    }

    /// A session that says nothing for a while (an idle terminal). Slow, so
    /// only with BROMURE_WSRELAY_IDLE_SECONDS set (to the silence's length).
    @Test("an idle session stays up",
          .enabled(if: hasPython && ProcessInfo.processInfo.environment["BROMURE_WSRELAY_IDLE_SECONDS"] != nil))
    func idle() async throws {
        let seconds = Int(ProcessInfo.processInfo.environment["BROMURE_WSRELAY_IDLE_SECONDS"] ?? "") ?? 75
        try await Self.withWorld { w in
            let id = Self.id("idle-\(seconds)")
            try w.join(id)
            let want = "recv \(id) 7 \(Self.sha(Data("echo:ab".utf8)))"
            let events = await w.wait(Double(seconds) + 20) { $0.contains(want) }
            #expect(events != nil, "what came after \(seconds) s of silence was lost: \(w.events)")
        }
    }
}
