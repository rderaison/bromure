import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

// A chat that opens on a byte window from the file's end (1.5 MB over a
// fat-client tunnel) must still show the last few prompts, not just the
// final exchange with everything before it behind "Load earlier".

@Suite("Chat continuity")
@MainActor
struct ChatContinuityTests {

    /// A machine whose transcript is 10 prompts, each answered at length,
    /// served the way the guest's chunk command reads it.
    private final class Provider: BeautifiedTranscriptProvider {
        let file: Data
        init() {
            var d = Data()
            for i in 1...10 {
                let answer = String(repeating: "word ", count: 600)
                d.append(Data((#"{"type":"user","message":{"role":"user","content":"prompt \#(i)"},"timestamp":"2026-01-01T00:00:0\#(i % 10)Z"}"# + "\n").utf8))
                d.append(Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer \#(i) \#(answer)"}]},"timestamp":"2026-01-01T00:00:0\#(i % 10)Z"}"# + "\n").utf8))
            }
            file = d
        }
        var accent: Color { .blue }
        var historyBytesHint: Int? { 4_000 }
        func activeTabIndex() -> Int? { 0 }
        func isWorking() -> Bool { false }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            if command.contains("capture-pane") { return "" }
            if command.contains("pane_current_path") { return "/home/ubuntu/p\n0\n" }
            let path = "/home/ubuntu/.claude/projects/p/s.jsonl"
            let re = try! NSRegularExpression(pattern: #"python3 - "\$f" ('[^']*'|\S+) (-?\d+) (\d+) (tail|earlier)"#)
            let ns = command as NSString
            guard let r = re.firstMatch(in: command, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let g = { (i: Int) in ns.substring(with: r.range(at: i)) }
            let known = g(1).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            let off = Int(g(2))!, want = Int(g(3))!
            let earlier = g(4) == "earlier"
            let size = file.count
            var start: Int, end: Int
            if earlier {
                end = min(max(off, 0), size)
                start = max(0, end - want)
                if start > 0, let nl = file[start..<end].firstIndex(of: 0x0A) { start = nl + 1 }
            } else {
                let fresh = known != path || off < 0 || off > size
                start = fresh ? max(0, size - want) : off
                if fresh, start > 0 { start = (file[..<start].lastIndex(of: 0x0A) ?? -1) + 1 }
                end = size
            }
            let chunk = file[start..<end]
            return "\(path)\n\n\(size)\n\(start)\n\(end)\n" + String(decoding: chunk, as: UTF8.self)
        }
    }

    @Test("a chat opening on a small window fetches back to the last 5 prompts")
    func keepsLastPrompts() async {
        let model = BeautifiedSessionModel(provider: Provider())
        model.start()
        let until = Date().addingTimeInterval(8)
        while BeautifiedSessionModel.userPrompts(in: model.items) < BeautifiedSessionModel.continuityPrompts,
              Date() < until {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        model.stop()
        let prompts = BeautifiedSessionModel.userPrompts(in: model.items)
        #expect(prompts >= 5)
        // Only what continuity needs: the rest stays behind "Load earlier".
        #expect(prompts < 10)
        #expect(model.canLoadEarlier)
    }
}
