import Foundation

// MARK: - fsck.ext4 integration
//
// macOS ships no e2fsprogs, so we locate a user- or bundle-provided fsck.ext4
// (a.k.a. e2fsck) and run it to (a) replay the journal / repair an unclean image
// before we read or write it, and (b) reconcile metadata after a grow/create/
// delete once those land. The tool operates on a whole-filesystem device, so:
//   • raw ext4 image  → run e2fsck directly on the file,
//   • partitioned disk → attach with hdiutil to expose the partition's device
//     node, e2fsck that, then detach.
//
// Nothing here needs the app itself to be privileged: hdiutil attaches a plain
// file as a user-owned device, and e2fsck reads/writes that node as the user.

enum Ext4Fsck {

    /// Directories to look in beyond $PATH (Homebrew keeps e2fsprogs keg-only).
    private static let extraDirs = [
        "/opt/homebrew/opt/e2fsprogs/sbin",
        "/opt/homebrew/sbin",
        "/usr/local/opt/e2fsprogs/sbin",
        "/usr/local/sbin",
        "/usr/sbin", "/sbin",
    ]

    /// Path to a usable fsck binary, preferring a copy bundled with the app.
    static func locate() -> String? {
        var dirs = [String]()
        if let res = Bundle.main.resourceURL?.appendingPathComponent("e2fsprogs/sbin").path {
            dirs.append(res)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        dirs.append(contentsOf: extraDirs)
        let fm = FileManager.default
        for dir in dirs {
            for name in ["fsck.ext4", "e2fsck"] {
                let p = dir + "/" + name
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    static var isAvailable: Bool { locate() != nil }

    struct Result {
        let status: Int32          // e2fsck: 0 clean, 1 errors fixed, 2 fixed+reboot, 4 left uncorrected…
        let output: String
        /// e2fsck exit codes 1 and 2 mean it corrected errors.
        var repaired: Bool { status == 1 || status == 2 }
        var clean: Bool { status == 0 }
        var summary: String {
            switch status {
            case 0: return "Filesystem is clean."
            case 1: return "Filesystem errors were corrected."
            case 2: return "Filesystem errors corrected; a reboot would normally be advised."
            case 4: return "Filesystem errors remain UNCORRECTED."
            case 8: return "e2fsck operational error."
            case 16: return "e2fsck usage error."
            default: return "e2fsck exited with status \(status)."
            }
        }
    }

    enum FsckError: Error, CustomStringConvertible {
        case notInstalled
        case attachFailed(String)
        case noExt4Partition
        var description: String {
            switch self {
            case .notInstalled:
                return "fsck.ext4 not found. Install it with `brew install e2fsprogs`."
            case .attachFailed(let m): return "could not attach the disk image: \(m)"
            case .noExt4Partition: return "no ext4 partition found in the image"
            }
        }
    }

    /// Run e2fsck on the ext4 filesystem inside `imagePath`. `partitionOffset` is
    /// the byte offset the reader found the superblock at (0 for a raw image).
    /// `autoFix` runs `-fy` (repair); otherwise `-fn` (report only).
    static func check(imagePath: String, partitionOffset: UInt64, autoFix: Bool) throws -> Result {
        guard let fsck = locate() else { throw FsckError.notInstalled }
        if partitionOffset == 0 {
            return try runFsck(fsck, device: imagePath, autoFix: autoFix)
        }
        // Partitioned disk: expose device nodes, find the ext4 slice, fsck, detach.
        let (whole, slices) = try attach(imagePath)
        defer { detach(whole) }
        guard let slice = ext4Slice(among: slices) else { throw FsckError.noExt4Partition }
        return try runFsck(fsck, device: slice, autoFix: autoFix)
    }

    // MARK: run

    private static func runFsck(_ fsck: String, device: String, autoFix: Bool) throws -> Result {
        // -f force a full check even if the fs looks clean; -y/-n non-interactive.
        let args = ["-f", autoFix ? "-y" : "-n", device]
        let (status, out) = runCapturing(fsck, args)
        return Result(status: status, output: out)
    }

    // MARK: hdiutil attach / detach

    /// Attach a raw image without mounting; return (whole-disk node, [slice nodes]).
    private static func attach(_ imagePath: String) throws -> (String, [String]) {
        let (status, out) = runCapturing("/usr/bin/hdiutil", [
            "attach", "-nomount", "-readwrite",
            "-imagekey", "diskimage-class=CRawDiskImage",
            "-plist", imagePath,
        ])
        guard status == 0 else { throw FsckError.attachFailed(out) }
        // Parse the plist for every /dev/diskN[sK] entity.
        var nodes = [String]()
        if let data = out.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            for e in entities {
                if let dev = e["dev-entry"] as? String { nodes.append(dev) }
            }
        }
        guard let whole = nodes.min(by: { $0.count < $1.count }) else {
            throw FsckError.attachFailed("no device nodes returned")
        }
        let slices = nodes.filter { $0 != whole }
        return (whole, slices.isEmpty ? nodes : slices)
    }

    private static func detach(_ whole: String) {
        _ = runCapturing("/usr/bin/hdiutil", ["detach", "-force", whole])
    }

    /// Pick the slice whose first block carries the ext4 superblock magic.
    private static func ext4Slice(among slices: [String]) -> String? {
        for dev in slices {
            guard let fh = FileHandle(forReadingAtPath: dev) else { continue }
            defer { try? fh.close() }
            do {
                try fh.seek(toOffset: 1024)
                if let d = try fh.read(upToCount: 2), d.count == 2,
                   UInt16(d[0]) | (UInt16(d[1]) << 8) == 0xEF53 {
                    return dev
                }
            } catch { continue }
        }
        return nil
    }

    // MARK: process helper

    private static func runCapturing(_ launch: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "failed to launch \(launch): \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
