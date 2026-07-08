import AppKit
import Foundation
import Testing
@testable import bromure_ac

/// Host side of the image-paste chain: the pasteboard→PNG extraction that
/// ClipboardImageBridge ships into the guest's meta share. The vsock +
/// xclip half runs in the VM and is covered by the E2E flow, not here.
@Suite("ClipboardImageBridge pasteboard→PNG")
struct ClipboardImageBridgeTests {

    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// A tiny valid RGBA bitmap for conversion tests.
    private func makeRep() -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
    }

    @Test("TIFF converts to PNG")
    func tiffToPNG() {
        let tiff = makeRep().tiffRepresentation!
        let png = ClipboardImageBridge.pngData(fromTIFF: tiff)
        #expect(png?.prefix(8) == Self.pngMagic)
    }

    @Test("Garbage bytes are rejected, not crashed on")
    func garbage() {
        #expect(ClipboardImageBridge.pngData(fromTIFF: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("PNG passes through untouched, TIFF-only converts, text yields nil")
    func pasteboardExtraction() {
        // A named private pasteboard so the user's real clipboard is
        // never touched by the test run.
        let pb = NSPasteboard(name: NSPasteboard.Name("io.bromure.tests.clipboard-image"))
        let rep = makeRep()

        pb.clearContents()
        let png = rep.representation(using: .png, properties: [:])!
        pb.setData(png, forType: .png)
        #expect(ClipboardImageBridge.pngData(from: pb) == png)

        pb.clearContents()
        pb.setData(rep.tiffRepresentation!, forType: .tiff)
        #expect(ClipboardImageBridge.pngData(from: pb)?.prefix(8) == Self.pngMagic)

        pb.clearContents()
        pb.setString("no image here", forType: .string)
        #expect(ClipboardImageBridge.pngData(from: pb) == nil)
    }
}

/// The guest half of ⌘V dispatch lives in the generated kitty.conf: one
/// script picks exactly one action via kitty remote control — image on
/// the CLIPBOARD → inject the literal Ctrl+V byte into the active pty,
/// text → kitty's own paste action. Guard the load-bearing pieces so a
/// conf refactor can't silently break either path. Two invariants bought
/// with pain: ⌘V must NEVER run paste_from_clipboard as an unconditional
/// kitty action (kitty requests UTF8_STRING without checking TARGETS and
/// xclip serves raw PNG bytes for it → binary pasted into the TTY), and
/// the dispatch must not rely on synthetic X keys (xdotool/XTEST proved
/// unreliable under a physically-held ⌘).
@Suite("kittyConfig ⌘V image-paste mapping")
struct KittyImagePasteMappingTests {

    @Test("super+v is a single remote-control dispatcher")
    func mapping() {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.customFontSize = 16
        let conf = TerminalAppDefaults.kittyConfig(
            for: p, terminalDefaults: .fallback, displayScale: 2)
        let mapLine = conf.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("map super+v") }
            .map(String.init)
        #expect(mapLine != nil)
        // Single launch action — never a combine (which runs every part
        // unconditionally) and never a bare paste_from_clipboard.
        #expect(mapLine?.contains("combine") == false)
        // --allow-remote-control is what authorizes the child's
        // `kitty @` calls even with remote control globally off.
        #expect(mapLine?.contains("launch --allow-remote-control --type=background") == true)
        #expect(mapLine?.contains("xclip -selection clipboard -t TARGETS") == true)
        // Image branch: the raw Ctrl+V byte to the active window's pty.
        #expect(mapLine?.contains(#"kitty @ send-text "\x16""#) == true)
        // Text branch: paste only through kitty's own action, i.e. the
        // token must appear as a `kitty @ action`, not a kitty action.
        #expect(mapLine?.contains("kitty @ action paste_from_clipboard") == true)
        #expect(mapLine?.contains("xdotool") == false)
    }
}
