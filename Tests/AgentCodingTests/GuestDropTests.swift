import Foundation
import Testing
@testable import bromure_ac

/// The beautified view stages dropped files in the guest at a path derived from
/// the (attacker-influenced) filename. These pin that a malicious name can never
/// escape the staging dir — `/` and `..` are neutralized, so every drop lands as
/// a direct child of `/tmp/bromure-drops`.
@Suite("GuestDrop path safety")
struct GuestDropTests {

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

    @Test("write commands chunk on a multiple of 4 base64 chars (append-safe)")
    func chunkedWriteDecodesIndependently() {
        // 500 KB → multiple chunks; each chunk must be a whole number of base64
        // quanta so `base64 -d` on each piece appends whole bytes.
        let data = Data((0..<500_000).map { UInt8($0 & 0xff) })
        let cmds = GuestDrop.writeCommands(guestPath: "/tmp/bromure-drops/0_x.bin", data: data)
        #expect(cmds.count > 1)
        #expect(cmds.first?.contains("mkdir -p") == true)
        #expect(cmds.first?.contains(">") == true)          // first truncates
        #expect(cmds.dropFirst().allSatisfy { $0.contains(">>") })  // rest append
    }
}
