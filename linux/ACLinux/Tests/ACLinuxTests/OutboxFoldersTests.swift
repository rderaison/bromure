import Foundation
import Testing
@testable import ACLinux

/// The outbox's sandbox-writable folders on Linux (main: SessionDisk's
/// urls/ and agent/, which bromure-sandboxd lets a sandboxed agent write
/// and nothing else in the outbox): made 0777 at every launch, never
/// through a link the guest left, and polled only when real.
@Suite("Outbox folders")
struct OutboxFoldersTests {
    @Test func theFoldersAreMadeWritableWhateverTheUmask() throws {
        let d = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let old = umask(0o077)
        defer { umask(old) }
        try HomeSeed.prepareOutboxDirectory(URL(fileURLWithPath: d + "/outbox"), forRestore: false)
        for name in ["urls", "agent"] {
            var st = stat()
            #expect(lstat(d + "/outbox/" + name, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR)
            #expect(st.st_mode & 0o7777 == 0o777, "\(name): \(String(st.st_mode & 0o7777, radix: 8))")
        }
    }

    /// A restored outbox keeps what the guest left: a link named urls is
    /// replaced by a folder, and what it pointed at keeps its mode.
    @Test func aLinkTheGuestLeftIsReplacedNotFollowed() throws {
        let d = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let outbox = d + "/outbox", host = d + "/host-folder"
        try FileManager.default.createDirectory(atPath: outbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: host, withIntermediateDirectories: true)
        chmod(host, 0o700)
        symlink(host, outbox + "/urls")
        #expect(HomeSeed.outboxFolders(outbox, "urls") == [outbox + "/"], "a link is never polled")
        try HomeSeed.prepareOutboxDirectory(URL(fileURLWithPath: outbox), forRestore: true)
        var st = stat()
        #expect(lstat(outbox + "/urls", &st) == 0 && st.st_mode & S_IFMT == S_IFDIR)
        #expect(stat(host, &st) == 0 && st.st_mode & 0o7777 == 0o700, "the link's target untouched")
        #expect(HomeSeed.outboxFolders(outbox, "urls") == [outbox + "/", outbox + "/urls/"])
    }
}
