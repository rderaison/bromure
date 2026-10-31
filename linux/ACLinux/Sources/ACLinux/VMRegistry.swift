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
    /// The running QEMU, so a restarted daemon can re-adopt it: its pid, its
    /// start time (/proc/<pid>/stat, against pid reuse), and the address the
    /// switch leased the VM.
    public var pid: Int32?
    public var pidStart: UInt64?
    public var lease: String?
    /// The VM's own home size in GiB (nil: the daemon's default); a raise
    /// grows home.img at the next cold boot.
    public var homeGB: Int?

    // @port-skip linux-only: VM record
    public var shortId: String { String(id.prefix(8)) }

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
    /// stopped unless `isAlive` says their QEMU is still there (the daemon
    /// re-adopts those). Suspended ones stay suspended (their state file is
    /// still valid).
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
        for i in records.indices where records[i].state == .suspended {
            if records[i].statePath.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
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
        records.first { $0.id == key || $0.shortId == key || $0.name == key }
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
