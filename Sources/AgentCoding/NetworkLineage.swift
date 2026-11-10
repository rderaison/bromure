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
        /// The parent at exec, exactly: the frame's `chain[0]` (pid AND start
        /// time). A pid is reused within minutes, so `ppid` alone can name a
        /// later process. nil = an older sentry that sent no chain.
        var parent: ProcKey? = nil
        var comm: String
        var exe: String
        var argv: String
        var at: Date
        var link: (toolUseID: String, confidence: String)?
    }

    struct Decision { var action: String; var layer: String; var reason: String?; var host: String?; var at: Date }

    private struct VM {
        var procs: [ProcKey: Proc] = [:]
        /// Latest start per pid: a flow's leaf, and the parent of a process
        /// whose exec carried no chain.
        var byPid: [Int: ProcKey] = [:]
        var toolCalls: [ToolCall] = []
        var decisions: [String: Decision] = [:]       // "proto|dst|dport"
        var folded: [String: (first: Date, count: Int, data: [String: AnyJSON])] = [:]
        /// Guest client port → the proxied target (cooperative proxy), and
        /// the claimant record (`claimants[port].id`) it was stored under.
        var proxied: [Int: (host: String, port: Int, at: Date, claim: UInt64)] = [:]
        /// Client ports claimed for two different targets, or by two
        /// connections: neither is believed (see `noteProxied`).
        var contested: [Int: Date] = [:]
        /// Connections that opened with a preamble naming each client port.
        var claimants: [Int: (count: Int, at: Date, id: UInt64)] = [:]
    }

    /// One connection's claim to a client port: the claimant record its
    /// preamble created (`noteClaimant`), which only its own target may be
    /// stored under (`noteProxied`).
    public struct Claim: Sendable { public let sport: Int; let id: UInt64 }
    private var nextClaimID: UInt64 = 0

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
    /// A proxied flow with no decision yet is looked at again this many
    /// times, `decisionWait` apart: the MiTM's verdict (its allow, or an L7
    /// deny after the handshake and the request) can land well after the
    /// first look. Still none after that: `unknown`, never a guessed allow.
    var proxyDecisionPolls = 6
    /// Where events go (tests replace it).
    var emit: @Sendable (UUID, String, [String: AnyJSON]) -> Void = { pid, type, data in
        BACEventEmitter.shared.emitDetached(profileID: pid, eventType: type, eventData: data)
    }
    var now: @Sendable () -> Date = { Date() }
    /// The names the guests' DNS answers gave an IP (the switch's snoop
    /// cache), most likely first. A direct flow carries only its address;
    /// the switch's decision names the host only when it logged one (its
    /// report is rate-limited per destination), so an agent's own fetch of a
    /// page it had just looked up went unmatched.
    var hostNames: @Sendable (String) -> [String] = { _ in [] }
    /// `hostNames`' names the guest asked for, without the CNAME targets its
    /// answers also gave the address. nil: `hostNames` as they are.
    var queriedHostNames: (@Sendable (String) -> [String])?

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
        if let first = (f["chain"] as? [[String: Any]])?.first, let pp = first["pid"] as? Int, pp == p.ppid {
            p.parent = ProcKey(pid: pp, startNs: Self.u64(first["start_ns"]))
        }
        // By its words only: a timing link waits for the flow's last look,
        // when the call a hook line brings late has had its chance.
        p.link = Self.link(p, in: vm, at: t, timing: false)
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
    ///
    /// The line comes from the guest, and any process there that can open
    /// vsock could send one (agentd's bridge isn't authenticated to the
    /// host), so a claim is held to what it can honestly mean. It only
    /// relabels a loopback flow to the bridge itself (see `resolve`), and a
    /// port claimed for two different targets is contested: neither claim
    /// is believed, whichever came first. The bridge always sends the real
    /// line for a connection that went through it, so a forged line for
    /// that connection can only ever make its row stay "127.0.0.1:<bridge>"
    /// — never name another host.
    ///
    /// A target is stored only under the claimant record of the connection
    /// that sent it, while that record is still live and that connection is
    /// the port's only claimant (Finding CWE-345, "A forged proxy preamble
    /// still relabels a flow after its claimant record expires": a direct
    /// connection holding its request past the record's 120 s, then sending
    /// it, was believed again — and a later connection from the same port
    /// counted 1 afresh and was labelled with it).
    public func noteProxied(profileID: UUID, claim: Claim, host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var vm = vms[profileID] ?? VM()
        let t = now()
        let sport = claim.sport
        vm.proxied = vm.proxied.filter { t.timeIntervalSince($0.value.at) < 120 }
        vm.contested = vm.contested.filter { t.timeIntervalSince($0.value) < 120 }
        vm.claimants = vm.claimants.filter { t.timeIntervalSince($0.value.at) < 120 }
        guard let live = vm.claimants[sport], live.id == claim.id, live.count == 1 else {
            vms[profileID] = vm
            return
        }
        if vm.contested[sport] != nil {
            vm.contested[sport] = t
        } else if let held = vm.proxied[sport], held.host != host || held.port != port {
            vm.proxied[sport] = nil
            vm.contested[sport] = t
        } else {
            vm.proxied[sport] = (host, port, t, claim.id)
        }
        vms[profileID] = vm
    }

    /// A connection to the MITM opened with a preamble naming `sport` — called
    /// as soon as its first line arrives, before the request is read. agentd
    /// writes that line the moment it accepts the client, so a connection
    /// through the bridge registers here at once; a second connection naming
    /// the same port (a forged line, however early or however long its
    /// request is held back) contests the port before the flow is resolved.
    @discardableResult
    public func noteClaimant(profileID: UUID, sport: Int) -> Claim {
        lock.lock(); defer { lock.unlock() }
        var vm = vms[profileID] ?? VM()
        let t = now()
        vm.claimants = vm.claimants.filter { t.timeIntervalSince($0.value.at) < 120 }
        vm.contested = vm.contested.filter { t.timeIntervalSince($0.value) < 120 }
        nextClaimID += 1
        let n = (vm.claimants[sport]?.count ?? 0) + 1
        // A fresh record (the earlier one aged out) is a new claimant: a
        // target stored under the old one doesn't carry over to it.
        let id = n == 1 ? nextClaimID : vm.claimants[sport]!.id
        vm.claimants[sport] = (n, t, id)
        if n > 1 { vm.contested[sport] = t; vm.proxied[sport] = nil }
        if n == 1, let held = vm.proxied[sport], held.claim != id { vm.proxied[sport] = nil }
        vms[profileID] = vm
        // A second claimant's id matches no record: it can never store.
        return Claim(sport: sport, id: nextClaimID)
    }

    /// The guest proxy bridge's loopback ports (agentd's listener): 65534,
    /// or 8080 on a workspace resumed from an older daemon's snapshot.
    static let bridgePorts: Set<Int> = [SessionDisk.guestProxyPort, 8080]

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
        // Nearest first: the policy note goes to the agent whose tree this is.
        // A raw packet-socket send has no destination to match a denial to.
        if proto != "packet" {
            PolicySteering.shared.noteFlow(profileID: profileID, dst: dst, dport: dport,
                                           pids: snapshot.processes.reversed().compactMap {
                                               if case .int(let p)? = $0["pid"] { return p }; return nil })
        }
        let flowID = UUID().uuidString
        scheduleResolve(profileID: profileID, flowID: flowID, frame: f, proto: proto, dst: dst,
                        dport: dport, processes: snapshot.processes, link: snapshot.link, polls: 0)
    }

    private func scheduleResolve(profileID: UUID, flowID: String, frame f: [String: Any], proto: String, dst: String,
                                 dport: Int, processes: [[String: AnyJSON]], link: (call: ToolCall, confidence: String)?,
                                 polls: Int, hookPolls: Int = 0) {
        DispatchQueue.global().asyncAfter(deadline: .now() + decisionWait) { [weak self] in
            self?.resolve(profileID: profileID, flowID: flowID, frame: f, proto: proto, dst: dst,
                          dport: dport, processes: processes, link: link, polls: polls, hookPolls: hookPolls)
        }
    }

    /// Extra looks a flow gets while its call may still be on its way
    /// (`hookLag`), `decisionWait` apart.
    static let maxHookPolls = 3

    // MARK: Join

    private func lineage(profileID: UUID, leaf: ProcKey, frame f: [String: Any])
        -> (processes: [[String: AnyJSON]], link: (call: ToolCall, confidence: String)?) {
        lock.lock(); defer { lock.unlock() }
        let vm = vms[profileID] ?? VM()
        var chain: [Proc] = []
        var cursor: ProcKey? = Self.resolve(leaf, in: vm)
        var seen = Set<ProcKey>()
        while let k = cursor, let p = vm.procs[k], seen.insert(k).inserted, chain.count < 16 {
            chain.append(p)
            cursor = Self.parentKey(of: p, in: vm)
        }
        // Processes the host never saw exec (older than the sentry): the
        // frame's own chain, nearest first.
        if chain.isEmpty {
            chain.append(Proc(key: leaf, ppid: 0, comm: f["comm"] as? String ?? "?",
                              exe: f["path"] as? String ?? "", argv: "", at: now(), link: nil))
        }
        // The kernel's chain for this flow (nearest first, by pid and start
        // time) picks up where the walk ends: after the walk's last process,
        // or its exact parent. All of it when the walk knew only the leaf.
        if let frameChain = f["chain"] as? [[String: Any]] {
            let keys: [ProcKey] = frameChain.compactMap { c in
                (c["pid"] as? Int).map { ProcKey(pid: $0, startNs: Self.u64(c["start_ns"])) }
            }
            let last = chain.last!
            let from: Int? = {
                if let i = keys.firstIndex(of: last.key) { return i + 1 }
                if let parent = last.parent, let i = keys.firstIndex(of: parent) { return i }
                return chain.count == 1 ? 0 : nil
            }()
            if let from {
                for (i, c) in frameChain.enumerated() where i >= from && i < keys.count {
                    let k = keys[i]
                    guard !seen.contains(k), chain.count < 16 else { continue }
                    seen.insert(k)
                    chain.append(vm.procs[k] ?? Proc(key: k, ppid: 0, comm: c["comm"] as? String ?? "?",
                                                     exe: "", argv: "", at: now(), link: nil))
                }
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

    /// The exec record for `k`: the exact identity, else — a module that
    /// reports a thread's own start time, not its group leader's (Finding
    /// CWE-670, "Lineage misses the exec record when start_ns is not the group
    /// leader's") — the latest process with that pid, but only one that
    /// started no later than `k` (a thread of it; a pid reused since started
    /// after). No start time at all: the latest with that pid, as before.
    private static func resolve(_ k: ProcKey, in vm: VM) -> ProcKey? {
        if vm.procs[k] != nil { return k }
        guard let b = vm.byPid[k.pid] else { return nil }
        if k.startNs == 0 { return b }
        return b.startNs != 0 && b.startNs <= k.startNs ? b : nil
    }

    /// How long after a process's exec its tool call may still arrive: an
    /// agent's hook line comes through the outbox (read every 0.7 s), and
    /// omp runs its hook without waiting for it, so the command it runs is
    /// often under way before the host hears of the call.
    static let hookLag: TimeInterval = 3
    /// How far a child may precede the call it's tied to by timing alone (no
    /// words in common): an agent that doesn't wait for its hook starts the
    /// command at the same moment, never seconds before.
    static let fuzzyLead: TimeInterval = 2

    /// The tool call `p` runs, from what's known now: the command in its
    /// argv (a shell the agent started), the command holding its argv (a
    /// program an in-process shell started), or -- the agent's hook having
    /// named its pid -- the agent's next child after the call.
    private static func link(_ p: Proc, in vm: VM, at t: Date, timing: Bool) -> (toolUseID: String, confidence: String)? {
        // Bromure's own hook runs as the agent's child, right at the call:
        // never the call's command.
        guard !p.argv.contains("/.bromure/agent-status.sh") else { return nil }
        // Nor the agent itself: its argv can quote a command (a prompt given
        // on its command line), and every flow of its own would inherit it.
        guard !vm.toolCalls.contains(where: { $0.agentPid == p.key.pid }) else { return nil }
        let calls = vm.toolCalls.filter { $0.at.timeIntervalSince(p.at) <= hookLag }
        if let l = matchToolCall(argv: p.argv, calls: calls, at: p.at) { return l }
        if let l = matchInProcessShell(argv: p.argv, ppid: p.ppid, calls: calls, at: p.at) { return l }
        guard timing else { return nil }
        // The agent's hook named its own pid: a process it starts right
        // after a tool call is that call's, even when the agent wrapped the
        // command beyond recognition. Each call links one such process.
        let taken = Set(vm.procs.values.compactMap { $0.key == p.key ? nil : $0.link?.toolUseID })
        // Only a call that runs a command starts one (a fetch never does).
        if let c = calls.reversed().first(where: {
            let after = p.at.timeIntervalSince($0.at)
            return $0.agentPid == p.ppid && runsCommand($0) && !taken.contains($0.id)
                && after <= 10 && after >= -fuzzyLead
        }) { return (c.id, "fuzzy") }
        return nil
    }

    /// A call that runs a command: a shell tool by name, or one whose hook
    /// line holds a command line -- the hook writes any other tool's input
    /// as its JSON (a fetch's `{"url": …}`).
    static func runsCommand(_ c: ToolCall) -> Bool {
        if LLMEventExtractor.isCommandTool(c.tool) { return true }
        guard let cmd = c.command?.trimmingCharacters(in: .whitespaces), !cmd.isEmpty else { return false }
        return !(cmd.hasPrefix("{") && (try? JSONSerialization.jsonObject(with: Data(cmd.utf8))) != nil)
    }

    /// A flow none of whose processes was linked when it started: its tool
    /// call may have arrived since (see `hookLag`). Links what it can now,
    /// leaf first, and keeps the links for the processes' later flows.
    private static func lateLink(_ processes: [[String: AnyJSON]], in vm: inout VM, timing: Bool)
        -> (toolUseID: String, confidence: String)? {
        // Words first, over the whole chain: a shell's own command outranks
        // a timing guess about its parent.
        if timing, let l = lateLink(processes, in: &vm, timing: false) { return l }
        // Only what the agent started: the agent and whatever launched it
        // (a shell whose argv quotes a prompt) would pass a link to every
        // flow the agent makes.
        let agents = Set(vm.toolCalls.compactMap(\.agentPid))
        let below = processes.lastIndex { d in
            if case .int(let pid)? = d["pid"] { return agents.contains(pid) }
            return false
        }.map { processes.index(after: $0) } ?? processes.startIndex
        for d in processes[below...].reversed() {
            guard case .int(let pid)? = d["pid"] else { continue }
            var k = ProcKey(pid: pid, startNs: 0)
            if case .int(let ns)? = d["start_ns"] { k.startNs = UInt64(truncatingIfNeeded: ns) }
            guard let key = resolve(k, in: vm), var p = vm.procs[key] else { continue }
            if let l = p.link { return l }
            guard let l = link(p, in: vm, at: p.at, timing: timing) else { continue }
            p.link = l
            vm.procs[key] = p
            return l
        }
        return nil
    }

    /// Whether a process of the chain started within `hookLag` of `t`: its
    /// call may still be on its way.
    private static func recentlyStarted(_ processes: [[String: AnyJSON]], in vm: VM, at t: Date) -> Bool {
        processes.contains { d in
            guard case .int(let pid)? = d["pid"] else { return false }
            var k = ProcKey(pid: pid, startNs: 0)
            if case .int(let ns)? = d["start_ns"] { k.startNs = UInt64(truncatingIfNeeded: ns) }
            guard let key = resolve(k, in: vm), let p = vm.procs[key], p.link == nil else { return false }
            return t.timeIntervalSince(p.at) < hookLag
        }
    }

    /// The process that started `p`: the exact identity its exec recorded,
    /// else (an older sentry) the latest process with its ppid, but only one
    /// that started before `p` — a pid reused afterwards isn't its parent.
    private static func parentKey(of p: Proc, in vm: VM) -> ProcKey? {
        if let parent = p.parent { return resolve(parent, in: vm) ?? parent }
        guard p.ppid != 0, let k = vm.byPid[p.ppid] else { return nil }
        if k.startNs != 0, p.key.startNs != 0, k.startNs > p.key.startNs { return nil }
        return k
    }

    private func resolve(profileID: UUID, flowID: String, frame f: [String: Any], proto: String, dst: String,
                         dport: Int, processes: [[String: AnyJSON]], link: (call: ToolCall, confidence: String)?,
                         polls: Int = 0, hookPolls: Int = 0) {
        let original = (dst, dport)
        let t = now()
        lock.lock()
        var vm = vms[profileID] ?? VM()
        var dst = dst, dport = dport
        var viaProxy = false
        // A loopback connect to the guest's proxy bridge: the real destination
        // is the CONNECT target the bridge tagged with this client port.
        // Only a flow to the bridge itself: a loopback connection anywhere
        // else is never relabelled by a (guest-written) claim.
        if dst.hasPrefix("127.") || dst == "::1", Self.bridgePorts.contains(dport),
           let sport = f["sport"] as? Int, let p = vm.proxied[sport],
           // Only while the claimant it was stored under is the port's live,
           // sole one.
           let live = vm.claimants[sport], live.id == p.claim, live.count == 1,
           t.timeIntervalSince(live.at) < 120 {
            dst = p.host; dport = p.port; viaProxy = true
        }
        var decision = viaProxy ? vm.decisions["\(proto)|host:\(dst)|\(dport)"] : vm.decisions["\(proto)|\(dst)|\(dport)"]
        // The MITM decides by hostname (L7): a deny or audit there overrides
        // the switch's allow for the same flow.
        if let host = decision?.host, let l7 = vm.decisions["\(proto)|host:\(host)|\(dport)"],
           l7.action != "allow", decision?.action != "deny" {
            decision = Decision(action: l7.action, layer: l7.layer, reason: l7.reason, host: host, at: l7.at)
        }
        // Proxied, and the MiTM hasn't said yet: look again rather than guess
        // (Finding CWE-670, "Proxied flows are recorded as allowed before an
        // L7 deny can land").
        if viaProxy, decision == nil, polls < proxyDecisionPolls {
            lock.unlock()
            scheduleResolve(profileID: profileID, flowID: flowID, frame: f, proto: proto, dst: original.0,
                            dport: original.1, processes: processes, link: link, polls: polls + 1,
                            hookPolls: hookPolls)
            return
        }
        let leafExe = processes.last.flatMap { if case .string(let s)? = $0["exe"] { return s } else { return nil } } ?? "?"
        let foldKey = "\(leafExe)|\(proto)|\(dst)|\(dport)"
        var data: [String: AnyJSON] = [
            "flow_id": .string(flowID), "proto": .string(proto), "dst": .string(dst), "dport": .int(dport),
            "count": .int(max(1, f["count"] as? Int ?? 1)), "processes": .array(processes.map { .object($0) }),
        ]
        if let sport = f["sport"] as? Int { data["sport"] = .int(sport) }
        if let dev = f["dev"] as? String { data["dev"] = .string(dev) }
        if viaProxy {
            data["via_proxy"] = .bool(true)
            data["host"] = .string(dst)
            // Still no decision: `unknown` below. The proxy logs its allows
            // only when allowed connections are logged, and an L7 refusal
            // only once it has read the request — silence isn't a verdict.
        }
        if let host = decision?.host { data["host"] = .string(host) }
        // No decision named it: what the guest's DNS answers called it --
        // when one site was looked up for the address. A shared (CDN)
        // address's first cached name is as likely another site's; an agent
        // fetch matched below names the one it was. A CNAME answer's target
        // is no second site: counted, it left every CDN-fronted flow without
        // a host (Finding "CNAME responses erase the hostname from unlinked
        // network flows").
        if data["host"] == nil, !viaProxy {
            let cached = hostNames(dst)
            let asked = queriedHostNames?(dst) ?? cached
            let named = asked.isEmpty ? cached : asked
            let names = Set(named.map(Self.bareHost)).subtracting(["", "?"])
            if names.count == 1, let name = named.first { data["host"] = .string(name) }
        }
        if proto == "packet" {
            // A raw packet socket (AF_PACKET): frames built below the socket
            // layer, so no destination here. The switch still filters and
            // intercepts whatever IP they carry, under its own events.
            data["decision"] = .string("raw")
        } else if let d = decision {
            data["decision"] = .string(d.action == "deny" ? "deny" : d.action == "audit" ? "audit" : "allow")
            data["layer"] = .string(d.layer)
            if let r = d.reason { data["reason"] = .string(r) }
        } else {
            // The switch filters TCP and UDP only; anything else passes untouched.
            data["decision"] = .string(proto == "tcp" || proto == "udp" ? "unknown" : "unfiltered")
        }
        // No spawned process claims it, and the agent itself made it: its own
        // built-in fetch (Claude's WebFetch, omp's fetch...), which starts no
        // process for the exec match. The agent's recent call whose input
        // names this host. Without a host to match, nothing: the same process
        // talks to its model's API all the time.
        // Only the flow's own process -- the leaf -- can be the agent here:
        // an ancestor's pid in the chain made every descendant (a dev server
        // it started, a command whose own link expired) eligible (Finding
        // CWE-670, "Agent-fetch fallback attributes descendant process
        // traffic to the agent's tool call").
        var link = link
        // Linked late: the call reached the host after the process started.
        // While a process of the chain is that recent, look again rather
        // than settle for a timing guess or nothing; the last look allows
        // the agent's-next-child link too.
        if link == nil {
            let last = hookPolls >= Self.maxHookPolls || !Self.recentlyStarted(processes, in: vm, at: t)
            if let l = Self.lateLink(processes, in: &vm, timing: last),
               let call = vm.toolCalls.first(where: { $0.id == l.toolUseID }) {
                link = (call, l.confidence)
            } else if !last {
                vms[profileID] = vm
                lock.unlock()
                scheduleResolve(profileID: profileID, flowID: flowID, frame: f, proto: proto, dst: original.0,
                                dport: original.1, processes: processes, link: nil, polls: polls,
                                hookPolls: hookPolls + 1)
                return
            }
        }
        if link == nil, let leaf = processes.last, case .int(let leafPid)? = leaf["pid"] {
            var leafKey = ProcKey(pid: leafPid, startNs: 0)
            if case .int(let ns)? = leaf["start_ns"] { leafKey.startNs = UInt64(truncatingIfNeeded: ns) }
            // The name the decision gave this flow is its destination, and
            // only that. Without one: the address (the proxied target), and
            // -- as aliases -- what the guest's DNS answers called it, which
            // for a shared (CDN) address is every site hosted there (Finding
            // CWE-670, "Agent fetch flow can be attributed to a different
            // fetch on a shared IP").
            let hosts = [decision?.host ?? dst]
            let aliases = decision?.host == nil && !viaProxy ? hostNames(dst) : []
            if let m = Self.matchAgentFetch(hosts: hosts, aliases: aliases, leafPid: leafPid,
                                            leafSeenAt: Self.resolve(leafKey, in: vm).flatMap { vm.procs[$0]?.at },
                                            calls: vm.toolCalls, at: t),
               let call = vm.toolCalls.first(where: { $0.id == m.toolUseID }) {
                link = (call, m.confidence)
                // The DNS name the call named, not just the first cached.
                if decision?.host == nil, !viaProxy, let h = m.host { data["host"] = .string(h) }
            }
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
    /// eval '"'"'<cmd>'"'"' …'`), so both sides are cut into words with
    /// quoting removed, and the command's words must appear in the argv's,
    /// in order and whole (Finding CWE-670, "Tool-call matching treats a
    /// 2-character substring as an exact link": a Bash call of `id` claimed
    /// any argv containing those letters — `width`, a URL path — and, newest
    /// first, stole longer commands it happened to sit inside). Of the calls
    /// that match, the most specific (longest) command wins, newest on a tie;
    /// only one of at least `exactMinLength` characters is an exact link.
    static func matchToolCall(argv: String, calls: [ToolCall], at: Date) -> (toolUseID: String, confidence: String)? {
        guard !argv.isEmpty else { return nil }
        let a = words(argv)
        let recent = calls.filter { at.timeIntervalSince($0.at) <= shellWindow && $0.command != nil }
        var best: (call: ToolCall, length: Int)?
        for c in recent {
            let w = words(c.command!)
            let length = w.reduce(0) { $0 + $1.count }
            guard length >= 2, contains(a, w) else { continue }
            if best == nil || length > best!.length || (length == best!.length && c.at >= best!.call.at) {
                best = (c, length)
            }
        }
        guard let best else { return nil }
        return (best.call.id, best.length >= exactMinLength ? "exact" : "likely")
    }

    /// An agent whose shell runs inside its own process (omp's brush): no
    /// shell exec carries the command -- each program in it is exec'd by the
    /// agent with only its own words (`curl -s URL` of `cd /tmp && curl -s
    /// URL | head`), so the command never appears in an argv. Such a
    /// process, the agent's own child (its hook named the agent's pid), is
    /// the call's whose command holds its argv's words, whole and in order;
    /// the newest such call within `shellWindow` (or `hookLag` before it).
    /// "exact" from `exactMinLength` characters, as for a shell.
    static func matchInProcessShell(argv: String, ppid: Int, calls: [ToolCall], at: Date)
        -> (toolUseID: String, confidence: String)? {
        var a = words(argv)
        guard !a.isEmpty else { return nil }
        let length = a.reduce(0) { $0 + $1.count }
        guard length >= 2 else { return nil }
        let candidates = calls.filter { c in
            guard c.agentPid == ppid, let cmd = c.command else { return false }
            let age = at.timeIntervalSince(c.at)
            return age <= shellWindow && age >= -hookLag
        }
        func holding(_ argvWords: [String]) -> ToolCall? {
            candidates.filter { contains(words($0.command!), argvWords) }.max { $0.at < $1.at }
        }
        var best = holding(a)
        // A program run by its path: `/usr/bin/curl` for a command's `curl`.
        if best == nil, a[0].contains("/"), let base = a[0].split(separator: "/").last {
            a[0] = String(base)
            best = holding(a)
        }
        guard let best else { return nil }
        return (best.id, length >= exactMinLength ? "exact" : "likely")
    }

    /// How long after an agent's tool call a connection from the agent's own
    /// process can be that call's fetch (a slow page, a redirect).
    static let agentFetchWindow: TimeInterval = 120

    /// A flow the agent's own process opened -- its pid is the flow's leaf,
    /// never just somewhere in its ancestry -- to `host`: the newest tool
    /// call of that agent, within `agentFetchWindow`, whose input names that
    /// host -- in a URL, or as the host itself (`www.` aside; a subdomain of
    /// it counts, a redirect to one being common). An IP destination matches
    /// only an input naming that IP. `leafSeenAt`, when the host saw the leaf
    /// exec: a process started after the call isn't the one that made it (a
    /// reused pid). "likely": the match is by host and time, not by process.
    static func matchAgentFetch(host: String, leafPid: Int, leafSeenAt: Date?, calls: [ToolCall], at: Date)
        -> (toolUseID: String, confidence: String, host: String?)? {
        matchAgentFetch(hosts: [host], leafPid: leafPid, leafSeenAt: leafSeenAt, calls: calls, at: at)
    }

    /// `matchAgentFetch` for a destination known by several names. `hosts`
    /// name the destination itself (the decision's host, or the address):
    /// any of them named counts. `aliases` are the names the guest's DNS
    /// gave the address -- on a shared (CDN) address, unrelated sites too:
    /// one counts only when it's the only alias the best-matching calls
    /// name; calls naming two different ones are two fetches the address
    /// can't tell apart, and the flow is nobody's. `host`: the alias the
    /// call named, when that's what matched.
    static func matchAgentFetch(hosts: [String], aliases: [String] = [], leafPid: Int, leafSeenAt: Date?,
                                calls: [ToolCall], at: Date)
        -> (toolUseID: String, confidence: String, host: String?)? {
        let hs = Set(hosts.map(Self.bareHost)).subtracting(["", "?"])
        let al = Set(aliases.map(Self.bareHost)).subtracting(["", "?"]).subtracting(hs)
        guard !hs.isEmpty || !al.isEmpty else { return nil }
        // 2: the host itself named; 1: a subdomain of it, or it of one (a
        // redirect); 0: neither. With the aliases the call matched by, when
        // no host of `hosts` matched as well.
        func rank(_ named: String, _ h: String) -> Int {
            named == h ? 2 : h.hasSuffix("." + named) || named.hasSuffix("." + h) ? 1 : 0
        }
        func rank(_ c: ToolCall) -> (rank: Int, via: Set<String>) {
            guard let cmd = c.command else { return (0, []) }
            let named = Self.hostsNamed(in: cmd)
            let direct = named.flatMap { n in hs.map { rank(n, $0) } }.max() ?? 0
            var best = direct, via = Set<String>()
            for n in named { for a in al {
                let r = rank(n, a)
                guard r > direct, r >= best, r > 0 else { continue }
                if r > best { best = r; via = [] }
                via.insert(a)
            } }
            return (best, via)
        }
        let candidates: [(call: ToolCall, rank: Int, via: Set<String>)] = calls.compactMap { c in
            guard let pid = c.agentPid, pid == leafPid else { return nil }
            // A command's traffic is its own processes', never the agent's:
            // a Bash `curl https://api.github.com` names a host, but the
            // agent connecting to github.com isn't it.
            guard !runsCommand(c) else { return nil }
            if let seen = leafSeenAt, seen > c.at.addingTimeInterval(1) { return nil }
            let age = at.timeIntervalSince(c.at)
            guard age >= -2, age <= agentFetchWindow else { return nil }
            let r = rank(c)
            return r.rank > 0 ? (c, r.rank, r.via) : nil
        }
        // The best-named host first, then the newest: a flow the sentry
        // reported late (repeats folded) still goes to the call naming it.
        // A call naming the destination itself beats one as well named by
        // an alias only.
        func key(_ c: (call: ToolCall, rank: Int, via: Set<String>)) -> (Int, Int, Date) {
            (c.rank, c.via.isEmpty ? 1 : 0, c.call.at)
        }
        guard let best = candidates.max(by: { key($0) < key($1) }) else { return nil }
        guard !best.via.isEmpty else { return (best.call.id, "likely", nil) }
        // Matched by an alias only (so is every call as good): they must all
        // name the same one, or the shared address can't say whose fetch
        // this was.
        let named = candidates.filter { $0.rank == best.rank }.reduce(into: Set<String>()) { $0.formUnion($1.via) }
        guard named.count == 1 else { return nil }
        return (best.call.id, "likely", named.first)
    }

    /// A host as compared: lowercased, no port, brackets, trailing dot or `www.`.
    static func bareHost(_ s: String) -> String {
        var h = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]. "))
        if h.hasPrefix("host:") { h = String(h.dropFirst(5)) }
        if !h.contains("::"), let colon = h.lastIndex(of: ":"), h[h.index(after: colon)...].allSatisfy(\.isNumber) {
            h = String(h[..<colon])
        }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    /// The hosts a tool call's input names: every URL's host, and the
    /// values of host-like fields (`host`, `domain`, `hostname`).
    static func hostsNamed(in input: String) -> Set<String> {
        var out = Set<String>()
        let ns = input as NSString
        if let urls = try? NSRegularExpression(pattern: #"[a-zA-Z][a-zA-Z0-9+.-]*://([^/\s"'?#@]+@)?([^/\s"'?#:\\]+)"#) {
            for m in urls.matches(in: input, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 2 {
                let r = m.range(at: 2)
                if r.location != NSNotFound { out.insert(bareHost(ns.substring(with: r))) }
            }
        }
        if let data = input.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["host", "hostname", "domain"] {
                if let v = obj[key] as? String { out.insert(bareHost(v)) }
            }
        }
        out.remove("")
        return out
    }

    /// Below this many characters (quoting and spaces aside) a command is
    /// too common a word sequence to call its match exact (`id`, `ls -la`).
    static let exactMinLength = 8

    /// Words with quotes and backslashes removed (empty ones dropped).
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map { w in
            String(w.unicodeScalars.filter { !"'\"\\".unicodeScalars.contains($0) }.map(Character.init))
        }.filter { !$0.isEmpty }
    }

    /// `needle` occurs in `haystack` as a contiguous run of whole words.
    static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
            if Array(haystack[i..<(i + needle.count)]) == needle { return true }
        }
        return false
    }

    static func u64(_ v: Any?) -> UInt64 {
        if let n = v as? NSNumber { return n.uint64Value }
        if let s = v as? String { return UInt64(s) ?? 0 }
        return 0
    }

    func reset(profileID: UUID) { lock.lock(); vms[profileID] = nil; lock.unlock() }
}
