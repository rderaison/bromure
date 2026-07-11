import Foundation
import SandboxEngine
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

@Suite("InitProgressModel browser-image weighting")
@MainActor
struct BrowserInstallProgressTests {

    /// The full first-open flow: catalog → disk (55%) → expansion (→70%)
    /// → boot artifacts (→76%) → netboot (78%) → guest-narrated
    /// postinstall tail → ready.
    @Test("Browser download phases map onto the 55/15/6/2/guest split")
    func browserPhaseWeighting() {
        let m = InitProgressModel()
        m.reset()
        m.narrateBrowserGuestLog = true

        m.noteBrowserHostProgress("Fetching image catalog…")
        #expect(m.progress < 0.02)

        m.noteBrowserHostProgress("Downloading Alpine Linux 3.22 + Chromium image (1.5 GB)… 50%")
        #expect(abs(m.progress - 0.275) < 0.005)
        // The status pill carries no percentage — the bar is the only one.
        #expect(m.status == "Downloading Alpine Linux 3.22 + Chromium image (1.5 GB)…")

        // The sparse expander's own internal messages.
        m.noteBrowserHostProgress("Expanding image… 50%")
        #expect(abs(m.progress - 0.625) < 0.005)

        m.noteBrowserHostProgress("Downloading vmlinuz (12 MB)…")
        #expect(abs(m.progress - 0.70) < 0.005)
        m.noteBrowserHostProgress("Downloading initrd (9 MB)…")
        #expect(abs(m.progress - 0.73) < 0.005)

        m.noteBrowserHostProgress("Downloading Alpine netboot installer…")
        #expect(abs(m.progress - 0.78) < 0.005)

        // Anchors the guest-narrated tail at 0.78 (span 0.21).
        m.noteBrowserHostProgress("Installing recommended packages (1 step(s)) and personalizing…")
        #expect(abs(m.progress - 0.78) < 0.005)

        m.appendLog("[browser-postinstall] mounting installed system from /dev/vda\n")
        #expect(abs(m.progress - (0.78 + 0.21 * 0.03)) < 0.005)
        m.appendLog("[browser-postinstall] personalising: layout=us scrolling=true locale=en_US\n")
        #expect(m.status == "Personalizing (keyboard, language, fonts)…")
        m.appendLog("[browser-postinstall] copied 213 macOS font files\n")
        #expect(abs(m.progress - (0.78 + 0.21 * 0.35)) < 0.005)
        #expect(m.status.contains("213"))
        m.appendLog("[browser-postinstall] entering alpine chroot\n")
        #expect(abs(m.progress - (0.78 + 0.21 * 0.40)) < 0.005)

        m.appendLog("[browser-postinstall-chroot] BEGIN step Cloudflare WARP client\n")
        #expect(m.status == "Installing Cloudflare WARP client…")
        #expect(abs(m.progress - (0.78 + 0.21 * 0.65)) < 0.005)
        m.appendLog("[browser-postinstall-chroot] END   step Cloudflare WARP client\n")
        #expect(m.status == "Installed Cloudflare WARP client")
        #expect(abs(m.progress - (0.78 + 0.21 * 0.90)) < 0.005)

        m.appendLog("[browser-postinstall] running final e2fsck on /dev/vda\n")
        #expect(abs(m.progress - (0.78 + 0.21 * 0.95)) < 0.005)
        m.appendLog("[browser-postinstall] all done\n")
        #expect(abs(m.progress - 0.99) < 0.005)

        m.noteBrowserHostProgress("Base image ready at /tmp/linux-base.img (Alpine Linux 3.22 + Chromium)")
        #expect(m.progress == 1.0)
    }

    @Test("Personalize-only flow (no catalog steps) still narrates and completes")
    func personalizeOnly() {
        let m = InitProgressModel()
        m.reset()
        m.narrateBrowserGuestLog = true
        m.noteBrowserHostProgress("Downloading Alpine netboot installer…")
        m.noteBrowserHostProgress("Personalizing image (fonts, keyboard, locale)…")
        m.appendLog("[browser-postinstall] copied 88 macOS font files\n")
        #expect(m.progress > 0.78)
        m.appendLog("[browser-postinstall] all done\n")
        #expect(abs(m.progress - 0.99) < 0.005)
        m.noteBrowserHostProgress("Base image ready at /x (Alpine Linux 3.22 + Chromium)")
        #expect(m.progress == 1.0)
    }

    @Test("Unknown guest lines never move the bar or the pill")
    func guestNoise() {
        let m = InitProgressModel()
        m.reset()
        m.narrateBrowserGuestLog = true
        m.noteBrowserHostProgress("Downloading Alpine netboot installer…")
        let before = m.progress
        let status = m.status
        m.appendLog("random apk output line\nfetch https://dl-cdn.alpinelinux.org/x.apk\n")
        // Only the gentle per-line nudge — no phase jump, no status change.
        #expect(m.progress - before < 0.01)
        #expect(m.status == status)
    }

    @Test("reset() clears browser mode so the AC bake path is unaffected")
    func resetClearsBrowserMode() {
        let m = InitProgressModel()
        m.reset()
        m.narrateBrowserGuestLog = true
        m.expectedTotalLines = 900
        m.reset()
        #expect(m.narrateBrowserGuestLog == false)
        #expect(m.expectedTotalLines == 7500)
        // The generic END-step accounting works again after reset.
        m.noteHostProgress("Installing recommended packages (2 step(s))…")
        m.appendLog("[ac-postinstall-chroot] END   step one (took 1s)\n")
        #expect(abs(m.progress - 0.495) < 0.01)
    }

    @Test("Browser download-side failures allow the local-build fallback")
    func browserDownloadSide() {
        #expect(LinuxImageManager.isDownloadSideFailure(ImageFetchError.catalogUnavailable))
        #expect(LinuxImageManager.isDownloadSideFailure(ImageFetchError.downloadFailed(404)))
        #expect(LinuxImageManager.isDownloadSideFailure(ImageFetchError.checksumInvalid("x")))
        #expect(LinuxImageManager.isDownloadSideFailure(URLError(.notConnectedToInternet)))
        #expect(!LinuxImageManager.isDownloadSideFailure(CancellationError()))
    }
}
