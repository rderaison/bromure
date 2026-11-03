import Foundation
import Testing
@testable import bromure_ac

/// Board: "P2P vpn stops working, no diagnostic". Clicking the fat client's
/// network tunnel said only "the privileged network helper isn't reachable --
/// check Login Items", with the helper enabled there, reboot after reboot.
/// The daemon chowned its socket to /dev/console's owner when it started --
/// launchd starts it at boot, before anyone logs in, so the socket was
/// root's (0600) and the user's app got EACCES on every connect. A SETUP
/// refusal's reason was dropped too (no fd attached → recvFD returned nil).
@Suite("Fat-client tunnel: the helper is reachable after a reboot, and failures say why")
struct FatClientTunnelDiagnosisTests {
    @Test("a connection is checked against the console user at that moment, not at boot")
    func peerCheck() {
        let allowed = FatClientTunnelDaemon.peerAllowed
        #expect(allowed(501, 501))
        #expect(allowed(0, nil))            // root, always
        #expect(!allowed(502, 501))         // another user
        #expect(!allowed(501, 0))           // nobody logged in (console is root's)
        #expect(!allowed(501, nil))
    }

    @Test("the socket is open to connect, and no longer handed to the boot-time console owner")
    func socketNotChownedAtBoot() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/FatClientTunnelDaemon.swift"), encoding: .utf8)
        #expect(!src.contains("chown(socketPath"))
        #expect(src.contains("chmod(socketPath, 0o666)"))
        #expect(src.contains("peerAllowed(peer, console: consoleUID())"))
    }

    @Test("a refusal without an fd keeps its reason")
    func errReplyKeepsReason() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let line = "ERR route 192.168.64.0/24: route: writing to routing socket: File exists\n"
        _ = line.withCString { write(fds[1], $0, strlen($0)) }
        let reply = try #require(FatClientTunnelDaemon.recvFD(fds[0]))
        #expect(reply.fd == -1)
        #expect(reply.message.hasPrefix("ERR route"))
        let why = FatClientTunnelDiagnosis.explainSetupError(reply.message, cidr: "192.168.64.0/24")
        #expect(why.contains("192.168.64.0/24") && why.contains("File exists"))
    }

    @Test("setup errors name the step")
    func setupErrors() {
        let e = FatClientTunnelDiagnosis.explainSetupError
        #expect(e("ERR denied: uid 502 isn't the console user (501)\n", "10.0.0.0/24").contains("uid 502"))
        #expect(e("ERR ifconfig utun7: ifconfig: ioctl (SIOCAIFADDR): File exists\n", "10.0.0.0/24").contains("utun7"))
        #expect(e(nil, "10.0.0.0/24").contains("without an answer"))
    }

    static let running = """
    system/io.bromure.fatclient-tunnel = {
    \tactive count = 1
    \tpath = /Library/LaunchDaemons/io.bromure.fatclient-tunnel.plist
    \tstate = running
    \tprogram = /Applications/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac
    \tpid = 412
    \tlast exit code = (never exited)
    \tendpoints = {
    \t\tstate = active
    \t}
    }
    """

    @Test("launchctl's view: the job's own keys, not nested ones")
    func parse() throws {
        let info = try #require(FatClientTunnelDiagnosis.parseLaunchctl(Self.running))
        #expect(info.state == "running")
        #expect(info.pid == "412")
        #expect(info.program == "/Applications/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac")
        #expect(info.lastExit == "(never exited)")
        #expect(FatClientTunnelDiagnosis.parseLaunchctl("Bad request.\nCould not find service \"x\" in domain for system") == nil)
    }

    @Test("the likely cause for each way the connect fails")
    func causes() {
        let app = "/Applications/Bromure Agentic Coding.app"
        let up = FatClientTunnelDiagnosis.parseLaunchctl(Self.running)
        func why(_ err: Int32, _ sock: FatClientTunnelDiagnosis.SocketInfo?, _ l: FatClientTunnelDiagnosis.LaunchdInfo?) -> String {
            FatClientTunnelDiagnosis.explainConnectFailure(errno: err, socket: sock, myUID: 501, launchd: l,
                                                           registration: "enabled", bundlePath: app)
        }
        // The reported case: root's 0600 socket from a boot-time start.
        let boot = why(EACCES, .init(ownerUID: 0, mode: 0o600), up)
        #expect(boot.contains("only lets user 0 in, not you (501)"))
        #expect(boot.contains("owner uid 0, mode 600") && boot.contains("registration: enabled"))
        // Approved from another copy of the app.
        var moved = up!; moved.program = "/Users/x/Downloads/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac"; moved.state = "waiting"
        #expect(why(ENOENT, nil, moved).contains("another copy of the app"))
        // Launched and dying (e.g. a re-signed build).
        var dying = up!; dying.state = "not running"; dying.lastExit = "78: EX_CONFIG"
        #expect(why(ENOENT, nil, dying).contains("78: EX_CONFIG"))
        #expect(why(ENOENT, nil, nil).contains("isn't loaded in launchd"))
        #expect(why(ECONNREFUSED, .init(ownerUID: 0, mode: 0o666), up).contains("nobody answers"))
    }
}
