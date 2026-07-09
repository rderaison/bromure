import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import bromure_ac

@Suite("TerminalImagePaste")
struct ImagePasteTests {

    // MARK: Helpers

    /// A private pasteboard so tests never touch (or depend on) the real
    /// general pasteboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("io.bromure.tests.\(UUID().uuidString)"))
    }

    private func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func tinyTIFF() -> Data {
        NSBitmapImageRep(data: tinyPNG())!.tiffRepresentation!
    }

    private func writeTempFile(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    // MARK: Detection

    @Test("Screenshot-style clipboard (bitmap, no text) is an image paste")
    func bitmapOnly() {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setData(tinyPNG(), forType: .png)
        let sources = TerminalImagePaste.sources(from: pb)
        #expect(sources?.count == 1)
        guard case .bitmap(let data, let ext)? = sources?.first else {
            Issue.record("expected a bitmap source"); return
        }
        #expect(ext == "png")
        #expect(!data.isEmpty)
    }

    @Test("TIFF-only clipboard converts to PNG")
    func tiffConverts() {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setData(tinyTIFF(), forType: .tiff)
        guard case .bitmap(let data, let ext)? =
                TerminalImagePaste.sources(from: pb)?.first else {
            Issue.record("expected a bitmap source"); return
        }
        #expect(ext == "png")
        // The converted bytes must decode as an image again.
        #expect(NSBitmapImageRep(data: data) != nil)
    }

    @Test("Clipboard with both text and image stays a text paste")
    func textWinsOverBitmap() {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("some text", forType: .string)
        pb.setData(tinyPNG(), forType: .png)
        #expect(TerminalImagePaste.sources(from: pb) == nil)
    }

    @Test("Plain text clipboard is not an image paste")
    func plainText() {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("hello", forType: .string)
        #expect(TerminalImagePaste.sources(from: pb) == nil)
    }

    @Test("Copied image file wins even with a text flavor alongside (Finder ⌘C)")
    func imageFileURL() throws {
        let url = try writeTempFile(tinyPNG(), ext: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        let pb = makePasteboard()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.lastPathComponent, forType: .string)
        pb.writeObjects([item])

        let sources = TerminalImagePaste.sources(from: pb)
        #expect(sources?.count == 1)
        guard case .file(let got, let ext)? = sources?.first else {
            Issue.record("expected a file source"); return
        }
        #expect(got.standardizedFileURL.path == url.standardizedFileURL.path)
        #expect(ext == "png")
    }

    @Test("A non-image file among the URLs falls back to text paste")
    func mixedFileURLs() throws {
        let img = try writeTempFile(tinyPNG(), ext: "png")
        let txt = try writeTempFile(Data("hi".utf8), ext: "txt")
        defer {
            try? FileManager.default.removeItem(at: img)
            try? FileManager.default.removeItem(at: txt)
        }
        let pb = makePasteboard()
        pb.clearContents()
        pb.writeObjects([img as NSURL, txt as NSURL])
        #expect(TerminalImagePaste.sources(from: pb) == nil)
    }

    // MARK: Naming

    @Test("Guest file name carries timestamp, uniquifier, and extension")
    func fileNameFormat() {
        let date = Date(timeIntervalSince1970: 1_752_072_612)   // 2025-07-09 14:50:12 UTC
        let name = TerminalImagePaste.fileName(
            ext: "png", date: date, unique: "1a2b3c4d",
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "clipboard-20250709-145012-1a2b3c4d.png")
    }

    // MARK: Upload

    /// Records every guest op and returns success, so the chunking logic
    /// can be exercised without a VM.
    @MainActor
    private final class OpRecorder {
        var ops: [[String: Any]] = []
        func run(_ op: [String: Any]) async throws -> [String: Any] {
            ops.append(op)
            return ["exit_code": 0]
        }
    }

    @Test("Upload mkdirs the pastes dir and chunk-writes under the request cap")
    @MainActor
    func uploadChunks() async throws {
        // One byte past a chunk boundary → exactly two writes.
        var big = Data(count: TerminalImagePaste.chunkBytes)
        big.append(0x42)
        let recorder = OpRecorder()
        let paths = try await TerminalImagePaste.upload(
            [.bitmap(big, ext: "png")], via: recorder.run)

        #expect(paths.count == 1)
        let path = try #require(paths.first)
        #expect(path.hasPrefix(TerminalImagePaste.pastesDir + "/clipboard-"))
        #expect(path.hasSuffix(".png"))

        let ops = recorder.ops
        #expect(ops.count == 3)
        #expect(ops[0]["op"] as? String == "mkdir")
        #expect(ops[0]["path"] as? String == TerminalImagePaste.pastesDir)
        #expect(ops[1]["op"] as? String == "write")
        #expect(ops[1]["append"] as? Bool == false)
        #expect(ops[2]["append"] as? Bool == true)
        #expect(ops[1]["path"] as? String == path)
        #expect(ops[2]["path"] as? String == path)

        // Reassembling the chunks yields the original bytes.
        let chunk1 = try #require(Data(base64Encoded: ops[1]["data"] as? String ?? ""))
        let chunk2 = try #require(Data(base64Encoded: ops[2]["data"] as? String ?? ""))
        #expect(chunk1.count == TerminalImagePaste.chunkBytes)
        #expect(chunk2 == Data([0x42]))
        #expect(chunk1 + chunk2 == big)
    }

    @Test("Upload reads file sources from disk and keeps their extension")
    @MainActor
    func uploadFileSource() async throws {
        let bytes = Data([1, 2, 3, 4, 5])
        let url = try writeTempFile(bytes, ext: "jpeg")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = OpRecorder()
        let paths = try await TerminalImagePaste.upload(
            [.file(url, ext: "jpeg")], via: recorder.run)

        let path = try #require(paths.first)
        #expect(path.hasSuffix(".jpeg"))
        #expect(recorder.ops.count == 2)   // mkdir + one write
        let sent = try #require(Data(base64Encoded: recorder.ops[1]["data"] as? String ?? ""))
        #expect(sent == bytes)
    }

    @Test("Two sources upload to two distinct guest paths")
    @MainActor
    func uploadDistinctPaths() async throws {
        let recorder = OpRecorder()
        let paths = try await TerminalImagePaste.upload(
            [.bitmap(Data([1]), ext: "png"), .bitmap(Data([2]), ext: "png")],
            via: recorder.run)
        #expect(paths.count == 2)
        #expect(Set(paths).count == 2)
    }
}
