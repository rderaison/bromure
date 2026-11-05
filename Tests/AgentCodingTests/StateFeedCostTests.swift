import Foundation
import Testing
@testable import bromure_ac

@Suite("The state feed doesn't redo work for what didn't change")
struct StateFeedCostTests {
    struct Row: Equatable, Identifiable, Encodable { var id: Int; var text: String }
    final class Count { var n = 0 }

    @Test("an unchanged item isn't encoded again; a changed or new one is; a gone one is forgotten")
    func memo() {
        let memo = EncodedRowMemo(), count = Count()
        func encode(_ r: Row) -> [String: Any]? { count.n += 1; return ["id": r.id, "text": r.text] }
        var items = (1...5).map { Row(id: $0, text: "m\($0)") }
        #expect(memo.rows(items, "d", encode: encode).count == 5 && count.n == 5)
        #expect(memo.rows(items, "d", encode: encode).map { $0["text"] as? String } == items.map(\.text))
        #expect(count.n == 5)                                  // nothing changed: nothing encoded
        items[2].text = "edited"; items.append(Row(id: 9, text: "new"))
        let rows = memo.rows(items, "d", encode: encode)
        #expect(count.n == 7)                                  // the edited one and the new one
        #expect(rows.map { $0["text"] as? String } == items.map(\.text))
        _ = memo.rows([items[0]], "d", encode: encode)
        _ = memo.rows(items, "d", encode: encode)
        #expect(count.n == 7 + 5)                              // dropped from the list: forgotten
        // Lists don't share entries even when ids collide.
        _ = memo.rows([Row(id: 1, text: "other list")], "e", encode: encode)
        #expect(count.n == 13)
        #expect(memo.rows(items, "d", encode: encode).first?["text"] as? String == "m1")
    }

    @Test("one producer builds the state, however many subscribe; a subscriber only sends")
    func oneProducer() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/AutomationServer.swift"), encoding: .utf8)
        func body(_ sig: String) throws -> Substring {
            let r = try #require(s.range(of: sig))
            let rest = s[r.upperBound...]
            return rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)]
        }
        let loop = try body("private func handleStateSubscribe(fd: Int32, delta: Bool = false) {")
        for build in ["buildStateSnapshot()", "stampedStateSnapshot()", "JSONSerialization.data", "compressed(using:"] {
            #expect(!loop.contains(build), Comment(rawValue: build))
        }
        #expect(loop.contains("feedSubscribe()") && loop.contains("defer { feedUnsubscribe() }"))
        #expect(loop.contains("waitForFeed(after:") && loop.contains("feedDeltas(after: seen)"))
        let producer = try body("private func feedLoop() {")
        #expect(producer.contains("buildStateSnapshot()") && producer.contains("feedCondition.broadcast()"))
        #expect(producer.contains("if feedSubscribers <= 0 {"))
        #expect(!producer.contains("wholeFrame("))   // whole frames only when one is sent
    }

    @Test("the native sidebar never sizes the window, and the reaper is paced")
    func sidebarAndReaper() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let w = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/UnifiedSessionWindow.swift"), encoding: .utf8)
        let host = try #require(w.range(of: "let sidebarHost = NonMovableHostingView(rootView: sidebar)"))
        #expect(w[host.upperBound...].prefix(700).contains("sidebarHost.sizingOptions = []"))
        let p = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Profile.swift"), encoding: .utf8)
        #expect(p.contains("stepPause: useconds_t = 250_000, filePause: useconds_t = 2_000_000"))
    }

    @Test("the snapshot's big lists go through the memo")
    func listsUseTheMemo() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        for key in ["\"delegations\")", "\"agentSessions\")", "\"tasks\")", "\"agentRooms\")", "\"automations\")",
                    "\"automationRuns\")", "\"watches\")", "\"findings\")"] {
            #expect(ac.contains("encodedRows(") && ac.contains(key), Comment(rawValue: key))
        }
        #expect(!ac.contains("delegationStore.delegations.compactMap(Self.codableToDict) ?? []"))
    }
}
