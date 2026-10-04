import AppKit
import SwiftUI

// MARK: - Attached machines in the local window

/// A chat with an agent on an attached machine (MachineLinks.swift): the
/// same beautified view the VMs' sessions get, reading and typing through
/// the machine's link instead of a guest's vsock.
@MainActor
final class MachineTranscriptProvider: BeautifiedTranscriptProvider {
    let accent: Color
    private weak var machine: AttachedMachine?
    private let machineID: UUID
    private let window: Int

    init(machine: AttachedMachine, window: Int, accent: Color) {
        self.machine = machine
        self.machineID = machine.id
        self.window = window
        self.accent = accent
    }

    var historyCacheKey: String? { "machine:\(machineID.uuidString):\(window)" }

    /// The bound window while the machine still lists it.
    func activeTabIndex() -> Int? {
        machine?.tabsModel.tabs.contains { $0.index == window } == true ? window : nil
    }

    func execGuest(_ command: String, timeout: Int) async -> String? {
        try? await machine?.hostExec(command, timeout: timeout)
    }

    func isWorking() -> Bool { machine?.hostTabStatus(window: window) == .working }

    func isWorking(window w: Int) -> Bool? {
        guard let machine, machine.tabsModel.tabs.contains(where: { $0.index == w }) else { return nil }
        return machine.hostTabStatus(window: w) == .working
    }

    func paneTarget(window w: Int) -> PaneTarget {
        let tab = machine?.tabsModel.tabs.first { $0.index == w }
        let s = machine?.sessionStore.session(profileID: machineID, windowIndex: w)
        return .chat(window: w, windowID: s?.windowID, display: s?.launchDisplay ?? tab?.display,
                     worktree: tab?.worktreeBranch)
    }

    func guestFileOp(_ op: [String: Any]) async -> [String: Any]? {
        let timeout = (op["op"] as? String) == "untar" ? 600 : 30
        return try? await machine?.hostFileOp(op, timeout: timeout)
    }
}

/// A terminal surface (an AppKit view) on a SwiftUI stage.
struct MachineTerminalView: NSViewRepresentable {
    let terminal: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        DispatchQueue.main.async { container.window?.makeFirstResponder(terminal) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for sub in container.subviews { sub.removeFromSuperview() }
    }
}
