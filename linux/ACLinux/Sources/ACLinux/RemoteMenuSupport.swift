import ArgumentParser
import CACLinuxShims
import Foundation

// What the shared remote menu (RemoteMenu.swift) takes from macOS files the
// Linux build doesn't compile: the host-list parser of ProfileViews' field
// and the CLI's edit-in-$EDITOR.

/// macOS: the SwiftUI host-list field; here only its parser.
// @port-skip linux-only: the namespace (macOS's is a SwiftUI View)
enum HostListField {
    // @port HostListField.static parse(_: String) h=0fbdba170f3362d9 @f127f8ab
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }
}

/// Write `doc` to a temp file, open $EDITOR (or vi) on it, and return the
/// parsed result — or nil if the user saved no change. Throws on an invalid
/// edit so we never PUT malformed JSON. The file holds a workspace's
/// document on a server other users share, so it is created owner-only
/// (O_EXCL, 0600, never through a link) in this user's runtime dir, not the
/// shared /tmp; one a dropped session left (its menu killed mid-edit) is
/// swept at the next edit.
// @port editJSONInEditor(_: [String:Any]) h=6a9020237e057451 @f127f8ab
func editJSONInEditor(_ doc: [String: Any], scratchDir: String = EditorScratch.directory()) throws -> [String: Any]? {
    let pretty = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    let file = try EditorScratch.create(contents: pretty, in: scratchDir)
    defer { try? FileManager.default.removeItem(at: file) }
    let before = try Data(contentsOf: file)

    let editor = ProcessInfo.processInfo.environment["VISUAL"]
        ?? ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
    // Pass the path as $1 so spaces/quotes in the temp path can't break the
    // line. Spawned with the terminal as its stdio and waited on here (not
    // Foundation's Process: see ChildProcess).
    let argv = ["/bin/sh", "-c", "\(editor) \"$1\"", "sh", file.path].map { strdup($0) } + [nil]
    defer { for a in argv { free(a) } }
    var pid: Int32 = 0
    let r = argv.withUnsafeBufferPointer { acl_spawn_fds("/bin/sh", $0.baseAddress, 0, 1, 2, nil, 0, &pid) }
    guard r == 0 else { throw ValidationError("Couldn't start the editor: \(String(cString: strerror(r))).") }
    let status = acl_wait_exited(pid)
    acl_reap(pid)
    guard status == 0 else {
        throw ValidationError("Editor exited with status \(status) — not saving.")
    }
    let after = try Data(contentsOf: file)
    if after == before { return nil }
    guard let obj = try JSONSerialization.jsonObject(with: after) as? [String: Any] else {
        throw ValidationError("The edited file isn't valid JSON — not saving.")
    }
    return obj
}

/// The shared `__remote-menu` command (RemoteMenu, internal to this module)
/// for the bromure-ac executable's subcommand list: every SSH login on the
/// embedded server is forced into it (RemoteSSHHandlers).
// @port-skip linux-only: macOS's root command lists RemoteMenu itself
public enum RemoteMenuEntry {
    // @port-skip linux-only: see RemoteMenuEntry
    public static var command: ParsableCommand.Type { RemoteMenu.self }
}

/// Where editJSONInEditor's files live: `<runtime dir>/editor` (0700; the
/// runtime dir is this user's, 0700, and goes at logout), one file per edit
/// named with the editing process's pid, so a file whose process is gone
/// (a session dropped mid-edit) is known stale.
// @port-skip linux-only: macOS writes the edit to its per-user temporary directory
enum EditorScratch {
    // @port-skip linux-only: see EditorScratch
    static func directory() -> String { DaemonConfig.fromEnvironment().runtimeDir + "/editor" }

    /// A new owner-only file holding `contents`, after sweeping stale ones.
    // @port-skip linux-only: see EditorScratch
    static func create(contents: Data, in dir: String = directory()) throws -> URL {
        if mkdir(dir, 0o700) != 0 && errno != EEXIST {
            throw ValidationError("Couldn't create \(dir): \(String(cString: strerror(errno))).")
        }
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw ValidationError("\(dir) isn't a directory of this user's.")
        }
        _ = chmod(dir, 0o700)
        sweep(dir)
        let path = dir + "/bromure-workspace-\(getpid())-\(UUID().uuidString).json"
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ValidationError("Couldn't create \(path): \(String(cString: strerror(errno))).") }
        defer { close(fd) }
        guard ControlClientIO.writeAll(fd, Array(contents)) else {
            unlink(path)
            throw ValidationError("Couldn't write \(path).")
        }
        return URL(fileURLWithPath: path)
    }

    /// Removes the edit files whose process is gone.
    // @port-skip linux-only: see EditorScratch
    static func sweep(_ dir: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            let parts = name.split(separator: "-")
            guard name.hasPrefix("bromure-workspace-"), parts.count > 2, let pid = Int32(parts[2]) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { unlink(dir + "/" + name) }
        }
    }
}
