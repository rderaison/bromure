import Foundation

/// Presents consent prompts to a user driving a workspace over CLI/SSH — on the
/// HOST side of the interactive pump, never inside the VM. The four MITM consent
/// brokers route through this when the session is attached interactively;
/// GUI-fronted sessions keep their NSAlert.
///
/// Security: the prompt is rendered on, and the answer read from, the user's
/// terminal connection (`clientFD`), which the host owns. The guest only ever
/// sees the other side of the pump, so a compromised guest can neither see the
/// prompt nor inject the answer. (This replaces an earlier tmux-popup approach
/// that lived inside the VM and was forgeable from the guest.)
///
/// FAIL-SAFE: any failure — no live attach, timeout, dismissed — returns nil, and
/// every broker maps nil to DENY.
public enum RemoteConsent {
    /// Whether this profile's session should be prompted on its terminal (it's
    /// attached interactively over CLI/SSH) rather than via an NSAlert.
    public static func isActive(for profileID: UUID) -> Bool {
        let active = ACAutomationServer.isInteractivelyAttached(profileID.uuidString)
        FileHandle.standardError.write(Data(
            "[consent] route pid=\(profileID.uuidString.prefix(8)) → \(active ? "terminal" : "GUI alert")\n".utf8))
        return active
    }

    /// Render `title` + `message` + a numbered menu on the attached user's
    /// terminal (host side) and return the chosen 0-based index, or nil (no live
    /// attach / dismissed / timeout — the caller treats as deny). Blocking; call
    /// off the main actor.
    public static func choose(profileID: UUID, title: String, message: String,
                              choices: [String], timeoutSeconds: TimeInterval = 120) -> Int? {
        let prompt = message.isEmpty ? title : title + "\n\n" + message
        return ACAutomationServer.presentConsentViaPump(
            profileID: profileID.uuidString, prompt: prompt,
            choices: choices, timeoutSeconds: timeoutSeconds)
    }
}
