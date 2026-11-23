import Foundation
import Testing
@testable import ACLinux

/// The image install's progress: macOS's setup-window accounting
/// (InitProgressModel), and the CLI's line for it.
@Suite("Install progress")
struct InstallProgressTests {
    @Test func theLocalBakeIsLineDrivenUpToTheCeiling() {
        let p = InstallProgress()
        p.appendLog(String(repeating: "x\n", count: 750))
        #expect(abs(p.progress - 0.10) < 1e-9)
        #expect(p.linesSeen == 750)
        // CR and CRLF are line ends too (the Alpine console's), counted once.
        p.appendLog("a\r\nb\rc\n")
        #expect(p.linesSeen == 753)
        // A line split across chunks counts once, when it ends.
        p.appendLog("par")
        #expect(p.linesSeen == 753)
        p.appendLog("tial\n")
        #expect(p.linesSeen == 754)
        p.appendLog(String(repeating: "x\n", count: 20_000))
        #expect(p.progress == InstallProgress.progressCeiling)
        p.noteHostProgress("Base image ready at /var/lib/bromure-ac-image/base.img (v201)")
        #expect(p.progress == 1.0)
    }

    @Test func theDownloadsPhasesMapAsOnMacOS() {
        let p = InstallProgress()
        p.noteHostProgress("Downloading Ubuntu 24.04 image (2.9 GB)… 50%")
        #expect(abs(p.progress - 0.30) < 1e-9)
        #expect(p.status == "Downloading Ubuntu 24.04 image (2.9 GB)…", "the bar shows the one percentage")
        p.noteHostProgress("Expanding image… 50%")
        #expect(abs(p.progress - 0.70) < 1e-9)
        // Never back.
        p.noteHostProgress("Downloading Ubuntu 24.04 image (2.9 GB)… 10%")
        #expect(abs(p.progress - 0.70) < 1e-9)
        // The steps share what's left: 0.70 → 0.99.
        p.noteHostProgress("Installing recommended packages (2 step(s))…")
        p.appendLog("[postinstall] END   step claude\n")
        #expect(abs(p.progress - (0.70 + 0.29 / 2)) < 1e-9)
        p.appendLog("[postinstall] END   step codex\n")
        #expect(abs(p.progress - 0.99) < 1e-9)
        p.reset()
        #expect(p.progress == 0 && p.linesSeen == 0 && p.status == "Preparing…")
    }

    @Test func percentHelpersAreMacOSs() {
        #expect(InstallProgress.trailingPercent(of: "foo 37%") == 0.37)
        #expect(InstallProgress.trailingPercent(of: "foo") == nil)
        #expect(InstallProgress.trailingPercent(of: "%") == nil)
        #expect(InstallProgress.firstInt(of: "Installing (12 step(s))…") == 12)
        #expect(InstallProgress.strippingTrailingPercent(from: "Expanding image… 45%") == "Expanding image…")
        #expect(InstallProgress.strippingTrailingPercent(from: "100%") == "100%" || InstallProgress.strippingTrailingPercent(from: "100%") == "")
        #expect(InstallProgress.strippingTrailingPercent(from: "a %") == "a %")
    }

    @Test func theCLILine() {
        let l = InstallProgress.line(progress: 0.5, elapsed: 192, status: "Installer: running setup.sh…", width: 80)
        #expect(l == "[##########..........]  50.0%  03:12  Installer: running setup.sh…")
        #expect(InstallProgress.line(progress: 1, elapsed: 3725, status: "done", width: 80)
                == "[####################] 100.0%  1:02:05  done")
        // Never wraps: one column short of the terminal.
        let narrow = InstallProgress.line(progress: 0.25, elapsed: 5, status: String(repeating: "s", count: 200), width: 40)
        #expect(narrow.count == 39 && narrow.hasPrefix("[##........]  25.0%  00:05  "))
    }
}
