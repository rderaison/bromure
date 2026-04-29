import Foundation

/// Aho-Corasick automaton over byte patterns. One scan over the input
/// stream finds every pattern occurrence in O(n + total-output-size).
/// Built once per setMap on the swapper; re-used for every outgoing
/// request in the session.
public final class AhoCorasick: @unchecked Sendable {
    private struct Node {
        var children: [UInt8: Int]
        var fail: Int
        var outputs: [Int]
    }

    private let nodes: [Node]
    public let patternCount: Int

    /// Build the automaton from `patterns`. Empty / duplicate patterns
    /// are silently dropped — they would pin the root state and emit a
    /// match on every byte, which isn't what callers want.
    public init(patterns: [[UInt8]]) {
        var nodes: [Node] = [Node(children: [:], fail: 0, outputs: [])]
        var seenPatterns: Set<Data> = []
        var keptCount = 0

        for (idx, pat) in patterns.enumerated() {
            if pat.isEmpty { continue }
            let key = Data(pat)
            if !seenPatterns.insert(key).inserted { continue }

            var cur = 0
            for b in pat {
                if let next = nodes[cur].children[b] {
                    cur = next
                } else {
                    nodes.append(Node(children: [:], fail: 0, outputs: []))
                    let newIdx = nodes.count - 1
                    nodes[cur].children[b] = newIdx
                    cur = newIdx
                }
            }
            nodes[cur].outputs.append(idx)
            keptCount += 1
        }

        // BFS over the trie, computing fail links + propagating outputs
        // along each fail chain so the scan loop only checks the current
        // node's `outputs` (no fail-walk per byte).
        var queue: [Int] = []
        for (_, child) in nodes[0].children {
            nodes[child].fail = 0
            queue.append(child)
        }
        while !queue.isEmpty {
            let u = queue.removeFirst()
            for (b, v) in nodes[u].children {
                queue.append(v)
                var f = nodes[u].fail
                while f != 0 && nodes[f].children[b] == nil {
                    f = nodes[f].fail
                }
                let target = nodes[f].children[b] ?? 0
                let fail = (target == v) ? 0 : target
                nodes[v].fail = fail
                if !nodes[fail].outputs.isEmpty {
                    nodes[v].outputs.append(contentsOf: nodes[fail].outputs)
                }
            }
        }

        self.nodes = nodes
        self.patternCount = keptCount
    }

    /// Scan `data` and return the set of pattern indices that appeared
    /// at least once. Index space matches the order of the original
    /// `patterns` array passed to init. Empty / duplicate inputs were
    /// dropped at construction; their slot is simply never reported.
    public func scan(_ data: Data) -> Set<Int> {
        if patternCount == 0 || data.isEmpty { return [] }
        var found = Set<Int>()
        var state = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf {
                while state != 0 && nodes[state].children[b] == nil {
                    state = nodes[state].fail
                }
                if let next = nodes[state].children[b] {
                    state = next
                }
                let outs = nodes[state].outputs
                if !outs.isEmpty {
                    for idx in outs { found.insert(idx) }
                }
            }
        }
        return found
    }
}

/// One matched fake token leaving the VM bound for the wrong host.
public struct CompromiseLeak: Sendable {
    /// First 4 + last 4 chars of the fake token, with an ellipsis
    /// between. Same convention as `SwapRecord.fakePreview` — full
    /// values never leave the host.
    public let fakeTokenPreview: String
    /// Display name of the credential the fake stands in for. Pulled
    /// from `TokenMap.Entry.consentDisplayName` when set; otherwise a
    /// generic "session token" label.
    public let credentialDisplayName: String
    /// Host scope the fake was minted for ("anthropic.com",
    /// "github.com", …). Empty / nil entries can't leak — they were
    /// declared as "any host", so this struct never fires for them.
    public let declaredHost: String
    /// SNI the VM was actually trying to send the fake to.
    public let observedHost: String
}

/// One detection event handed to the host. Carries everything the
/// alert UI needs to explain the compromise to the user.
public struct CompromiseEvent: Sendable {
    public let profileID: UUID
    public let observedHost: String
    public let leaks: [CompromiseLeak]
    public let timestamp: Date
}
