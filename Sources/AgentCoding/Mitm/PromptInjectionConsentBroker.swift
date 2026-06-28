import AppKit
import Foundation

/// "Ask me what to do" handler for prompt-injection detections. Shows the
/// flagged text in a scrollable textarea and lets the user allow or block the
/// outbound request. Mirrors `SupplyChainConsentBroker`, simpler: a per
/// (profile, source, content) decision memory so the same flagged input isn't
/// re-prompted on every turn (the system prompt / tool_result repeats).
public actor PromptInjectionConsentBroker {
    public init() {}

    private var decisions: [String: Bool] = [:]   // key → allowed
    private var pending: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var profileNames: [UUID: String] = [:]

    public func setProfileName(_ name: String, for id: UUID) { profileNames[id] = name }

    /// True → allow the request through, false → block it.
    public func consent(profileID: UUID, detectorName: String,
                        source: String, flaggedText: String) async -> Bool {
        let key = "\(profileID.uuidString)|\(source)|\(flaggedText.hashValue)"
        if let prior = decisions[key] { return prior }
        if pending[key] != nil {
            return await withCheckedContinuation { c in pending[key, default: []].append(c) }
        }
        pending[key] = []
        let name = profileNames[profileID] ?? "this workspace"
        let allow = await Self.ask(profileName: name, detectorName: detectorName,
                                   source: source, flaggedText: flaggedText)
        decisions[key] = allow
        let waiters = pending.removeValue(forKey: key) ?? []
        for w in waiters { w.resume(returning: allow) }
        return allow
    }

    public func reset(profileID: UUID) {
        let prefix = profileID.uuidString + "|"
        for k in decisions.keys where k.hasPrefix(prefix) { decisions.removeValue(forKey: k) }
    }

    @MainActor
    private static func ask(profileName: String, detectorName: String,
                            source: String, flaggedText: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(format: NSLocalizedString(
            "Possible %@ in “%@”", comment: "Prompt-injection consent title"),
            detectorName, profileName)
        alert.informativeText = String(format: NSLocalizedString(
            "Bromure flagged content the agent is about to send to the model (from %@). Review it below — allow it through, or block this request?",
            comment: "Prompt-injection consent body"), source)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 170))
        tv.string = flaggedText
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 170))
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        alert.addButton(withTitle: NSLocalizedString("Block this request", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Allow this request", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        // First button = Block.
        return alert.runModal() != .alertFirstButtonReturn
    }
}
