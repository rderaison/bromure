import Foundation
import Testing
@testable import bromure_ac

// The new-session folder browser: path arithmetic (pure) and the offline
// listing straight out of a home.img. The image-backed test follows the
// Ext4Volume convention — it runs only when BROMURE_EXT4_TEST_IMAGE points at
// a HOME image (a workspace's profiles/<id>/home.img), and skips otherwise.

@Suite("New-session folder browser")
struct NewSessionFolderBrowserTests {

    @Test("parent and child of home-relative and absolute guest paths")
    func pathArithmetic() {
        #expect(NewSessionView.parentFolder(of: "~") == "~")
        #expect(NewSessionView.parentFolder(of: "/") == "/")
        #expect(NewSessionView.parentFolder(of: "~/a/b") == "~/a")
        #expect(NewSessionView.parentFolder(of: "~/a") == "~")
        #expect(NewSessionView.parentFolder(of: "/x/y") == "/x")
        #expect(NewSessionView.parentFolder(of: "/x") == "/")
        #expect(NewSessionView.parentFolder(of: "proj") == "~")   // a bare name typed in the field
        #expect(NewSessionView.childFolder(of: "~", named: "proj") == "~/proj")
        #expect(NewSessionView.childFolder(of: "~/proj", named: "src") == "~/proj/src")
        #expect(NewSessionView.childFolder(of: "/", named: "tmp") == "/tmp")
        // The picker's path popup: the folder on show and the way back up.
        #expect(NewSessionView.ancestors(of: "~/a/b") == ["~/a/b", "~/a", "~"])
        #expect(NewSessionView.ancestors(of: "/x/y") == ["/x/y", "/x", "/"])
        #expect(NewSessionView.ancestors(of: "~") == ["~"])
        #expect(GuestFolderPickerView.name(of: "~/a/b") == "b")
        #expect(GuestFolderPickerView.name(of: "~") == "~")
    }

    @Test("host home dir listing: folders only, dotfolders out, case-insensitive order")
    func hostFolders() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nsfb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for sub in ["beta", "Alpha", ".hidden", "gamma"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a-file.txt"))
        #expect(ACAppDelegate.hostFolders(in: dir) == ["Alpha", "beta", "gamma"])
        #expect(ACAppDelegate.hostFolders(in: dir.appendingPathComponent("nope")) == nil)
    }

    @Test("ext4 home image listing: the home's folders, then a subfolder, no dotfolders")
    func ext4Folders() throws {
        guard let img = ProcessInfo.processInfo.environment["BROMURE_EXT4_TEST_IMAGE"] else { return }
        let home = try #require(ACAppDelegate.ext4Folders(imagePath: img, path: "/"))
        #expect(!home.isEmpty)
        #expect(home.allSatisfy { !$0.hasPrefix(".") })
        #expect(home == home.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        // Every listed name is a directory the volume can resolve and walk.
        let first = try #require(home.first)
        #expect(ACAppDelegate.ext4Folders(imagePath: img, path: "/" + first) != nil)
        // A missing folder is "unreadable", not an empty list.
        #expect(ACAppDelegate.ext4Folders(imagePath: img, path: "/no-such-folder-\(UUID().uuidString)") == nil)
    }
}
