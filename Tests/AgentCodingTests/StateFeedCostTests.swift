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

    @Test("every subscriber sends the frame built once per snapshot, not its own")
    func oneFramePerBuild() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/AutomationServer.swift"), encoding: .utf8)
        let sub = try #require(s.range(of: "private func handleStateSubscribe(fd: Int32) {"))
        let loop = s[sub.upperBound...].prefix(2_400)
        #expect(loop.contains("let (content, frame) = stateFrame()"))
        #expect(!loop.contains("JSONSerialization.data") && !loop.contains("compressed(using:"))
        #expect(s.contains("if let c = frameCache, c.at == at { frameLock.unlock(); return (c.content, c.frame) }"))
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
