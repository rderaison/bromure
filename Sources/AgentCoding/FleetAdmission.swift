#if os(macOS)
import AppKit

/// "“X” wants to join …" — asked once per waiting machine, as a sheet on
/// the window that shows the host (this Mac's own, or a fat client's). An
/// answer given elsewhere (the server itself, another client) takes the
/// question away here.
@MainActor
final class FleetAdmissionPrompter {
    private let model: SessionListModel
    private let hostName: () -> String?
    private let window: () -> NSWindow?
    private let act: (UUID, FleetAction) -> Void
    private var shown: (id: UUID, alert: NSAlert, window: NSWindow)?
    /// Put off for now ("Decide Later"): not asked again this run; the
    /// sidebar still offers the answer.
    private var deferred: Set<UUID> = []

    init(model: SessionListModel, hostName: @escaping () -> String?,
         window: @escaping () -> NSWindow?, act: @escaping (UUID, FleetAction) -> Void) {
        self.model = model
        self.hostName = hostName
        self.window = window
        self.act = act
        track()
    }

    private func track() {
        withObservationTracking { _ = model.pendingMachines } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.sync()
                self?.track()
            }
        }
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    func sync() {
        let waiting = model.pendingMachines
        if let s = shown, !waiting.contains(where: { $0.id == s.id }) {
            // Answered elsewhere.
            s.window.endSheet(s.alert.window, returnCode: .abort)
            shown = nil
        }
        guard shown == nil,
              let next = waiting.first(where: { !deferred.contains($0.id) }),
              let win = window(), win.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let host = hostName(), !host.isEmpty {
            alert.messageText = String(format: NSLocalizedString("“%@” wants to join the fleet on “%@”", comment: "fleet admission"),
                                       next.name, host)
        } else {
            alert.messageText = String(format: NSLocalizedString("“%@” wants to join this Mac's fleet", comment: "fleet admission"),
                                       next.name)
        }
        alert.informativeText = NSLocalizedString(
            "It's a Mac running Bromure Sidecar: its agents run natively — not in a sandbox — as that Mac's user. Once allowed, it's listed beside your VMs, and its agents and the agents in your workspaces can message each other, hand each other work and exchange files.\n\nOnly allow a Mac you trust. You can remove it from the fleet at any time.",
            comment: "fleet admission")
        alert.addButton(withTitle: NSLocalizedString("Allow", comment: "fleet admission"))
        alert.addButton(withTitle: NSLocalizedString("Block", comment: "fleet admission"))
        alert.addButton(withTitle: NSLocalizedString("Decide Later", comment: "fleet admission"))
        let id = next.id
        shown = (id, alert, win)
        NSApp.requestUserAttention(.informationalRequest)
        alert.beginSheetModal(for: win) { [weak self] r in
            guard let self else { return }
            self.shown = nil
            switch r {
            case .alertFirstButtonReturn: self.act(id, .allow)
            case .alertSecondButtonReturn: self.act(id, .block)
            case .alertThirdButtonReturn: self.deferred.insert(id)
            default: break
            }
            DispatchQueue.main.async { self.sync() }
        }
    }

    /// "Remove from Fleet": asked first — its agents lose each other.
    static func confirmRemove(_ name: String, on window: NSWindow?, then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Remove “%@” from the fleet?", comment: "fleet remove"), name)
        alert.informativeText = NSLocalizedString(
            "Its agents and the agents in your workspaces can no longer reach each other, and it stays blocked until you unblock it.",
            comment: "fleet remove")
        alert.addButton(withTitle: NSLocalizedString("Remove", comment: "fleet remove"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "fleet remove"))
        alert.buttons.first?.hasDestructiveAction = true
        if let window {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { then() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            then()
        }
    }
}
#endif
