import Foundation
import Testing
@testable import bromure_ac

/// Board: the Files pane's preview said "Binary file" for a PNG or a movie,
/// and "File is too large to preview" past 512 KB -- the text preview's
/// window. Images and videos are now shown, read off the machine a chunk at
/// a time through the pane's file service (`MediaView`, as the chat's
/// display cards are).
@Suite("Files pane: images and videos are previewed, not called binary", .serialized)
@MainActor
struct FilePreviewMediaTests {
    /// A PNG of `bytes` bytes (only the signature is real).
    private static func png(_ bytes: Int) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        d.append(Data(repeating: 0x00, count: bytes - d.count))
        return d
    }

    private final class Guest: @unchecked Sendable {
        var stamp = "900000 1700000000"
        var files: [String: Data] = [:]
        var commands: [String] = []
    }

    private func model(_ g: Guest, fileService: Bool = true) -> FileExplorerModel {
        let m = FileExplorerModel()
        m.execProvider = { _, command, _ in
            g.commands.append(command)
            if command.hasPrefix("stat ") { return g.stamp }
            if command.hasPrefix("head -c") {
                // The text preview's read: the first bytes, base64.
                // The command quotes the folder and the name apart.
                for (path, data) in g.files where command.contains((path as NSString).lastPathComponent) {
                    return data.prefix(512 * 1024 + 1).base64EncodedString()
                }
            }
            return ""
        }
        if fileService {
            m.fileOpProvider = { _, op in
                guard op["op"] as? String == "read", let path = op["path"] as? String,
                      let data = g.files[path] else { return ["error": "no such file"] }
                let offset = op["offset"] as? Int ?? 0, length = op["length"] as? Int ?? data.count
                let slice = data.subdata(in: min(offset, data.count)..<min(offset + length, data.count))
                return ["data": slice.base64EncodedString(), "size": data.count,
                        "eof": offset + slice.count >= data.count]
            }
        }
        m.setLocation(profileID: UUID(), cwd: "/home/ubuntu", repoRoot: nil)
        return m
    }

    /// Until `done` holds (a selection's load runs on its own task), at most 3 s.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<300 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test("an image past the text window is shown in full, through the file service")
    func imageShown() async throws {
        let g = Guest()
        let big = Self.png(900_000)                        // past the 512 KB text window
        g.files["/home/ubuntu/shot.png"] = big
        let m = model(g)
        m.select("shot.png")
        await until { m.detailKind == "media" }
        #expect(m.detailKind == "media")
        guard case .media(let path, let reader) = m.detail else { Issue.record("not media"); return }
        #expect(path == "/home/ubuntu/shot.png")
        #expect(await reader.read(path, 25 * 1024 * 1024) == big, "read whole, in chunks")
        // The cache key follows the file: rewritten, it's a new picture.
        let first = reader.cacheKey(path)
        g.stamp = "900001 1700000099"
        m.select("shot.png")
        await until { if case .media(_, let r) = m.detail { return r.cacheKey(path) != first } else { return false } }
        guard case .media(_, let again) = m.detail else { Issue.record("not media"); return }
        #expect(again.cacheKey(path) != first)
        #expect(!g.commands.contains { $0.hasPrefix("head -c") }, "no text read for an image")
    }

    @Test("videos are media; text is still text; without a file service it's as before")
    func kinds() async throws {
        let g = Guest()
        g.files["/home/ubuntu/demo.mp4"] = Data(repeating: 1, count: 2_000_000)
        g.files["/home/ubuntu/notes.txt"] = Data("hello\n".utf8)
        g.files["/home/ubuntu/logo.png"] = Self.png(64)
        let m = model(g)
        m.select("demo.mp4")
        await until { m.detailKind == "media" }
        #expect(m.detailKind == "media")
        m.select("notes.txt")
        await until { if case .code(let t, _) = m.detail { return t == "hello\n" } else { return false } }
        guard case .code(let text, _) = m.detail else { Issue.record("not code: \(m.detailKind)"); return }
        #expect(text == "hello\n")
        // A view with no file service (none injected): the text preview's answer.
        let bare = model(g, fileService: false)
        bare.select("logo.png")
        await until { bare.detailKind == "binary" }
        #expect(bare.detailKind == "binary")
    }

    /// Finding: the key was `stat -c '%s %Y'` -- size and whole seconds, of
    /// the symlink itself. A same-size image rewritten within the second, or
    /// a link pointed at another image, kept its key and the old picture.
    @Test("the version follows symlinks and carries inode, size and nanosecond times")
    func stampCommand() {
        let cmd = FileExplorerModel.mediaStampCommand("'/home/ubuntu'/'shot.png'")
        #expect(cmd.hasPrefix("stat -L "), "the file a link leads to, as the file service reads it")
        for field in ["%d", "%i", "%s", "%y", "%z"] { #expect(cmd.contains(field), "\(field)") }
        #expect(!cmd.contains("%Y"), "whole seconds only")
        #expect(cmd.contains("'/home/ubuntu'/'shot.png'"))
    }

    @Test("same version, same key; any other version, or none known, a new one")
    func scopes() {
        let id = UUID()
        let a = "66306 1234 900000 2026-11-08 12:00:00.100000000 -0500 2026-11-08 12:00:00.100000000 -0500"
        let b = "66306 1234 900000 2026-11-08 12:00:00.700000000 -0500 2026-11-08 12:00:00.700000000 -0500"
        #expect(FileExplorerModel.mediaScope(profileID: id, stamp: a) == FileExplorerModel.mediaScope(profileID: id, stamp: a))
        #expect(FileExplorerModel.mediaScope(profileID: id, stamp: a) != FileExplorerModel.mediaScope(profileID: id, stamp: b),
                "a same-size rewrite within the second")
        #expect(FileExplorerModel.mediaScope(profileID: id, stamp: "") != FileExplorerModel.mediaScope(profileID: id, stamp: ""),
                "an unknown version never reuses what was cached")
        #expect(FileExplorerModel.mediaScope(profileID: UUID(), stamp: a) != FileExplorerModel.mediaScope(profileID: id, stamp: a))
    }

    @Test("a file whose stat fails is read afresh on every look")
    func noStampNoReuse() async throws {
        let g = Guest()
        g.stamp = ""
        g.files["/home/ubuntu/shot.png"] = Self.png(64)
        let m = model(g)
        m.select("shot.png")
        await until { m.detailKind == "media" }
        guard case .media(let path, let first) = m.detail else { Issue.record("not media"); return }
        m.select("shot.png")
        await until { if case .media(_, let r) = m.detail { return r.cacheKey(path) != first.cacheKey(path) } else { return false } }
        guard case .media(_, let again) = m.detail else { Issue.record("not media"); return }
        #expect(again.cacheKey(path) != first.cacheKey(path))
    }
}
