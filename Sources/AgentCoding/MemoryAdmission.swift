import Foundation

/// A workspace's memory as its guest reports it (`vmstat.txt`).
struct GuestMemorySnapshot: Equatable {
    var availableKB: Int
    var totalKB: Int
    /// `/proc/pressure/memory`, avg10: the share of the last 10 s some task
    /// (`some`) or every task (`full`) was stalled waiting on memory.
    var pressureSome: Double
    var pressureFull: Double
}

/// Whether one more agent fits in a workspace, or would push it into the OOM
/// killer, which takes running agents down with it. See MEMORY_MANAGEMENT.md.
enum MemoryAdmission {
    /// What an agent costs. One survey of a live guest: 456 MB of agent and
    /// about 380 MB of per-agent MCP helpers, for three Claude agents.
    static let agentCostKB = 900 * 1024
    /// What the workspace keeps in hand beyond that, at least.
    static let minimumReserveKB = 512 * 1024
    static let pressureSomeLimit = 30.0
    static let pressureFullLimit = 5.0

    enum Verdict: Equatable {
        case admit
        case tooLittleMemory(availableKB: Int, totalKB: Int)
        case underPressure
    }

    /// - Parameters:
    ///   - otherAgents: sessions on the workspace besides this one. With none,
    ///     nothing can be closed to make room, so the agent is always let in.
    ///   - launchingNow: those of them still starting: what they'll use isn't
    ///     in `availableKB` yet, and five started at once all read the same.
    static func decide(_ memory: GuestMemorySnapshot?, otherAgents: Int, launchingNow: Int) -> Verdict {
        guard let memory, memory.totalKB > 0, otherAgents > 0 else { return .admit }
        if memory.pressureFull >= pressureFullLimit || memory.pressureSome >= pressureSomeLimit {
            return .underPressure
        }
        let reserve = max(minimumReserveKB, memory.totalKB / 20)
        let needed = agentCostKB * (1 + max(0, launchingNow)) + reserve
        return memory.availableKB < needed
            ? .tooLittleMemory(availableKB: memory.availableKB, totalKB: memory.totalKB) : .admit
    }

    /// What the session says when it wasn't started; nil when it was admitted.
    static func refusal(_ verdict: Verdict) -> String? {
        let advice = NSLocalizedString(
            "End another session on this machine or give the machine more memory, then send your message again.",
            comment: "session start refused for memory")
        switch verdict {
        case .admit:
            return nil
        case .underPressure:
            return NSLocalizedString("This machine is running out of memory, so the agent wasn't started.",
                                     comment: "session start refused for memory") + " " + advice
        case .tooLittleMemory(let available, let total):
            return String(format: NSLocalizedString(
                "This machine has %.1f GB of memory free out of %.0f GB, too little for another agent, so it wasn't started.",
                comment: "session start refused for memory"),
                Double(available) / 1_048_576, (Double(total) / 1_048_576).rounded())
                + " " + advice
        }
    }
}
