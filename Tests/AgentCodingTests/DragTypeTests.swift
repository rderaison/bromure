import Foundation
import Testing
import UniformTypeIdentifiers
@testable import bromure_ac

// A file dragged out of the guest travels under a type; the receiver names
// the copy after that type's preferred extension. For a type whose
// preferred extension isn't the file's own that renamed the copy — a
// ".yaml" landed as ".yml" — so such a file travels as plain data instead.

@Suite("Drag-out file type")
struct DragTypeTests {

    @Test("a file whose extension is the type's preferred one keeps its type")
    func preferredExtensionKeepsType() {
        #expect(FileExplorerModel.dragType(forFileName: "photo.png") == .png)
        #expect(FileExplorerModel.dragType(forFileName: "index.html") == .html)
        #expect(FileExplorerModel.dragType(forFileName: "Photo.PNG") == .png)
    }

    @Test("a mismatched extension travels as plain data, name intact")
    func mismatchedExtensionIsData() {
        // The system's preferred extension for YAML is "yml".
        #expect(UTType.yaml.preferredFilenameExtension == "yml")
        #expect(FileExplorerModel.dragType(forFileName: "config.yaml") == .data)
        #expect(FileExplorerModel.dragType(forFileName: "config.yml") == .yaml)
        // No extension at all: nothing to rename by.
        #expect(FileExplorerModel.dragType(forFileName: "Makefile") == .data)
    }
}
