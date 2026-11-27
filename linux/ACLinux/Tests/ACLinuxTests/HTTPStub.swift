import Foundation
import Glibc
@testable import ACLinux

/// Fixtures/http_stub_server.py, running: a stand-in for bromure.io's device
/// sign-out and for a custom inference server's model list, on loopback.
final class HTTPStub: @unchecked Sendable {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/http_stub_server.py").path
    static let available = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

    let dir: String
    let port: Int
    private let server: ChildProcess

    /// Starts it; nil when it didn't come up.
    init?() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // ChildProcess, not Foundation's Process (see DeviceChannelPresenceTests).
        server = try ChildProcess(name: "http-stub", executable: "/usr/bin/python3",
                                  arguments: ["-I", Self.fixture, dir + "/port", dir + "/events"],
                                  logPath: dir + "/server.log")
        try server.start()
        var found: Int?
        for _ in 0..<100 where found == nil {
            found = Int((try? String(contentsOfFile: dir + "/port", encoding: .utf8)) ?? "")
            if found == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard let found else {
            _ = server.signal(SIGKILL)
            try? FileManager.default.removeItem(atPath: dir)
            return nil
        }
        port = found
    }

    func stop() {
        _ = server.signal(SIGKILL)
        try? FileManager.default.removeItem(atPath: dir)
    }

    var base: String { "http://127.0.0.1:\(port)" }

    /// The requests it got, one a line.
    var events: [String] {
        ((try? String(contentsOfFile: dir + "/events", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}
