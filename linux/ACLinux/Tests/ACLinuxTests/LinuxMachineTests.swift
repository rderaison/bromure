import Foundation
import Testing
@testable import ACLinux

/// The control connection as the blocking fd the shared machine-link code
/// works on (ControlResponse.descriptor), and the daemon's /machines routes
/// and /state lines over MachineLinkHub.
@Suite("Attached machines on the daemon", .serialized)
struct LinuxMachineTests {
    /// A control server answering every request with `respond`.
    static func server(_ dir: String, _ respond: @escaping @Sendable (ControlRequest) -> ControlResponse) async throws -> (ControlServer, String) {
        let path = dir + "/c.sock"
        let s = try await ControlServer.start(path: path) { respond($0) }
        return (s, path)
    }

    static func dial(_ path: String) -> Int32? { VsockFDListenerTests.dial(path) }

    static func say(_ fd: Int32, _ s: String) { _ = Array(s.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }

    final class Flag: @unchecked Sendable {
        let lock = NSLock(); var value = false; var count = 0
        func set() { lock.lock(); value = true; lock.unlock() }
        func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A body that answers in full and closes: the client reading to EOF
    /// gets the reply and the close (nothing waits on Content-Length).
    @Test func aDescriptorBodysReplyEndsWithTheClose() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let (srv, path) = try await Self.server(dir) { _ in
            .descriptor(head: "") { fd in
                LinuxMachineTests.say(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
                close(fd)
            }
        }
        let fd = try #require(Self.dial(path)); defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Self.say(fd, "GET /x HTTP/1.1\r\n\r\n")
        var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { #expect(n == 0, "EOF, not a timeout"); break }; out.append(contentsOf: buf[0..<n]) }
        #expect(String(decoding: out, as: UTF8.self).hasSuffix("\r\n\r\nhi"))
        await srv.close()
    }

    /// The client gone for good: the pair closes too, so a body that
    /// ignores EOF and keeps writing (a machine-side stream) finds out.
    @Test func aClientsCloseEndsABodyThatIgnoresEOF() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let ended = Flag()
        let (srv, path) = try await Self.server(dir) { _ in
            .descriptor(head: "") { fd in
                let until = Date().addingTimeInterval(10)
                while Date() < until {
                    var b: UInt8 = 120
                    if Glibc.send(fd, &b, 1, Int32(MSG_NOSIGNAL)) < 0 { ended.set(); break }
                    usleep(10_000)
                }
                close(fd)
            }
        }
        let fd = try #require(Self.dial(path))
        Self.say(fd, "GET /stream HTTP/1.1\r\n\r\n")
        var b: UInt8 = 0
        _ = read(fd, &b, 1)          // the stream is flowing
        close(fd)
        let until = Date().addingTimeInterval(5)
        while !ended.isSet && Date() < until { usleep(20_000) }
        #expect(ended.isSet, "the body's writes fail once the client is gone")
        await srv.close()
    }

    /// A client that doesn't read: the bridge stops reading the body, whose
    /// writes then wait, rather than everything piling up in the daemon.
    @Test func aSlowClientHoldsTheBodyBack() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let written = Flag(), done = Flag()
        let (srv, path) = try await Self.server(dir) { _ in
            .descriptor(head: "") { fd in
                let chunk = [UInt8](repeating: 65, count: 65536)
                var tv = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                for _ in 0..<1024 {           // 64 MiB at most
                    let n = chunk.withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                    if n <= 0 { break }
                    written.add(n)
                }
                done.set()
                close(fd)
            }
        }
        let fd = try #require(Self.dial(path)); defer { close(fd) }
        Self.say(fd, "GET /flood HTTP/1.1\r\n\r\n")
        // Never read: the body is held back, its last send times out.
        let until = Date().addingTimeInterval(15)
        while !done.isSet && Date() < until { usleep(50_000) }
        #expect(done.isSet)
        #expect(written.total < 24 << 20, "held back at \(written.total) bytes, not the whole 64 MiB")
        await srv.close()
    }

    static func request(_ method: String, _ path: String, _ body: [String: Any] = [:]) -> ControlRequest {
        ControlRequest(method: method, path: path, body: JSONValue(foundation: body) ?? .object([:]))
    }

    @Test func machineRoutesRefuseWhatTheyShould() async throws {
        let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A machine can't take the id of a workspace or VM of this server.
        let taken = await d.machineRoute(Self.request("POST", "/machines/link", ["id": rec.id, "name": "x"]), "/machines/link")
        #expect(taken?.status == 403)
        #expect(taken?.body["error"]?.stringValue?.contains("belongs to a workspace") == true)
        #expect(await d.machineRoute(Self.request("POST", "/machines/link"), "/machines/link")?.status == 400)
        #expect(await d.machineRoute(Self.request("POST", "/machines/approve", ["id": UUID().uuidString]), "/machines/approve")?.status == 400)
        #expect(await d.machineRoute(Self.request("POST", "/machines/approve", ["id": UUID().uuidString, "allow": true]),
                                     "/machines/approve")?.status == 404, "no such machine")
        // Not a machine's: the router goes on.
        #expect(await d.machineRoute(Self.request("GET", "/vms/\(UUID().uuidString)"), "/vms/x") == nil)
        #expect(await d.machineRoute(Self.request("POST", "/vms/\(UUID().uuidString)/type"), "/vms/x/type") == nil)
        await d.shutdown()
    }

    /// /state's machine lines: one asking to join, then blocked.
    @Test func theStateListsPendingAndBlockedMachines() throws {
        let hub = MachineLinkHub.shared
        let id = UUID()
        var sp: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sp) == 0)
        defer { close(sp[1]); hub.forget(id: id) }
        #expect(hub.park(fd: sp[0], id: id, name: "asking-mac", owner: "device:t"))
        var s = Daemon.withMachines(["workspaces": .array([]), "vms": .array([])])
        guard case .array(let pending)? = s["pendingMachines"] else { Issue.record("no pendingMachines"); return }
        #expect(pending.contains { $0["id"]?.stringValue == id.uuidString && $0["name"]?.stringValue == "asking-mac" })
        #expect(hub.decide(id: id, allow: false))
        s = Daemon.withMachines(["workspaces": .array([]), "vms": .array([])])
        guard case .array(let blocked)? = s["blockedMachines"] else { Issue.record("no blockedMachines"); return }
        #expect(blocked.contains { $0["id"]?.stringValue == id.uuidString })
        if case .array(let p)? = s["pendingMachines"] { #expect(!p.contains { $0["id"]?.stringValue == id.uuidString }) }
        // Not attached: no workspace or VM for it.
        #expect(s["workspaces"] == .array([]) && s["vms"] == .array([]))
    }
}
