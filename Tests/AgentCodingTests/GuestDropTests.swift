import Foundation
import Testing
@testable import bromure_ac

/// The beautified view stages dropped files in the guest at a path derived from
/// the (attacker-influenced) filename. These pin that a malicious name can never
/// escape the staging dir — `/` and `..` are neutralized, so every drop lands as
/// a direct child of `GuestDrop.baseDir`.
@Suite("GuestDrop path safety")
struct GuestDropTests {

    @Test("drops live in the home image, as direct children of the drops dir")
    func dropsDirInHome() {
        #expect(GuestDrop.baseDir.hasPrefix("/home/ubuntu/"))
        let p = GuestDrop.path(index: 0, name: "photo.png")
        #expect(p == GuestDrop.baseDir + "/0_photo.png")
    }

    @Test("a send's stamp makes the same name land at a new path each time")
    func stampsDiffer() {
        let a = GuestDrop.stamp(), b = GuestDrop.stamp()
        #expect(a != b)
        #expect(a.count == "20260919-213000-ab12".count)
        // The stamp survives the name cleanup, so the path carries it.
        #expect(GuestDrop.path(index: 0, name: "\(a)_photo.png").contains(a))
    }

    @Test("a turn's words lose the paths its pictures stand for, whitespace folded")
    func wordsWithoutPaths() {
        let img = GuestDrop.baseDir + "/0_20260919-213000-ab12_photo.png"
        #expect(TranscriptItemView.withoutPaths("Second picture. \(img)", [img]) == "Second picture.")
        #expect(TranscriptItemView.withoutPaths("\(img)", [img]) == "")
        #expect(TranscriptItemView.withoutPaths("Look:\n\(img)\nand tell me", [img]) == "Look:\nand tell me")
        // Paths not stood for by a picture stay in the words.
        #expect(TranscriptItemView.withoutPaths("see \(img)", []) == "see \(img)")
    }

    @Test("imagePaths finds the drop images a turn names, old dir included")
    func imagePathsInTurn() {
        let img = GuestDrop.baseDir + "/0_20260919-213000-ab12_photo.png"
        let doc = GuestDrop.baseDir + "/1_20260919-213000-ab12_notes.pdf"
        let old = GuestDrop.legacyBaseDir + "/0_b1_shot.JPG"
        let text = "Look at \(img) and \(doc)\nalso \(old) and \(img) plus /home/ubuntu/other.png"
        #expect(GuestDrop.imagePaths(in: text) == [img, old])
        #expect(GuestDrop.imagePaths(in: "no drops here").isEmpty)
    }

    @Test("safeName strips separators and traversal sequences")
    func safeNameNeutralizes() {
        #expect(!GuestDrop.safeName("../../etc/passwd").contains("/"))
        #expect(!GuestDrop.safeName("../../etc/passwd").contains(".."))
        #expect(!GuestDrop.safeName("..").contains(".."))
        #expect(!GuestDrop.safeName("a/b/c").contains("/"))
        // A normal name keeps its shape.
        #expect(GuestDrop.safeName("photo.png") == "photo.png")
        // Empty / dot-only degrade to a safe default.
        #expect(GuestDrop.safeName("") == "file")
        #expect(GuestDrop.safeName(".") == "file")
        // Spaces and shell metacharacters collapse to underscores, so the guest
        // path is never a shell hazard AND stays a single token in the message
        // text the agent reads.
        #expect(GuestDrop.safeName("my photo.png") == "my_photo.png")
        let hostile = GuestDrop.safeName("a b;c$d`e\"f'g|h&i.png")
        #expect(hostile.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
        #expect(!hostile.contains(" "))
        // Unicode letters/digits are preserved (no mojibake, still shell-safe).
        #expect(GuestDrop.safeName("café.png") == "café.png")
    }

    @Test("path + writeOps handle a spaced/metachar name: no spaces, file-op only")
    func spacedNameStagesCleanly() {
        let path = GuestDrop.path(index: 0, name: "my cool $file;.png")
        #expect(path.hasPrefix(GuestDrop.baseDir + "/"))
        #expect(!path.dropFirst(GuestDrop.baseDir.count + 1).contains(" "))  // one token
        // The write goes through the file-op plane (op:"write" with the path in
        // JSON) — no shell, so the path is passed to open() verbatim regardless
        // of characters. Verify the ops carry that exact path.
        let ops = GuestDrop.writeOps(guestPath: path, data: Data([1, 2, 3]))
        #expect(ops.allSatisfy { ($0["path"] as? String) == path })
        #expect(ops.allSatisfy { ($0["op"] as? String) == "write" })
    }

    @Test("path stays a direct child of the staging dir for hostile names")
    func pathIsContained() {
        let hostile = ["../../etc/passwd", "..", "../secret", "a/../../b",
                       "foo/bar", "\u{0}evil", "....//....//x"]
        for name in hostile {
            let p = GuestDrop.path(index: 0, name: name)
            #expect(p.hasPrefix(GuestDrop.baseDir + "/"))
            let leaf = String(p.dropFirst(GuestDrop.baseDir.count + 1))
            #expect(!leaf.contains("/"), "leaf must have no separator: \(leaf)")
            #expect(!leaf.contains(".."), "leaf must have no traversal: \(leaf)")
        }
    }

    @Test("writeOps uploads via the file-op plane, chunked, reconstructing input")
    func writeOpsChunksAndReconstructs() {
        // 7 MB → more than one write chunk. Drops upload through the file-op
        // plane (base64 in JSON), NOT a shell `printf` — so a filled chunk can't
        // blow the kernel's 128 KB per-argv cap (the bug where the drop's path
        // was referenced but the bytes never landed, esp. over the fat-client
        // tunnel). First op truncates (append:false), the rest append; decoding
        // the pieces in order must reconstruct the input.
        let path = "/tmp/bromure-drops/0_x.bin"
        let data = Data((0..<(7 * 1024 * 1024)).map { UInt8($0 & 0xff) })
        let ops = GuestDrop.writeOps(guestPath: path, data: data)
        #expect(ops.count > 1)
        #expect(ops.allSatisfy { ($0["op"] as? String) == "write" })
        #expect(ops.allSatisfy { ($0["path"] as? String) == path })
        #expect(ops.first?["append"] as? Bool == false)                    // truncate
        #expect(ops.dropFirst().allSatisfy { $0["append"] as? Bool == true })  // append
        var rebuilt = Data()
        for op in ops {
            guard let b64 = op["data"] as? String, let piece = Data(base64Encoded: b64)
            else { Issue.record("op missing base64 data"); return }
            rebuilt.append(piece)
        }
        #expect(rebuilt == data)
    }

    @Test("writeOps: small data is one truncating write; empty data still writes")
    func writeOpsSmallAndEmpty() {
        let small = Data((0..<1000).map { UInt8($0 & 0xff) })
        let sOps = GuestDrop.writeOps(guestPath: "/tmp/bromure-drops/0_s.bin", data: small)
        #expect(sOps.count == 1)
        #expect(sOps.first?["append"] as? Bool == false)
        #expect(Data(base64Encoded: sOps.first?["data"] as? String ?? "") == small)

        let eOps = GuestDrop.writeOps(guestPath: "/tmp/bromure-drops/0_e.bin", data: Data())
        #expect(eOps.count == 1)                       // one truncating write → empty file
        #expect(eOps.first?["append"] as? Bool == false)
        #expect(eOps.first?["data"] as? String == "")
    }
}
