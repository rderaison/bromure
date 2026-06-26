import Foundation

/// Which backend a request is routed to.
public enum Backend: String, Sendable, Equatable {
    case cloud
    case local
}

/// Why the router picked a backend — surfaced into the trace marker
/// (§4.4 `x-bromure-served-by`) and useful for tests.
public enum RoutingReason: String, Sendable, Equatable {
    case forcedCloud        // routing == .cloud
    case forcedLocal        // routing == .local
    case sticky             // session already pinned (coherence guard)
    case overBudget         // cloud token budget exhausted for the window
    case unhealthy          // health gate (EWMA TTFT / failures) tripped
    case splitRatio         // proactively pinned local by the split %
    case hardError          // realtime: connection refused / 429 / 5xx
    case softTimeout        // realtime: no first token within TTFT budget
    case cloudHealthy       // default — cloud is fine
}

public struct RoutingDecision: Sendable, Equatable {
    public var backend: Backend
    public var reason: RoutingReason
    public init(_ backend: Backend, _ reason: RoutingReason) {
        self.backend = backend
        self.reason = reason
    }
}

/// Tunables for the hybrid policy engine. Defaults match §8 decisions:
/// 5 s soft TTFT, conservative health gate (≥3 failures or EWMA > 8 s over
/// ~10 requests, recover after a few clean probes), 24 h budget window.
public struct HybridConfig: Sendable, Equatable {
    public var cloudTokenBudget: Int          // 0 = unlimited
    public var budgetWindowSeconds: Double     // rolling wall-clock window
    public var softTTFTSeconds: Double         // soft fallback threshold
    public var localSplitPercent: Int          // 0..100 of new sessions → local
    public var ewmaTTFTThresholdSeconds: Double
    public var failureThreshold: Int
    public var failureWindow: Int              // "last ~10 requests"
    public var ewmaAlpha: Double               // EWMA decay (newer = heavier)
    public var recoveryProbes: Int             // clean probes to recover

    public init(cloudTokenBudget: Int = 0,
                budgetWindowSeconds: Double = 86_400,
                softTTFTSeconds: Double = 5,
                localSplitPercent: Int = 0,
                ewmaTTFTThresholdSeconds: Double = 8,
                failureThreshold: Int = 3,
                failureWindow: Int = 10,
                ewmaAlpha: Double = 0.3,
                recoveryProbes: Int = 3) {
        self.cloudTokenBudget = cloudTokenBudget
        self.budgetWindowSeconds = budgetWindowSeconds
        self.softTTFTSeconds = softTTFTSeconds
        self.localSplitPercent = max(0, min(100, localSplitPercent))
        self.ewmaTTFTThresholdSeconds = ewmaTTFTThresholdSeconds
        self.failureThreshold = failureThreshold
        self.failureWindow = failureWindow
        self.ewmaAlpha = ewmaAlpha
        self.recoveryProbes = recoveryProbes
    }

    /// Build the hybrid config from a profile's persisted knobs.
    public init(profile: Profile) {
        self.init(cloudTokenBudget: max(0, profile.hybridCloudTokenBudget),
                  softTTFTSeconds: profile.hybridSoftTTFTSeconds,
                  localSplitPercent: profile.hybridLocalSplitPercent)
    }
}

/// The hybrid routing policy engine (§4.3). Thread-safe; one instance per
/// profile. Time is injected (`now`) so the rolling-window budget and the
/// health gate are deterministically testable.
///
/// Precedence for a *new session* (first match wins, §4.3.1):
///   sticky → over-budget → unhealthy(EWMA) → split-ratio → cloud
/// Realtime hard/soft triggers fire *during* a request via
/// `recordHardError` / `recordSoftTimeout`, which also pin the session
/// local for the rest of its life (the coherence guard, Trap 2).
public final class HybridRouter: @unchecked Sendable {
    public private(set) var config: HybridConfig
    private let lock = NSLock()

    // Sticky session decisions (coherence guard).
    private var sessionBackend: [String: Backend] = [:]

    // Cloud token budget ledger: (timestamp, tokens).
    private var cloudTokenLedger: [(t: Double, n: Int)] = []

    // Health gate state.
    private var ewmaTTFT: Double? = nil
    private var recentFailures: [Bool] = []   // sliding window, true = failure
    private var unhealthy = false
    private var cleanProbes = 0

    public init(config: HybridConfig) {
        self.config = config
    }

    public func update(config: HybridConfig) {
        lock.lock(); self.config = config; lock.unlock()
    }

    // MARK: - Routing decision

    /// Decide the backend for a session under hybrid routing.
    public func route(sessionID: String, now: Double) -> RoutingDecision {
        lock.lock(); defer { lock.unlock() }

        // Coherence guard: a session never switches mid-trajectory.
        if let pinned = sessionBackend[sessionID] {
            return RoutingDecision(pinned, .sticky)
        }

        let decision = decideFresh(sessionID: sessionID, now: now)
        sessionBackend[sessionID] = decision.backend
        return decision
    }

    private func decideFresh(sessionID: String, now: Double) -> RoutingDecision {
        // 1. over-budget
        if config.cloudTokenBudget > 0,
           cloudTokensInWindow(now: now) >= config.cloudTokenBudget {
            return RoutingDecision(.local, .overBudget)
        }
        // 2. unhealthy (EWMA / failure gate)
        if unhealthy {
            return RoutingDecision(.local, .unhealthy)
        }
        // 3. split-ratio assignment
        if config.localSplitPercent > 0,
           Self.stableBucket(sessionID) < config.localSplitPercent {
            return RoutingDecision(.local, .splitRatio)
        }
        // 4. otherwise cloud
        return RoutingDecision(.cloud, .cloudHealthy)
    }

    /// Force a session local for the rest of its life (realtime fallback).
    private func pinLocal(_ sessionID: String) {
        sessionBackend[sessionID] = .local
    }

    // MARK: - Realtime triggers (Trap 1)

    /// Hard trigger: connection refused / timeout / 429 / 529 / 5xx. The
    /// caller replays the request local; we pin the session and feed the
    /// health gate so subsequent sessions skip the cloud penalty.
    public func recordHardError(sessionID: String, now: Double) {
        lock.lock(); defer { lock.unlock() }
        pinLocal(sessionID)
        pushOutcome(failure: true, ttft: nil)
    }

    /// Soft trigger: no first token within the TTFT budget. Same handling
    /// as a hard error for stickiness, but counts as a slow sample.
    public func recordSoftTimeout(sessionID: String, now: Double) {
        lock.lock(); defer { lock.unlock() }
        pinLocal(sessionID)
        pushOutcome(failure: true, ttft: config.softTTFTSeconds)
    }

    /// A clean cloud success with its measured time-to-first-token.
    public func recordSuccess(ttftSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        pushOutcome(failure: false, ttft: ttftSeconds)
    }

    // MARK: - Budget

    /// Account cloud-served tokens against the rolling window (§4.3.1).
    public func recordCloudTokens(_ n: Int, now: Double) {
        guard n > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        cloudTokenLedger.append((t: now, n: n))
        pruneLedger(now: now)
    }

    /// Tokens served by cloud within the current rolling window.
    public func cloudTokensInWindow(now: Double) -> Int {
        let cutoff = now - config.budgetWindowSeconds
        return cloudTokenLedger.reduce(0) { $1.t >= cutoff ? $0 + $1.n : $0 }
    }

    private func pruneLedger(now: Double) {
        let cutoff = now - config.budgetWindowSeconds
        cloudTokenLedger.removeAll { $0.t < cutoff }
    }

    // MARK: - Health gate (§4.3, conservative)

    private func pushOutcome(failure: Bool, ttft: Double?) {
        recentFailures.append(failure)
        if recentFailures.count > config.failureWindow {
            recentFailures.removeFirst(recentFailures.count - config.failureWindow)
        }
        if let ttft {
            ewmaTTFT = ewmaTTFT.map { config.ewmaAlpha * ttft + (1 - config.ewmaAlpha) * $0 } ?? ttft
        }

        let failures = recentFailures.lazy.filter { $0 }.count
        let slow = (ewmaTTFT ?? 0) > config.ewmaTTFTThresholdSeconds

        if unhealthy {
            // Recover only after a streak of clean, fast probes.
            if !failure && !slow {
                cleanProbes += 1
                if cleanProbes >= config.recoveryProbes {
                    unhealthy = false
                    cleanProbes = 0
                    recentFailures.removeAll()
                }
            } else {
                cleanProbes = 0
            }
        } else if failures >= config.failureThreshold || slow {
            unhealthy = true
            cleanProbes = 0
        }
    }

    // MARK: - Introspection (tests / observability)

    public var isUnhealthy: Bool { lock.lock(); defer { lock.unlock() }; return unhealthy }
    public var ttftEWMA: Double? { lock.lock(); defer { lock.unlock() }; return ewmaTTFT }
    public func pinnedBackend(for sessionID: String) -> Backend? {
        lock.lock(); defer { lock.unlock() }; return sessionBackend[sessionID]
    }

    /// Forget a finished session so its sticky decision doesn't leak.
    public func endSession(_ sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        sessionBackend.removeValue(forKey: sessionID)
    }

    // MARK: - Stable hashing

    /// Deterministic 0–99 bucket from a session id. Swift's `Hasher` is
    /// per-process randomized, so the split ratio uses an FNV-1a hash to
    /// stay reproducible across launches and in tests.
    static func stableBucket(_ s: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % 100)
    }
}
