import Foundation

/// Keeps the in-process ONNX classifiers (PII/Rampart, prompt-injection
/// source + rules) resident only while something needs them (B46: ~1.3 GB
/// RSS with both loaded for a whole demo day).
///
/// The classifiers already load lazily on first use. This releases them again
/// once no RUNNING workspace has the matching policy on and they have sat idle
/// for `idleSeconds` — the idle guard keeps the policy-less users (agent-to-
/// agent delegation scans, repo watcher, automations) from reloading on every
/// message. Reconciled on a timer (every 2 min).
@MainActor
enum ClassifierLifecycle {
    struct Needs: Equatable {
        var pii = false
        var sourceInjection = false
        var rulesInjection = false
    }

    static let idleSeconds: TimeInterval = 300
    private static var timer: Timer?
    private static var needs: @MainActor () -> Needs = { Needs(pii: true, sourceInjection: true, rulesInjection: true) }

    /// What the given running workspaces' policies need resident.
    nonisolated static func needs(for running: [Profile]) -> Needs {
        Needs(pii: running.contains { $0.pii.isActive },
              sourceInjection: running.contains { $0.promptInjection.detectSourceInjection },
              rulesInjection: running.contains { $0.promptInjection.detectRulesInjection })
    }

    /// Call once at launch with a provider of the running workspaces.
    static func start(running: @escaping @MainActor () -> [Profile]) {
        needs = { Self.needs(for: running()) }
        timer?.invalidate()
        let t = Timer(timeInterval: 120, repeats: true) { _ in
            Task { @MainActor in ClassifierLifecycle.reconcile() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Release every classifier no running workspace needs (and nothing used
    /// for `idleSeconds`).
    static func reconcile() {
        let n = needs()
        let idle = idleSeconds
        Task.detached(priority: .utility) {
            if !n.pii { await PIIDetector.shared.unloadIfIdle(idle) }
            if !n.sourceInjection { await PromptInjectionClassifier.shared.unloadIfIdle(idle) }
            if !n.rulesInjection { await PromptInjectionClassifier.claudeMd.unloadIfIdle(idle) }
        }
    }
}
