import Foundation

/// One VM the daemon knows about, persisted across daemon restarts.
// @port-skip linux-only: the Linux daemon's VM record (macOS keeps sessions in memory, profiles on disk)
public struct VMRecord: Codable, Sendable, Equatable {
    // @port-skip linux-only: VM states
    public enum State: String, Codable, Sendable {
        case starting, running, suspended, stopped
    }

    public var id: String
    public var name: String
    public var machine: String
    public var cid: UInt32
    public var mac: String
    public var state: State
    public var ip: String?
    public var cpus: Int
    public var memoryMiB: Int
    public var createdAt: Date
    public var bootedAt: Date?
    /// The suspend state file (with its overlay identity sidecar).
    public var statePath: String?
    /// The running Firecracker, so a restarted daemon can re-adopt it: its pid, its
    /// start time (/proc/<pid>/stat, against pid reuse), and the address the
    /// switch leased the VM.
    public var pid: Int32?
    public var pidStart: UInt64?
    public var lease: String?
    /// The VM's own home size in GiB (nil: the daemon's default); a raise
    /// grows home.img at the next cold boot.
    public var homeGB: Int?
    /// A registration sign-in's throwaway VM (LinuxRegistration): no
    /// workspace, never listed, never taken back by a restarted daemon.
    public var registration: Bool?
    /// A machine of a Kubernetes cluster, registry or connector: the owner's
    /// id. Never a workspace, never listed as one; taken back by a
    /// restarted daemon like any VM.
    public var kube: String?
    /// The managed machine's data disk (data.img, vdc) in GiB, if it has one.
    public var dataDiskGB: Int?
    /// Host folders shared into a managed machine at /mnt/bromure-share-<N>
    /// (virtiofs tags share-1...; the base image's fstab slots), read-write.
    /// macOS: KubeClusterEngine.MachineSpec.folders (a disk-repair rescue's).
    public var folders: [String]?
    /// A disk-repair rescue's: the id of the machine whose disks it checks
    /// (that machine's folder is shared in read-write). Never taken back by
    /// a restarted daemon (ended and removed at startup), and while it
    /// exists that machine may not start or be removed.
    public var rescueFor: String?

    /// Not a workspace: a sign-in VM or a cluster's machine.
    // @port-skip linux-only: VM record
    public var managed: Bool { registration == true || kube != nil }

    // @port-skip linux-only: VM record
    public var shortId: String { String(id.prefix(8)) }

    /// The VM as a `/state` workspace row (macOS: a profile), the shape a
    /// fat client's sidebar reads: `state` running, booting, suspended or off.
    // partial: no profile fields (tool, accent, auth, fonts, tokens, disk sizes)
    // @port-skip linux-only: macOS builds rows from profiles (ACAppDelegate.automationWorkspaceList)
    public var workspaceJSON: JSONValue {
        let s: String
        switch state {
        case .running: s = "running"
        case .starting: s = "booting"
        case .suspended: s = "suspended"
        default: s = "off"
        }
        return ["id": .string(id), "name": .string(name), "state": .string(s),
                "memoryGB": .number(Double(memoryMiB) / 1024), "cpuCount": .number(Double(cpus))]
    }

    /// The macOS vmEntry's core keys (`id`, `shortId`, `name`, `state`, `ip`,
    /// `cpuCount`, `memoryGB`, `bootedAt`, `macAddress`) plus Linux ones.
    // @port-skip linux-only: JSON shape for /vms (a subset of macOS's automationVMList entry)
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "shortId": .string(shortId), "name": .string(name),
            "state": .string(state.rawValue), "machine": .string(machine),
            "cid": .number(Double(cid)), "macAddress": .string(mac),
            "cpuCount": .number(Double(cpus)), "memoryGB": .number(Double(memoryMiB) / 1024),
            "ip": ip.map(JSONValue.string) ?? .null,
            "bootedAt": bootedAt.map { .number($0.timeIntervalSince1970.rounded()) } ?? .null,
        ]
        if let homeGB { o["homeGB"] = .number(Double(homeGB)) }
        if state == .running, let b = bootedAt { o["uptimeSeconds"] = .number(Date().timeIntervalSince(b).rounded()) }
        return .object(o)
    }
}

/// The daemon's VM list as JSON at `$XDG_STATE_HOME/bromure-ac/vms.json`,
/// rewritten atomically on every change.
// @port-skip linux-only: Linux daemon state persistence
public struct VMRegistry: Sendable {
    public let path: String
    public private(set) var records: [VMRecord] = []

    /// Loads the registry. VMs recorded as running or starting are marked
    /// stopped unless `isAlive` says their Firecracker is still there (the daemon
    /// re-adopts those). Suspended ones stay suspended while their snapshot
    /// is there.
    // @port-skip linux-only: Linux daemon state persistence
    public init(path: String, isAlive: (VMRecord) -> Bool = { _ in false }) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            records = (try? dec.decode([VMRecord].self, from: data)) ?? []
        }
        var changed = false
        for i in records.indices where (records[i].state == .running || records[i].state == .starting) && !isAlive(records[i]) {
            records[i].state = .stopped
            records[i].pid = nil
            records[i].pidStart = nil
            records[i].ip = nil
            changed = true
        }
        // A suspended VM's snapshot is `<state>/vms/<id>/snapshot/vm.snap`
        // (Daemon.snapshotDir); without it, there's nothing to resume.
        let vmsDir = (path as NSString).deletingLastPathComponent + "/vms/"
        for i in records.indices where records[i].state == .suspended {
            let snap = vmsDir + records[i].id + "/snapshot/vm.snap"
            if !FileManager.default.fileExists(atPath: snap) {
                records[i].state = .stopped
                changed = true
            }
        }
        if changed { try? save() }
    }

    // @port-skip linux-only: Linux daemon state persistence
    public func save() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(records).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// By id, short id or name (as macOS matches `/vms/{id}`).
    // @port-skip linux-only: Linux daemon state persistence
    public func find(_ key: String) -> VMRecord? {
        records.first { $0.id.caseInsensitiveCompare(key) == .orderedSame || $0.shortId == key || $0.name == key }
    }

    // @port-skip linux-only: Linux daemon state persistence
    public mutating func upsert(_ r: VMRecord) throws {
        if let i = records.firstIndex(where: { $0.id == r.id }) { records[i] = r } else { records.append(r) }
        try save()
    }

    // @port-skip linux-only: Linux daemon state persistence
    public mutating func remove(id: String) throws {
        records.removeAll { $0.id == id }
        try save()
    }
}
