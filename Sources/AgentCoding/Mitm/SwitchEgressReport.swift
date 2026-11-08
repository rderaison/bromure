import Foundation
#if canImport(SandboxEngine)
import SandboxEngine
#endif

/// The Security Log line and Security Timeline event for a flow the switch's
/// egress firewall decided (VMNetSwitch.EgressEvent): the switch (in
/// SandboxEngine) can't reach these AgentCoding sinks, so the app's observer
/// calls this. Shared by the macOS app and the Linux daemon, so a switch
/// decision makes the same row on both.
enum SwitchEgressReport {
    /// `engine`: the MiTM engine whose guardrails explain an identity-gate
    /// denial (nil: the event goes without its reason).
    static func record(_ ev: VMNetSwitch.EgressEvent, engine: MitmEngine? = nil) {
        let proto = ev.proto == 6 ? "tcp" : ev.proto == 17 ? "udp" : ev.proto == 41 ? "ipv6" : "ip\(ev.proto)"
        let host = ev.proto == 41 ? "(no IPv6 rules)"
                 : (ev.hostnames.first ?? UtunPacket.ipString(ev.dstIP))
        let dst = ev.port > 0 ? "\(host):\(ev.port)" : host
        let action = ev.denied ? "deny" : "allow"
        let who = ev.profileID.map { String($0.uuidString.prefix(8)) } ?? "-"
        let ipString = UtunPacket.ipString(ev.dstIP)
        // The trailing segments of a connection the MiTM just cut (and
        // reported as "connection closed"): not a second, "deny" row.
        if ev.denied, ev.midFlow, let pid = ev.profileID,
           EgressConnectionRegistry.shared.recentlyCut(profileID: pid, hostnames: ev.hostnames,
                                                       ip: ipString, port: Int(ev.port)) {
            return
        }
        var eventData: [String: AnyJSON] = [
            "action": .string(action),
            "layer": .string("l4"),
            "proto": .string(proto),
            "host": .of(ev.hostnames.first),
            "ip": .string(ipString),
            "port": .int(Int(ev.port)),
            "hostnames": .array(ev.hostnames.map { .string($0) }),
            // Which rule decided (nil: the default action, or a
            // transport drop) — the timeline names it and offers to
            // switch it off / remove it.
            "rule": .of(ev.rule),
            "by_policy": .bool(ev.byPolicy),
        ]
        // The program the identity gate denied: the drawer row's Allow names it.
        if let exe = ev.exe {
            eventData["exe"] = .string(exe)
            // And why: the policy allows the destination, but not for this
            // program. Without it the timeline said "default policy" and the
            // agent was told the firewall "denies what no rule allows".
            if ev.denied, let pid = ev.profileID,
               let why = engine?.guardrailsConfig(for: pid)?.egressPolicy?
                .identityDenialReason(hostnames: ev.hostnames, ip: ev.dstIP, port: ev.port, exe: exe) {
                eventData["reason"] = .string(why)
            }
        }
        // One more connection to a destination already listed: count it
        // on the timeline's folded row (local only — no log line, no
        // cloud event per connection).
        if ev.isRepeat {
            if let pid = ev.profileID {
                EgressReportDeduper.countRepeat(profileID: pid, eventData: eventData)
            }
            return
        }
        // ✗ colors blocks red, → colors allows blue in the Security Log view.
        SupplyChainLog.shared.record("[firewall] \(ev.denied ? "✗" : "→") \(action) \(proto) \(dst) (\(who))")
        if let pid = ev.profileID {
            BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "egress.firewall", eventData: eventData)
        }
    }
}
