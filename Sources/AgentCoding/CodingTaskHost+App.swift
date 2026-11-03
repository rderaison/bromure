#if os(macOS)
import Foundation

/// The macOS app as the coding-task engine's host: the members it spells
/// otherwise (the pane's roster, the task dispatcher).
extension ACAppDelegate: CodingTaskHost {
    func dispatcherSendBack(_ taskID: UUID, feedback: String) async -> Bool {
        await taskDispatcher.sendBack(taskID, feedback: feedback)
    }
    func dispatcherSteerLanding(_ taskID: UUID, text: String) async -> Bool {
        await taskDispatcher.steerLanding(taskID, text: text)
    }
    func dispatcherRecall(_ taskID: UUID) { taskDispatcher.recall(taskID) }
}
#endif
