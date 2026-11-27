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

#if os(macOS)   // tar runs as a Process: the iOS/visionOS clients share only write()
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
        // A fresh name, owner-only while it fills and until it's unpacked
        // (CWE-200): nothing to stage it beside.
        do {
            try await writeChunks(archive, to: guestArchive, label: name, op: op, progress: progress, staged: true)
        } catch {
            _ = try? await op(["op": "remove", "path": guestArchive])
            throw error
        }
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
        for w in GuestDrop.writeOps(guestPath: guestArchive, data: archive, staged: true) { _ = try await op(w) }
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
#endif

    /// One file onto `guestPath`, never left half-written: the bytes go to a
    /// hidden temp file beside it, which replaces `guestPath` in one atomic
    /// step (the guest's `rename`) only once all of it was read and written.
    /// A copy that fails part-way leaves a file already there untouched and
    /// removes the temp file. A guest agent too old for `rename` gets the
    /// direct write it always had, and so does a destination whose DIRECTORY
    /// we may not write — see below.
    static func write(_ src: URL, to guestPath: String, label: String, op: FileOp,
                      progress: ((String) -> Void)?) async throws {
        let dir = (guestPath as NSString).deletingLastPathComponent
        let name = (guestPath as NSString).lastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".\(name).bromure-\(UUID().uuidString).part")
        // Did the guest accept a write to `tmp`? Only a write that SUCCEEDED
        // counts, so a refusal of the very first one — the create — leaves
        // this false.
        var tmpCreated = false
        var viaTmp = true
        do {
            // Owner-only while it fills (CWE-200): the file it replaces may
            // be private. `rename` gives it its final mode.
            try await writeChunks(src, to: tmp, label: label, op: { spec in
                let result = try await op(spec)
                if (spec["op"] as? String) == "write" { tmpCreated = true }
                return result
            }, progress: progress, staged: true)
        } catch {
            _ = try? await op(["op": "remove", "path": tmp])
            // Writing a file does not need write access to its directory, but
            // CREATING a sibling of it does. A group-writable file in someone
            // else's directory is the ordinary case: the direct write this
            // replaced worked there, so refusing the upload is a regression.
            //
            // Narrow on purpose. Only when the guest refused AND nothing was
            // written: a denial part-way through must never become a direct
            // write, which is not atomic and would leave `guestPath` in
            // whatever state the failure left it.
            guard !tmpCreated, Self.refusedByFilesystem(error) else { throw error }
            NSLog("[upload] %@: cannot create a temp file in its directory (%@) — writing straight to it. NOT atomic: a copy that fails part-way leaves the destination incomplete.",
                  guestPath, "\(error)")
            viaTmp = false
        }
        if viaTmp {
            do {
                _ = try await op(["op": "rename", "path": tmp, "dest": guestPath])
                return
            } catch {
                _ = try? await op(["op": "remove", "path": tmp])
                guard ("\(error) " + error.localizedDescription).localizedCaseInsensitiveContains("unknown file op") else { throw error }
            }
        }
        try await writeChunks(src, to: guestPath, label: label, op: op, progress: progress)
    }

    /// The guest's answer when the filesystem refused. bromure-agentd.py's
    /// file ops end in `except Exception as e: return {"error": str(e)}`, so
    /// an OSError arrives as Python's own text — `[Errno 13] Permission
    /// denied: '/path/.f.bromure-….part'`. Mirrors permissionDenied() in
    /// web-client/src/core/remote/chunkedWrite.ts; keep the two in step.
    /// Only the text before the path counts: a file named
    /// `permission-denied` that failed for another reason isn't a refusal.
    static func refusedByFilesystem(_ error: Error) -> Bool {
        ["\(error)", error.localizedDescription].contains { full in
            let text = full.components(separatedBy: ": '")[0]
            return text.range(of: #"\[errno (1|13)\]|permission denied|operation not permitted"#,
                              options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// One file, chunked: a truncating first write, then appends. `staged`:
    /// an upload's staging file, created owner-only.
    private static func writeChunks(_ src: URL, to guestPath: String, label: String, op: FileOp,
                                    progress: ((String) -> Void)?, staged: Bool = false) async throws {
        guard let handle = try? FileHandle(forReadingFrom: src) else { return }
        defer { try? handle.close() }
        var first = true
        var sent: Int64 = 0
        while true {
            let data = handle.readData(ofLength: chunkBytes)
            if data.isEmpty && !first { break }
            var w: [String: Any] = ["op": "write", "path": guestPath,
                                    "data": data.base64EncodedString(), "append": !first]
            if staged && first { w["staged"] = true }
            _ = try await op(w)
            sent += Int64(data.count)
            progress?(String(format: NSLocalizedString("Copying %@ in… %@", comment: ""), label,
                             ByteCountFormatter.string(fromByteCount: sent, countStyle: .file)))
            first = false
            if data.count < chunkBytes { break }
        }
    }

#if os(macOS)
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
#endif
}
