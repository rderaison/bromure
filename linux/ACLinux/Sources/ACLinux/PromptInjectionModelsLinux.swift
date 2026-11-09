import Foundation

extension Daemon {
    /// A workspace's detectors' models, fetched into this user's models
    /// dir when missing (macOS: launch and pushLiveCredentials call
    /// ensureInstalledInBackground the same way). One that fails its pin is
    /// deleted, as on macOS (PromptInjectionModelPins).
    // @port-skip linux-only: the daemon's share of macOS's launch / pushLiveCredentials model fetches
    static func fetchDetectorModels(for profile: Profile) {
        if profile.promptInjection.detectSourceInjection { PromptInjectionModels.ensureInstalledInBackground(.promptGuard) }
        if profile.promptInjection.detectRulesInjection { PromptInjectionModels.ensureInstalledInBackground(.claudeMdGuard) }
        if profile.pii.isActive { PromptInjectionModels.ensureInstalledInBackground(.piiRampart) }
    }
}

extension PromptInjectionModels {
    /// One at a time, as macOS's alert.
    @MainActor private static var diskAlertAsked = false

    /// macOS's disk-full alert, with its words, asked through the user's
    /// fat client (a server has no screen); nobody connected: the log has it.
    // partial: through the fat client (PendingPromptBroker), not a modal on the server's screen
    // @port PromptInjectionModels.static presentDiskFullAlert(_: String) h=18f6ad1f66a64f4d @4e8d6a79
    @MainActor static func presentDiskFullAlert(_ detail: String) async {
        guard !diskAlertAsked else { return }
        diskAlertAsked = true
        defer { diskAlertAsked = false }
        _ = await PendingPromptBroker.shared.answerAsync(
            profileID: nil,
            title: NSLocalizedString("Not enough disk space to download the prompt-injection model",
                                     comment: "Alert title when a detector model can't be downloaded due to low disk"),
            message: detail, buttons: ["OK"], fallback: 0, timeout: 600)
    }
}
