import Foundation

/// Reading a stopped workspace's ext4 home image straight off the host
/// (Ext4Volume, read-only; safe even if a VM has the disk attached, the
/// ext4 browser's tolerance): the new-session folder browser's folders, a
/// coding task's Claude transcript.
enum HomeImageReader {
    /// Subfolder names of a directory inside a home.img (home-relative
    /// path, "/" for the home). Pure file IO — run detached.
    static func folders(imagePath: String, path: String) -> [String]? {
        guard let vol = try? Ext4Volume(path: imagePath),
              let dirIno = try? vol.resolve(path),
              let entries = try? vol.listDir(dirIno) else { return nil }
        var names: [String] = []
        for e in entries where e.name != "." && e.name != ".." && !e.name.hasPrefix(".") {
            if e.isDir || ((try? vol.inode(e.ino))?.isDir ?? false) { names.append(e.name) }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Locate + read the newest session transcript for a task inside a
    /// home.img: candidate project dirs are any `*-<slug>` (worktree
    /// sessions) plus the Claude-encoded cwd (plain-tab sessions); the
    /// newest `.jsonl` by inode mtime wins. Pure file IO — run detached.
    static func claudeTranscript(imagePath: String, slug: String,
                                 guestCwd: String) -> String? {
        guard slug.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }),
              !slug.isEmpty,
              let vol = try? Ext4Volume(path: imagePath) else { return nil }
        // home.img is mounted at /home/ubuntu → in-image paths are
        // home-relative.
        guard let projIno = try? vol.resolve("/.claude/projects"),
              let entries = try? vol.listDir(projIno) else { return nil }
        var cwd = guestCwd
        while cwd.count > 1 && cwd.hasSuffix("/") { cwd = String(cwd.dropLast()) }
        let enc1 = cwd.replacingOccurrences(of: "/", with: "-")
        let enc2 = cwd.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        var newest: (mtime: UInt32, data: [UInt8])?
        for entry in entries {
            let name = entry.name
            guard name != "." && name != "..",
                  name.hasSuffix("-\(slug)") || name == enc1 || name == enc2,
                  let dirInode = try? vol.inode(entry.ino), dirInode.isDir,
                  let files = try? vol.listDir(entry.ino) else { continue }
            for f in files where f.name.hasSuffix(".jsonl") {
                guard let ino = try? vol.inode(f.ino), ino.isRegular else { continue }
                // i_mtime: LE32 at 0x10 of the raw inode record.
                let r = ino.raw
                guard r.count >= 0x14 else { continue }
                let mtime = UInt32(r[0x10]) | (UInt32(r[0x11]) << 8)
                    | (UInt32(r[0x12]) << 16) | (UInt32(r[0x13]) << 24)
                if newest == nil || mtime > newest!.mtime,
                   let data = try? vol.readData(ino, limit: 25_000_000) {
                    newest = (mtime, data)
                }
            }
        }
        guard let newest, !newest.data.isEmpty else { return nil }
        return String(decoding: Data(newest.data.prefix(25_000_000)), as: UTF8.self)
    }
}
