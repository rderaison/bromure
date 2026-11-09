import Foundation

extension Daemon {
    /// A clone-first automation run's copy of the workspace `baseID`
    /// (macOS: ACAppDelegate.cloneWorkspaceForAutomation): the profile
    /// duplicated (ProfileStore.duplicate: settings, credentials, host-only
    /// keys), and its VM's system disk, home and data images as reflinks
    /// into a VM registered stopped under the copy's id. Copy-on-write only,
    /// as the checkpoints: a filesystem without reflinks makes no clone (a
    /// plain copy of the images would cost what macOS's clonefile never
    /// does), and the run fails with the engine's "couldn't clone".
    /// `cloner`: tests.
    // @port-skip linux-only: the daemon's half of ACAppDelegate.cloneWorkspaceForAutomation (the VM's images, its record)
    func cloneWorkspace(_ baseID: UUID, runSlug: String,
                        cloner: VMCheckpoints.Cloner = VMCheckpoints.reflink) async -> Profile? {
        let key = baseID.uuidString.lowercased()
        guard let (base, rec) = workspace(key), rec.kube == nil, rec.registration != true else { return nil }
        let store = profileStore
        var clone: Profile
        do {
            clone = try store.duplicate(base, named: "\(base.name) ⌁ \(runSlug)")
        } catch {
            BACDebug.log("automation", "workspace clone failed: \(error)")
            return nil
        }
        // A leftover clone (the run never finished, the daemon restarted
        // mid-run) must not boot itself at the next start.
        if clone.bootAtStartup {
            clone.bootAtStartup = false
            try? store.save(clone)
        }
        let cloneKey = clone.id.uuidString.lowercased()
        let src = vmDir(key), dst = vmDir(cloneKey)
        func undo(_ why: String) -> Profile? {
            BACDebug.log("automation", "workspace clone of '\(base.name)' failed: \(why)")
            try? store.delete(clone)
            // A UUID we just made: vmDir names nothing but the clone's directory.
            try? FileManager.default.removeItem(atPath: dst)
            return nil
        }
        // A base under repair is changing: not a copy to start from.
        if repairMarks.contains(key) { return undo("it is being repaired") }
        do {
            try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        } catch {
            return undo("\(error)")
        }
        // The images, not the meta share or saved state (a cold boot, as
        // macOS's duplicate skips vm.state).
        for name in ["disk.raw", "home.img", "data.img"] where FileManager.default.fileExists(atPath: src + "/" + name) {
            if let why = cloner(src + "/" + name, dst + "/" + name) { return undo(why) }
        }
        var body: [String: JSONValue] = ["name": .string(clone.name), "cpus": .number(Double(rec.cpus)),
                                         "memoryGB": .number(Double(rec.memoryMiB) / 1024)]
        if let gb = rec.homeGB { body["homeGB"] = .number(Double(gb)) }
        let vm = await createVM(.object(body), id: cloneKey, boot: false, dataDiskGB: rec.dataDiskGB)
        guard vm.status == 201 else { return undo("its VM wasn't registered (\(vm.status))") }
        // Subscription credentials live in the stores by profile id: the
        // clone uses the base's through an alias, never a copy (a refresh
        // token rotates; two copies refreshed apart log each other out).
        if let mitm {
            if mitm.claudeStore.hasProfileRecord(baseID) { try? mitm.claudeStore.alias(clone.id, to: baseID) }
            if mitm.codexStore.hasProfileRecord(baseID) { try? mitm.codexStore.alias(clone.id, to: baseID) }
            if mitm.grokStore.hasProfileRecord(baseID) { try? mitm.grokStore.alias(clone.id, to: baseID) }
            if mitm.kimiStore.hasProfileRecord(baseID) { try? mitm.kimiStore.alias(clone.id, to: baseID) }
        }
        return clone
    }

    /// A finished run's clone goes (macOS: ACAppDelegate.destroyAutomationClone):
    /// its VM stopped (a start under way waited for, bounded), its record,
    /// images and profile deleted, its subscription aliases and stand-in
    /// registrations dropped. One still busy past the wait is left for a
    /// manual remove.
    // @port-skip linux-only: the daemon's half of ACAppDelegate.destroyAutomationClone
    func destroyClone(_ id: UUID, pollInterval: Duration = .seconds(5)) async {
        let key = id.uuidString.lowercased()
        guard let (profile, _) = workspace(key) else { return }
        BACDebug.log("automation", "destroying clone workspace “\(profile.name)”")
        for _ in 0..<24 {
            guard let rec = registry.find(key) else { break }
            if live[key] != nil { _ = await deleteVM(rec, action: "shutdown") }
            if live[key] == nil, !starting.contains(key), !repairMarks.contains(key) { break }
            try? await Task.sleep(for: pollInterval)
        }
        if let rec = registry.find(key) {
            let r = remove(rec)
            guard r.status == 200 else {
                BACDebug.log("automation", "clone “\(profile.name)” still in use — leaving it for manual cleanup")
                return
            }
        }
        do {
            try profileStore.delete(profile)
        } catch {
            BACDebug.log("automation", "clone delete failed: \(error)")
        }
        if let mitm {
            try? mitm.claudeStore.forget(for: id)
            try? mitm.codexStore.forget(for: id)
            try? mitm.grokStore.forget(for: id)
            try? mitm.kimiStore.forget(for: id)
            mitm.claudeStore.unregisterBogusKeys(for: id)
            mitm.codexStore.unregisterBogusKeys(for: id)
            mitm.grokStore.unregisterBogusKeys(for: id)
            mitm.kimiStore.unregisterBogusKeys(for: id)
        }
    }
}
