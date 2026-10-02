import Foundation

/// Explains each network flow out of a workspace, end to end
/// (NETWORK_LINEAGE.md): the agent's tool call and the reasoning behind it,
/// the processes that ran (from the kernel sentry's `exec`), the flow (the
/// sentry's `net_flow`), and the decision the host made about it (the switch's
/// firewall, the MITM's L7 policy, or none for ICMP).
///
/// The tool call arrives first (the AI proxy sees the model's response before
/// the agent runs the command), so a shell the agent starts is linked the
/// moment its `exec` arrives, and every flow below it inherits the link.
public final class NetworkLineage: @unchecked Sendable {
    public static let shared = NetworkLineage()

    public struct ToolCall: Sendable {
        public var id: String
        public var tool: String
        public var command: String?
        public var reasoning: String
        public var at: Date
        /// From the agent's hook: the agent process, and which agent.
        public var agentPid: Int? = nil
        public var agent: String? = nil
    }

    struct ProcKey: Hashable { var pid: Int; var startNs: UInt64 }
    struct Proc {
        var key: ProcKey
        var ppid: Int
        var comm: String
        var exe: String
        var argv: String
        var at: Date
        var link: (toolUseID: String, confidence: String)?
    }

    struct Decision { var action: String; var layer: String; var reason: String?; var host: String?; var at: Date }

    private struct VM {
        var procs: [ProcKey: Proc] = [:]
        /// Latest start per pid, to walk `ppid` (which carries no start time).
        var byPid: [Int: ProcKey] = [:]
        var toolCalls: [ToolCall] = []
        var decisions: [String: Decision] = [:]       // "proto|dst|dport"
        var folded: [String: (first: Date, count: Int, data: [String: AnyJSON])] = [:]
        /// Guest client port → the proxied target (cooperative proxy).
        var proxied: [Int: (host: String, port: Int, at: Date)] = [:]
    }

    private let lock = NSLock()
    private var vms: [UUID: VM] = [:]
    /// How long a tool call waits for its shell, a decision is remembered, and
    /// identical flows fold into one row.
    static let toolCallTTL: TimeInterval = 600
    static let shellWindow: TimeInterval = 30
    static let decisionTTL: TimeInterval = 60
    static let foldWindow: TimeInterval = 60
    static let maxProcs = 4096
    /// How long a flow waits for the switch's decision before it's emitted.
    var decisionWait: TimeInterval = 1.5
    /// Where events go (tests replace it).
    var emit: @Sendable (UUID, String, [String: AnyJSON]) -> Void = { pid, type, data in
        BACEventEmitter.shared.emitDetached(profileID: pid, eventType: type, eventData: data)
    }
    var now: @Sendable () -> Date = { Date() }

    // MARK: Inputs

    /// A tool call the AI proxy saw in a model response. Returns false when
    /// it was already known (a retried or replayed response), so its
    /// reasoning is reported once.
    /// The same call can arrive twice: from the agent's hook (before it runs,
    /// with the agent's pid) and from the AI proxy (with the reasoning). The
    /// second fills in what the first lacked; only the first returns true.
    @discardableResult
    public func noteToolCall(profileID: UUID, id: String, tool: String, command: String?, reasoning: String,
                             agentPid: Int? = nil, agent: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var vm = vms[profileID] ?? VM()
        let t = now()
        if let i = vm.toolCalls.firstIndex(where: { $0.id == id && t.timeIntervalSince($0.at) <= Self.toolCallTTL }) {
            if vm.toolCalls[i].reasoning.isEmpty { vm.toolCalls[i].reasoning = reasoning }
            if vm.toolCalls[i].command == nil { vm.toolCalls[i].command = command }
            if vm.toolCalls[i].agentPid == nil { vm.toolCalls[i].agentPid = agentPid }
            if vm.toolCalls[i].agent == nil { vm.toolCalls[i].agent = agent }
            vms[profileID] = vm
            return false
        }
        vm.toolCalls.removeAll { t.timeIntervalSince($0.at) > Self.toolCallTTL || $0.id == id }
        vm.toolCalls.append(ToolCall(id: id, tool: tool, command: command, reasoning: reasoning, at: t,
                                     agentPid: agentPid, agent: agent))
        vms[profileID] = vm
        return true
    }

    /// The tool call behind `id`, while it's remembered.
    public func toolCall(profileID: UUID, id: String) -> ToolCall? {
        lock.lock(); defer { lock.unlock() }
        return vms[profileID]?.toolCalls.first { $0.id == id }
    }

    /// A sentry `exec` frame: remember the process, and link it to the tool
    /// call whose command it runs.
    public func noteExec(profileID: UUID, _ f: [String: Any]) {
        guard let pid = f["pid"] as? Int else { return }
        let key = ProcKey(pid: pid, startNs: Self.u64(f["start_ns"]))
        let t = now()
        lock.lock(); defer { lock.unlock() }
        var vm = vms[profileID] ?? VM()
        var p = Proc(key: key, ppid: f["ppid"] as? Int ?? 0, comm: f["comm"] as? String ?? "?",
                     exe: f["path"] as? String ?? "", argv: f["argv"] as? String ?? "", at: t, link: nil)
        p.link = Self.matchToolCall(argv: p.argv, calls: vm.toolCalls, at: t)
        if p.link == nil {
            // The agent's hook named its own pid: a process it starts right
            // after a tool call is that call's, even when the agent wrapped the
            // command beyond recognition. Each call links one such process.
            let taken = Set(vm.procs.values.compactMap { $0.link?.toolUseID })
            if let c = vm.toolCalls.reversed().first(where: {
                $0.agentPid == p.ppid && !taken.contains($0.id) && t.timeIntervalSince($0.at) <= 10
            }) { p.link = (c.id, "fuzzy") }
        }
        vm.procs[key] = p
        vm.byPid[pid] = key
        if vm.procs.count > Self.maxProcs {
            // Oldest first; a long-lived agent keeps being re-seen in chains.
            let drop = vm.procs.values.sorted { $0.at < $1.at }.prefix(vm.procs.count - Self.maxProcs * 3 / 4)
            for d in drop { vm.procs[d.key] = nil; if vm.byPid[d.key.pid] == d.key { vm.byPid[d.key.pid] = nil } }
        }
        vms[profileID] = vm
    }

    /// A request that arrived through the guest's proxy bridge, from the
    /// guest client port `sport` (the bridge's `BROMURE-CLIENT` preamble).
    public func noteProxied(profileID: UUID, sport: Int, host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var vm = vms[profileID] ?? VM()
        let t = now()
        vm.proxied = vm.proxied.filter { t.timeIntervalSince($0.value.at) < 120 }
        vm.proxied[sport] = (host, port, t)
        vms[profileID] = vm
    }

    /// The host's decision about a flow (switch L4, MITM L7, binary identity).
    public func noteDecision(profileID: UUID, proto: String, dst: String, dport: Int,
                             action: String, layer: String, reason: String? = nil, host: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var vm = vms[profileID] ?? VM()
        let t = now()
        vm.decisions = vm.decisions.filter { t.timeIntervalSince($0.value.at) < Self.decisionTTL }
        let key = "\(proto)|\(dst)|\(dport)"
        // A deny outranks an allow for the same destination (the L7 layer can
        // refuse what L4 let through).
        if let old = vm.decisions[key], old.action == "deny", action != "deny", t.timeIntervalSince(old.at) < 5 { }
        else { vm.decisions[key] = Decision(action: action, layer: layer, reason: reason, host: host, at: t) }
        vms[profileID] = vm
    }

    /// A sentry `net_flow` frame: resolve the process chain and the tool call
    /// now, wait briefly for the host's decision, then emit `net.flow`.
    public func noteFlow(profileID: UUID, _ f: [String: Any]) {
        guard let pid = f["pid"] as? Int else { return }
        let proto = f["proto"] as? String ?? "ip"
        let dst = f["dst"] as? String ?? "?"
        let dport = f["dport"] as? Int ?? 0
        let leaf = ProcKey(pid: pid, startNs: Self.u64(f["start_ns"]))
        let snapshot = lineage(profileID: profileID, leaf: leaf, frame: f)
        let flowID = UUID().uuidString
        DispatchQueue.global().asyncAfter(deadline: .now() + decisionWait) { [weak self] in
            self?.resolve(profileID: profileID, flowID: flowID, frame: f, proto: proto, dst: dst,
                          dport: dport, processes: snapshot.processes, link: snapshot.link)
        }
    }

    // MARK: Join

    private func lineage(profileID: UUID, leaf: ProcKey, frame f: [String: Any])
        -> (processes: [[String: AnyJSON]], link: (call: ToolCall, confidence: String)?) {
        lock.lock(); defer { lock.unlock() }
        let vm = vms[profileID] ?? VM()
        var chain: [Proc] = []
        var cursor: ProcKey? = vm.procs[leaf] != nil ? leaf : vm.byPid[leaf.pid]
        var seen = Set<Int>()
        while let k = cursor, let p = vm.procs[k], seen.insert(k.pid).inserted, chain.count < 16 {
            chain.append(p)
            cursor = vm.byPid[p.ppid]
        }
        // Processes the host never saw exec (older than the sentry): the
        // frame's own chain, nearest first.
        if chain.isEmpty {
            chain.append(Proc(key: leaf, ppid: 0, comm: f["comm"] as? String ?? "?",
                              exe: f["path"] as? String ?? "", argv: "", at: now(), link: nil))
        }
        if let frameChain = f["chain"] as? [[String: Any]] {
            let known = Set(chain.map(\.key.pid))
            for c in frameChain {
                guard let p = c["pid"] as? Int, !known.contains(p) else { continue }
                if let last = chain.last, last.ppid != 0, last.ppid != p { continue }
                chain.append(Proc(key: ProcKey(pid: p, startNs: Self.u64(c["start_ns"])), ppid: 0,
                                  comm: c["comm"] as? String ?? "?", exe: "", argv: "", at: now(), link: nil))
            }
        }
        var link: (ToolCall, String)?
        for p in chain {
            if let l = p.link, let call = vm.toolCalls.first(where: { $0.id == l.toolUseID }) { link = (call, l.confidence); break }
        }
        // Root → leaf, the 8 nearest the flow (the viewer's cap).
        let processes: [[String: AnyJSON]] = chain.prefix(8).reversed().map { p in
            var d: [String: AnyJSON] = ["pid": .int(p.key.pid), "comm": .string(p.comm)]
            if p.key.startNs != 0 { d["start_ns"] = .int(Int(truncatingIfNeeded: p.key.startNs)) }
            if !p.exe.isEmpty { d["exe"] = .string(p.exe) }
            if !p.argv.isEmpty { d["argv"] = .string(String(p.argv.prefix(256))) }
            return d
        }
        return (processes, link)
    }

    private func resolve(profileID: UUID, flowID: String, frame f: [String: Any], proto: String, dst: String,
                         dport: Int, processes: [[String: AnyJSON]], link: (call: ToolCall, confidence: String)?) {
        let t = now()
        lock.lock()
        var vm = vms[profileID] ?? VM()
        var dst = dst, dport = dport
        var viaProxy = false
        // A loopback connect to the guest's proxy bridge: the real destination
        // is the CONNECT target the bridge tagged with this client port.
        if dst.hasPrefix("127.") || dst == "::1", let sport = f["sport"] as? Int, let p = vm.proxied[sport] {
            dst = p.host; dport = p.port; viaProxy = true
        }
        var decision = viaProxy ? vm.decisions["\(proto)|host:\(dst)|\(dport)"] : vm.decisions["\(proto)|\(dst)|\(dport)"]
        // The MITM decides by hostname (L7): a deny or audit there overrides
        // the switch's allow for the same flow.
        if let host = decision?.host, let l7 = vm.decisions["\(proto)|host:\(host)|\(dport)"],
           l7.action != "allow", decision?.action != "deny" {
            decision = Decision(action: l7.action, layer: l7.layer, reason: l7.reason, host: host, at: l7.at)
        }
        let leafExe = processes.last.flatMap { if case .string(let s)? = $0["exe"] { return s } else { return nil } } ?? "?"
        let foldKey = "\(leafExe)|\(proto)|\(dst)|\(dport)"
        var data: [String: AnyJSON] = [
            "flow_id": .string(flowID), "proto": .string(proto), "dst": .string(dst), "dport": .int(dport),
            "count": .int(max(1, f["count"] as? Int ?? 1)), "processes": .array(processes.map { .object($0) }),
        ]
        if let sport = f["sport"] as? Int { data["sport"] = .int(sport) }
        if viaProxy {
            data["via_proxy"] = .bool(true)
            data["host"] = .string(dst)
            // No explicit decision for a proxied target = the proxy let it
            // through (a refusal is always logged).
            if decision == nil { decision = Decision(action: "allow", layer: "proxy", reason: nil, host: dst, at: t) }
        }
        if let host = decision?.host { data["host"] = .string(host) }
        if let d = decision {
            data["decision"] = .string(d.action == "deny" ? "deny" : d.action == "audit" ? "audit" : "allow")
            data["layer"] = .string(d.layer)
            if let r = d.reason { data["reason"] = .string(r) }
        } else {
            // The switch filters TCP and UDP only; anything else passes untouched.
            data["decision"] = .string(proto == "tcp" || proto == "udp" ? "unknown" : "unfiltered")
        }
        if let link {
            data["agent"] = .object(["tool": .string(link.call.tool), "tool_use_id": .string(String(link.call.id.prefix(128))),
                                     "confidence": .string(link.confidence)])
            if let c = link.call.command { data["command"] = .string(String(c.prefix(256))) }
        }
        // Fold identical flows from the same program for a minute.
        vm.folded = vm.folded.filter { t.timeIntervalSince($0.value.first) < Self.foldWindow || $0.value.count > 0 }
        var flush: [[String: AnyJSON]] = []
        for (k, v) in vm.folded where t.timeIntervalSince(v.first) >= Self.foldWindow {
            if v.count > 0 {
                var d = v.data
                d["count"] = .int(v.count); d["repeat"] = .bool(true)
                d["flow_id"] = .string(UUID().uuidString)   // one id per uploaded event
                flush.append(d)
            }
            vm.folded[k] = nil
        }
        let isRepeat = vm.folded[foldKey] != nil
        if isRepeat { vm.folded[foldKey]!.count += max(1, f["count"] as? Int ?? 1); vm.folded[foldKey]!.data = data }
        else { vm.folded[foldKey] = (t, 0, data) }
        vms[profileID] = vm
        lock.unlock()
        for d in flush { emit(profileID, "net.flow", d) }
        if !isRepeat { emit(profileID, "net.flow", data) }
    }

    // MARK: Matching a shell to a tool call

    /// The tool call whose command this argv runs, within `shellWindow` of
    /// the response. Agents wrap commands (Claude Code: `bash -c -l '…
    /// eval '"'"'<cmd>'"'"' …'`), so both sides are compared with quoting and
    /// whitespace removed.
    static func matchToolCall(argv: String, calls: [ToolCall], at: Date) -> (toolUseID: String, confidence: String)? {
        guard !argv.isEmpty else { return nil }
        let a = normalize(argv)
        let recent = calls.filter { at.timeIntervalSince($0.at) <= shellWindow && $0.command != nil }
        // Newest first: an agent re-running a command means the latest call.
        for c in recent.reversed() {
            let n = normalize(c.command!)
            if n.count >= 2, a.contains(n) { return (c.id, "exact") }
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        String(s.unicodeScalars.filter { !"'\"\\ \t\n".unicodeScalars.contains($0) }.map(Character.init))
    }

    static func u64(_ v: Any?) -> UInt64 {
        if let n = v as? NSNumber { return n.uint64Value }
        if let s = v as? String { return UInt64(s) ?? 0 }
        return 0
    }

    func reset(profileID: UUID) { lock.lock(); vms[profileID] = nil; lock.unlock() }
}
