import Foundation
import SandboxEngine

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
    /// How a run_as-with-shared-folders entry starts (unenforceableProtections).
    static let runAsSharesPrefix = "run_as_user "
    // @port-skip linux-only: a Linux refusal (macOS stages the guest sandbox)
    var description: String {
        let scripts = missing.filter { $0.hasPrefix(Self.scriptsPrefix) }
        let runAs = missing.filter { $0.hasPrefix(Self.runAsSharesPrefix) }
        let rest = missing.filter { !$0.hasPrefix(Self.scriptsPrefix) && !$0.hasPrefix(Self.runAsSharesPrefix) }
        var parts: [String] = []
        // Not a protection still to come: a combination a Linux host can't
        // serve (linux/VIRTIOFS_DAC.md), and the two ways out.
        for entry in runAs {
            parts.append("'\(workspace)' isn't started: its policy's \(entry), and on a Linux host that user can't write "
                + "the shared folders (they stay owned by the workspace user). Remove run_as_user from the policy, "
                + "or the workspace's shared folders")
        }
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
        // A separate run_as user with shared folders: its workload could
        // read them and never write them.
        if let user = runAsUserBlockedByShares(profile) {
            missing.append(SandboxUnavailable.runAsSharesPrefix + "'\(user)' is set together with shared folders")
        }
        // No verified sentry module catalog for this host's architecture.
        if profile.effectiveKernelSentry != .off, !sentryCatalog {
            missing.append("the kernel sentry (\(profile.effectiveKernelSentry.rawValue))")
        }
        return missing
    }

    /// The run_as user of `profile`'s OpenShell policy when the workspace
    /// also has shared folders, else nil. On a Linux host a share's files
    /// stay owned by the workspace user (virtiofsd can't remap them per
    /// guest user, and the guest kernel can't idmap a virtiofs mount), so a
    /// separate user's workload could read them and not write them
    /// (linux/VIRTIOFS_DAC.md, option 6). The workspace user itself, by
    /// name or uid, isn't separate. Read as the guest's spec is staged
    /// (OpenShellSandboxSpec's lenient `process` section), not through the
    /// strict policy parse: a policy that fails that parse elsewhere still
    /// hands the guest its run_as user.
    // @port-skip linux-only: a Linux refusal (macOS's VZ shares let the run_as user write)
    static func runAsUserBlockedByShares(_ profile: Profile) -> String? {
        guard !SessionDisk.sharedFolders(profile.folderPaths).isEmpty,
              case .object(let process)? = OpenShellSandboxSpec(policyYAML: profile.networkPolicy, workdirs: [],
                                                                strictSandbox: false, sentry: "off").process,
              let value = process["run_as_user"] else { return nil }
        let user: String
        switch value {
        case .null: return nil
        case .string(let s): user = s
        case .int(let i): user = String(i)
        // Anything else the guest would still be handed: refused, as it is.
        default: user = "\(value)"
        }
        return ["ubuntu", "1000"].contains(user) ? nil : user
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
        // A run_as user with shared folders isn't a protection the guest
        // runs without: its supervisor's own status says that user can't
        // write them (check_workdir_access).
        let missing = unenforceableProtections(profile, setupDir: staged, sentryCatalog: sentryCatalog)
            .filter { !$0.hasPrefix(SandboxUnavailable.runAsSharesPrefix) }
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
