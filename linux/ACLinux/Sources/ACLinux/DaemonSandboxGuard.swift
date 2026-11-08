import Foundation

/// TEMPORARY (remove when Linux takes the published sentry module
/// catalog): the guest's sandbox is staged (writeSandboxFiles), and the
/// sentry's channel and module staging are wired (DaemonSentry.swift), but
/// its modules come only from a configured catalog
/// (BROMURE_SENTRY_CATALOG_BASE), and a guest whose sentry can't load runs
/// without it. So a workspace that asks for the sentry isn't started at
/// all, rather than booted without the protection it expects: fail closed.
struct SandboxUnavailable: Error, CustomStringConvertible {
    let workspace: String
    let missing: [String]
    // @port-skip linux-only: a temporary Linux refusal (macOS stages the guest sandbox)
    var description: String {
        "'\(workspace)' asks for \(missing.joined(separator: ", ")), which this server can't enforce yet; "
            + "it isn't started rather than run without it"
    }
}

extension Daemon {
    /// What `profile` asks for that a Linux guest can't enforce yet (empty:
    /// nothing). TEMPORARY, with SandboxUnavailable.
    // @port-skip linux-only: a temporary Linux refusal (macOS stages the guest sandbox)
    static func unenforceableProtections(_ profile: Profile) -> [String] {
        // The strict sandbox and the OpenShell spec are staged
        // (writeSandboxFiles); the sentry's modules not from the published
        // catalog yet.
        guard profile.effectiveKernelSentry != .off else { return [] }
        return ["the kernel sentry (\(profile.effectiveKernelSentry.rawValue))"]
    }

    /// A VM taken back (adoptRunning) whose workspace asks for a protection
    /// this server can't enforce yet keeps running (stopping it isn't the
    /// daemon's call), but it's said loudly: a warning in the daemon log and
    /// a degraded `sandbox.status` on the Security Timeline (what a guest
    /// whose sandbox failed reports on macOS). TEMPORARY, with
    /// SandboxUnavailable.
    // @port-skip linux-only: a temporary Linux warning (macOS stages the guest sandbox)
    static func warnUnenforceableAdopted(_ rec: VMRecord, profile: Profile) {
        guard !rec.managed, rec.registration != true else { return }
        let missing = unenforceableProtections(profile)
        guard !missing.isEmpty else { return }
        let reason = "\(missing.joined(separator: ", ")) not staged on this server: the guest runs without it"
        FileHandle.standardError.write(Data("bromure-ac daemon: WARNING: '\(profile.name)' was taken back running UNPROTECTED: \(reason)\n".utf8))
        var data: [String: AnyJSON] = ["filesystem": .string("failed"), "action": .string("degraded"), "reason": .string(reason)]
        if profile.effectiveKernelSentry != .off {
            data["sentry"] = .string("unavailable")
            data["sentry_reason"] = .string("not staged on this server")
        }
        BACEventEmitter.shared.emitDetached(profileID: profile.id, eventType: "sandbox.status", eventData: data)
    }

    /// Refuses `rec`'s launch when its workspace asks for a protection this
    /// server can't enforce yet. TEMPORARY, with SandboxUnavailable.
    // @port-skip linux-only: a temporary Linux refusal (macOS stages the guest sandbox)
    func refuseUnenforceableSandbox(_ rec: VMRecord) async throws {
        guard !rec.managed, rec.registration != true, let profile = await launchProfile(for: rec) else { return }
        let missing = Self.unenforceableProtections(profile)
        guard !missing.isEmpty else { return }
        let refusal = SandboxUnavailable(workspace: profile.name, missing: missing)
        FileHandle.standardError.write(Data("bromure-ac daemon: refused to start: \(refusal)\n".utf8))
        throw refusal
    }
}
