import Foundation

// MARK: - Guest sandbox status

/// What the guest's root launcher reported about OpenShell's
/// filesystem_policy / landlock / process enforcement (on the attestor
/// channel, `{"event":"sandbox_status",…}`), per workspace. A change is
/// recorded on the Security Timeline (and so in OCSF), and a sandbox that
/// failed or degraded is a watchdog signal.
public final class GuestSandboxStatusStore: @unchecked Sendable {
    public static let shared = GuestSandboxStatusStore()

    public struct Status: Equatable, Sendable {
        public var filesystem: String          // enforced / degraded / failed / off
        public var degradedReason: String?
        public var landlockABI: Int?
        public var seccomp: String?
        public var runAsUser: String?
        public var runAsUID: Int?
        public var sentry: String?             // running / unavailable / off
        /// Why the sentry is unavailable (kernel mismatch, no headers, …).
        public var sentryReason: String?
        /// The strict revocation: true = every privilege path removed,
        /// false = attempted but not fully applied, nil = not a strict boot.
        public var strictApplied: Bool?
        public var additionsReadWrite: [String]
        public var additionsReadOnly: [String]
        /// Guest-side caveats (e.g. the run_as uid can't write a workdir).
        public var warnings: [String]
        /// The supervisor restarted the sandboxed session server this many
        /// times (kill-server, last window closed, …).
        public var serverRestarts: Int
        public var receivedAt: Date
        /// The booted spec asked for a filesystem ruleset (`requested.filesystem`).
        public var filesystemRequested: Bool? = nil

        /// The filesystem sandbox isn't doing what was asked: Landlock failed
        /// (an unreadable spec, an unsafe socket layout, a crashed supervisor)
        /// or best effort degraded to nothing — the session may run
        /// unconfined, and only these two fields say so.
        public var filesystemFailed: Bool { filesystem == "failed" || filesystem == "degraded" }

        /// `off` because nothing was asked of the filesystem: no spec, no
        /// filesystem_policy (a process-only policy), or one with no paths.
        static let filesystemOffAsAsked: Set<String> = ["filesystem_policy not configured", "no paths configured"]

        /// The filesystem sandbox is off for a reason that isn't the policy's
        /// own: a run_as identity that couldn't be provisioned or resolved
        /// (off, with that reason), or any reason not known to be intended.
        public var filesystemOffUnasked: Bool {
            guard filesystem == "off", let reason = degradedReason, !reason.isEmpty else { return false }
            return !Self.filesystemOffAsAsked.contains(reason)
        }

        /// The booted policy asked for a ruleset and none is in force yet,
        /// with no failure said: the sandbox is still being assembled (held
        /// for a required sentry). Not a fault, but not "off" either.
        public var filesystemNotYetApplied: Bool {
            filesystem == "off" && (degradedReason ?? "").isEmpty && filesystemRequested == true
        }

        /// Anything the sandbox reported as not working as asked. The
        /// sentry counts only when the workspace wants one. A filesystem
        /// sandbox reported `off` counts only when the guest's own reason
        /// says the apply failed (Finding CWE-451, "Sandbox card warns when
        /// a process-only policy correctly leaves the filesystem off"): it
        /// was judged against the editor's unsaved draft, and a `process`
        /// section — or a filesystem_policy with no paths — warned forever.
        public func needsAttention(sentryExpected: Bool) -> Bool {
            filesystemFailed || strictApplied == false || !warnings.isEmpty
                || (sentry == "unavailable" && sentryExpected)
                || filesystemOffUnasked
        }
    }

    private let lock = NSLock()
    private var statuses: [UUID: Status] = [:]
    /// Fired on every change (UI refresh).
    public var onChange: (@Sendable (UUID) -> Void)?
    /// The kernels the guest reports (running first, then every installed
    /// one) and whether its sentry is waiting for a module: the host fetches
    /// and stages them (SentryModuleStore).
    public var onKernels: (@Sendable (UUID, [String], Bool) -> Void)?

    public func status(for profileID: UUID) -> Status? {
        lock.lock(); defer { lock.unlock() }
        return statuses[profileID]
    }

    /// The sentry's own state from the latest report, including one sent while
    /// the sandbox was still `pending` (and so not recorded as a Status): a
    /// required sentry is loaded before the supervisor publishes, and its
    /// `waiting` must still be seen.
    private var sentryStates: [UUID: (state: String, reason: String?)] = [:]
    public func sentryState(for profileID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return statuses[profileID]?.sentry ?? sentryStates[profileID]?.state
    }
    /// Why the sentry is unavailable, from the same latest report.
    public func sentryReason(for profileID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return statuses[profileID]?.sentryReason ?? sentryStates[profileID]?.reason
    }

    public func reset(profileID: UUID) {
        lock.lock(); statuses[profileID] = nil; sentryStates[profileID] = nil; lock.unlock()
        onChange?(profileID)
    }

    func update(profileID: UUID, report r: [String: Any], now: Date = Date()) {
        // Kernels first, even while the sandbox is still `pending`: the sentry
        // loads before the sandbox is assembled, and may be waiting for the
        // host to fetch its module.
        let kernels = [r["sentry_kernel"] as? String].compactMap { $0 } + (r["installed_kernels"] as? [String] ?? [])
        if !kernels.isEmpty { onKernels?(profileID, kernels, r["sentry"] as? String == "waiting") }
        if let sentry = r["sentry"] as? String {
            lock.lock(); sentryStates[profileID] = (sentry, r["sentry_reason"] as? String); lock.unlock()
        }
        // The guest hasn't assembled its sandbox yet: nothing to record, and
        // nothing to cross-check (an early "off" would read as an impostor).
        if r["filesystem"] as? String == "pending" { return }
        let runAs = r["run_as"] as? [String: Any]
        let additions = r["additions"] as? [String: Any]
        let st = Status(
            filesystem: r["filesystem"] as? String ?? "off",
            degradedReason: r["degraded_reason"] as? String,
            landlockABI: r["landlock_abi"] as? Int,
            seccomp: r["seccomp"] as? String,
            runAsUser: runAs?["user"] as? String,
            runAsUID: runAs?["uid"] as? Int,
            sentry: r["sentry"] as? String,
            sentryReason: r["sentry_reason"] as? String,
            strictApplied: r["strict_applied"] as? Bool,
            additionsReadWrite: additions?["read_write"] as? [String] ?? [],
            additionsReadOnly: additions?["read_only"] as? [String] ?? [],
            warnings: r["warnings"] as? [String] ?? [],
            serverRestarts: r["server_restarts"] as? Int ?? 0,
            receivedAt: now,
            filesystemRequested: (r["requested"] as? [String: Any])?["filesystem"] as? Bool)
        lock.lock()
        let previous = statuses[profileID]
        statuses[profileID] = st
        lock.unlock()
        KernelSentryService.shared.crossCheck(profileID: profileID, guestSentry: st.sentry,
                                              digest: r["sentry_digest"] as? String)
        // Restarts of the sandboxed session server: a burst means something
        // keeps killing it (the first step of trying to get an unsandboxed
        // replacement) — a watchdog signal.
        let restartDelta = st.serverRestarts - (previous?.serverRestarts ?? 0)
        if restartDelta >= 3 {
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "sentry.alarm", eventData: [
                "kind": .string("tampering"), "weight": .int(10),
                "reason": .string("the sandboxed session server was restarted \(restartDelta) times"),
            ])
        }
        var comparable = st; comparable.receivedAt = previous?.receivedAt ?? now
        guard previous != comparable else { return }
        // Into the app log too (tee'd to bromure-ac.log): when a sandboxed
        // workspace has no session, the guest's own explanation is here.
        let tag = profileID.uuidString.prefix(8)
        var line = "[sandbox] \(tag) filesystem=\(st.filesystem) seccomp=\(st.seccomp ?? "-") run_as=\(st.runAsUser ?? "-") sentry=\(st.sentry ?? "-")"
        if let v = st.strictApplied { line += " strict_applied=\(v)" }
        if let v = st.degradedReason { line += " reason=\(v)" }
        // Which guest code produced this (short script hashes), so a run can't
        // be mistaken for one of a different delivery.
        if let build = r["build"] as? [String: Any], !build.isEmpty {
            line += " build=" + build.keys.sorted().map { "\($0):\(build[$0].map { "\($0)" } ?? "?")" }.joined(separator: ",")
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        for w in st.warnings where !(previous?.warnings.contains(w) ?? false) {
            FileHandle.standardError.write(Data("[sandbox] \(tag) warning: \(w)\n".utf8))
        }
        var data: [String: AnyJSON] = [
            "filesystem": .string(st.filesystem),
            "action": .string(st.filesystem == "failed" || st.filesystem == "degraded" ? "degraded"
                              : st.filesystem == "off" ? "off" : "enforced"),
        ]
        if let v = st.degradedReason { data["reason"] = .string(v) }
        if let v = st.filesystemRequested { data["requested_filesystem"] = .bool(v) }
        if let v = st.landlockABI { data["landlock_abi"] = .int(v) }
        if let v = st.seccomp { data["seccomp"] = .string(v) }
        if let v = st.runAsUser { data["run_as"] = .string(v) }
        if let v = st.sentry { data["sentry"] = .string(v) }
        if let v = st.sentryReason { data["sentry_reason"] = .string(v) }
        if let v = st.strictApplied { data["strict_applied"] = .bool(v) }
        if !st.additionsReadWrite.isEmpty { data["additions_rw"] = .array(st.additionsReadWrite.map { .string($0) }) }
        if !st.additionsReadOnly.isEmpty { data["additions_ro"] = .array(st.additionsReadOnly.map { .string($0) }) }
        if !st.warnings.isEmpty { data["warnings"] = .array(st.warnings.map { .string($0) }) }
        BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "sandbox.status", eventData: data)
        onChange?(profileID)
    }
}
