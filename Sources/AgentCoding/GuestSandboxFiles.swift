import Foundation
import SandboxEngine

// The guest sandbox's files in the meta share: the strict marker and the
// root attestor, the package shims, the OpenShell sandbox spec with its root
// launcher, supervisor and sentry loader, and the advisor's address; and the
// shared folders' names in the guest the spec's workdirs use. macOS
// (SessionDisk.prepareMetadataShare) and the Linux daemon stage the same
// files; each brings its own kernel modules (`stageSentryModules`).

extension SessionDisk {
    /// Resolved set of (host folder URL, guest mount basename) pairs for
    /// every folder this profile shares into the VM. Capped at 8 to match
    /// the base image's pre-allocated fstab slots.
    public struct SharedFolder: Sendable {
        public let url: URL
        public let mountName: String  // basename used for ~ubuntu/<name>
    }

    public static func sharedFolders(_ folderPaths: [String]) -> [SharedFolder] {
        var seen: Set<String> = []
        var result: [SharedFolder] = []
        for path in folderPaths.prefix(8) {
            let url = URL(fileURLWithPath: path)
            var name = url.lastPathComponent
            if name.isEmpty { name = "share" }
            // De-dup basenames so two folders named "src" don't both
            // try to symlink to ~ubuntu/src.
            var unique = name
            var n = 2
            while seen.contains(unique) {
                unique = "\(name)-\(n)"
                n += 1
            }
            seen.insert(unique)
            result.append(SharedFolder(url: url, mountName: unique))
        }
        return result
    }

    /// The sandbox's files for `profile` into the meta share `tmp`, from
    /// the guest scripts in `setupDir`; `workdirs` are the shared folders'
    /// paths in the guest. `stageSentryModules` fills the spec's `sentry/`
    /// directory with the kernel modules it has (called only with an
    /// active spec).
    static func writeSandboxFiles(into tmp: URL, profile: Profile, setupDir: URL, workdirs: [String],
                                  stageSentryModules: (_ sentryDest: URL) -> Void) throws {
        let fm = FileManager.default
        // Strict sandbox: the root attestor and the (runtime-only)
        // privilege revocation ship beside agentd, and the marker
        // tells agentd to start the one and apply the other.
        for name in ["bromure-attestd.py", "bromure-strict.py"] {
            let src = setupDir.appendingPathComponent(name)
            let dest = tmp.appendingPathComponent(name)
            if let data = try? Data(contentsOf: src), (try? Data(contentsOf: dest)) != data {
                try data.write(to: dest, options: .atomic)
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dest.path)
            }
        }
        let marker = tmp.appendingPathComponent("strict-sandbox")
        if profile.effectiveStrictSandbox {
            try "1\n".writeIfChanged(to: marker)
        } else {
            try? fm.removeItem(at: marker)
        }
        // Package installs under the OpenShell engine (no root):
        // `home-packages` makes pip default to the home folder;
        // `pkg-bin/` puts the apt / apt-get / sudo shims ahead of the
        // real commands, turning `apt-get install` into a request the
        // user approves and the root supervisor carries out.
        let homePackages = tmp.appendingPathComponent("home-packages")
        if profile.effectiveSandboxHomePackages {
            try "1\n".writeIfChanged(to: homePackages)
        } else {
            try? fm.removeItem(at: homePackages)
        }
        let pkgBin = tmp.appendingPathComponent("pkg-bin")
        let shimSrc = setupDir.appendingPathComponent("bromure-pkg-shim")
        if profile.effectiveSandboxSystemPackages, let shim = try? Data(contentsOf: shimSrc) {
            try fm.createDirectory(at: pkgBin, withIntermediateDirectories: true)
            for name in ["apt", "apt-get", "sudo"] {
                let dst = pkgBin.appendingPathComponent(name)
                if (try? Data(contentsOf: dst)) != shim {
                    try shim.write(to: dst, options: .atomic)
                    try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dst.path)
                }
            }
        } else {
            try? fm.removeItem(at: pkgBin)
        }
        // OpenShell filesystem_policy / landlock / process + the
        // kernel sentry: the guest's root launcher applies them before
        // any agent code runs. Absent → behave exactly as before.
        let spec = OpenShellSandboxSpec(
            policyYAML: profile.networkPolicy,
            workdirs: workdirs,
            strictSandbox: profile.effectiveStrictSandbox,
            sentry: profile.effectiveKernelSentry.rawValue)
        let specDest = tmp.appendingPathComponent(OpenShellSandboxSpec.fileName)
        // `policy.local` (the OpenShell policy advisor) serves every
        // workspace whose firewall is an OpenShell policy, with or
        // without sandbox sections: the guest maps the name whenever
        // this file is present.
        let advisorDest = tmp.appendingPathComponent("advisor.json")
        if profile.usesOpenShellPolicy {
            try #"{"host":"policy.local","address":"\#(EgressPolicy.advisorAddressString)"}"#
                .appending("\n").writeIfChanged(to: advisorDest)
        } else {
            try? fm.removeItem(at: advisorDest)
        }
        // The guest side: the root launcher + supervisor, the kernel
        // sentry loader, their Python modules, and the prebuilt sentry
        // module (+ its source for an on-guest rebuild when the guest
        // kernel differs). Staged only with an active spec.
        let guestFiles = ["bromure-sandboxd", "bromure-sentryd", "bromure_openshell.py",
                          "bromure_idmap.py", "bromure_sandbox_status.py"]
        let sentryDest = tmp.appendingPathComponent("sentry")
        if spec.isActive {
            for name in guestFiles {
                let src = setupDir.appendingPathComponent(name)
                let dst = tmp.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: src) else { continue }
                if (try? Data(contentsOf: dst)) != data {
                    try data.write(to: dst, options: .atomic)
                    try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dst.path)
                }
            }
            // Modules come from the CDN (SentryModuleStore), not the
            // bundle: the verified cached module of every kernel this
            // workspace is known to have. A kernel the host hasn't seen
            // yet is fetched while the guest waits for it. The source
            // ships for the guest's last-resort local build.
            let sentrySrc = setupDir.appendingPathComponent("sentry-dist/src")
            try? fm.removeItem(at: sentryDest)
            try fm.createDirectory(at: sentryDest, withIntermediateDirectories: true)
            if fm.fileExists(atPath: sentrySrc.path) {
                try fm.copyItem(at: sentrySrc, to: sentryDest.appendingPathComponent("src"))
            }
            stageSentryModules(sentryDest)
            let data = spec.jsonData()
            if (try? Data(contentsOf: specDest)) != data { try data.write(to: specDest, options: .atomic) }
        } else {
            try? fm.removeItem(at: specDest)
            for name in guestFiles { try? fm.removeItem(at: tmp.appendingPathComponent(name)) }
            try? fm.removeItem(at: sentryDest)
        }
    }
}
