import Foundation
import SandboxEngine

extension Daemon {
    /// The guest's root attestor channel (vsock 5840: binary identity and
    /// the guest sandbox's status) for a workspace whose guest runs one,
    /// strict sandbox or an active OpenShell spec, served by the shared
    /// AttestorBridge (macOS: attachIdentityBridge, through a VZ listener).
    /// The pinned secret is host-side, in the workspace's directory: a
    /// fresh boot starts without it (the attestor's first hello pins a new
    /// one), a VM taken back keeps it (its attestor reconnects with it).
    // partial: no kernel sentry listener (5841) yet: a sentry workspace isn't started on Linux (DaemonSandboxGuard)
    // @port ACAppDelegate.attachIdentityBridge(profile: Profile, socketDevice: VZVirtioSocketDevice, restoring: Bool) h=1f4dd907b7e6b4e0 @e074ca01
    func serveAttestor(_ rec: VMRecord, profile: Profile?, udsPath: String, stored: Int32?, restoring: Bool) async -> VsockFDListener? {
        guard let profile, !rec.managed, rec.registration != true else {
            if let stored { close(stored) }
            return nil
        }
        let spec = OpenShellSandboxSpec(policyYAML: profile.networkPolicy, workdirs: [],
                                        strictSandbox: profile.effectiveStrictSandbox,
                                        sentry: profile.effectiveKernelSentry.rawValue)
        if !restoring { await MainActor.run { GuestSandboxStatusStore.shared.reset(profileID: profile.id) } }
        guard profile.effectiveStrictSandbox || spec.isActive else {
            if let stored { close(stored) }
            return nil
        }
        let secret = profileStore.profileDirectory(for: profile).appendingPathComponent("attestor.secret")
        if !restoring { try? FileManager.default.removeItem(at: secret) }
        // A VM taken back must present the secret pinned on disk; only a
        // fresh boot (whose attestor says hello before any agent code) pins.
        let bridge = AttestorBridge(profileID: profile.id, secretFile: secret, mayPin: !restoring,
                                    strict: profile.effectiveStrictSandbox)
        do {
            // The channel is blocking (a read loop for the VM's life): a
            // thread of its own per connection, as on macOS; a few wait for
            // their hello at once, the oldest cut off past that.
            let l = try VsockFDListener(udsPath: udsPath, port: BinaryIdentityService.vsockPort,
                                        fdStoreName: "attest-" + rec.shortId, stored: stored) { [weak bridge] fd in
                guard let bridge else { close(fd); return }
                guard bridge.admitHandshake(fd) else { close(fd); return }
                Thread.detachNewThread { bridge.handshakeAndServe(fd, connection: nil) }
            }
            bridge.listener = l
            BinaryIdentityService.shared.adoptBridge(bridge, for: profile.id)
            return l
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': no attestor listener: \(error)\n".utf8))
            return nil
        }
    }
}
