import Foundation
import NIOConcurrencyHelpers

/// A VM's rollback points on a Linux server (macOS: ProfileStore's disk and
/// home checkpoints, APFS clones). Copy-on-write only, as macOS's cost model
/// is: a reflink (FICLONE) of disk.raw / home.img into the VM's
/// `checkpoints/` (`checkpoints/home/`), `<unix-ts>.img`. A filesystem
/// without reflinks (ext4) takes none: copying whole images every boot
/// would cost the disk space and I/O macOS never pays.
enum VMCheckpoints {
    // @port-skip linux-only: ProfileStore.DiskCheckpoint over the daemon's VM layout
    struct Checkpoint: Equatable {
        let id: String
        let createdAt: Date
        let path: String
        let allocatedBytes: Int64
    }

    enum Target: String { case disk, home }

    /// Clone `src` to a new `dst` (created 0600): nil, or why it couldn't.
    typealias Cloner = @Sendable (_ src: String, _ dst: String) -> String?

    /// FICLONE (_IOW(0x94, 9, int)): a reflink, or the reason there is none.
    // @port-skip linux-only: ProfileStore.cloneItem's clonefile, without its plain-copy fallback
    static let reflink: Cloner = { src, dst in
        let s = open(src, O_RDONLY | O_CLOEXEC)
        guard s >= 0 else { return "can't open \(src): \(String(cString: strerror(errno)))" }
        defer { close(s) }
        let d = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard d >= 0 else { return "can't create \(dst): \(String(cString: strerror(errno)))" }
        if ioctl(d, UInt(0x4004_9409), s) == 0 { close(d); return nil }
        let err = errno
        close(d)
        unlink(dst)
        switch err {
        case EOPNOTSUPP, EINVAL, EXDEV, ENOTTY, EPERM:
            return unsupportedReason
        default:
            return "reflink failed: \(String(cString: strerror(err)))"
        }
    }

    static let unsupportedReason =
        "this server's filesystem can't make copy-on-write clones (no reflink, as on ext4), so no checkpoints are taken"

    // @port-skip linux-only: ProfileStore.checkpointsDirectory / homeCheckpointsDirectory, per VM
    static func directory(_ vmDir: String, _ target: Target) -> String {
        target == .home ? vmDir + "/checkpoints/home" : vmDir + "/checkpoints"
    }

    // @port-skip linux-only: the VM's disk.raw / home.img
    static func image(_ vmDir: String, _ target: Target) -> String {
        target == .home ? vmDir + "/home.img" : vmDir + "/disk.raw"
    }

    /// Newest first (macOS: ProfileStore.list(in:)).
    // @port-skip linux-only: ProfileStore.list(in:) over a VM's checkpoint folder
    static func list(_ dir: String) -> [Checkpoint] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.compactMap { name -> Checkpoint? in
            guard name.hasSuffix(".img"), let ts = Int(name.dropLast(4)) else { return nil }
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
            return Checkpoint(id: String(ts), createdAt: Date(timeIntervalSince1970: TimeInterval(ts)),
                              path: path, allocatedBytes: Int64(st.st_blocks) * 512)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// A rollback point of `image` into `dir` (macOS: snapshotImage):
    /// `automatic` takes none if one was taken that calendar day. nil when
    /// none was taken; `error` says why when it couldn't be.
    // @port-skip linux-only: ProfileStore.snapshotImage with the daemon's cloner
    static func snapshot(_ image: String, into dir: String, at date: Date, automatic: Bool,
                         clone: Cloner) -> (checkpoint: Checkpoint?, error: String?) {
        guard FileManager.default.fileExists(atPath: image) else { return (nil, nil) }
        if automatic, let newest = list(dir).first, Calendar.current.isDate(newest.createdAt, inSameDayAs: date) {
            return (nil, nil)                                   // one a day
        }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { return (nil, "can't create \(dir): \(error)") }
        let ts = Int(date.timeIntervalSince1970)
        let dst = dir + "/\(ts).img"
        guard !FileManager.default.fileExists(atPath: dst) else { return (nil, nil) }   // one per second
        if let why = clone(image, dst) { return (nil, why) }
        return (list(dir).first { $0.id == String(ts) }, nil)
    }

    /// Delete what's beyond macOS's ladder (ProfileStore.checkpointRetention).
    // @port-skip linux-only: ProfileStore.pruneCheckpoints, synchronous (reflinks free at once)
    static func prune(_ dir: String, now: Date) {
        let all = list(dir)
        let keep = ProfileStore.checkpointRetention(all.map(\.createdAt), now: now)
        for c in all where !keep.contains(c.createdAt) { unlink(c.path) }
    }

    /// Put checkpoint `id` back over `image` (macOS: revertImage): a clone of
    /// it beside the image, renamed over it. nil, or the error.
    // @port-skip linux-only: ProfileStore.revertImage with the daemon's cloner
    static func revert(_ id: String, in dir: String, over image: String, clone: Cloner) -> String? {
        guard id.allSatisfy(\.isNumber), !id.isEmpty, list(dir).contains(where: { $0.id == id }) else {
            return "Checkpoint \(id) not found"
        }
        let tmp = image + ".revert-\(UUID().uuidString)"
        if let why = clone(dir + "/\(id).img", tmp) { return why }
        guard rename(tmp, image) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp)
            return "couldn't put it in place: \(why)"
        }
        return nil
    }
}

extension Daemon {
    /// The cloner checkpoints use (tests: one that copies).
    // @port-skip linux-only: the daemon's checkpoint cloner (tests replace it)
    struct CheckpointCloner: Sendable { var clone: VMCheckpoints.Cloner }
    static let checkpointCloner = NIOLockedValueBox(CheckpointCloner(clone: VMCheckpoints.reflink))
    // @port-skip linux-only: the daemon's checkpoint cloner
    static var cloner: VMCheckpoints.Cloner { checkpointCloner.withLockedValue { $0 }.clone }

    /// Can this server's VM directory make reflinks? A probe clone of a
    /// scratch file, once per daemon: nil, or why not.
    // @port-skip linux-only: probes FICLONE where the VMs' disks live
    func checkpointSupport() -> String? {
        if let known = checkpointProbe { return known.isEmpty ? nil : known }
        let base = config.stateDir + "/.reflink-probe-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: base, contents: Data("probe".utf8))
        let why = Self.cloner(base, base + ".clone")
        unlink(base); unlink(base + ".clone")
        checkpointProbe = why ?? ""
        return why
    }

    /// A running VM's session-start rollback points (macOS: the first
    /// non-empty tab roster, proof the disk boots): disk and home, one a
    /// day, a home over 64 GB none; then the ladder. Once per boot, on the
    /// 5 s tick; nothing at all where reflinks don't work.
    // @port-skip linux-only: ACAppDelegate's first-roster checkpoint (onTabsChanged), on the daemon's tick
    func observeCheckpoints(now: Date = Date()) {
        let running = Set(registry.records.filter { $0.state == .running && live[$0.id] != nil }.map(\.id))
        checkpointedBoots.formIntersection(running)              // a stopped VM's next boot takes its own
        for id in running.subtracting(checkpointedBoots) {
            let roster = GuestOutbox.parseRoster(GuestOutbox.read(vmDir(id) + "/outbox/tabs.txt") ?? "")
            guard !roster.isEmpty else { continue }
            checkpointedBoots.insert(id)
            guard checkpointSupport() == nil else { continue }
            let dir = vmDir(id), clone = Self.cloner
            let name = registry.records.first { $0.id == id }?.name ?? id
            Task.detached {
                for target in [VMCheckpoints.Target.disk, .home] {
                    let image = VMCheckpoints.image(dir, target)
                    if target == .home, let size = (try? FileManager.default.attributesOfItem(atPath: image))?[.size] as? Int64,
                       size > ProfileStore.automaticHomeCheckpointCap { continue }
                    let r = VMCheckpoints.snapshot(image, into: VMCheckpoints.directory(dir, target), at: now,
                                                   automatic: true, clone: clone)
                    if let e = r.error {
                        FileHandle.standardError.write(Data("bromure-ac daemon: '\(name)': no \(target.rawValue) checkpoint: \(e)\n".utf8))
                    }
                    VMCheckpoints.prune(VMCheckpoints.directory(dir, target), now: now)
                }
            }
        }
    }

    /// `GET /vms/<id>/checkpoints`: newest first, disk then home, as macOS
    /// lists them; when there are none because the filesystem can't clone,
    /// a `note` says so.
    // @port ACAppDelegate.automationListCheckpoints(_: String) h=d8c277f042296251 @8546d1e2
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListCheckpoints h=7cc422c69e54d04c @d3ebbda2
    // partial: GET /vms/<id>/checkpoints lists disk and home checkpoints (target field), not home only
    // @port ACAppDelegate.homeCheckpoints(for: Profile.ID) h=a3f815668fe527ef @d3ebbda2
    func checkpointsRoute(_ rec: VMRecord) -> ControlResponse {
        func entry(_ c: VMCheckpoints.Checkpoint, _ target: VMCheckpoints.Target) -> JSONValue {
            ["id": .string(c.id), "createdAt": .number(Double(Int(c.createdAt.timeIntervalSince1970))),
             "allocatedBytes": .number(Double(c.allocatedBytes)), "target": .string(target.rawValue)]
        }
        let dir = vmDir(rec.id)
        let list = VMCheckpoints.list(VMCheckpoints.directory(dir, .disk)).map { entry($0, .disk) }
            + VMCheckpoints.list(VMCheckpoints.directory(dir, .home)).map { entry($0, .home) }
        var body: [String: JSONValue] = ["checkpoints": .array(list)]
        if list.isEmpty, let why = checkpointSupport() { body["note"] = .string("No checkpoints: \(why).") }
        return ControlResponse(200, .object(body))
    }

    /// `POST /vms/<id>/revert {checkpoint, target: disk|home}`: the image
    /// put back as it was at that checkpoint. The VM must be off (its
    /// disks are replaced whole); a home revert first checkpoints the
    /// current home, as macOS's does. 400 with the reason otherwise.
    // @port ACAppDelegate.automationRevertCheckpoint(idOrName: String, checkpoint: String, target: String) h=50590851e9ffd1bc @8546d1e2
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onRevertCheckpoint h=441d58ccf169857c @d3ebbda2
    // partial: target=home. Same refusals, checkpoints the current home first (the fat client's rewindHome posts exactly this)
    // @port ACAppDelegate.rewindHome(_: Profile.ID, to: String) h=1619df340c9c648c @d3ebbda2
    // partial: the restore itself. The NSAlert checkpoint picker is screen-only
    // @port ACAppDelegate.restoreHomeStorage(_: Profile) h=40238836dae1efe9 @d3ebbda2
    func revertRoute(_ rec: VMRecord, _ body: JSONValue) -> ControlResponse {
        func refused(_ e: String) -> ControlResponse { ControlResponse(400, ["error": .string(e)]) }
        let cp = body["checkpoint"]?.stringValue ?? ""
        guard let target = VMCheckpoints.Target(rawValue: body["target"]?.stringValue ?? "disk") else {
            return refused("target is disk or home")
        }
        // The image is replaced wholesale, so the VM must not have it open,
        // nor a suspended one hold a memory image of the old disk.
        guard live[rec.id] == nil, rec.state != .running, rec.state != .starting, !starting.contains(rec.id) else {
            return refused("Stop the workspace first (`vm kill \(rec.name)`), then revert.")
        }
        // Nor while a repair (fsck, a cluster machine's) or a rescue VM has
        // the images: the revert would replace one under the checker.
        guard !repairMarks.contains(rec.id), !hasRescue(for: rec.id) else {
            return refused("'\(rec.name)' is being repaired: try again when the repair is done.")
        }
        guard rec.state != .suspended else {
            return refused("It's suspended, its memory paired with these disks: shut it down first (`vm kill \(rec.name)`), then revert.")
        }
        let dir = vmDir(rec.id), clone = Self.cloner
        let cpDir = VMCheckpoints.directory(dir, target)
        if VMCheckpoints.list(cpDir).isEmpty, let why = checkpointSupport() {
            return refused("Nothing to revert to: \(why).")
        }
        let image = VMCheckpoints.image(dir, target)
        if target == .home {
            // Safety net first, as the GUI's restore does.
            if let e = VMCheckpoints.snapshot(image, into: cpDir, at: Date(), automatic: false, clone: clone).error {
                return refused("Couldn't checkpoint the current home first: \(e)")
            }
        }
        if let e = VMCheckpoints.revert(cp, in: cpDir, over: image, clone: clone) { return refused(e) }
        return ControlResponse(200, ["status": "reverted", "checkpoint": .string(cp), "target": .string(target.rawValue),
                                     "workspace": .string(rec.name)])
    }
}

extension Daemon {
    /// Tests: probe the (replaced) cloner again.
    // @port-skip linux-only: tests
    func resetCheckpointProbeForTesting() { checkpointProbe = nil }
}
