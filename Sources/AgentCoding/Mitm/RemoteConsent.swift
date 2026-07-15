import Foundation

/// Decides where a MITM consent prompt (credentials, guardrail writes,
/// supply-chain bypass, prompt-injection) is presented — and, for the terminal
/// case, renders it on the user's side of the interactive pump.
///
/// Three destinations, in priority order:
///   • `.fatClient` — a rich-client mirror is connected (it polls `/state`
///     sub-second). The prompt is queued on `PendingPromptBroker`; the fat
///     client renders it as a native NSAlert on ITS OWN Mac and the answer
///     rides back over the SSH tunnel. A GUI client must never be prompted in
///     tmux.
///   • `.terminalPump` — a plain SSH/CLI session is attached interactively (no
///     fat client). The prompt is rendered on, and the answer read from, the
///     user's terminal connection (`clientFD`), which the host owns. The guest
///     only ever sees the other side of the pump, so a compromised guest can
///     neither see the prompt nor inject the answer. (This replaced an earlier
///     tmux-popup approach that lived inside the VM and was forgeable.)
///   • `.localAlert` — nobody is attached remotely; the app is being driven
///     locally, so the broker shows its own NSAlert on this Mac.
///
/// FAIL-SAFE: any failure — no live attach, timeout, dismissed — resolves to
/// DENY, and every broker maps that to its safe default.
public enum RemoteConsent {
    public enum Route: Equatable, Sendable {
        case localAlert
        case terminalPump
        case fatClient
    }

    /// Where `profileID`'s consent prompts should be presented right now.
    /// Thread-safe — the MITM brokers call this from their actors.
    public static func route(for profileID: UUID) -> Route {
        // A connected fat client polls `/state` continuously; prefer its
        // native alert over any tmux popup even when the mirror has also
        // attached this workspace's terminal (which would set the flag below).
        if PendingPromptBroker.hasLiveListener() {
            FileHandle.standardError.write(Data(
                "[consent] route pid=\(profileID.uuidString.prefix(8)) → fat-client alert\n".utf8))
            return .fatClient
        }
        if ACAutomationServer.isInteractivelyAttached(profileID.uuidString) {
            FileHandle.standardError.write(Data(
                "[consent] route pid=\(profileID.uuidString.prefix(8)) → terminal pump\n".utf8))
            return .terminalPump
        }
        FileHandle.standardError.write(Data(
            "[consent] route pid=\(profileID.uuidString.prefix(8)) → local alert\n".utf8))
        return .localAlert
    }

    /// Present `choices` on the connected fat client's screen (a native NSAlert,
    /// via `PendingPromptBroker` over the tunnel) and return the chosen 0-based
    /// index, or nil when it resolves to `denyIndex` — no client, timeout,
    /// dismissed, or the user explicitly denied. Callers treat nil as deny,
    /// matching `choose`'s semantics, so the two remote paths share one mapping.
    ///
    /// If several fat clients are watching, they all render the same prompt; the
    /// first answer removes it from `/state` and the others dismiss it.
    public static func chooseOnFatClient(profileID: UUID, title: String, message: String,
                                         choices: [String], denyIndex: Int,
                                         timeoutSeconds: TimeInterval = 120) async -> Int? {
        let idx = await PendingPromptBroker.shared.askAsync(
            profileID: profileID, title: title, message: message,
            buttons: choices, fallback: denyIndex, timeout: timeoutSeconds)
        return idx == denyIndex ? nil : idx
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
