import Testing
@testable import bromure_ac

@Suite("Queued messages")
struct QueuedMessageTests {
    @Test("each agent queues the way its TUI allows editing")
    func modesPerAgent() {
        // Steered into the agent's own queue, whole queue recallable.
        #expect(AgentQueueSupport.mode(for: "claude") == .native(recall: "Up"))
        #expect(AgentQueueSupport.mode(for: "omp") == .native(recall: "M-Up"))
        // Steered in within seconds; an Enter-steer can't be recalled.
        #expect(AgentQueueSupport.mode(for: "codex") == .native(recall: nil))
        // Follow-ups only after the turn, recallable one at a time or not
        // at all: held here instead, same timing, fully editable.
        #expect(AgentQueueSupport.mode(for: "kimi") == .held)
        #expect(AgentQueueSupport.mode(for: "grok") == .held)
        #expect(AgentQueueSupport.mode(for: nil) == .held)
    }
}
