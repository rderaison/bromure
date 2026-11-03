import Foundation

/// The daemon's side of a registration sign-in (LinuxRegistration.swift):
/// the throwaway VM, booted for a Profile that is never saved, hidden from
/// the workspace lists, and gone at the end (and at a restart: a daemon
/// never takes a sign-in VM back).
extension Daemon {
    /// Boots the sign-in VM for `scratch`; its Firecracker vsock socket
    /// (the token agents' `<v.sock>_8446/_8447` listen beside it).
    // @port-skip linux-only: UbuntuSandboxVM(sessionDisk:).prepare/start for the registration VM, as a daemon VM record
    func startRegistrationVM(_ scratch: Profile) async throws -> String {
        let id = scratch.id.uuidString.lowercased()
        registrationProfiles[id] = scratch
        let name = "register-\(scratch.tool.rawValue)-\(id.prefix(8))"
        let r = await createVM(.object(["name": .string(name)]), id: id, registration: true)
        guard r.status == 201, let l = live[id] else {
            registrationProfiles[id] = nil
            throw GuestCommandError.unavailable(r.body["error"]?.stringValue ?? "the sign-in machine didn't start")
        }
        return l.config.firecrackerVsockPath
    }

    /// Ends the sign-in VM and deletes everything it had.
    // @port-skip linux-only: teardownClaudeRegistration's vm.stop + removeItem(scratchDir), as a daemon VM record
    func destroyRegistrationVM(_ pid: UUID) async {
        let id = pid.uuidString.lowercased()
        if let rec = registry.find(id) {
            if live[id] != nil { _ = await deleteVM(rec, action: "kill") }
            if let r = registry.find(id) { _ = remove(r) }
        }
        registrationProfiles[id] = nil
    }

    /// Whether a client's callback relay into `pid`'s guest may still be
    /// open (macOS: loopbackForwarders' activeRelays): one counted open, or
    /// one opened in the last 10 s (an SSH forward's end isn't seen here;
    /// the caller's 5 s bound caps the wait).
    // @port-skip linux-only: LoopbackCallbackForwarder.activeRelays over the Linux forwards
    func hasActiveLoopbackRelays(_ pid: UUID) -> Bool {
        guard let rec = registry.find(pid.uuidString.lowercased()), rec.state == .running,
              let ip = sw.dhcp.leasedIP(for: rec.mac) else { return false }
        if (activeRelays[ip] ?? 0) > 0 { return true }
        return relayOpened[ip].map { Date().timeIntervalSince($0) < 10 } ?? false
    }

    /// Sign-in VMs a previous daemon left: ended and deleted, never taken
    /// back (their run, its broker and its token channels died with it).
    // @port-skip linux-only: the Linux daemon's restart (macOS's registration VM dies with the app)
    func dropLeftoverRegistrations() {
        for rec in registry.records where rec.registration == true {
            if Self.killIfOurs(rec) {
                FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': a sign-in machine from before the restart, ended\n".utf8))
            }
            var r = rec
            r.state = .stopped
            r.pid = nil
            try? registry.upsert(r)
            _ = remove(r)
        }
    }
}
