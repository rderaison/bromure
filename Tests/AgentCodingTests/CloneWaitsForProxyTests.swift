import Foundation
import Testing
@testable import bromure_ac

/// A workspace answers exec a few seconds before agentd's proxy bridge
/// listens; a clone fired on the first answer (an automation on a freshly
/// booted workspace) failed to connect. The clone now waits for the proxy
/// its environment names.
@Suite("Clone waits for the guest proxy")
struct CloneWaitsForProxyTests {
    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A local repository to clone (no network: the wait is what's tested).
    private func sourceRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "cd \(q(dir.path)) && git init -q && git -c user.email=t@t -c user.name=t "
                       + "commit -q --allow-empty -m init"]
        try p.run(); p.waitUntilExit()
        return dir
    }

    /// Runs the clone command under bash with `env`; (exit status, seconds).
    private func runClone(from src: URL, env: [String: String]) throws -> (Int32, TimeInterval) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-dst-\(UUID().uuidString)/repo").path
        let cmd = CodingTaskEngine.cloneRepoCommand(quotedPath: q(dest), quotedURL: q(src.path))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        var e = ProcessInfo.processInfo.environment
        for k in ["HTTPS_PROXY", "https_proxy"] { e.removeValue(forKey: k) }
        e.merge(env) { $1 }
        p.environment = e
        p.standardError = Pipe()
        let t0 = Date()
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, Date().timeIntervalSince(t0))
    }

    @Test("a proxy that comes up late is waited for, then the clone runs")
    func waitsForLateProxy() throws {
        let src = try sourceRepo()
        let port = Int.random(in: 41000...48000)
        // Listens one second from now, for a few seconds.
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        listener.arguments = ["python3", "-I", "-c",
                              "import socket,time;time.sleep(1);s=socket.socket();"
                              + "s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);"
                              + "s.bind(('127.0.0.1',\(port)));s.listen(8);time.sleep(6)"]
        guard (try? listener.run()) != nil else { return }   // no python3 here
        defer { listener.terminate() }
        let (status, took) = try runClone(from: src, env: ["HTTPS_PROXY": "http://127.0.0.1:\(port)"])
        #expect(status == 0)
        #expect(took >= 0.8)
        #expect(took < 10)
    }

    @Test("no proxy named: no wait")
    func noProxyNoWait() throws {
        let src = try sourceRepo()
        let (status, took) = try runClone(from: src, env: [:])
        #expect(status == 0)
        #expect(took < 3)
    }

    @Test("an existing repository isn't cloned again, and isn't waited for")
    func existingRepoSkipsWait() throws {
        let src = try sourceRepo()
        let cmd = CodingTaskEngine.cloneRepoCommand(quotedPath: q(src.path), quotedURL: q("/nonexistent"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        // A port nothing listens on: a wait here would take 30 s.
        p.environment = ["PATH": "/usr/bin:/bin", "HTTPS_PROXY": "http://127.0.0.1:1"]
        let t0 = Date()
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(Date().timeIntervalSince(t0) < 3)
    }
}
