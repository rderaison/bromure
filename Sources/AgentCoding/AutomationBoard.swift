import Foundation

// MARK: - Column classification

/// Pure column logic for the automation board, separated from the views for
/// testability. An automation card never leaves Scheduled — a fire SPAWNS a
/// run card that flows In Progress → Done (or Needs Attention).
enum AutomationBoard {
    struct Columns {
        /// Launched runs whose agent is still going (live tab, not stamped done).
        var inProgress: [AutomationRunRecord] = []
        /// Failed/blocked runs awaiting the user's dismissal. The column
        /// only exists while this is non-empty.
        var needsAttention: [AutomationRunRecord] = []
        /// Everything over: completed, ended (tab gone), skipped, and
        /// acknowledged failures.
        var done: [AutomationRunRecord] = []
    }

    /// `isLive` answers "does this launched run still have a live tab?" —
    /// the caller resolves it against the tab roster.
    static func classify(runs: [AutomationRunRecord],
                         isLive: (AutomationRunRecord) -> Bool) -> Columns {
        var out = Columns()
        for run in runs where !run.isBacklogSeed {
            switch run.outcome {
            case .launched where run.completedAt == nil && isLive(run):
                out.inProgress.append(run)
            case .failed, .blocked:
                if run.acknowledgedAt == nil {
                    out.needsAttention.append(run)
                } else {
                    out.done.append(run)
                }
            default:
                out.done.append(run)
            }
        }
        out.inProgress.sort { $0.firedAt > $1.firedAt }
        out.needsAttention.sort { $0.firedAt > $1.firedAt }
        out.done.sort { ($0.completedAt ?? $0.firedAt) > ($1.completedAt ?? $1.firedAt) }
        return out
    }

    /// Does a tab's worktree branch belong to a run's slug — exact, or with
    /// the guest's "-N" dedup suffix? (Same match the engine's completion
    /// path uses.)
    static func branchMatches(_ branch: String?, slug: String) -> Bool {
        guard let branch, branch.hasPrefix("wt/") else { return false }
        let part = String(branch.dropFirst(3))
        return part == slug || (part.hasPrefix(slug + "-")
            && Int(part.dropFirst(slug.count + 1)) != nil)
    }
}
