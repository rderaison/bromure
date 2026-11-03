import Foundation
import Testing
@testable import bromure_ac

/// Collects what the lineage store emits.
final class LineageSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, [String: AnyJSON])] = []
    func add(_ t: String, _ d: [String: AnyJSON]) { lock.lock(); items.append((t, d)); lock.unlock() }
    var flows: [[String: AnyJSON]] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.0 == "net.flow" }.map(\.1) }
}

@Suite("Network lineage: reasoning → tool call → processes → flow → decision")
struct NetworkLineageTests {
    static func S(_ v: AnyJSON?) -> String? { if case .string(let s)? = v { return s }; return nil }
    static func I(_ v: AnyJSON?) -> Int? { if case .int(let i)? = v { return i }; return nil }

    func store(_ sink: LineageSink) -> NetworkLineage {
        let l = NetworkLineage()
        l.decisionWait = 0.05
        l.emit = { _, t, d in sink.add(t, d) }
        return l
    }

    func waitFor(_ sink: LineageSink, _ n: Int) async {
        for _ in 0..<300 where sink.flows.count < n { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func comms(_ flow: [String: AnyJSON]) -> [String] {
        guard case .array(let ps)? = flow["processes"] else { return [] }
        return ps.compactMap { if case .object(let p) = $0 { return Self.S(p["comm"]) } else { return nil } }
    }

    /// The user's example, end to end.
    @Test("claude → bash → ping → ICMP 1.1.1.1, tied to the Bash call that asked for it")
    func pingFromClaude() async throws {
        let sink = LineageSink(), l = store(sink), pid = UUID()
        l.noteExec(profileID: pid, ["pid": 412, "ppid": 1, "start_ns": 100, "comm": "claude", "path": "/usr/bin/node", "argv": "claude"])
        l.noteToolCall(profileID: pid, id: "toolu_01", tool: "Bash", command: "ping -c1 1.1.1.1",
                       reasoning: "Let me check the network is reachable first.")
        // Claude Code's real wrapping: a login shell, a snapshot, eval '…'.
        l.noteExec(profileID: pid, ["pid": 980, "ppid": 412, "start_ns": 200, "comm": "bash", "path": "/usr/bin/bash",
            "argv": "/bin/bash -c -l source /home/ubuntu/.claude/shell-snapshots/snapshot-bash-1.sh && eval 'ping -c1 1.1.1.1' < /dev/null && pwd -P >| /tmp/claude-1-cwd"])
        l.noteExec(profileID: pid, ["pid": 981, "ppid": 980, "start_ns": 300, "comm": "ping", "path": "/usr/bin/ping", "argv": "ping -c1 1.1.1.1"])
        l.noteFlow(profileID: pid, ["pid": 981, "start_ns": 300, "proto": "icmp", "dst": "1.1.1.1", "dport": 0, "sport": 7, "comm": "ping"])
        await waitFor(sink, 1)
        let f = try #require(sink.flows.first)
        #expect(comms(f) == ["claude", "bash", "ping"])
        #expect(Self.S(f["decision"]) == "unfiltered" && Self.S(f["proto"]) == "icmp" && Self.S(f["dst"]) == "1.1.1.1")
        guard case .object(let agent)? = f["agent"] else { Issue.record("no agent link"); return }
        #expect(Self.S(agent["tool_use_id"]) == "toolu_01" && Self.S(agent["confidence"]) == "exact")
        #expect(l.toolCall(profileID: pid, id: "toolu_01")?.reasoning == "Let me check the network is reachable first.")
        let row = try #require(SecurityTimeline.map(profileID: pid, eventType: "net.flow", eventData: f, now: Date()))
        #expect(row.condition == "Bash `ping -c1 1.1.1.1`: claude → bash → ping → ICMP 1.1.1.1")
        #expect(row.decision == "passed (not filtered)")
    }

    @Test("A TCP flow takes the switch's decision; an L7 deny for its hostname overrides an L4 allow")
    func decisions() async throws {
        let sink = LineageSink(), l = store(sink), pid = UUID()
        l.noteExec(profileID: pid, ["pid": 50, "ppid": 1, "comm": "curl", "path": "/usr/bin/curl", "argv": "curl https://evil.example"])
        l.noteDecision(profileID: pid, proto: "tcp", dst: "203.0.113.9", dport: 443, action: "allow", layer: "l4", host: "evil.example")
        l.noteDecision(profileID: pid, proto: "tcp", dst: "host:evil.example", dport: 443, action: "deny", layer: "l7",
                       reason: "no matching network policy", host: "evil.example")
        l.noteFlow(profileID: pid, ["pid": 50, "proto": "tcp", "dst": "203.0.113.9", "dport": 443, "sport": 41000])
        // An unrelated flow nobody decided on: TCP is "unknown", not "unfiltered".
        l.noteExec(profileID: pid, ["pid": 60, "ppid": 1, "comm": "nc", "path": "/usr/bin/nc", "argv": "nc 198.51.100.1 22"])
        l.noteFlow(profileID: pid, ["pid": 60, "proto": "tcp", "dst": "198.51.100.1", "dport": 22])
        await waitFor(sink, 2)
        let curl = try #require(sink.flows.first { Self.S($0["dst"]) == "203.0.113.9" })
        #expect(Self.S(curl["decision"]) == "deny" && Self.S(curl["layer"]) == "l7" && Self.S(curl["host"]) == "evil.example")
        #expect(curl["agent"] == nil)
        let nc = try #require(sink.flows.first { Self.S($0["dst"]) == "198.51.100.1" })
        #expect(Self.S(nc["decision"]) == "unknown")
    }

    @Test("A raw packet-socket send: no destination, its interface, a raw decision, no policy note")
    func packetSocket() async throws {
        let sink = LineageSink(), l = store(sink), pid = UUID()
        l.noteExec(profileID: pid, ["pid": 70, "ppid": 1, "comm": "python3", "path": "/usr/bin/python3", "argv": "python3 raw.py"])
        // The module's real shape: dst/dport present but empty, family AF_PACKET.
        l.noteFlow(profileID: pid, ["pid": 70, "proto": "packet", "ip_proto": 0, "family": 17, "dst": "",
                                    "dport": 0, "sport": 0, "count": 1, "dev": "eth0", "comm": "python3"])
        await waitFor(sink, 1)
        let f = try #require(sink.flows.first)
        #expect(Self.S(f["decision"]) == "raw" && Self.S(f["dev"]) == "eth0" && Self.S(f["proto"]) == "packet")
        let row = try #require(SecurityTimeline.map(profileID: pid, eventType: "net.flow", eventData: f, now: Date()))
        #expect(row.condition == "python3 → raw frames on eth0")
        #expect(row.decision == "raw socket")
    }

    @Test("A shell started long after the tool call, or running another command, isn't linked")
    func noFalseLinks() {
        let t0 = Date()
        let calls = [NetworkLineage.ToolCall(id: "a", tool: "Bash", command: "ping -c1 1.1.1.1", reasoning: "", at: t0)]
        #expect(NetworkLineage.matchToolCall(argv: "bash -c 'ping -c1 1.1.1.1'", calls: calls, at: t0 + 5)?.toolUseID == "a")
        #expect(NetworkLineage.matchToolCall(argv: "bash -c 'ping -c1 1.1.1.1'", calls: calls, at: t0 + 60) == nil)
        #expect(NetworkLineage.matchToolCall(argv: "bash -c 'ping -c1 8.8.8.8'", calls: calls, at: t0 + 5) == nil)
        // Quotes inside the command survive Claude Code's '"'"' escaping.
        let q = [NetworkLineage.ToolCall(id: "q", tool: "Bash", command: "echo 'hi there' | nc 1.2.3.4 80", reasoning: "", at: t0)]
        #expect(NetworkLineage.matchToolCall(argv: #"bash -c -l eval 'echo '"'"'hi there'"'"' | nc 1.2.3.4 80'"#, calls: q, at: t0 + 1)?.toolUseID == "q")
    }

    /// Finding (CWE-670): "Tool-call matching treats a 2-character substring
    /// as an exact link". `id` claimed any argv containing those letters, and
    /// newest-first let it steal a longer command it sat inside.
    @Test("A short command matches only whole words, never as exact, and never over a longer one")
    func shortCommandMatches() {
        let t0 = Date()
        let idCall = NetworkLineage.ToolCall(id: "id", tool: "Bash", command: "id", reasoning: "", at: t0 + 2)
        let curl = NetworkLineage.ToolCall(id: "curl", tool: "Bash", command: "curl -s https://api.example/valid?id=1",
                                           reasoning: "", at: t0)
        // Letters inside another word, a URL path or query: no link.
        for argv in ["bash -c width", "consider --valid", "curl -s https://x.example/id/7", "printf %s idle"] {
            #expect(NetworkLineage.matchToolCall(argv: argv, calls: [idCall], at: t0 + 3) == nil, "\(argv)")
        }
        // The word itself: linked, but only "likely".
        let short = NetworkLineage.matchToolCall(argv: "/bin/bash -c -l eval 'id' < /dev/null", calls: [idCall], at: t0 + 3)
        #expect(short?.toolUseID == "id" && short?.confidence == "likely")
        // A newer short call doesn't steal the longer command it sits inside.
        let both = NetworkLineage.matchToolCall(argv: "bash -c curl -s https://api.example/valid?id=1 id",
                                                calls: [curl, idCall], at: t0 + 3)
        #expect(both?.toolUseID == "curl" && both?.confidence == "exact")
        // Words in order and contiguous: the same words elsewhere don't link.
        let ping = NetworkLineage.ToolCall(id: "p", tool: "Bash", command: "ping -c1 1.1.1.1", reasoning: "", at: t0)
        #expect(NetworkLineage.matchToolCall(argv: "ping 1.1.1.1 -c1", calls: [ping], at: t0 + 1) == nil)
        #expect(NetworkLineage.matchToolCall(argv: "bash -c 'ping -c1 1.1.1.1'", calls: [ping], at: t0 + 1)?.confidence == "exact")
    }

    /// Finding (CWE-670): "Process lineage walks parents by pid and drops
    /// start_ns". The walk followed `byPid[ppid]` — the newest process with
    /// that pid — so once the agent exited and its pid was reused, the flow
    /// was chained to the newcomer, and the kernel's own chain was skipped.
    @Test("A reused parent pid isn't the parent: the walk follows the exact (pid, start_ns) the exec recorded")
    func reusedParentPid() async throws {
        let sink = LineageSink(), l = store(sink), pid = UUID()
        l.noteExec(profileID: pid, ["pid": 412, "ppid": 1, "start_ns": 100, "comm": "claude", "path": "/usr/bin/node",
                                    "chain": [["pid": 1, "start_ns": 1, "comm": "systemd"]]])
        l.noteExec(profileID: pid, ["pid": 980, "ppid": 412, "start_ns": 200, "comm": "bash", "path": "/usr/bin/bash",
                                    "chain": [["pid": 412, "start_ns": 100, "comm": "claude"], ["pid": 1, "start_ns": 1, "comm": "systemd"]]])
        // claude exits; its pid goes to an unrelated program.
        l.noteExec(profileID: pid, ["pid": 412, "ppid": 1, "start_ns": 500, "comm": "cron", "path": "/usr/sbin/cron",
                                    "chain": [["pid": 1, "start_ns": 1, "comm": "systemd"]]])
        l.noteExec(profileID: pid, ["pid": 981, "ppid": 980, "start_ns": 600, "comm": "curl", "path": "/usr/bin/curl",
                                    "chain": [["pid": 980, "start_ns": 200, "comm": "bash"], ["pid": 1, "start_ns": 1, "comm": "systemd"]]])
        l.noteFlow(profileID: pid, ["pid": 981, "start_ns": 600, "proto": "tcp", "dst": "1.2.3.4", "dport": 443, "comm": "curl",
                                    "chain": [["pid": 980, "start_ns": 200, "comm": "bash"], ["pid": 1, "start_ns": 1, "comm": "systemd"]]])
        await waitFor(sink, 1)
        let f = try #require(sink.flows.first)
        #expect(comms(f) == ["systemd", "claude", "bash", "curl"])
        #expect(!comms(f).contains("cron"))

        // An older sentry (no chain on exec): a pid reused after the child
        // started isn't taken for its parent either.
        let sink2 = LineageSink(), l2 = store(sink2)
        l2.noteExec(profileID: pid, ["pid": 50, "ppid": 1, "start_ns": 10, "comm": "zsh"])
        l2.noteExec(profileID: pid, ["pid": 60, "ppid": 50, "start_ns": 20, "comm": "wget"])
        l2.noteExec(profileID: pid, ["pid": 50, "ppid": 1, "start_ns": 30, "comm": "sshd"])
        l2.noteFlow(profileID: pid, ["pid": 60, "start_ns": 20, "proto": "tcp", "dst": "1.2.3.4", "dport": 80, "comm": "wget"])
        await waitFor(sink2, 1)
        #expect(comms(try #require(sink2.flows.first)) == ["wget"])
    }

    /// Finding (CWE-670): "Lineage misses the exec record when start_ns is
    /// not the group leader's". An older module reports the probed thread's
    /// own start time: a worker thread's flow, or a child it forked, named a
    /// key no exec was recorded under, and the walk lost argv, the tool call,
    /// and the parent.
    @Test("A worker thread's flow, and a child it forked, still find the process's exec — not a reused pid's")
    func workerThreads() async throws {
        let sink = LineageSink(), l = store(sink), pid = UUID()
        l.noteExec(profileID: pid, ["pid": 412, "ppid": 1, "start_ns": 100, "comm": "claude", "path": "/usr/bin/node",
                                    "argv": "node /usr/bin/claude", "chain": [["pid": 1, "start_ns": 1, "comm": "systemd"]]])
        l.noteExec(profileID: pid, ["pid": 700, "ppid": 412, "start_ns": 200, "comm": "agent-go", "path": "/usr/bin/agent-go",
                                    "argv": "agent-go serve", "chain": [["pid": 412, "start_ns": 100, "comm": "claude"]]])
        // A flow from one of agent-go's threads (its own start time).
        l.noteFlow(profileID: pid, ["pid": 700, "start_ns": 260, "proto": "tcp", "dst": "1.2.3.4", "dport": 443, "comm": "agent-go",
                                    "chain": [["pid": 412, "start_ns": 100, "comm": "claude"]]])
        await waitFor(sink, 1)
        let f = try #require(sink.flows.first)
        #expect(comms(f) == ["claude", "agent-go"])
        guard case .array(let ps)? = f["processes"], case .object(let leaf)? = ps.last else {
            Issue.record("no processes"); return
        }
        #expect(NetworkLineageTests.S(leaf["argv"]) == "agent-go serve")
        // A child forked by that thread: its exec names the thread as parent.
        l.noteExec(profileID: pid, ["pid": 701, "ppid": 700, "start_ns": 300, "comm": "git", "path": "/usr/bin/git",
                                    "argv": "git fetch", "chain": [["pid": 700, "start_ns": 270, "comm": "agent-go"]]])
        l.noteFlow(profileID: pid, ["pid": 701, "start_ns": 300, "proto": "tcp", "dst": "5.6.7.8", "dport": 22, "comm": "git",
                                    "chain": [["pid": 700, "start_ns": 270, "comm": "agent-go"]]])
        await waitFor(sink, 2)
        let g = try #require(sink.flows.first { NetworkLineageTests.S($0["dst"]) == "5.6.7.8" })
        #expect(comms(g) == ["claude", "agent-go", "git"])
        // A thread time EARLIER than the latest exec with that pid isn't it:
        // that pid was reused after this process started.
        l.noteExec(profileID: pid, ["pid": 800, "ppid": 1, "start_ns": 900, "comm": "cron", "path": "/usr/sbin/cron"])
        l.noteFlow(profileID: pid, ["pid": 800, "start_ns": 850, "proto": "tcp", "dst": "9.9.9.9", "dport": 80, "comm": "old"])
        await waitFor(sink, 3)
        let h = try #require(sink.flows.first { NetworkLineageTests.S($0["dst"]) == "9.9.9.9" })
        #expect(!comms(h).contains("cron"))
    }

    @Test("Repeats of one flow from one program fold; the chain comes from the frame when exec was never seen")
    func foldAndFrameChain() async throws {
        let sink = LineageSink(), l = store(sink), pid = UUID()
        for _ in 0..<5 {
            l.noteFlow(profileID: pid, ["pid": 70, "start_ns": 9, "proto": "udp", "dst": "1.1.1.1", "dport": 53, "comm": "dig",
                                        "path": "/usr/bin/dig",
                                        "chain": [["pid": 69, "comm": "bash"], ["pid": 1, "comm": "systemd"]]])
        }
        for _ in 0..<200 where sink.flows.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)   // the other four must not follow
        #expect(sink.flows.count == 1)
        #expect(comms(sink.flows[0]) == ["systemd", "bash", "dig"])
    }
}

@Suite("Network lineage: @infra's shape asks")
struct NetworkLineageShapeTests {
    @Test("A tool call is reported once; processes are capped at 8 with start_ns")
    func shape() async throws {
        let sink = LineageSink(), l = NetworkLineage(), pid = UUID()
        l.decisionWait = 0.02
        l.emit = { _, t, d in sink.add(t, d) }
        #expect(l.noteToolCall(profileID: pid, id: "toolu_x", tool: "Bash", command: "ls", reasoning: "r"))
        #expect(!l.noteToolCall(profileID: pid, id: "toolu_x", tool: "Bash", command: "ls", reasoning: "r"))
        for i in 1...12 {
            l.noteExec(profileID: pid, ["pid": 100 + i, "ppid": i == 1 ? 1 : 99 + i, "start_ns": 1000 + i, "comm": "p\(i)", "argv": "p\(i)"])
        }
        l.noteFlow(profileID: pid, ["pid": 112, "start_ns": 1012, "proto": "tcp", "dst": "10.0.0.1", "dport": 80])
        for _ in 0..<300 where sink.flows.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        guard case .array(let ps)? = try #require(sink.flows.first)["processes"] else { Issue.record("no processes"); return }
        #expect(ps.count == 8)
        if case .object(let leaf)? = ps.last { #expect(NetworkLineageTests.I(leaf["start_ns"]) == 1012) }
    }
}

@Suite("Network lineage through the guest's proxy bridge")
struct NetworkLineageProxyTests {
    @Test("The bridge's BROMURE-CLIENT line is stripped and its port read; plain requests are untouched")
    func preamble() {
        var req = Data("BROMURE-CLIENT 1 sport=53111 peer=127.0.0.1\nCONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8)
        #expect(HTTPMitmConnection.stripClientPreamble(&req) == 53111)
        #expect(String(decoding: req, as: UTF8.self) == "CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        var plain = Data("CONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8)
        #expect(HTTPMitmConnection.stripClientPreamble(&plain) == nil && plain.count == 36)
        var bad = Data("BROMURE-CLIENT 1 sport=99999\nGET http://x/ HTTP/1.1\r\n\r\n".utf8)
        #expect(HTTPMitmConnection.stripClientPreamble(&bad) == nil)
        #expect(String(decoding: bad, as: UTF8.self).hasPrefix("GET "))
    }

    @Test("curl → 127.0.0.1:65534 becomes curl → CONNECT example.com:443 with the proxy's decision")
    func proxiedFlow() async throws {
        let sink = LineageSink(), l = NetworkLineage(), pid = UUID()
        l.decisionWait = 0.05
        l.emit = { _, t, d in sink.add(t, d) }
        l.noteExec(profileID: pid, ["pid": 40, "ppid": 1, "comm": "curl", "path": "/usr/bin/curl", "argv": "curl https://example.com/"])
        l.noteProxied(profileID: pid, claim: l.noteClaimant(profileID: pid, sport: 53111), host: "example.com", port: 443)
        // The proxy's own allow (egress.firewall, layer proxy).
        l.noteDecision(profileID: pid, proto: "tcp", dst: "host:example.com", dport: 443, action: "allow", layer: "proxy",
                       host: "example.com")
        l.noteFlow(profileID: pid, ["pid": 40, "proto": "tcp", "dst": "127.0.0.1", "dport": 65534, "sport": 53111])
        // A denied one: the L7 deny is keyed by hostname.
        l.noteExec(profileID: pid, ["pid": 41, "ppid": 1, "comm": "curl", "path": "/usr/bin/curl", "argv": "curl https://evil.example/"])
        l.noteProxied(profileID: pid, claim: l.noteClaimant(profileID: pid, sport: 53112), host: "evil.example", port: 443)
        l.noteDecision(profileID: pid, proto: "tcp", dst: "host:evil.example", dport: 443, action: "deny", layer: "l7",
                       reason: "no matching network policy", host: "evil.example")
        l.noteFlow(profileID: pid, ["pid": 41, "proto": "tcp", "dst": "127.0.0.1", "dport": 65534, "sport": 53112])
        for _ in 0..<300 where sink.flows.count < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let ok = try #require(sink.flows.first { NetworkLineageTests.S($0["dst"]) == "example.com" })
        #expect(NetworkLineageTests.I(ok["dport"]) == 443 && NetworkLineageTests.S(ok["decision"]) == "allow")
        if case .bool(true)? = ok["via_proxy"] {} else { Issue.record("not marked via_proxy") }
        let denied = try #require(sink.flows.first { NetworkLineageTests.S($0["dst"]) == "evil.example" })
        #expect(NetworkLineageTests.S(denied["decision"]) == "deny" && NetworkLineageTests.S(denied["layer"]) == "l7")
        let row = try #require(SecurityTimeline.map(profileID: pid, eventType: "net.flow", eventData: ok, now: Date()))
        #expect(row.condition == "curl → TCP example.com:443")
    }

    /// Finding (CWE-670): "Proxied flows are recorded as allowed before an
    /// L7 deny can land". With no decision 1.5 s after the connect, a proxied
    /// flow was written "allow / proxy" for good — while the MiTM's L7 deny,
    /// logged once it had read the request, came later.
    @Test("A proxied flow waits for the MiTM's verdict, and says unknown rather than guess allow")
    func proxiedFlowWaitsForVerdict() async throws {
        let sink = LineageSink(), l = NetworkLineage(), pid = UUID()
        l.decisionWait = 0.05
        l.proxyDecisionPolls = 6
        l.emit = { _, t, d in sink.add(t, d) }
        l.noteExec(profileID: pid, ["pid": 50, "ppid": 1, "comm": "curl", "path": "/usr/bin/curl", "argv": "curl -X POST https://api.example/x"])
        l.noteProxied(profileID: pid, claim: l.noteClaimant(profileID: pid, sport: 53200), host: "api.example", port: 443)
        l.noteFlow(profileID: pid, ["pid": 50, "proto": "tcp", "dst": "127.0.0.1", "dport": 65534, "sport": 53200])
        // Past the first look, the L7 deny lands.
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(sink.flows.isEmpty, "emitted before the verdict")
        l.noteDecision(profileID: pid, proto: "tcp", dst: "host:api.example", dport: 443, action: "deny", layer: "l7",
                       reason: "POST not permitted by policy", host: "api.example")
        for _ in 0..<300 where sink.flows.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        let denied = try #require(sink.flows.first)
        #expect(NetworkLineageTests.S(denied["dst"]) == "api.example")
        #expect(NetworkLineageTests.S(denied["decision"]) == "deny" && NetworkLineageTests.S(denied["layer"]) == "l7")

        // No verdict ever: unknown, not a guessed allow.
        l.noteExec(profileID: pid, ["pid": 51, "ppid": 1, "comm": "wget", "path": "/usr/bin/wget", "argv": "wget https://quiet.example/"])
        l.noteProxied(profileID: pid, claim: l.noteClaimant(profileID: pid, sport: 53201), host: "quiet.example", port: 443)
        l.noteFlow(profileID: pid, ["pid": 51, "proto": "tcp", "dst": "127.0.0.1", "dport": 65534, "sport": 53201])
        for _ in 0..<300 where sink.flows.count < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let quiet = try #require(sink.flows.first { NetworkLineageTests.S($0["dst"]) == "quiet.example" })
        #expect(NetworkLineageTests.S(quiet["decision"]) == "unknown")
        if case .bool(true)? = quiet["via_proxy"] {} else { Issue.record("not marked via_proxy") }
    }

    /// Finding (CWE-345): "A direct vsock client can forge BROMURE-CLIENT and
    /// relabel a proxied flow". A guest process connecting straight to the
    /// MITM's vsock port could claim any client port and make a loopback flow
    /// read as a benign host.
    @Test("A forged bridge claim relabels neither a loopback flow elsewhere nor a contested port, in either order")
    func forgedProxyClaim() async throws {
        let sink = LineageSink(), l = NetworkLineage(), pid = UUID()
        l.decisionWait = 0.05
        l.emit = { _, t, d in sink.add(t, d) }
        // A loopback connection to the attacker's own listener, claimed as benign.
        l.noteProxied(profileID: pid, claim: l.noteClaimant(profileID: pid, sport: 40001), host: "benign.example", port: 443)
        l.noteFlow(profileID: pid, ["pid": 60, "proto": "tcp", "dst": "127.0.0.1", "dport": 9999, "sport": 40001])
        // Two connections claiming one port, in either order: neither is believed.
        let bridge2 = l.noteClaimant(profileID: pid, sport: 40002), forged2 = l.noteClaimant(profileID: pid, sport: 40002)
        l.noteProxied(profileID: pid, claim: bridge2, host: "evil.example", port: 443)
        l.noteProxied(profileID: pid, claim: forged2, host: "benign.example", port: 443)
        l.noteFlow(profileID: pid, ["pid": 61, "path": "/usr/bin/a", "proto": "tcp", "dst": "127.0.0.1", "dport": 65534, "sport": 40002])
        let forged3 = l.noteClaimant(profileID: pid, sport: 40003)
        l.noteProxied(profileID: pid, claim: forged3, host: "benign.example", port: 443)   // forged, first
        let bridge3 = l.noteClaimant(profileID: pid, sport: 40003)
        l.noteProxied(profileID: pid, claim: bridge3, host: "evil.example", port: 443)     // the bridge's
        l.noteProxied(profileID: pid, claim: forged3, host: "benign.example", port: 443)   // refreshed: still contested
        l.noteFlow(profileID: pid, ["pid": 62, "path": "/usr/bin/b", "proto": "tcp", "dst": "127.0.0.1", "dport": 65534, "sport": 40003])
        // One honest claim still relabels (its target sent twice is fine).
        let honest4 = l.noteClaimant(profileID: pid, sport: 40004)
        l.noteProxied(profileID: pid, claim: honest4, host: "pypi.org", port: 443)
        l.noteProxied(profileID: pid, claim: honest4, host: "pypi.org", port: 443)
        l.noteFlow(profileID: pid, ["pid": 63, "path": "/usr/bin/c", "proto": "tcp", "dst": "127.0.0.1", "dport": 65534, "sport": 40004])
        for _ in 0..<300 where sink.flows.count < 4 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let own = try #require(sink.flows.first { NetworkLineageTests.I($0["sport"]) == 40001 })
        #expect(NetworkLineageTests.S(own["dst"]) == "127.0.0.1" && NetworkLineageTests.I(own["dport"]) == 9999)
        if case .bool(true)? = own["via_proxy"] { Issue.record("a non-bridge loopback flow was relabelled") }
        for sport in [40002, 40003] {
            let f = try #require(sink.flows.first { NetworkLineageTests.I($0["sport"]) == sport })
            #expect(NetworkLineageTests.S(f["dst"]) == "127.0.0.1", "sport \(sport) relabelled")
        }
        let honest = try #require(sink.flows.first { NetworkLineageTests.I($0["sport"]) == 40004 })
        #expect(NetworkLineageTests.S(honest["dst"]) == "pypi.org")
    }

    @Test("A planted claim whose bridge request is held back past the flow's resolution is still contested")
    func heldBackRequest() async throws {
        let sink = LineageSink(), l = NetworkLineage(), pid = UUID()
        l.decisionWait = 0.05
        l.emit = { _, t, d in sink.add(t, d) }
        // The forged direct connection: its preamble, then its target.
        let forged = l.noteClaimant(profileID: pid, sport: 40010)
        l.noteProxied(profileID: pid, claim: forged, host: "benign.example", port: 443)
        // The attacker connects to the bridge from that port; agentd's line
        // arrives at once, its request is held back (no target yet).
        l.noteClaimant(profileID: pid, sport: 40010)
        l.noteFlow(profileID: pid, ["pid": 64, "path": "/usr/bin/d", "proto": "tcp", "dst": "127.0.0.1",
                                    "dport": 65534, "sport": 40010])
        for _ in 0..<300 where sink.flows.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        let f = try #require(sink.flows.first)
        #expect(NetworkLineageTests.S(f["dst"]) == "127.0.0.1")
        if case .bool(true)? = f["via_proxy"] { Issue.record("labelled from a contested port") }
        // One connection, one claim: still labelled.
        l.noteProxied(profileID: pid, claim: l.noteClaimant(profileID: pid, sport: 40011), host: "pypi.org", port: 443)
        l.noteFlow(profileID: pid, ["pid": 65, "path": "/usr/bin/e", "proto": "tcp", "dst": "127.0.0.1",
                                    "dport": 65534, "sport": 40011])
        for _ in 0..<300 where sink.flows.count < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(sink.flows.contains { NetworkLineageTests.S($0["dst"]) == "pypi.org" })
    }

    /// Finding (CWE-345): "A forged proxy preamble still relabels a flow
    /// after its claimant record expires". A direct vsock connection held
    /// its request past the claimant record's 120 s (and the contested
    /// mark's), then sent it; a later connection from that port counted 1
    /// afresh and its flow was labelled with the forged target.
    @Test("A claim whose record aged out stores nothing, and a fresh claimant doesn't inherit an old target")
    func expiredClaimant() async throws {
        final class Clock: @unchecked Sendable { var t = Date() }
        let clock = Clock()
        let sink = LineageSink(), l = NetworkLineage(), pid = UUID()
        l.decisionWait = 0.05
        l.now = { clock.t }
        l.emit = { _, t, d in sink.add(t, d) }
        // 1-2: the forged direct connection's preamble, then the attacker's
        // bridge connection from that port (contested), closed.
        let forged = l.noteClaimant(profileID: pid, sport: 40020)
        l.noteClaimant(profileID: pid, sport: 40020)
        // 3: past the record's lifetime, the held request arrives.
        clock.t += 121
        l.noteProxied(profileID: pid, claim: forged, host: "benign.example", port: 443)
        // 4: a new bridge connection from the same port, request held back.
        l.noteClaimant(profileID: pid, sport: 40020)
        l.noteFlow(profileID: pid, ["pid": 70, "path": "/usr/bin/x", "proto": "tcp", "dst": "127.0.0.1",
                                    "dport": 65534, "sport": 40020])
        for _ in 0..<300 where sink.flows.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        let f = try #require(sink.flows.first)
        #expect(NetworkLineageTests.S(f["dst"]) == "127.0.0.1")
        if case .bool(true)? = f["via_proxy"] { Issue.record("labelled from an expired claim") }

        // A target stored under a live record, which then ages out: a new
        // claimant on that port isn't labelled with it either.
        let old = l.noteClaimant(profileID: pid, sport: 40021)
        l.noteProxied(profileID: pid, claim: old, host: "benign.example", port: 443)
        clock.t += 121
        l.noteClaimant(profileID: pid, sport: 40021)
        l.noteFlow(profileID: pid, ["pid": 71, "path": "/usr/bin/y", "proto": "tcp", "dst": "127.0.0.1",
                                    "dport": 65534, "sport": 40021])
        for _ in 0..<300 where sink.flows.count < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let g = try #require(sink.flows.first { NetworkLineageTests.I($0["sport"]) == 40021 })
        #expect(NetworkLineageTests.S(g["dst"]) == "127.0.0.1")

        // The honest bridge path, clock and all: claimed, stored, labelled.
        let honest = l.noteClaimant(profileID: pid, sport: 40022)
        l.noteProxied(profileID: pid, claim: honest, host: "pypi.org", port: 443)
        l.noteFlow(profileID: pid, ["pid": 72, "path": "/usr/bin/z", "proto": "tcp", "dst": "127.0.0.1",
                                    "dport": 65534, "sport": 40022])
        for _ in 0..<300 where sink.flows.count < 3 { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(sink.flows.contains { NetworkLineageTests.S($0["dst"]) == "pypi.org" })
    }

    @Test("The preamble's port is read from the first line without consuming the stream")
    func peekPreamble() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let msg = Array("BROMURE-CLIENT 1 sport=51234 peer=127.0.0.1\nCONNECT a:443 HTTP/1.1\r\n\r\n".utf8)
        _ = msg.withUnsafeBytes { write(fds[1], $0.baseAddress, msg.count) }
        #expect(HTTPMitmConnection.peekPreambleSport(fd: fds[0]) == 51234)
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fds[0], &buf, buf.count)
        #expect(n == msg.count)                                 // nothing was consumed
        // No preamble: nothing claimed.
        var g: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &g) == 0)
        defer { close(g[0]); close(g[1]) }
        let plain = Array("CONNECT a:443 HTTP/1.1\r\n\r\n".utf8)
        _ = plain.withUnsafeBytes { write(g[1], $0.baseAddress, plain.count) }
        #expect(HTTPMitmConnection.peekPreambleSport(fd: g[0]) == nil)
    }

    @Test("A connection whose preamble dodged the first-line count can't label a flow")
    func dodgedPeekCantLabel() {
        #expect(HTTPMitmConnection.claimedSport(parsed: 51234, peeked: 51234) == 51234)
        #expect(HTTPMitmConnection.claimedSport(parsed: 51234, peeked: nil) == nil)    // line held back past the peek
        #expect(HTTPMitmConnection.claimedSport(parsed: 51234, peeked: 40000) == nil)
        #expect(HTTPMitmConnection.claimedSport(parsed: nil, peeked: nil) == nil)
    }
}

@Suite("Network lineage from the agents' PreToolUse hooks")
struct NetworkLineageHookTests {
    @Test("A hook call links the agent's next child even when argv doesn't show the command; the proxy adds the reasoning later")
    func hookThenProxy() async throws {
        let sink = LineageSink(), l = NetworkLineage(), pid = UUID()
        l.decisionWait = 0.02
        l.emit = { _, t, d in sink.add(t, d) }
        l.noteExec(profileID: pid, ["pid": 500, "ppid": 1, "comm": "codex", "path": "/usr/bin/codex", "argv": "codex"])
        #expect(l.noteToolCall(profileID: pid, id: "call_9", tool: "shell", command: "curl -s https://example.com",
                               reasoning: "", agentPid: 500, agent: "codex"))
        // Codex runs it through its own wrapper: the command isn't in argv.
        l.noteExec(profileID: pid, ["pid": 501, "ppid": 500, "comm": "codex-linux-sa", "path": "/usr/bin/codex-linux-sandbox",
                                    "argv": "codex-linux-sandbox --policy …"])
        l.noteExec(profileID: pid, ["pid": 502, "ppid": 501, "comm": "curl", "path": "/usr/bin/curl", "argv": "/usr/bin/curl --silent https://example.com"])
        // The proxy sees the same call later, with the reasoning: merged, not duplicated.
        #expect(!l.noteToolCall(profileID: pid, id: "call_9", tool: "shell", command: nil, reasoning: "Fetch the page."))
        l.noteFlow(profileID: pid, ["pid": 502, "proto": "tcp", "dst": "93.184.216.34", "dport": 443])
        for _ in 0..<300 where sink.flows.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        let f = try #require(sink.flows.first)
        guard case .object(let agent)? = f["agent"] else { Issue.record("no agent link"); return }
        #expect(NetworkLineageTests.S(agent["tool_use_id"]) == "call_9" && NetworkLineageTests.S(agent["confidence"]) == "fuzzy")
        #expect(l.toolCall(profileID: pid, id: "call_9")?.reasoning == "Fetch the page.")
        #expect(l.toolCall(profileID: pid, id: "call_9")?.command == "curl -s https://example.com")
    }
}
