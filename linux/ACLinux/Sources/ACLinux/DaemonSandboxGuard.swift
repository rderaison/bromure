import Foundation

/// The guest's sandbox is staged (writeSandboxFiles), and the sentry's
/// channel and module staging are wired (DaemonSentry.swift), its modules
/// from the published, signed catalog for this host's architecture. A
/// guest whose sentry can't load runs without it, so while no verified
/// catalog is to be had (none published for this arch yet, or none
/// reachable or cached) a workspace that asks for the sentry isn't started
/// at all, rather than booted without the protection it expects: fail
/// closed.
/// The same refusal covers a sandbox whose guest scripts aren't beside
/// agentd on this server (SessionDisk.missingGuestSandboxScripts: staging
/// would fail closed anyway; this says so as a 409).
struct SandboxUnavailable: Error, CustomStringConvertible {
    let workspace: String
    let missing: [String]
    /// How a missing-scripts entry starts (unenforceableProtections).
    static let scriptsPrefix = "the guest sandbox's scripts "
    // @port-skip linux-only: a Linux refusal (macOS stages the guest sandbox)
    var description: String {
        let scripts = missing.filter { $0.hasPrefix(Self.scriptsPrefix) }
        let rest = missing.filter { !$0.hasPrefix(Self.scriptsPrefix) }
        var parts: [String] = []
        // Not a protection Linux lacks: an install that left them out.
        if !scripts.isEmpty {
            parts.append("'\(workspace)' isn't started: this server's install is incomplete (\(scripts.joined(separator: "; "))). "
                + "Re-run the installer: linux/install-user-service.sh, or linux/multiuser/install.sh on a multi-user server")
        }
        if !rest.isEmpty {
            parts.append("'\(workspace)' asks for \(rest.joined(separator: ", ")), which this server can't enforce yet; "
                + "it isn't started rather than run without it")
        }
        return parts.joined(separator: ". ")
    }
}

extension Daemon {
    /// What `profile` asks for that a Linux guest can't enforce (empty:
    /// nothing): the sentry while no verified catalog is to be had
    /// (`sentryCatalog` false), and, with
    /// `setupDir` (where the guest scripts ship, beside agentd), a sandbox
    /// whose scripts the install left out.
    // @port-skip linux-only: a Linux refusal (macOS stages the guest sandbox)
    static func unenforceableProtections(_ profile: Profile, setupDir: URL? = nil, sentryCatalog: Bool = false) -> [String] {
        var missing: [String] = []
        // The strict sandbox and the OpenShell spec are staged
        // (writeSandboxFiles) from the scripts beside agentd.
        if let setupDir {
            let files = SessionDisk.missingGuestSandboxScripts(profile, setupDir: setupDir)
            if !files.isEmpty {
                missing.append(SandboxUnavailable.scriptsPrefix
                               + "\(files.joined(separator: ", ")) are missing from \(setupDir.path)")
            }
        }
        // No verified sentry module catalog for this host's architecture.
        if profile.effectiveKernelSentry != .off, !sentryCatalog {
            missing.append("the kernel sentry (\(profile.effectiveKernelSentry.rawValue))")
        }
        return missing
    }

    /// A VM taken back (adoptRunning) whose workspace asks for a protection
    /// this server can't enforce yet keeps running (stopping it isn't the
    /// daemon's call), but it's said loudly: a warning in the daemon log and
    /// a degraded `sandbox.status` on the Security Timeline (what a guest
    /// whose sandbox failed reports on macOS). `staged`: the VM's meta
    /// share, where its sandbox's scripts were staged when it booted (one
    /// booted on an incomplete install has none). `sentryCatalog`: a verified
    /// module catalog is cached.
    // @port-skip linux-only: a Linux warning (macOS stages the guest sandbox)
    static func warnUnenforceableAdopted(_ rec: VMRecord, profile: Profile, staged: URL? = nil, sentryCatalog: Bool = false) {
        guard !rec.managed, rec.registration != true else { return }
        let missing = unenforceableProtections(profile, setupDir: staged, sentryCatalog: sentryCatalog)
        guard !missing.isEmpty else { return }
        let said = missing.map { $0.hasPrefix(SandboxUnavailable.scriptsPrefix) ? $0 : $0 + " not staged on this server" }
        let reason = "\(said.joined(separator: ", ")): the guest runs without it"
        FileHandle.standardError.write(Data("bromure-ac daemon: WARNING: '\(profile.name)' was taken back running UNPROTECTED: \(reason)\n".utf8))
        var data: [String: AnyJSON] = ["filesystem": .string("failed"), "action": .string("degraded"), "reason": .string(reason)]
        if profile.effectiveKernelSentry != .off {
            data["sentry"] = .string("unavailable")
            data["sentry_reason"] = .string("not staged on this server")
        }
        BACEventEmitter.shared.emitDetached(profileID: profile.id, eventType: "sandbox.status", eventData: data)
    }

    /// Refuses `rec`'s launch when its workspace asks for a protection this
    /// server can't enforce (SandboxUnavailable).
    // @port-skip linux-only: a Linux refusal (macOS stages the guest sandbox)
    func refuseUnenforceableSandbox(_ rec: VMRecord) async throws {
        guard !rec.managed, rec.registration != true, let profile = await launchProfile(for: rec) else { return }
        let catalog = profile.effectiveKernelSentry != .off ? await sentryCatalogReady() : false
        let missing = Self.unenforceableProtections(profile, setupDir: setupDir, sentryCatalog: catalog)
        guard !missing.isEmpty else { return }
        let refusal = SandboxUnavailable(workspace: profile.name, missing: missing)
        FileHandle.standardError.write(Data("bromure-ac daemon: refused to start: \(refusal)\n".utf8))
        throw refusal
    }
}
