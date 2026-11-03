import Foundation

/// A VM's own system disk, before its first boot. The sparse copy of the
/// base image carries the bake's /etc/machine-id; each VM gets its own here
/// (macOS: every VZ VM boots from a fresh APFS clone, then the guest's
/// first boot makes one), so journald, DHCP client ids and anything keyed
/// on it don't collide between VMs, or between users' VMs.
// @port-skip linux-only: the Linux system disk is a raw GPT image written with debugfs
public enum GuestDisk {
    static let linuxFilesystemType: [UInt8] = [0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47,
                                               0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4]

    /// 32 lowercase hex digits, as systemd writes it.
    // @port-skip linux-only: machine-id
    public static func newMachineID() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    /// The byte offset of the root filesystem in a GPT image: the partition
    /// named "root", else the first Linux filesystem partition.
    // @port-skip linux-only: GPT
    public static func rootPartitionOffset(_ image: String) throws -> UInt64 {
        guard let h = FileHandle(forReadingAtPath: image) else { throw MachineError.io("open \(image)", errno) }
        defer { try? h.close() }
        try h.seek(toOffset: 512)
        let header = h.readData(ofLength: 92)
        guard header.count == 92, header.prefix(8) == Data("EFI PART".utf8) else {
            throw MachineError.invalidConfig("\(image): no GPT header")
        }
        func u64(_ d: Data, _ o: Int) -> UInt64 { d[d.startIndex + o ..< d.startIndex + o + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        func u32(_ d: Data, _ o: Int) -> UInt32 { d[d.startIndex + o ..< d.startIndex + o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        let entriesLBA = u64(header, 72), count = Int(min(u32(header, 80), 256)), size = Int(u32(header, 84))
        guard size >= 128 else { throw MachineError.invalidConfig("\(image): bad GPT entry size \(size)") }
        try h.seek(toOffset: entriesLBA * 512)
        let entries = h.readData(ofLength: count * size)
        var firstLinux: UInt64?
        for i in 0..<(entries.count / size) {
            let e = entries.subdata(in: i * size ..< (i + 1) * size)
            guard Array(e.prefix(16)) == linuxFilesystemType else { continue }
            let start = u64(e, 32) * 512
            let name = String(decoding: stride(from: 56, to: 128, by: 2).map { UInt16(e[$0]) | UInt16(e[$0 + 1]) << 8 }
                                  .prefix { $0 != 0 }, as: UTF16.self)
            if name == "root" { return start }
            if firstLinux == nil { firstLinux = start }
        }
        guard let firstLinux else { throw MachineError.invalidConfig("\(image): no Linux partition") }
        return firstLinux
    }

    /// Writes `id` as /etc/machine-id (and /var/lib/dbus/machine-id, a copy
    /// in the base image) into the image's root filesystem, then reads it
    /// back. The image must not be in use.
    // @port-skip linux-only: machine-id
    static func setMachineID(image: String, id: String) async throws {
        let debugfs = ["/usr/sbin/debugfs", "/sbin/debugfs"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let debugfs else { throw MachineError.invalidConfig("debugfs not found (install e2fsprogs)") }
        let fs = image + "?offset=\(try rootPartitionOffset(image))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acl-mid-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try (id + "\n").write(toFile: dir + "/id", atomically: false, encoding: .utf8)
        var cmds = ""
        for (path, mode) in [("/etc/machine-id", "0100444"), ("/var/lib/dbus/machine-id", "0100644")] {
            cmds += "rm \(path)\nwrite \(dir)/id \(path)\nsif \(path) mode \(mode)\nsif \(path) uid 0\nsif \(path) gid 0\n"
        }
        try cmds.write(toFile: dir + "/cmds", atomically: false, encoding: .utf8)
        try await ChildProcess.run(debugfs, ["-w", "-f", dir + "/cmds", fs])
        let back = try ChildProcess.capture(debugfs, ["-R", "cat /etc/machine-id", fs], input: nil)
        guard String(decoding: back, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == id else {
            throw MachineError.toolFailed("debugfs", 0, "machine-id didn't read back as \(id)")
        }
    }
}
