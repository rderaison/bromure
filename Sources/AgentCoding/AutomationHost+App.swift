#if os(macOS)
import Foundation

/// The macOS app as the scheduled-automation engine's host.
extension ACAppDelegate: AutomationHost {
    func settleCodingTaskRefusals(now: Date, liveBranches: (UUID) -> [String]) {
        codingTaskEngine.settlePendingRefusals(now: now, liveBranches: liveBranches)
    }
}
#endif
