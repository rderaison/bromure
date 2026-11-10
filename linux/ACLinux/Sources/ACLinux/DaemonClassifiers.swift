import Foundation

/// The in-process ONNX classifiers (PII/Rampart, prompt-injection source +
/// rules) kept resident only while something needs them (macOS:
/// ClassifierLifecycle, ~1.3 GB RSS with both loaded): released again once
/// no running workspace has the matching policy on and they've sat idle for
/// `idleSeconds`, so the policy-less users (delegation scans, the repo
/// watcher, automations) don't reload them on every message. Reconciled
/// every 2 minutes.
enum LinuxClassifierLifecycle {
    // @port-skip linux-only: see LinuxClassifierLifecycle
    struct Needs: Equatable {
        var pii = false
        var sourceInjection = false
        var rulesInjection = false
    }

    static let idleSeconds: TimeInterval = 300

    /// What the given running workspaces' policies need resident.
    // @port ClassifierLifecycle.static needs(for: [Profile]) h=06ce0afda45c0aa9 @19b04b00
    static func needs(for running: [Profile]) -> Needs {
        Needs(pii: running.contains { $0.pii.isActive },
              sourceInjection: running.contains { $0.promptInjection.detectSourceInjection },
              rulesInjection: running.contains { $0.promptInjection.detectRulesInjection })
    }

    /// Release every classifier no running workspace needs (and nothing used
    /// for `idleSeconds`).
    // @port ClassifierLifecycle.static reconcile() h=f9493a984977c712 @19b04b00
    static func reconcile(_ n: Needs) async {
        if !n.pii { await PIIDetector.shared.unloadIfIdle(idleSeconds) }
        if !n.sourceInjection { await PromptInjectionClassifier.shared.unloadIfIdle(idleSeconds) }
        if !n.rulesInjection { await PromptInjectionClassifier.claudeMd.unloadIfIdle(idleSeconds) }
    }
}

extension Daemon {
    /// The classifiers' reconcile, every 2 minutes, over the running workspaces.
    // partial: a task over the daemon's live workspaces (macOS: a RunLoop timer)
    // @port ClassifierLifecycle.static start(running: @escaping@MainActor()->[Profile]) h=0cace14a55be29b9 @19b04b00
    func startClassifierLifecycle(every interval: Duration = .seconds(120)) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                let running = await self.runningWorkspaceProfiles()
                await LinuxClassifierLifecycle.reconcile(LinuxClassifierLifecycle.needs(for: running))
            }
        }
    }

    /// The running workspaces' profiles (not a cluster's or a sign-in's machines).
    // @port-skip linux-only: see startClassifierLifecycle
    func runningWorkspaceProfiles() -> [Profile] {
        records.filter { live[$0.id] != nil && !$0.managed }.compactMap { existingProfile(for: $0) }
    }
}
