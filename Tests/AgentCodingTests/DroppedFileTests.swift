import Foundation
import Testing
@testable import bromure_ac

@Suite("Dropped files: host paths pasted by a text field become attachments")
struct DroppedFileTests {
    private func tempFile(_ name: String, bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test("A bare path (the whole text) becomes one file and leaves no text")
    func wholeText() throws {
        let url = try tempFile("shot.png", bytes: [1, 2, 3])
        let (text, files) = DroppedFile.absorbHostPaths(in: url.path, offered: [url.path])
        #expect(text.isEmpty)
        #expect(files.map(\.name) == ["shot.png"])
        #expect(files.first?.isImage == true)
        #expect(files.first?.data == Data([1, 2, 3]))
    }

    @Test("A path with spaces dropped mid-sentence is found whole; the sentence survives")
    func pathWithSpaces() throws {
        let url = try tempFile("red square.png", bytes: [9])
        let (text, files) = DroppedFile.absorbHostPaths(in: "What color is this?\n\(url.path)\nThanks", offered: [url.path])
        #expect(files.map(\.name) == ["red square.png"])
        #expect(text == "What color is this?\nThanks")
    }

    @Test("Two paths on one line, a non-image among them")
    func twoTokens() throws {
        let a = try tempFile("notes.txt", bytes: [1])
        let b = try tempFile("pic.jpg", bytes: [2])
        let (text, files) = DroppedFile.absorbHostPaths(in: "look \(a.path) \(b.path) please", offered: [a.path, b.path])
        #expect(files.map(\.name) == ["notes.txt", "pic.jpg"])
        #expect(files.map(\.isImage) == [false, true])
        #expect(text == "look please")
    }

    @Test("Prose, a missing path, and a directory are left alone")
    func noFalsePositives() {
        let (text, files) = DroppedFile.absorbHostPaths(in: "fix /this/does/not/exist.png and /tmp too", offered: ["/this/does/not/exist.png", "/tmp"])
        #expect(files.isEmpty)
        #expect(text == "fix /this/does/not/exist.png and /tmp too")
    }

    @Test("A TYPED path to an existing host file is text, never an upload")
    func typedPathStaysText() throws {
        let secret = try tempFile("id_rsa", bytes: [7])
        let other = try tempFile("dropped.txt", bytes: [8])
        let typed = "rm -f \(secret.path) and report"
        let (none, noFiles) = DroppedFile.absorbHostPaths(in: typed, offered: [])
        #expect(noFiles.isEmpty)
        #expect(none == typed)
        // Another file being dropped doesn't let a typed path ride along.
        let (text, files) = DroppedFile.absorbHostPaths(in: typed + " " + other.path, offered: [other.path])
        #expect(files.map(\.name) == ["dropped.txt"])
        #expect(text == typed)
        #expect(DroppedFile.hostFileURL(secret.path, offered: [other.path]) == nil)
    }
}
