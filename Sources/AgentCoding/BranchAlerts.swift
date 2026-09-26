#if os(macOS)
import AppKit

/// The two questions a branch session asks before it goes — shared by the
/// local window and the fat client's.
@MainActor
enum BranchAlerts {
    /// "Discard “X”?" — the checkout, the branch and the session go.
    static func confirmDiscard(_ s: AgentSession, on window: NSWindow, then discard: @escaping () -> Void) {
        guard let branch = s.worktreeBranch else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Discard “%@”?", comment: "discard branch"), s.title)
        alert.informativeText = String(format: NSLocalizedString("The branch %@ and its checkout are deleted with the session%@. This can't be undone.", comment: "discard branch"),
                                       branch, SessionHome.branchSummary(s).map { " (" + $0 + ")" } ?? "")
        alert.addButton(withTitle: NSLocalizedString("Discard", comment: "discard branch"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn { discard() }
        }
    }

    /// Archiving or deleting a branch session whose work isn't merged: keep
    /// the branch (it stays on the machine, no longer reopened at boot) or
    /// throw it away. `decide(true)` = discard; nothing on Cancel.
    static func askFate(_ s: AgentSession, deleting: Bool, on window: NSWindow,
                        decide: @escaping (_ discard: Bool) -> Void) {
        guard let branch = s.worktreeBranch else { return }
        let empty = s.branchInfo?.isEmpty == true
        let alert = NSAlert()
        alert.messageText = String(format: deleting
            ? NSLocalizedString("Delete “%@” — and its branch?", comment: "branch fate")
            : NSLocalizedString("Archive “%@” — and its branch?", comment: "branch fate"), s.title)
        alert.informativeText = empty
            ? String(format: NSLocalizedString("Nothing was done on %@ yet, so there's nothing to lose by removing it.", comment: "branch fate"), branch)
            : String(format: NSLocalizedString("%@ has work that isn't merged%@. Keep it to merge or pick it up later, or discard it.", comment: "branch fate"),
                     branch, SessionHome.branchSummary(s).map { " (" + $0 + ")" } ?? "")
        let keep = NSLocalizedString("Keep Branch", comment: "branch fate")
        let discard = NSLocalizedString("Discard Branch", comment: "branch fate")
        // Empty: removing it is the obvious answer, so it's the default.
        alert.addButton(withTitle: empty ? discard : keep)
        alert.addButton(withTitle: empty ? keep : discard)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if !empty { alert.buttons[1].hasDestructiveAction = true }
        alert.beginSheetModal(for: window) { resp in
            guard resp != .alertThirdButtonReturn else { return }
            decide((resp == .alertFirstButtonReturn) == empty)
        }
    }
}
#endif
