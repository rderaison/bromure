import Foundation
import Testing
@testable import bromure_ac

@Suite("InitProgressModel download weighting")
@MainActor
struct InitProgressModelTests {

    @Test("Download → expand → postinstall maps onto the 60/20/20 split")
    func downloadPathWeighting() {
        let m = InitProgressModel()
        m.reset()

        // (Each host message also logs a console line, nudging the bar by
        // 1/7500 — hence "near zero", not exactly zero, in these checks.)
        m.noteHostProgress("Fetching image catalog…")
        #expect(m.progress < 0.01)

        m.noteHostProgress("Downloading Ubuntu 24.04 image (2.9 GB)… 50%")
        #expect(abs(m.progress - 0.30) < 0.001)
        // The status pill carries no percentage — the bar is the only one.
        #expect(m.status == "Downloading Ubuntu 24.04 image (2.9 GB)…")

        m.noteHostProgress("Verifying checksum…")
        #expect(abs(m.progress - 0.60) < 0.001)

        m.noteHostProgress("Expanding image… 50%")
        #expect(abs(m.progress - 0.70) < 0.001)
        m.noteHostProgress("Expanding image… 100%")
        #expect(abs(m.progress - 0.80) < 0.001)

        m.noteHostProgress("Installing recommended packages (4 step(s), ~2-5 min)…")
        #expect(abs(m.progress - 0.80) < 0.001)

        // Guest-side step completions advance the last segment
        // (0.80 → 0.99 across the 4 steps).
        m.appendLog("[ac-postinstall-chroot] END   step Claude Code (Anthropic) (took 30s)\n")
        #expect(abs(m.progress - (0.80 + 0.19 / 4)) < 0.001)
        m.appendLog("[ac-postinstall-chroot] END   step Codex CLI (OpenAI) (took 20s)\n")
        m.appendLog("[ac-postinstall-chroot] END   step Grok CLI (x.ai) (took 3s)\n")
        m.appendLog("[ac-postinstall-chroot] END   step Google Cloud SDK (gcloud) (took 60s)\n")
        #expect(abs(m.progress - 0.99) < 0.001)

        m.noteHostProgress("Base image ready at /tmp/base.img (v200, Ubuntu 24.04)")
        #expect(m.progress == 1.0)
    }

    @Test("Standalone postinstall run maps its steps across the whole bar")
    func standalonePostinstall() {
        let m = InitProgressModel()
        m.reset()
        m.noteHostProgress("Installing recommended packages (2 step(s))…")
        #expect(m.progress < 0.01)
        m.appendLog("[ac-postinstall-chroot] END   step opencode (took 9s)\n")
        #expect(abs(m.progress - 0.495) < 0.01)
        m.appendLog("[ac-postinstall-chroot] END   step other (took 9s)\n")
        #expect(abs(m.progress - 0.99) < 0.001)
        m.noteHostProgress("Packages installed (base image now v200.1).")
        #expect(m.progress == 1.0)
    }

    @Test("Bar never regresses when phases interleave with line counting")
    func monotonic() {
        let m = InitProgressModel()
        m.reset()
        m.noteHostProgress("Downloading Ubuntu 24.04 image (2.9 GB)… 80%")
        #expect(abs(m.progress - 0.48) < 0.001)
        // A stale lower percentage (or plain log lines) must not move it back.
        m.noteHostProgress("Downloading Ubuntu 24.04 image (2.9 GB)… 40%")
        #expect(abs(m.progress - 0.48) < 0.001)
        m.appendLog("some log line\nanother\n")
        #expect(m.progress >= 0.48)
    }

    @Test("The Alpine netboot download doesn't move the weighted bar")
    func alpineDownloadIgnored() {
        let m = InitProgressModel()
        m.reset()
        m.noteHostProgress("Downloading Alpine netboot installer…")
        #expect(m.progress < 0.01)
    }

    @Test("Percent stripping leaves plain messages alone")
    func percentStripping() {
        #expect(InitProgressModel.strippingTrailingPercent(
            from: "Downloading X image… 7%") == "Downloading X image…")
        #expect(InitProgressModel.strippingTrailingPercent(
            from: "Verifying checksum…") == "Verifying checksum…")
        #expect(InitProgressModel.strippingTrailingPercent(from: "100%") == "")
        #expect(InitProgressModel.strippingTrailingPercent(from: "50% off") == "50% off")
    }
}

@Suite("Download fallback classification")
struct DownloadFallbackTests {

    @Test("Download-side failures allow the local-build fallback")
    func downloadSide() {
        #expect(UbuntuImageManager.isDownloadSideFailure(UbuntuImageError.catalogUnavailable))
        #expect(UbuntuImageManager.isDownloadSideFailure(UbuntuImageError.downloadFailed(404)))
        #expect(UbuntuImageManager.isDownloadSideFailure(UbuntuImageError.checksumInvalid("x")))
        #expect(UbuntuImageManager.isDownloadSideFailure(UbuntuImageError.imageExpandFailed("x")))
        #expect(UbuntuImageManager.isDownloadSideFailure(URLError(.notConnectedToInternet)))
    }

    @Test("VM-side failures, disk space, and cancellation do not")
    func vmSide() {
        // A failed postinstall step must never trigger a full local
        // rebake — the bake would hit the same VM machinery.
        #expect(!UbuntuImageManager.isDownloadSideFailure(
            UbuntuImageError.installerReportedFailure("step failed")))
        #expect(!UbuntuImageManager.isDownloadSideFailure(UbuntuImageError.installerTimeout))
        #expect(!UbuntuImageManager.isDownloadSideFailure(UbuntuImageError.noGuestNetwork))
        #expect(!UbuntuImageManager.isDownloadSideFailure(CancellationError()))
    }
}
