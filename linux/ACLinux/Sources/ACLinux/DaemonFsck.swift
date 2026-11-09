import Foundation

extension Daemon {
    /// `POST /vms/<id>/fsck {"repair", "home"}`: the native ext4 checker
    /// (Ext4Fsck, as macOS's `workspaces fsck` runs it) on this daemon's own
    /// image -- the system disk, or the home with `home` -- under the VM's
    /// repair mark, so no start can take it meanwhile. Refused while the VM
    /// runs, starts, stops, has a rescue VM or another repair; a repair also
    /// while it is suspended (its saved memory holds the old disk).
    // @port-skip linux-only: the daemon side of `workspaces fsck` (macOS's CLI opens the images itself)
    func fsckRoute(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        let repair = body["repair"] == .bool(true), home = body["home"] == .bool(true)
        let id = rec.id
        guard live[id] == nil, stopping[id] == nil, !starting.contains(id), !rebooting.contains(id), !hasRescue(for: id),
              rec.state != .running, rec.state != .starting else {
            return ControlResponse(409, ["error": .string("'\(rec.name)' is running — stop it first (`workspaces kill \(rec.name)`).")])
        }
        if repair, rec.state == .suspended {
            return ControlResponse(409, ["error": .string("'\(rec.name)' is suspended: its saved memory holds this disk. Stop it (`workspaces kill \(rec.name)`) before repairing.")])
        }
        guard repairMarks.insert(id) else {
            return ControlResponse(409, ["error": .string("'\(rec.name)' is already being repaired.")])
        }
        let path = vmDir(id) + (home ? "/home.img" : "/disk.raw")
        return await repairMarks.whileMarked(id) {
            guard FileManager.default.fileExists(atPath: path) else {
                return ControlResponse(404, ["error": .string("No \(home ? "home" : "system disk") image for '\(rec.name)'.")])
            }
            // A thread of its own: a long check would hold a cooperative-pool one.
            let result: Result<Ext4Fsck.Result, Error> = await SecureDir.offPool {
                do { return .success(try Ext4Fsck.check(imagePath: path, autoFix: repair)) }
                catch { return .failure(error) }
            }
            switch result {
            case .success(let r):
                return ControlResponse(200, ["status": .number(Double(r.status)), "output": .string(r.output),
                                             "summary": .string(r.summary)])
            case .failure(let error):
                return ControlResponse(500, ["error": .string("fsck couldn't run: \(error)")])
            }
        }
    }
}
