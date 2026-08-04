import Foundation
import Testing
@testable import bromure_ac

// The wizard's rail artwork rendered as a bare blue gradient on machines other
// than the one it was made on: the files were committed, but the only thing
// putting them where the code looked was a hand copy in build.sh, and the code
// read Bundle.main. Anything that resolves through the SPM resource bundle
// travels with the package; anything that doesn't, doesn't.
@Suite("Wizard artwork ships with the package")
struct WizardArtworkTests {

    @Test("both rail images resolve from the resource bundle", arguments: ["wizard-day", "wizard-night"])
    func resolves(_ name: String) throws {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "ac"),
            "\(name).jpg is not in the SPM resource bundle — declare it in Package.swift")
        let data = try Data(contentsOf: url)
        #expect(data.count > 10_000, "\(name).jpg looks truncated")
        // JPEG SOI marker: catches an LFS pointer or a placeholder committed
        // in place of the real image.
        #expect(data.prefix(2) == Data([0xFF, 0xD8]), "\(name).jpg is not a JPEG")
    }

    @Test("the dark/light pair the view asks for is exactly what's bundled")
    func matchesViewLookup() throws {
        // Mirrors OnboardingWizardView.railImage: if someone renames an asset,
        // this fails rather than silently falling back to the gradient.
        for name in ["wizard-day", "wizard-night"] {
            #expect(Bundle.module.url(forResource: name, withExtension: "jpg",
                                      subdirectory: "ac") != nil)
        }
    }
}
