import Foundation
#if os(macOS)
import SandboxEngine
#endif

// Cloud event client → /v1/installs/:installId/ac-events.
//
// One emitter, one uploader, one activity-based session tracker —
// kept in this file so the credential hooks (TokenSwap, SSHAgent,
// AWSResigner) and the LLM-body parser plug into the same surface.
//
// Privacy posture: emit silently no-ops when the Mac isn't enrolled
// with bromure.io (no install token → nothing to authenticate as,
// nothing to send), AND when the profile is in private mode
// (the per-profile private-mode flag is set from the Profile UI; the
// hook is in place here so toggling it is purely a UI change). Anything that would be
// streamed bypasses the emitter entirely — the buffer never sees it.

/// Wire-shape event matching the server's POST /v1/installs/:installId/ac-events.
public struct BACCloudEvent: Codable, Sendable {
    public let sessionId: UUID
    public let profileId: UUID?
    public let ts: Date
    public let eventType: String
    public let eventData: [String: AnyJSON]

    public init(sessionId: UUID, profileId: UUID?, ts: Date,
                eventType: String, eventData: [String: AnyJSON]) {
        self.sessionId = sessionId
        self.profileId = profileId
        self.ts = ts
        self.eventType = eventType
        self.eventData = eventData
    }
}

/// Minimal codable any-value so each event can carry its own
/// payload shape without us needing one struct per event type. The
/// server accepts whatever JSON object shape we send and stores it
/// as jsonb; what's enumerated server-side is just `eventType`.
public enum AnyJSON: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyJSON])
    case object([String: AnyJSON])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v); return }
        if let v = try? c.decode(Int.self)    { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
        if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "AnyJSON unsupported scalar")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension AnyJSON {
    public static func of(_ v: String?) -> AnyJSON { v.map { .string($0) } ?? .null }
    public static func of(_ v: Int?) -> AnyJSON    { v.map { .int($0) } ?? .null }
    public static func of(_ v: Double?) -> AnyJSON { v.map { .double($0) } ?? .null }
    public static func of(_ v: Bool?) -> AnyJSON   { v.map { .bool($0) } ?? .null }
}

/// Activity-based session tracker. A "session" rolls over after 20
/// minutes of no activity for that profile, matching the product
/// model (sessions = "when a user starts using claude
/// and stops using it", not VM lifecycle). One session id per
/// (profile, activity window).
public actor BACSessionTracker {
    public static let shared = BACSessionTracker()

    private var sessionIdByProfile: [UUID: UUID] = [:]
    private var lastActivityByProfile: [UUID: Date] = [:]

    /// Idle threshold for rolling a profile to a new session id.
    /// Picked deliberately long: AC sessions are bursty (claude
    /// thinks, then runs five tool calls in 30 s, then idle for
    /// 8 min while the user reads the diff). 20 min keeps that
    /// whole arc in one session; an hour-long lunch break breaks
    /// into two.
    public static let idleTimeoutSec: TimeInterval = 20 * 60

    /// Returns the current session id for `profileID`, rolling to a
    /// fresh one when more than `idleTimeoutSec` has passed since
    /// the last activity. Bumps the last-activity timestamp for
    /// `now`.
    ///
    /// `rolled` in the result is true on the call that opened a new
    /// session — the emitter uses it to interleave a session.start
    /// (and a session.end for the prior one if there was one).
    public struct Bump {
        public let sessionId: UUID
        public let priorSessionId: UUID?
        public let rolled: Bool
    }

    public func bump(profileID: UUID, now: Date = Date()) -> Bump {
        let prior = sessionIdByProfile[profileID]
        let last = lastActivityByProfile[profileID]
        let timedOut: Bool = {
            guard let last else { return prior == nil }   // first activity ⇒ rolled
            return now.timeIntervalSince(last) > Self.idleTimeoutSec
        }()
        if timedOut || prior == nil {
            let fresh = UUID()
            sessionIdByProfile[profileID] = fresh
            lastActivityByProfile[profileID] = now
            return Bump(sessionId: fresh, priorSessionId: prior, rolled: true)
        }
        lastActivityByProfile[profileID] = now
        return Bump(sessionId: prior!, priorSessionId: nil, rolled: false)
    }

    /// Force-close the session for `profileID` (e.g. when the
    /// window closes). The next bump opens a fresh one.
    public func close(profileID: UUID) -> UUID? {
        let prior = sessionIdByProfile[profileID]
        sessionIdByProfile[profileID] = nil
        lastActivityByProfile[profileID] = nil
        return prior
    }
}

/// Caller's view of the emitter — every credential hook + the LLM
/// parser funnels through here. Sendable so it can be invoked from
/// the proxy's connection task without bouncing back to MainActor.
///
/// `enabled` short-circuits when no install identity is present
/// (not enrolled) or when the profile is in private mode.
public final class BACEventEmitter: @unchecked Sendable {
    public static let shared = BACEventEmitter()
    private init() {}

    private let lock = NSLock()
    private var uploader: BACCloudUploader?
    /// Profile UUIDs flagged "do not stream", populated from the
    /// Profile UI's private-mode toggle.
    private var privateProfileIDs: Set<UUID> = []

    public func setPrivateProfiles(_ ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        privateProfileIDs = ids
    }

    public func ensureUploader() {
        lock.lock(); defer { lock.unlock() }
        if uploader == nil {
            uploader = BACCloudUploader()
        }
    }

    /// Cheap, lock-guarded "is this install enrolled and streaming?"
    /// signal for hot paths (the MITM proxy) that want to emit
    /// telemetry whenever enrolled — without paying the keychain /
    /// disk read `emit()`'s hard gate does per call. The uploader is
    /// stood up on enroll/launch and torn down on unenroll, so its
    /// presence mirrors enrollment. `emit()` still applies the
    /// authoritative enrollment + private-mode gates before upload.
    public var isStreamingEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return uploader != nil
    }

    /// Drop any buffered events and tear down the uploader (called on
    /// unenroll so the next enrollment starts clean).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        uploader?.shutdown()
        uploader = nil
    }

    /// Async because the session tracker is an actor. Callers from
    /// existing `async` contexts (the proxy, the credential hooks)
    /// just `await`; the credential hooks already do.
    public func emit(profileID: UUID,
                     eventType: String,
                     eventData: [String: AnyJSON]) async {
        // Local Security Timeline — ALWAYS, before either gate below. It's an
        // on-device view of what the engines did on the user's own machine,
        // independent of the enrolled-only, cloud-bound telemetry.
        await SecurityTimeline.shared.record(profileID: profileID,
                                             eventType: eventType, eventData: eventData)
        #if os(macOS)
        // OpenShell policy advisor: every firewall denial is evidence for the
        // agent (`/v1/denials`) and may become a drafted proposal.
        if eventType == "egress.firewall", case .string(let action)? = eventData["action"], action == "deny" {
            func s(_ k: String) -> String? { if case .string(let v)? = eventData[k] { return v }; return nil }
            var port = 0
            if case .int(let p)? = eventData["port"] { port = p }
            OpenShellAdvisor.shared.recordDenial(
                profileID: profileID, layer: s("layer") ?? "l4", host: s("host") ?? s("ip") ?? "?",
                port: port, method: s("method"), path: s("path"), reason: s("reason") ?? "no matching network policy")
        }
        // Network lineage: every host decision about a flow (switch L4, MITM
        // L7, binary identity) joins the flow the sentry reports.
        if eventType == "egress.firewall" {
            func s(_ k: String) -> String? { if case .string(let v)? = eventData[k] { return v }; return nil }
            var port = 0
            if case .int(let p)? = eventData["port"] { port = p }
            let layer = s("layer") ?? "l4"
            let dst = s("ip") ?? s("host").map { "host:\($0)" } ?? "?"
            NetworkLineage.shared.noteDecision(
                profileID: profileID, proto: s("proto") ?? "tcp", dst: dst, dport: port,
                action: s("action") ?? "allow", layer: layer, reason: s("reason"), host: s("host"))
        }
        // The agent watchdog judges the session as a whole (off by default).
        AgentWatchdog.shared.observe(profileID: profileID, eventType: eventType, eventData: eventData)
        // OCSF JSONL export (SIEM) — local like the timeline; off by default.
        if OCSFExporter.shared.isEnabled {
            let workspace = await MainActor.run { SecurityTimeline.shared.workspaceName(profileID) }
            OCSFExporter.shared.record(profileID: profileID, workspace: workspace,
                                       eventType: eventType, eventData: eventData)
        }
        #endif

        // The agent's reasoning stays on this Mac unless the organization
        // opted in: "what the AI did, never what it said" is the default.
        #if os(macOS)
        if eventType == "agent.reasoning", OpenShellGovernance.shared.managed?.captureAgentReasoning != true { return }
        #endif

        // Hard gate: no install identity → nothing to authenticate
        // as, nothing to upload.
        guard BACEnrollmentStore.load() != nil,
              BACEnrollmentStore.loadInstallToken() != nil else {
            BACDebug.log("[ac/emit]",
                         "drop (not enrolled) eventType=\(eventType)")
            return
        }
        // Soft gate: per-profile private mode.
        let isPrivate: Bool = {
            lock.lock(); defer { lock.unlock() }
            return privateProfileIDs.contains(profileID)
        }()
        if isPrivate {
            BACDebug.log("[ac/emit]",
                         "drop (private profile) eventType=\(eventType)")
            return
        }

        let bumpT0 = Date()
        BACDebug.log("[ac/emit]",
                     "session bump start eventType=\(eventType) profile=\(profileID)")
        let bump = await BACSessionTracker.shared.bump(profileID: profileID)
        BACDebug.log("[ac/emit]",
                     "session bump done eventType=\(eventType) rolled=\(bump.rolled) took=\(BACDebug.ms(bumpT0))")
        if bump.rolled, let prior = bump.priorSessionId {
            // The previous session ended at "20 min after the last
            // event" but we only learn that on the *next* event, so
            // backdate session.end to that boundary. Keeps the
            // server-side session view's duration accurate.
            let endTs = Date(timeIntervalSinceNow: -BACSessionTracker.idleTimeoutSec)
            queue(BACCloudEvent(
                sessionId: prior, profileId: profileID,
                ts: endTs, eventType: "session.end",
                eventData: ["reason": .string("idle_timeout")]))
        }
        if bump.rolled {
            queue(BACCloudEvent(
                sessionId: bump.sessionId, profileId: profileID,
                ts: Date(), eventType: "session.start",
                eventData: [:]))
        }
        queue(BACCloudEvent(
            sessionId: bump.sessionId, profileId: profileID,
            ts: Date(), eventType: eventType, eventData: eventData))
    }

    /// Synchronous-context emit for callers that aren't already
    /// async (NSWindow close handler, AppKit menus). Spawns a Task.
    public func emitDetached(profileID: UUID,
                             eventType: String,
                             eventData: [String: AnyJSON]) {
        Task { await emit(profileID: profileID,
                          eventType: eventType,
                          eventData: eventData) }
    }

    /// Force-close `profileID`'s active session (e.g. window close).
    public func closeSession(profileID: UUID, reason: String) {
        Task {
            guard let prior = await BACSessionTracker.shared.close(profileID: profileID) else { return }
            queue(BACCloudEvent(
                sessionId: prior, profileId: profileID,
                ts: Date(), eventType: "session.end",
                eventData: ["reason": .string(reason)]))
        }
    }

    private func queue(_ event: BACCloudEvent) {
        lock.lock()
        let up = uploader
        lock.unlock()
        if let up {
            BACDebug.log("[ac/emit]",
                         "queue eventType=\(event.eventType) session=\(event.sessionId)")
            up.enqueue(event)
        } else {
            BACDebug.log("[ac/emit]",
                         "drop (no uploader) eventType=\(event.eventType)")
        }
    }
}

extension BACEventEmitter {
    /// Flush any buffered events synchronously (best-effort). Called
    /// at app teardown.
    public func flush() async {
        let up: BACCloudUploader? = lock.withLock { uploader }
        await up?.flushNow()
    }
}
