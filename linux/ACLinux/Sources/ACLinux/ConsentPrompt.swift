import Foundation
import NIOConcurrencyHelpers

/// Where a MITM consent prompt (credential use, guardrail write, supply-chain
/// bypass, prompt injection) is asked on a Linux server (macOS:
/// Mitm/ConsentPrompt.swift, which also has a local panel). A server has no
/// screen: the question goes to the fat client (PendingPromptBroker, what
/// its mirror shows). RemoteConsent's terminal route never applies here
/// (nothing marks a workspace interactively attached on Linux); with no fat
/// client nobody can answer, and no answer means no, as when a macOS panel
/// times out. Returns the chosen index, or nil for deny / timeout.
// @port-skip linux-only: ConsentPrompt.swift is AppKit (its local panel); the routing below is the same
enum ConsentPrompt {
    /// macOS's NSAlert.Style, for the callers' `style:`; nothing is drawn here.
    enum Style { case informational, warning, critical }

    // @port-skip linux-only: ConsentPrompt.defaultTimeout without UserDefaults' app domain (120 s, as its default)
    static var defaultTimeout: TimeInterval { 120 }

    // @port-skip linux-only: ConsentPrompt.choose without the local panel
    static func choose(profileID: UUID, title: String, message: String,
                       choices: [String], denyIndex: Int,
                       style: Style = .informational,
                       detailText: String? = nil,
                       timeout: TimeInterval = ConsentPrompt.defaultTimeout,
                       token: UUID = UUID()) async -> Int? {
        if let hook = chooseForTesting.withLockedValue({ $0 }) { return await hook(profileID) }
        let deadline = Date().addingTimeInterval(max(1, timeout))
        let body = detailText.map { message + "\n\n" + String($0.prefix(1500)) } ?? message
        let idx: Int?
        switch RemoteConsent.route(for: profileID) {
        case .fatClient:
            idx = await PendingPromptBroker.shared.answerAsync(
                profileID: profileID, title: title, message: body,
                buttons: choices, fallback: denyIndex,
                timeout: max(1, deadline.timeIntervalSinceNow))
        case .terminalPump:
            idx = await Task.detached {
                RemoteConsent.choose(profileID: profileID, title: title, message: body,
                                     choices: choices,
                                     timeoutSeconds: max(1, deadline.timeIntervalSinceNow),
                                     token: token)
            }.value
        case .localAlert:
            FileHandle.standardError.write(Data("bromure-ac daemon: consent '\(title)' denied: no fat client or terminal attached to answer it\n".utf8))
            idx = nil
        }
        return idx == nil || idx == denyIndex ? nil : idx
    }

    /// Tests: the answer, by workspace (nil: asked as above).
    static let chooseForTesting = NIOLockedValueBox<(@Sendable (UUID) async -> Int?)?>(nil)

    /// A one-button notice (nothing to decide): the connected fat client's
    /// prompt; a headless terminal session gets none (the caller logs it),
    /// and there's no local panel to show it in.
    // @port-skip linux-only: ConsentPrompt.notice without the local panel
    static func notice(profileID: UUID, title: String, message: String) {
        guard case .fatClient = RemoteConsent.route(for: profileID) else { return }
        Task { @MainActor in
            _ = await PendingPromptBroker.shared.askAsync(
                profileID: profileID, title: title, message: message,
                buttons: [NSLocalizedString("OK", comment: "")],
                fallback: 0, timeout: 120)
        }
    }

    /// There is no local panel to take back.
    // @port-skip linux-only: ConsentPrompt.withdrawLocal (no local panel)
    static func withdrawLocal(token: UUID) {}
}
