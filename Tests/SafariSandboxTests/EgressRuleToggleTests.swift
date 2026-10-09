import Foundation
import Testing
@testable import SandboxEngine

/// Per-rule on/off + temporary (timed / until-stop) rules, and the switch's
/// live policy swap.
@Suite("Egress rules: on/off, expiry, live swap")
struct EgressRuleToggleTests {
    private func ip(_ s: String) -> UInt32 { EgressPolicy.parseIPv4(s)! }

    @Test("A rule encoded before on/off + expiry existed decodes as on and permanent")
    func codableBackCompat() throws {
        let legacy = """
        {"action":"allow","proto":"tcp","target":{"host":{"domain":"github.com","includeApex":true}},
         "ports":{"ranges":[[443,443]]}}
        """
        let r = try JSONDecoder().decode(EgressPolicy.Rule.self, from: Data(legacy.utf8))
        #expect(r.enabled)
        #expect(r.expiresAt == nil)
        #expect(!r.untilStop)
        #expect(r.text == "allow tcp github.com:443")
        // And the new fields round-trip.
        var timed = r
        timed.enabled = false
        timed.expiresAt = Date(timeIntervalSince1970: 1_760_000_000)
        let again = try JSONDecoder().decode(EgressPolicy.Rule.self, from: JSONEncoder().encode(timed))
        #expect(again == timed)
    }

    @Test("Off and timed rules round-trip through the pf text")
    func textRoundTrip() throws {
        let text = """
        #@off allow tcp registry.npmjs.org:443
        allow tcp github.com:443 #@until=1760000000
        allow web api.example.com GET,POST #@until=stop
        default deny
        """
        let p = try EgressPolicy.parse(text)
        #expect(p.rules.count == 3)
        #expect(!p.rules[0].enabled)
        #expect(p.rules[1].expiresAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(p.rules[2].untilStop)
        #expect(p.rules[2].methods == .list(["GET", "POST"]))
        #expect(try EgressPolicy.parse(p.serialize()) == p)
        #expect(p.serialize() == text)
    }

    @Test("Older parsers read an off rule as a comment and ignore an expiry")
    func olderParserDegradesSafely() {
        // What a pre-annotation parser keeps of each line: text before '#'.
        let stripped = "#@off allow tcp x.com:443".prefix(while: { $0 != "#" })
        #expect(stripped.trimmingCharacters(in: .whitespaces).isEmpty)
        let timed = "allow tcp x.com:443 #@until=1".prefix(while: { $0 != "#" })
        #expect(timed.trimmingCharacters(in: .whitespaces) == "allow tcp x.com:443")
    }

    @Test("A plain comment is not mistaken for an annotation; '#@offset' isn't off")
    func plainComments() throws {
        let p = try EgressPolicy.parse("# note\nallow tcp a.com:443 # keep\n#@offset: a note\n")
        #expect(p.rules.count == 1)
        #expect(p.rules[0].enabled && p.rules[0].expiresAt == nil)
    }

    @Test("Switched-off rules are skipped by the evaluator")
    func disabledIgnored() throws {
        let p = try EgressPolicy.parse("#@off allow tcp github.com:443\ndefault deny")
        #expect(p.verdict(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443) == .deny)
        #expect(p.firstMatch(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443) == nil)
        // A later matching rule now decides.
        let q = try EgressPolicy.parse("#@off deny tcp github.com\nallow tcp github.com:443\ndefault deny")
        #expect(q.verdict(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443) == .allow)
    }

    @Test("A timed rule matches until its expiry, then not — without any sweep")
    func expiryEvaluated() throws {
        let p = try EgressPolicy.parse("allow tcp github.com:443 #@until=1000\ndefault deny")
        let before = Date(timeIntervalSince1970: 999)
        let at = Date(timeIntervalSince1970: 1000)
        #expect(p.verdict(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443, now: before) == .allow)
        #expect(p.verdict(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443, now: at) == .deny)
        #expect(p.permitsMethod(hostnames: ["github.com"], port: 443, method: "GET", now: at))
        #expect(p.nextExpiry == at)
    }

    @Test("Until-stop rules stay on until the workspace stops")
    func untilStop() throws {
        let text = "allow tcp github.com:443 #@until=stop\nallow tcp npmjs.org:443 #@until=100\ndefault deny"
        let p = try EgressPolicy.parse(text)
        #expect(p.verdict(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443,
                          now: .distantFuture) == .allow)
        // A periodic sweep switches off only the expired timed rule…
        let swept = try #require(EgressPolicy.sweeping(text, now: Date(timeIntervalSince1970: 200),
                                                      workspaceStopped: false))
        let s1 = try EgressPolicy.parse(swept)
        #expect(s1.rules[0].enabled && s1.rules[0].untilStop)
        #expect(!s1.rules[1].enabled && s1.rules[1].expiresAt == nil)
        // …and stopping the workspace ends the until-stop one.
        let stopped = try #require(EgressPolicy.sweeping(swept, now: Date(timeIntervalSince1970: 200),
                                                        workspaceStopped: true))
        let s2 = try EgressPolicy.parse(stopped)
        #expect(s2.rules.allSatisfy { !$0.enabled && !$0.isTemporary })
        #expect(s2.verdict(ip: nil, hostnames: ["github.com"], proto: .tcp, port: 443) == .deny)
        // Nothing left to do → nil (no rewrite, no save).
        #expect(EgressPolicy.sweeping(stopped, now: .distantFuture, workspaceStopped: true) == nil)
        #expect(EgressPolicy.sweeping("allow tcp a.com:443", now: .distantFuture, workspaceStopped: true) == nil)
    }

    @Test("The editor rows carry on/off + expiry through pf text")
    func editRows() throws {
        let text = "#@off allow tcp a.com:443\nallow udp b.com:53 #@until=1760000000\ndefault deny"
        let rows = try EgressPolicy.parse(text).editRows()
        #expect(!rows[0].enabled)
        #expect(rows[1].expiresAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(EgressPolicy.pfText(rows: rows, defaultAllow: false) == text)
    }

    @Test("Expiries are whole seconds so the saved text compares equal")
    func expiryRounding() throws {
        let e = EgressPolicy.expiry(in: 900, from: Date(timeIntervalSince1970: 100.7))
        #expect(e == Date(timeIntervalSince1970: 1000))
        var p = EgressPolicy(defaultAction: .deny, rules: [
            EgressPolicy.Rule(action: .allow, proto: .tcp, target: .host(domain: "a.com", includeApex: true),
                              expiresAt: e)])
        #expect(try EgressPolicy.parse(p.serialize()) == p)
        let changed = p.disableExpired(now: e)
        #expect(changed)
        #expect(!p.rules[0].enabled)
    }

    // MARK: - Switch

    @Test("Swapping a port's policy changes the verdict for the very next frame")
    func liveSwapOnSwitch() throws {
        let sw = VMNetSwitch()          // never attaches, so vmnet never starts
        let port = 4242
        let dst = ip("140.82.112.3")
        let allow = try EgressPolicy.parse("allow tcp github.com:443\ndefault deny")
        sw.setEgressPolicy(allow, forPortID: port)
        #expect(sw.egressVerdict(portID: port, ip: dst, hostnames: ["github.com"], proto: .tcp, port: 443) == .allow)
        // The user switches the rule off: same flow, denied at once.
        var off = allow
        off.rules[0].enabled = false
        sw.setEgressPolicy(off, forPortID: port)
        #expect(sw.egressVerdict(portID: port, ip: dst, hostnames: ["github.com"], proto: .tcp, port: 443) == .deny)
        // And a temporary allow lapses by itself.
        var timed = allow
        timed.rules[0].expiresAt = Date(timeIntervalSince1970: 50)
        sw.setEgressPolicy(timed, forPortID: port)
        #expect(sw.egressVerdict(portID: port, ip: dst, hostnames: ["github.com"], proto: .tcp, port: 443,
                                 now: Date(timeIntervalSince1970: 49)) == .allow)
        #expect(sw.egressVerdict(portID: port, ip: dst, hostnames: ["github.com"], proto: .tcp, port: 443,
                                 now: Date(timeIntervalSince1970: 50)) == .deny)
        sw.setEgressPolicy(nil, forPortID: port)
        #expect(sw.egressVerdict(portID: port, ip: dst, hostnames: [], proto: .tcp, port: 443) == .allow)
    }

    @Test("A denied segment is answered by flags: SYN → RST+ACK, established → RST, RST → nothing")
    func denyResetByFlags() {
        #expect(VMNetSwitch.denyReset(tcpFlags: 0x02) == .syn)            // SYN
        #expect(VMNetSwitch.denyReset(tcpFlags: 0x10) == .established)    // ACK
        #expect(VMNetSwitch.denyReset(tcpFlags: 0x18) == .established)    // PSH|ACK
        #expect(VMNetSwitch.denyReset(tcpFlags: 0x11) == .established)    // FIN|ACK
        #expect(VMNetSwitch.denyReset(tcpFlags: 0x04) == .none)           // RST
        #expect(VMNetSwitch.denyReset(tcpFlags: 0x14) == .none)           // RST|ACK
        #expect(VMNetSwitch.denyReset(tcpFlags: nil) == .none)            // UDP
    }

    @Test("The established-flow RST uses the guest's ACK number as its sequence")
    func establishedReset() {
        // Ethernet (14) + IPv4 (20) + TCP (20): guest 192.168.64.2:50000 → 140.82.112.3:443.
        var frame = [UInt8](repeating: 0, count: 14 + 40)
        frame[12] = 0x08; frame[13] = 0x00
        frame[14] = 0x45; frame[14 + 9] = 6
        let g = ip("192.168.64.2"), d = ip("140.82.112.3")
        for i in 0..<4 {
            frame[14 + 12 + i] = UInt8((g >> (24 - 8 * UInt32(i))) & 0xFF)
            frame[14 + 16 + i] = UInt8((d >> (24 - 8 * UInt32(i))) & 0xFF)
        }
        let t = 34
        frame[t] = 0xC3; frame[t + 1] = 0x50          // sport 50000
        frame[t + 2] = 0x01; frame[t + 3] = 0xBB      // dport 443
        frame[t + 4 ..< t + 8] = [0x00, 0x00, 0x10, 0x00]   // seq 4096
        frame[t + 8 ..< t + 12] = [0xAB, 0xCD, 0xEF, 0x01]  // ack
        frame[t + 12] = 0x50; frame[t + 13] = 0x18          // PSH|ACK
        let rst = frame.withUnsafeMutableBufferPointer {
            VMNetSwitch.buildTCPReset($0.baseAddress!, $0.count, established: true)
        }
        #expect(Array(rst[12..<16]) == Array(frame[14 + 16 ..< 14 + 20]))   // src = remote
        #expect(Array(rst[16..<20]) == Array(frame[14 + 12 ..< 14 + 16]))   // dst = guest
        #expect(Array(rst[20..<22]) == [0x01, 0xBB] && Array(rst[22..<24]) == [0xC3, 0x50])
        #expect(Array(rst[24..<28]) == [0xAB, 0xCD, 0xEF, 0x01])            // seq = guest's ack
        #expect(rst[33] == 0x04)                                            // RST only
    }
}
