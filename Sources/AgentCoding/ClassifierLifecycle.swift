import Foundation

/// Where an on-device detector model stands, asked without waiting for it.
enum ModelReadiness: Equatable, Sendable {
    /// Loaded: a scan runs now.
    case ready
    /// Being loaded (seconds, at first use or after an idle release).
    case loading
    /// Still loading past `warmupGrace`: a request no longer gets "try
    /// again" (an agent's retries run out), it waits for the load as before.
    case loadingLong
    /// Not installed, or it failed to load: the scan goes on without it.
    case absent

    static let warmupGrace: TimeInterval = 30

    static func loading(since start: Date, now: Date = Date()) -> ModelReadiness {
        now.timeIntervalSince(start) < warmupGrace ? .loading : .loadingLong
    }
}

/// The queue a detector's load and inference run on. Both block for a long
/// time — an ONNX session over a few hundred MB takes seconds to build — and
/// an actor's default executor is one of Swift concurrency's shared threads
/// (one per core): a load there held it, and with them the async work of the
/// whole app (see `MitmBlockingExecutor`). A dispatch queue's thread is its
/// own.
enum ClassifierQueue {
    static func make(_ label: String) -> DispatchSerialQueue {
        DispatchSerialQueue(label: "io.bromure.classifier.\(label)", qos: .userInitiated)
    }
}

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
