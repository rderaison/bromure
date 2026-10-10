import AppKit
import Testing
@testable import bromure_ac

@Suite("Menu-bar mark")
@MainActor
struct MenuBarMarkTests {
    @Test("The menu-bar icon is the app icon's mark, a template, wider than tall")
    func appMark() throws {
        let mark = try #require(BromureIcons.image("app-mark"))
        #expect(mark.isTemplate)
        #expect(mark.size.width > mark.size.height)
        // The same drawing as the app icon's layer, not a stale copy.
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let icon = try Data(contentsOf: src.appendingPathComponent("Resources/BromureAC.icon/Assets/mark.svg"))
        let bundled = try Data(contentsOf: src.appendingPathComponent("Sources/AgentCoding/Resources/icons/app-mark.svg"))
        #expect(icon == bundled)
        if let out = ProcessInfo.processInfo.environment["MENU_MARK_PNG"] {
            let h: CGFloat = 32
            let w = (h * mark.size.width / mark.size.height).rounded()
            let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
                NSColor.white.setFill(); r.fill(); mark.draw(in: r); return true }
            let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        }
    }
}
