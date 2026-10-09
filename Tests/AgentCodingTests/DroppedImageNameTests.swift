import Foundation
import Testing
@testable import bromure_ac

// Image data dropped without a backing file (Preview, a browser, Photos):
// named after what the drag suggests, with the extension its bytes call for.

@Suite("Dropped image names")
struct DroppedImageNameTests {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test("the suggested name and the bytes' own extension")
    func named() {
        #expect(DroppedFile.imageName(suggested: "whatisthis", data: jpeg, typeID: "public.jpeg") == "whatisthis.jpg")
        // A suggestion carrying the wrong extension for the bytes.
        #expect(DroppedFile.imageName(suggested: "whatisthis.png", data: jpeg, typeID: "public.image") == "whatisthis.jpg")
        #expect(DroppedFile.imageName(suggested: nil, data: png, typeID: "public.png") == "pasted-image.png")
        #expect(DroppedFile.imageName(suggested: "  ", data: jpeg, typeID: "public.image") == "pasted-image.jpg")
        // Nothing to go on in the bytes: the drag's declared type.
        #expect(DroppedFile.imageName(suggested: "scan", data: Data([1, 2, 3]), typeID: "public.jpeg") == "scan.jpeg")
        // A dot that isn't an image extension stays in the name.
        #expect(DroppedFile.imageName(suggested: "v1.2 draft", data: png, typeID: "public.png") == "v1.2 draft.png")
    }

    @Test("formats by signature")
    func signatures() {
        #expect(DroppedFile.imageExtension(of: jpeg) == "jpg")
        #expect(DroppedFile.imageExtension(of: png) == "png")
        #expect(DroppedFile.imageExtension(of: Data("GIF89a".utf8)) == "gif")
        #expect(DroppedFile.imageExtension(of: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == "webp")
        #expect(DroppedFile.imageExtension(of: Data([0, 0, 0, 24] + Array("ftypheic".utf8))) == "heic")
        #expect(DroppedFile.imageExtension(of: Data([1, 2, 3])) == nil)
    }

    @Test("the file from the report: JPEG bytes")
    func reported() throws {
        let url = URL(fileURLWithPath: "/Users/renaud/.bromure/inbox/8fa2b45b/0_20260930-165831-d908_pasted-image.png")
        guard let data = try? Data(contentsOf: url) else { return }   // not on every machine
        #expect(DroppedFile.imageName(suggested: "whatisthis", data: data, typeID: "public.image") == "whatisthis.jpg")
    }
}
