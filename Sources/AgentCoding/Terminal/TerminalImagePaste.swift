import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Image paste for native terminal surfaces.
///
/// The agent in the guest can't see the Mac clipboard, and a bitmap can't
/// travel down the pty as bytes — so a ⌘V with an image on the clipboard
/// becomes a file transfer: the image is written into the guest over the
/// vsock file channel and the *guest path* is pasted in its place. Claude
/// (or any guest tool) then reads the image from disk like any other file.
///
/// What counts as an image paste (`sources(from:)`):
/// - copied image *files* (Finder ⌘C): file URLs where every URL is an
///   image — the accompanying string flavor is just host file names,
///   meaningless inside the guest;
/// - copied *bitmaps* (screenshot-to-clipboard, a browser's "Copy Image")
///   with no plain-text flavor. Anything that also offers text (rich
///   text, spreadsheet cells that render an image flavor too) stays a
///   text paste, so ordinary ⌘V is never hijacked.
enum TerminalImagePaste {

    /// One clipboard image to transfer. File contents are read lazily in
    /// `upload` (off the paste keystroke), never at detection time.
    enum Source: Sendable {
        case bitmap(Data, ext: String)
        case file(URL, ext: String)
    }

    /// Where pastes land in the guest. Inside ~/.bromure so it stays out
    /// of the repo working tree, and inside the home image so the path
    /// survives a VM reboot (agent conversations may re-read it later).
    static let pastesDir = "/home/ubuntu/.bromure/pastes"

    /// Same rationale as FileBrowserModel: 6 MB raw ≈ 8 MB base64, inside
    /// the guest agent's 10 MB request cap with room to spare.
    static let chunkBytes = 6 * 1024 * 1024

    /// Refuse pastes beyond this (a mis-⌘C of a giant file in Finder must
    /// not silently pump gigabytes into the VM); the paste falls back to
    /// its text flavor instead.
    static let maxTotalBytes = 96 * 1024 * 1024

    // MARK: Detection

    /// The images `pasteboard` should paste as guest files, or nil when
    /// this is not an image paste (text pastes return nil, always).
    static func sources(from pasteboard: NSPasteboard) -> [Source]? {
        var total = 0

        // Copied files win over the string flavor (for a Finder copy the
        // string is just the file name) — but only when *every* URL is an
        // image; a mixed selection pastes as text like before.
        if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var out: [Source] = []
            for url in urls {
                guard let type = imageType(of: url),
                      let size = try? url.resourceValues(
                          forKeys: [.fileSizeKey]).fileSize
                else { return nil }
                total += size
                guard total <= maxTotalBytes else { return nil }
                let ext = url.pathExtension.isEmpty
                    ? (type.preferredFilenameExtension ?? "png")
                    : url.pathExtension.lowercased()
                out.append(.file(url, ext: ext))
            }
            return out
        }

        // Bare bitmaps only: any plain-text flavor means the text is the
        // primary content and must keep pasting as text.
        guard pasteboard.string(forType: .string) == nil else { return nil }
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return png.count <= maxTotalBytes ? [.bitmap(png, ext: "png")] : nil
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]),
           !png.isEmpty {
            return png.count <= maxTotalBytes ? [.bitmap(png, ext: "png")] : nil
        }
        return nil
    }

    private static func imageType(of url: URL) -> UTType? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .image) else { return nil }
        return type
    }

    // MARK: Naming

    /// "clipboard-20260709-153012-1a2b3c4d.png" — the timestamp is for
    /// humans browsing the dir; `unique` is what actually prevents
    /// collisions (two pastes in the same second).
    static func fileName(ext: String, date: Date, unique: String,
                         timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return "clipboard-\(fmt.string(from: date))-\(unique).\(ext)"
    }

    // MARK: Transfer

    /// Runs one {"file": …} op in the target guest (see GuestFileOpProvider).
    typealias GuestFileOp = @MainActor (_ op: [String: Any]) async throws -> [String: Any]

    /// Write every source into the guest's pastes dir, chunked; returns
    /// the guest paths in source order. Throws on the first failed op.
    /// `progress` (0…1, monotonic) is reported after every chunk; the
    /// denominator uses directory sizes for file sources, so drift only
    /// skews the fraction, never the bytes.
    static func upload(_ sources: [Source], via op: GuestFileOp,
                       progress: (@MainActor (Double) -> Void)? = nil) async throws -> [String] {
        let estimatedTotal = max(1, sources.reduce(0) { sum, source in
            switch source {
            case .bitmap(let d, _): return sum + d.count
            case .file(let url, _):
                return sum + ((try? url.resourceValues(
                    forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        })
        var sent = 0
        _ = try await op(["op": "mkdir", "path": pastesDir])
        var paths: [String] = []
        for source in sources {
            let data: Data
            let ext: String
            switch source {
            case .bitmap(let d, let e):
                data = d; ext = e
            case .file(let url, let e):
                // Mapped: the bytes page in per-chunk below instead of
                // loading the whole file up front.
                data = try Data(contentsOf: url, options: .mappedIfSafe)
                ext = e
            }
            let unique = String(UUID().uuidString.prefix(8)).lowercased()
            let path = pastesDir + "/" + fileName(ext: ext, date: Date(), unique: unique)
            var offset = 0
            var first = true
            repeat {
                let end = min(offset + chunkBytes, data.count)
                _ = try await op([
                    "op": "write",
                    "path": path,
                    "data": data.subdata(in: offset..<end).base64EncodedString(),
                    "append": !first,
                ])
                first = false
                sent += end - offset
                offset = end
                if let progress {
                    await progress(min(1, Double(sent) / Double(estimatedTotal)))
                }
            } while offset < data.count
            paths.append(path)
        }
        return paths
    }

    // MARK: Paste orchestration

    /// Called from the runtime's read-clipboard callback (main thread).
    /// Returns false when this isn't an image paste — the caller then
    /// completes the request with the string flavor as usual. Returns
    /// true when the image transfer was kicked off; the caller must
    /// complete the pending clipboard request (empty) so libghostty
    /// isn't left waiting on the transfer, and the guest path arrives
    /// later as its own paste.
    static func beginImagePaste(surfaceUserdata ptr: UnsafeMutableRawPointer,
                                pasteboard: NSPasteboard = .general) -> Bool {
        guard let view = GhosttyRuntime.surfaceView(for: ptr),
              view.profileID != nil,
              let sources = sources(from: pasteboard), !sources.isEmpty
        else { return false }

        Task { @MainActor in
            guard let view = GhosttyRuntime.surfaceView(for: ptr),
                  let profileID = view.profileID,
                  let delegate = NSApp.delegate as? ACAppDelegate else {
                NSSound.beep()
                return
            }
            // Host-side thumbnail chip at the caret — the human sees what
            // was pasted; the pty still only ever gets the path text.
            let overlay = PasteThumbnailOverlay.present(over: view, sources: sources)
            do {
                let paths = try await upload(
                    sources,
                    via: { try await delegate.guestFileOp(profileID: profileID, op: $0) },
                    progress: { overlay?.setProgress($0) })
                overlay?.markDone()
                // The transfer can outlive the surface (retire/reattach,
                // VM shutdown) — re-resolve; if it's gone, drop the paste.
                guard let live = GhosttyRuntime.surfaceView(for: ptr),
                      let surface = live.surface else { return }
                let text = paths.joined(separator: " ") + " "
                text.withCString {
                    ghostty_surface_text(surface, $0, UInt(text.utf8.count))
                }
                // Fire-and-forget hygiene: pastes older than a week go
                // away so the home image doesn't grow without bound.
                Task {
                    _ = try? await delegate.guestExec(
                        profileID: profileID,
                        command: "find \(pastesDir) -type f -mtime +7 -delete 2>/dev/null; true",
                        timeout: 10)
                }
            } catch {
                overlay?.markFailed()
                NSLog("[ghostty] image paste failed: %@", String(describing: error))
                NSSound.beep()
            }
        }
        return true
    }
}
