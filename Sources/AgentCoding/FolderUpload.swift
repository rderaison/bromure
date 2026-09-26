import Foundation

/// Copies a folder from this Mac into a guest folder over the guest file
/// service — for the file pane, a chat and the composer alike. It travels as
/// one gzipped tar the guest unpacks (`untar`, see `_untar_confined` in
/// bromure-agentd.py: any entry that would land outside the target is
/// skipped): a file-op round trip per file was minutes for a node_modules
/// over a remote link. A guest too old to unpack gets it file by file.
enum FolderUpload {
    typealias FileOp = ([String: Any]) async throws -> [String: Any]

    /// Raw bytes per write — the base64 stays under the guest's request cap.
    private static let chunkBytes = 6 * 1024 * 1024

    /// The contents of `src` into `guestDir` (created if need be). Returns
    /// how many entries the guest refused to unpack (links pointing outside
    /// the folder, devices…). `progress` gets a line to show while it runs.
    @discardableResult
    static func upload(_ src: URL, into guestDir: String, op: FileOp,
                       progress: ((String) -> Void)? = nil) async throws -> Int {
        let name = src.lastPathComponent
        progress?(String(format: NSLocalizedString("Packing %@…",
                                                   comment: "a dropped folder is being archived"), name))
        let archive = try await tarball(of: src)
        defer { try? FileManager.default.removeItem(at: archive) }
        let guestArchive = "/tmp/bromure-drop-\(UUID().uuidString).tgz"
        try await write(archive, to: guestArchive, label: name, op: op, progress: progress)
        progress?(String(format: NSLocalizedString("Unpacking %@…",
                                                   comment: "a dropped folder is being unpacked in the VM"), name))
        do {
            let resp = try await op(["op": "untar", "path": guestDir, "archive": guestArchive])
            return resp["skippedCount"] as? Int ?? 0
        } catch {
            // An agent without `untar` (a server not yet updated) — or one
            // that failed to unpack: copy it the slow way.
            _ = try? await op(["op": "remove", "path": guestArchive])
            try await loose(src, to: guestDir, op: op, progress: progress)
            return 0
        }
    }

    /// `src` packed, as bytes — a folder dropped on a remote new-session
    /// screen travels to the server this way (`unpack` there).
    static func packed(_ src: URL) async throws -> Data {
        let archive = try await tarball(of: src)
        defer { try? FileManager.default.removeItem(at: archive) }
        return try Data(contentsOf: archive)
    }

    /// A folder `packed` elsewhere, unpacked into `guestDir`.
    static func unpack(_ archive: Data, into guestDir: String, op: FileOp) async throws {
        let guestArchive = "/tmp/bromure-drop-\(UUID().uuidString).tgz"
        for w in GuestDrop.writeOps(guestPath: guestArchive, data: archive) { _ = try await op(w) }
        _ = try await op(["op": "untar", "path": guestDir, "archive": guestArchive])
    }

    /// `src`'s contents as a gzipped tar in a temporary file: links kept as
    /// links, no Finder metadata (no `._` files).
    private static func tarball(of src: URL) async throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-drop-\(UUID().uuidString).tgz")
        return try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-czf", out.path, "--no-mac-metadata", "--no-xattrs", "-C", src.path, "."]
            var env = ProcessInfo.processInfo.environment
            env["COPYFILE_DISABLE"] = "1"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            p.standardError = errPipe
            try p.run()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: out)
                throw ACAppDelegate.GuestExecError.commandFailed(
                    exitCode: Int(p.terminationStatus), stderr: String(decoding: err, as: UTF8.self))
            }
            return out
        }.value
    }

    /// One file, chunked: a truncating first write, then appends.
    static func write(_ src: URL, to guestPath: String, label: String, op: FileOp,
                      progress: ((String) -> Void)?) async throws {
        guard let handle = try? FileHandle(forReadingFrom: src) else { return }
        defer { try? handle.close() }
        var first = true
        var sent: Int64 = 0
        while true {
            let data = handle.readData(ofLength: chunkBytes)
            if data.isEmpty && !first { break }
            _ = try await op(["op": "write", "path": guestPath,
                              "data": data.base64EncodedString(), "append": !first])
            sent += Int64(data.count)
            progress?(String(format: NSLocalizedString("Copying %@ in… %@", comment: ""), label,
                             ByteCountFormatter.string(fromByteCount: sent, countStyle: .file)))
            first = false
            if data.count < chunkBytes { break }
        }
    }

    /// The file-by-file copy: a folder per mkdir, a file per write.
    private static func loose(_ src: URL, to guestDir: String, op: FileOp,
                              progress: ((String) -> Void)?) async throws {
        _ = try await op(["op": "mkdir", "path": guestDir])
        let children = (try? FileManager.default.contentsOfDirectory(
            at: src, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children {
            let dest = (guestDir as NSString).appendingPathComponent(child.lastPathComponent)
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false {
                try await loose(child, to: dest, op: op, progress: progress)
            } else {
                try await write(child, to: dest, label: child.lastPathComponent, op: op, progress: progress)
            }
        }
    }
}
