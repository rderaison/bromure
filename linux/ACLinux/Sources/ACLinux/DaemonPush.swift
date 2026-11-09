import Foundation

/// A coding agent's needs-input / resolved transitions to the phone push
/// pipeline (bromure.io, then APNs), as macOS's reportPushTransition: only
/// while Remote Access is on (a phone can't answer a server it can't reach)
/// and only for a server enrolled in bromure.io. The rich title (workspace ·
/// tab) is sealed to each phone's push key; what bromure.io and Apple see
/// stays generic.
extension LinuxSessionHost {
    /// What a status change sends, if anything.
    enum PushAction: Equatable { case needsInput, resolved }

    // @port-skip linux-only: reportPushTransition's decision, testable
    static func pushAction(from old: AgentStatus, to new: AgentStatus) -> PushAction? {
        guard old != new else { return nil }
        if new == .needsInput { return .needsInput }
        return old == .needsInput ? .resolved : nil
    }

    /// The sealed notification's content.
    // @port-skip linux-only: reportPushTransition's rich payload, testable
    static func richPushPayload(profileName: String, tabLabel: String) -> Data? {
        let title = tabLabel.isEmpty ? profileName : "\(profileName) · \(tabLabel)"
        return try? JSONSerialization.data(withJSONObject: ["title": title, "body": "An agent needs your input"])
    }

    /// The server's local idle time for the cloud's idle-aware debounce
    /// (macOS: the Mac's HID idle). A server has no local keyboard or mouse:
    /// it is always unattended, as a Mac nobody sits at, so a push goes
    /// almost at once.
    static let unattendedIdleSeconds: Double = 86_400

    /// Tests: the push sent (nil: the control plane).
    nonisolated(unsafe) static var pushSenderForTesting: ((PushAction, String, Data?) -> Void)?

    // partial: no HID idle on a server (unattendedIdleSeconds); Remote Access is the daemon's remote.json
    // @port ACAppDelegate.reportPushTransition(_: Profile.ID, index: Int, from: AgentStatus, to: AgentStatus) h=40fb93f9fcd1b2eb @4237c02e
    func reportPushTransition(_ id: UUID, index: Int, from old: AgentStatus, to new: AgentStatus) {
        guard let action = Self.pushAction(from: old, to: new) else { return }
        let key = "ni-\(id.uuidString)-\(index)"
        let rich = action == .needsInput
            ? Self.richPushPayload(profileName: profile(for: id)?.name ?? "Workspace",
                                   tabLabel: tabs[id]?.tabs.first(where: { $0.index == index })?.shownLabel ?? "")
            : nil
        if let send = Self.pushSenderForTesting { send(action, key, rich); return }
        guard RemoteSettings.load(stateDir + "/remote.json").enabled,
              let (client, bearer) = ControlPlaneClient.current() else { return }
        let pid = id.uuidString
        Task {
            switch action {
            case .needsInput:
                var sealed: [String: String] = [:]
                if let rich, let recipients = try? await client.pushRecipients(bearer: bearer) {
                    for r in recipients {
                        if let blob = PushCrypto.seal(rich, toPublicKeyHex: r.pubkey) { sealed[r.installId] = blob }
                    }
                }
                try? await client.notifyNeedsInput(
                    bearer: bearer, eventKey: key, profileId: pid, windowIndex: index,
                    fallbackTitle: "Bromure", macIdleSeconds: Self.unattendedIdleSeconds, sealed: sealed)
            case .resolved:
                try? await client.notifyResolved(bearer: bearer, eventKey: key)
            }
        }
    }
}
