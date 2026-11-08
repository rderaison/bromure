import Foundation
import Testing
@testable import ACLinux

/// The state stream's frames (macOS: StateDeltaTests): compressed when
/// that's smaller, in the raw DEFLATE macOS's `.zlib` writes; deltas of the
/// sections that changed, which a client merges back into the state.
@Suite("State stream frames")
struct StateFramesTests {
    static let enc: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    static func state(cpu: Double, uptime: Int, delegations: [String]) -> JSONValue {
        .object([
            "version": 3,
            "vms": [["id": "vm1", "cpu": .number(cpu), "uptimeSeconds": .number(Double(uptime))]],
            // Text that doesn't compress to nothing, as real messages don't.
            "delegations": .array(delegations.map { d in
                ["id": .string(d), "messages": .array((0..<40).map { i in .string("\(d)-\(i)-" + UUID().uuidString) })]
            }),
            "tasks": [["id": "t1"]],
        ])
    }

    /// The client's side: frames off the wire, merged (whole replaces,
    /// delta sets and unsets sections).
    static func receive(_ wire: Data) -> JSONValue? {
        var buf = [UInt8](wire), at = 0
        var s: [String: JSONValue]?
        while at + 5 <= buf.count {
            let len = Int(buf[at]) << 24 | Int(buf[at + 1]) << 16 | Int(buf[at + 2]) << 8 | Int(buf[at + 3])
            guard len >= 1, at + 4 + len <= buf.count else { return nil }
            let flag = buf[at + 4]
            var payload = Data(buf[(at + 5)..<(at + 4 + len)])
            if flag & 1 != 0 { guard let p = NPMRegistryTransforms.inflateRaw(payload, limit: 64 << 20) else { return nil }; payload = p }
            guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: payload) else { return nil }
            if flag & 2 != 0 {
                guard var cur = s, case .object(let set)? = o["set"], case .array(let unset)? = o["unset"] else { return nil }
                for (k, v) in set { cur[k] = v }
                for case .string(let k) in unset { cur[k] = nil }
                s = cur
            } else {
                s = o
            }
            at += 4 + len
        }
        buf.removeAll()
        return s.map(JSONValue.object)
    }

    @Test func aCPUFigureMovingSendsTheVMsOnly() throws {
        let a = Self.state(cpu: 1, uptime: 10, delegations: ["d1", "d2"])
        // Same delegations (same texts): rebuild b from a with the VM changed.
        guard case .object(var bo) = a else { return }
        bo["vms"] = [["id": "vm1", "cpu": 42, "uptimeSeconds": 11]]
        let b = JSONValue.object(bo)
        let (set, unset) = Daemon.changedSections(from: Daemon.comparableSections(a, Self.enc), to: Daemon.comparableSections(b, Self.enc))
        #expect(set == ["vms"] && unset.isEmpty)
        let whole = Daemon.frame(try Self.enc.encode(a), delta: false)
        let delta = try #require(Daemon.deltaFrame(snapshot: b, set: set, unset: unset, Self.enc))
        #expect(delta.count * 10 < whole.count, "a fraction of the whole state")
        #expect(whole[4] & 1 == 1, "the whole state compresses")
        #expect(Self.receive(whole + delta) == b, "merged, it's the new state (uptime came along)")
    }

    @Test func uptimeAloneIsntAChangeAndSectionsComeAndGo() throws {
        let a = Self.state(cpu: 1, uptime: 10, delegations: ["d1"])
        guard case .object(var t) = a else { return }
        t["vms"] = [["id": "vm1", "cpu": 1, "uptimeSeconds": 99]]
        #expect(Daemon.changedSections(from: Daemon.comparableSections(a, Self.enc),
                                       to: Daemon.comparableSections(.object(t), Self.enc)) == ([], []))
        var b = t
        b["tasks"] = nil
        b["pendingMachines"] = [["id": "m1"]]
        let ab = Daemon.changedSections(from: Daemon.comparableSections(a, Self.enc), to: Daemon.comparableSections(.object(b), Self.enc))
        #expect(ab.set == ["pendingMachines"] && ab.unset == ["tasks"])
        let wire = Daemon.frame(try Self.enc.encode(a), delta: false)
            + (try #require(Daemon.deltaFrame(snapshot: .object(b), set: ab.set, unset: ab.unset, Self.enc)))
        // Uptime moving alone isn't sent (the 15 s whole frame carries it).
        let got = try #require(Self.receive(wire))
        #expect(Daemon.withoutUptime(got) == Daemon.withoutUptime(.object(b)))
    }

    @Test func aSmallFrameGoesUncompressed() throws {
        let f = Daemon.frame(Data(#"{"a":1}"#.utf8), delta: true)
        #expect(f[4] == 2, "delta, not compressed (it wouldn't be smaller)")
        #expect(f.prefix(4) == Data([0, 0, 0, 8]) && f.dropFirst(5) == Data(#"{"a":1}"#.utf8))
    }
}
