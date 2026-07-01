import Foundation
import Testing
@testable import bromure_ac

/// The magic-keychord trigger is configurable; these cover the byte parser and
/// its human label so a bad `overlay-key` file can't silently mis-bind.
@Suite("Overlay keychord parsing")
struct OverlayChordTests {

    @Test("Control forms map to the right byte")
    func controlForms() {
        #expect(RemoteMenuApp.parseChordByte("C-]") == 0x1D)   // default
        #expect(RemoteMenuApp.parseChordByte("c-]") == 0x1D)
        #expect(RemoteMenuApp.parseChordByte("^]") == 0x1D)
        #expect(RemoteMenuApp.parseChordByte("C-o") == 0x0F)
        #expect(RemoteMenuApp.parseChordByte("C-g") == 0x07)
    }

    @Test("Hex and decimal forms")
    func numericForms() {
        #expect(RemoteMenuApp.parseChordByte("0x1d") == 0x1D)
        #expect(RemoteMenuApp.parseChordByte("29") == 0x1D)
    }

    @Test("Whitespace is tolerated; junk rejected")
    func edges() {
        #expect(RemoteMenuApp.parseChordByte("  C-]\n") == 0x1D)
        #expect(RemoteMenuApp.parseChordByte("") == nil)
        #expect(RemoteMenuApp.parseChordByte("C-") == nil)
    }

    @Test("Label round-trips the default")
    func label() {
        #expect(RemoteMenuApp.chordLabel(0x1D) == "Ctrl-]")
        #expect(RemoteMenuApp.chordLabel(0x0F) == "Ctrl-O")
    }
}
