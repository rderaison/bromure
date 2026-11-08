import Foundation
import SandboxEngine

/// TEMPORARY (remove when the guest sandbox staging lands on Linux): the
/// daemon doesn't stage the guest's sandbox yet (macOS's prepareMetadataShare
/// sandbox section: the OpenShell spec and its root launcher, the strict
/// marker and attestor, the kernel sentry), and a guest without those files
/// runs unconfined, saying nothing. So a workspace that asks for any of them
/// isn't started at all, rather than booted without the protection it
/// expects: fail closed.
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
        var out: [String] = []
        if profile.effectiveStrictSandbox { out.append("the strict sandbox") }
        let spec = OpenShellSandboxSpec(policyYAML: profile.networkPolicy, workdirs: [], strictSandbox: false, sentry: "off")
        if spec.filesystemPolicy != nil { out.append("an OpenShell filesystem_policy") }
        if spec.landlock != nil { out.append("OpenShell landlock settings") }
        if spec.process != nil { out.append("OpenShell process rules") }
        if profile.effectiveKernelSentry != .off { out.append("the kernel sentry (\(profile.effectiveKernelSentry.rawValue))") }
        return out
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
