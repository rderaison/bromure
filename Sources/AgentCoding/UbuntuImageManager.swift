import AppKit
import CommonCrypto
import Foundation
import SandboxEngine
@preconcurrency import Virtualization

/// Builds, downloads, and locates the Ubuntu base image for Bromure
/// Agentic Coding.
///
/// Two ways to obtain the image:
///
/// **Download (preferred)** — `downloadBaseImage` fetches the prebuilt
/// free-software image published weekly to dl.bromure.io (img-catalog.json
/// names the current build), verifies + expands it, then applies the
/// catalog's postinstall steps (Claude Code, Codex, Grok, gcloud — the
/// non-free software the published image cannot contain) in a chroot.
///
/// **Local build (fallback)** — mirrors the browser's Alpine bootstrap:
///   1. Download the Alpine netboot kernel + initramfs (small, ~25 MB).
///   2. Boot a one-shot installer VM on a fresh raw disk.
///   3. Drive the installer over its serial console: log in, mount our
///      vm-setup virtiofs share, run setup.sh.
///   4. setup.sh debootstraps Ubuntu Noble onto the disk, installs the
///      free-software tooling (node, kitty, docker, cloud CLIs…), and
///      grub-installs for EFI boot.
///   5. Apply the img-catalog postinstall steps (same chroot mechanism
///      as the download path, via postinstall.sh).
///   6. On completion, promote the disk to base.img.
///
/// The runtime VM (UbuntuSandboxVM) boots base.img directly via
/// VZEFIBootLoader — no kernel extraction needed because GRUB is on the
/// disk's EFI partition.
public final class UbuntuImageManager {
    /// Bump to force a base-image rebuild on next launch.
    /// **NEVER bump this without explicit user approval** — base-image
    /// rebuilds cost the user ~5 minutes of install time. Prefer landing
    /// changes in host-side managed dotfiles (~/.bashrc, ~/.xinitrc via
    /// Profile.prepareHomeDirectory) which apply on the next launch with
    /// no rebuild.
    ///
    /// Bumped to 27 (with explicit approval) to add xdotool +
    /// x11-xserver-utils to the apt install for native tab switching
    /// and the resize watcher.
    /// Bumped to 28 (with explicit approval) to add `gh` (GitHub CLI)
    /// and `glab` (GitLab CLI) so HTTPS-token profiles get a working
    /// `gh` / `glab` out of the box without an extra `auth login` step.
    /// Bumped to 29 (with explicit approval) to install codex via the
    /// official Rust binary release from github.com/openai/codex
    /// instead of the flaky npm postinstall path.
    /// Bumped to 30 (with explicit approval) to run apt-get
    /// dist-upgrade after the initial bootstrap — the base image now
    /// ships with every security/bug fix that landed since the noble
    /// release, so `apt upgrade` in the user's VM is a no-op on day 1.
    /// Bumped to 31 (with explicit approval) to bake in the cloud
    /// CLIs needed for the Credentials → Cloud sections to work
    /// out of the box: kubectl, doctl, awscli v2, gcloud, az.
    public static let imageVersion = "200"

    /// Ubuntu LTS release we target. Update when a new LTS lands.
    public static let ubuntuRelease = "noble"
    /// Human name for `ubuntuRelease` — surfaces in img-catalog.json's
    /// image description and the setup UI. Keep the two in sync.
    public static let imageDescription = "Ubuntu 24.04"

    /// Default size of the raw target disk. Roomy because rust toolchains,
    /// node_modules, model caches and project clones all want space.
    public static let baseDiskBytes: UInt64 = 24 * 1024 * 1024 * 1024  // 24 GB
    /// Free host space required before starting a base-image build. The
    /// disk is 24 GB *sparse*; the install's physical footprint is ~6-8 GB,
    /// so 8 GB is a realistic floor that catches a near-full host without
    /// demanding the full logical size.
    public static let minimumBuildFreeBytes: UInt64 = 8 * 1024 * 1024 * 1024  // 8 GB

    public static let installerCPUs: Int = 4
    public static let installerMemoryBytes: UInt64 = 4 * 1024 * 1024 * 1024  // 4 GB

    // Alpine netboot release used as the installer environment. Kept in sync
    // with the browser image manager so we don't fork the toolchain version.
    private static let alpineVersion = "3.22"
    private static let alpineRelease = "3.22.3"
    private static var releasesBase: String {
        "https://dl-cdn.alpinelinux.org/alpine/v\(alpineVersion)/releases/aarch64"
    }

    // Internal (not private): UbuntuImageManager+Remote.swift — the
    // prebuilt-image download path — shares these.
    let storageDir: URL
    private let setupDir: URL

    public init(storageDir: URL? = nil, setupDir: URL) {
        self.storageDir = storageDir ?? Self.defaultStorageDirectory
        self.setupDir = setupDir
    }

    public static var defaultStorageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("BromureAC", isDirectory: true)
    }

    // MARK: - On-disk paths

    public var baseDiskURL: URL { storageDir.appendingPathComponent("base.img") }
    public var efiVarsURL: URL { storageDir.appendingPathComponent("efivars.bin") }
    public var versionStampURL: URL { storageDir.appendingPathComponent("base.version") }
    /// Records where the installed image came from (the img-catalog.json
    /// image uuid for downloads, nil for local builds) and which
    /// postinstall step uuids have been applied. The diff between the
    /// catalog's steps and `appliedStepUUIDs` drives the "new packages
    /// are recommended" consent prompt.
    public var imageStateURL: URL { storageDir.appendingPathComponent("image-state.json") }

    private var alpineKernelURL: URL { storageDir.appendingPathComponent("alpine-vmlinuz") }
    private var alpineInitrdURL: URL { storageDir.appendingPathComponent("alpine-initramfs") }
    /// Original Alpine initrd with a small `init.bromure` shim cpio
    /// appended. The shim clamps interface MTU in the initramfs BEFORE
    /// Alpine's `/init` fetches modloop / apkovl / APKINDEX, so a
    /// VPN-path-MTU-shrunk host doesn't blackhole the install before
    /// we ever reach the login prompt where we used to clamp.
    private var shimmedInitrdURL: URL { storageDir.appendingPathComponent("alpine-initramfs-shimmed") }

    // MARK: - Status

    /// True when the on-disk artefacts exist, regardless of version
    /// stamp. A stale image still boots — it just won't have the latest
    /// setup.sh additions. Use `baseImageNeedsUpdate` to gate a nag.
    public var hasBaseImage: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: baseDiskURL.path)
            && fm.fileExists(atPath: efiVarsURL.path)
            && fm.fileExists(atPath: versionStampURL.path)
    }

    /// True when an image is present but its **major** version is older
    /// than the app's bundled `imageVersion`. The app surfaces a
    /// non-blocking "rebuild?" prompt when this is true.
    ///
    /// Compares the major component only: a stamp like `200.3` (a manual
    /// rebuild revision of bundled major `200`) is NOT stale, so the nag
    /// stays quiet between rebuilds. Per-profile drift detection — which
    /// fires the reset prompt on `200` → `200.1` — compares the full
    /// stamp instead (see `BromureAC.startSession`), so the revision
    /// suffix still reaches existing profiles.
    public var baseImageNeedsUpdate: Bool {
        guard hasBaseImage,
              let stamp = try? String(contentsOf: versionStampURL, encoding: .utf8)
        else { return false }
        let major = Self.majorVersion(
            of: stamp.trimmingCharacters(in: .whitespacesAndNewlines))
        return major != Self.imageVersion
    }

    /// On-disk version stamp ("31", "32", …) or nil when no image.
    public var installedImageVersion: String? {
        guard let stamp = try? String(contentsOf: versionStampURL, encoding: .utf8)
        else { return nil }
        return stamp.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Versioning

    /// The major component of a version stamp — everything before the
    /// first dot. `"200"` → `"200"`, `"200.3"` → `"200"`. Used so the
    /// stale-image nag tracks the bundled `imageVersion` while ignoring
    /// the per-rebuild revision suffix.
    static func majorVersion(of stamp: String) -> String {
        String(stamp.prefix { $0 != "." })
    }

    /// The stamp to write for the image we're about to promote.
    ///
    /// A rebuild at the same major bumps a dot-revision so existing
    /// profiles (which recorded the prior stamp at clone time) detect
    /// drift and get offered a reset: `200` → `200.1` → `200.2` … A
    /// build whose major differs from what's on disk — the app shipped a
    /// new `imageVersion`, or there's no prior stamp — writes the bundled
    /// version fresh, with no revision.
    static func nextStamp(priorStamp: String?, bundled: String) -> String {
        guard let prior = priorStamp?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prior.isEmpty,
              majorVersion(of: prior) == bundled
        else { return bundled }
        // Same major — increment the revision after the first dot. A
        // bare "200" has revision 0, so the next is "200.1".
        let rev: Int
        if let dot = prior.firstIndex(of: "."),
           let n = Int(prior[prior.index(after: dot)...]) {
            rev = n
        } else {
            rev = 0
        }
        return "\(bundled).\(rev + 1)"
    }

    // MARK: - Public: build

    /// End-to-end base-image build. Idempotent: if the version stamp is
    /// current and all artefacts exist, returns immediately.
    ///
    /// `progress` receives short, human-friendly checkpoints ("Booting
    /// installer…"). `output` receives the raw, line-oriented serial
    /// stream from the installer guest (everything apt / debootstrap /
    /// setup.sh prints) — high-volume; suitable for piping straight into
    /// a console log view.
    ///
    /// `postinstallSteps` are the img-catalog.json commands to apply after
    /// the free-software install completes (Claude Code, Codex, … — see
    /// ImageCatalog). `includeMacFonts` shares the host's font dirs with
    /// the installer so they're copied into the image; the publish
    /// pipeline (init-foss-image) turns it off because Apple's
    /// fonts must not ship in the redistributable image.
    public func createBaseImage(
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void = { _ in },
        force: Bool = false,
        includeMacFonts: Bool = true,
        postinstallSteps: [PostinstallStep] = []
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)

        // Skip the build only when caller hasn't asked for force AND
        // the on-disk image is current. With `force = true`, the
        // existing image stays in place + usable; we build into
        // .partial paths and only swap the originals at the end.
        if !force, hasBaseImage && !baseImageNeedsUpdate {
            progress("Base image already at version \(Self.imageVersion).")
            return
        }

        let scratchDisk = storageDir.appendingPathComponent("base.img.partial")
        let scratchEFI = storageDir.appendingPathComponent("efivars.partial")

        // Snapshot whether a complete, bootable image was already in
        // place before this build starts. On failure we use this to
        // decide cleanup scope: if there was a working image, leave
        // it alone; if there wasn't (initial setup, or recovery from
        // a previously-failed setup), wipe every artefact so the
        // next launch can't satisfy `hasBaseImage` with fragments
        // and panic the kernel trying to boot a half-installed disk.
        let hadCompletePriorImage = hasBaseImage

        // Capture the stamp now, before the build can touch it, so the
        // promote step can derive the next revision. A rebuild at the
        // same major bumps `200` → `200.1`; a new major writes fresh.
        let priorStamp = installedImageVersion
        let newStamp = Self.nextStamp(priorStamp: priorStamp,
                                      bundled: Self.imageVersion)

        do {
            // 0. Fail fast on a near-full host. The install writes the
            //    Ubuntu rootfs + toolchains (~6-8 GB physical) into the
            //    sparse disk over ~30 min; if the host runs out of space
            //    partway, apt/debootstrap retry forever and the user sees
            //    only an unexplained timeout (the exact bug this guards).
            //    A preflight turns that into a clear "free up space" message
            //    before we boot anything; the mid-install monitor in
            //    runInstaller catches running-out later in the build.
            try EphemeralDisk.checkDiskSpace(at: storageDir.path,
                                             minimumFreeBytes: Self.minimumBuildFreeBytes)

            // 1. Alpine netboot files. Cached across runs.
            if !fm.fileExists(atPath: alpineKernelURL.path) ||
               !fm.fileExists(atPath: alpineInitrdURL.path) {
                progress("Downloading Alpine netboot installer…")
                try await downloadAlpineNetboot(progress: progress)
            } else {
                progress("Using cached Alpine netboot.")
            }

            // 2. Fresh raw target disk. Sparse — actual size on disk
            //    grows as the installer writes blocks. Goes to a
            //    .partial path so the existing base.img stays
            //    available for sessions that launch while the
            //    rebuild is in flight.
            try? fm.removeItem(at: scratchDisk)
            progress("Allocating \(Self.baseDiskBytes / (1024*1024*1024))GB sparse disk…")
            try createSparseDisk(at: scratchDisk, sizeBytes: Self.baseDiskBytes)

            // 3. Drive Alpine through the install. A guest-kernel crash
            //    (panic/Oops) mid-bake is a rare transient of VZ + the
            //    Alpine linux-virt kernel under heavy dpkg I/O — worth
            //    exactly one clean retry on a fresh disk before failing
            //    the build (setup.sh repartitions from scratch anyway,
            //    but a pristine sparse file keeps no half-written blocks).
            progress("Booting Alpine installer (this drives the Ubuntu install)…")
            do {
                try await runInstaller(
                    targetDisk: scratchDisk,
                    includeMacFonts: includeMacFonts,
                    progress: progress,
                    output: output
                )
            } catch UbuntuImageError.installerReportedFailure(let msg)
                where msg.contains("Kernel panic") || msg.contains("Internal error: Oops") {
                progress("Guest kernel crashed mid-install — retrying once on a fresh disk…")
                try? fm.removeItem(at: scratchDisk)
                try createSparseDisk(at: scratchDisk, sizeBytes: Self.baseDiskBytes)
                try await runInstaller(
                    targetDisk: scratchDisk,
                    includeMacFonts: includeMacFonts,
                    progress: progress,
                    output: output
                )
            }

            // 3b. Apply the catalog's postinstall steps (agent installs)
            //     to the still-unpromoted disk. Fonts were already copied
            //     by the installer run above (when enabled), so the
            //     postinstall boot doesn't attach the font shares again.
            if !postinstallSteps.isEmpty {
                progress("Installing recommended packages (\(postinstallSteps.count) step(s))…")
                try await runPostinstall(
                    steps: postinstallSteps,
                    targetDisk: scratchDisk,
                    includeMacFonts: false,
                    progress: progress,
                    output: output
                )
            }

            // 4. Build a fresh EFI variable store next to the existing
            //    one. First boot of the installed Ubuntu populates it
            //    with the boot entry GRUB registers. Like the disk:
            //    keep the old file in place until step 5's atomic swap.
            try? fm.removeItem(at: scratchEFI)
            _ = try VZEFIVariableStore(
                creatingVariableStoreAt: scratchEFI,
                options: []
            )

            // 5. Promote — only now do we touch the live files. Disk
            //    swap is atomic (rename); EFI vars + version stamp are
            //    individual writes that we sequence so a crash mid-step
            //    leaves the rebuild restartable from the .partial files
            //    rather than killing the running image.
            try? fm.removeItem(at: baseDiskURL)
            try fm.moveItem(at: scratchDisk, to: baseDiskURL)
            try? fm.removeItem(at: efiVarsURL)
            try fm.moveItem(at: scratchEFI, to: efiVarsURL)
            try newStamp.write(to: versionStampURL, atomically: true, encoding: .utf8)
            writeImageState(BaseImageState(
                imageUUID: nil,   // local build — no catalog uuid
                version: newStamp,
                appliedStepUUIDs: postinstallSteps.map(\.uuid)))

            progress("Base image ready at \(baseDiskURL.path) (v\(newStamp))")
        } catch {
            // Always discard scratch files — they're either incomplete
            // installs or unswapped artefacts from a successful build
            // that failed mid-promote.
            try? fm.removeItem(at: scratchDisk)
            try? fm.removeItem(at: scratchEFI)

            // No prior working image means anything currently sitting
            // at the live paths is from this (failed) run — possibly
            // just `base.img` if we crashed between the two moves in
            // step 5, possibly all three with mismatched contents.
            // Either way it can't be trusted to boot. Wipe so the next
            // launch routes back to setup with a clean slate.
            if !hadCompletePriorImage {
                try? fm.removeItem(at: baseDiskURL)
                try? fm.removeItem(at: efiVarsURL)
                try? fm.removeItem(at: versionStampURL)
                try? fm.removeItem(at: imageStateURL)
            }
            throw error
        }
    }

    // MARK: - Image state (source + applied postinstall steps)

    /// Sidecar to the version stamp: which published image build the
    /// on-disk base.img came from (nil = built locally) and which
    /// img-catalog postinstall steps have been applied to it.
    public struct BaseImageState: Codable, Sendable, Equatable {
        public var imageUUID: String?
        public var version: String
        public var appliedStepUUIDs: [String]

        public init(imageUUID: String?, version: String, appliedStepUUIDs: [String]) {
            self.imageUUID = imageUUID
            self.version = version
            self.appliedStepUUIDs = appliedStepUUIDs
        }
    }

    public func loadImageState() -> BaseImageState? {
        guard let data = try? Data(contentsOf: imageStateURL) else { return nil }
        return try? JSONDecoder().decode(BaseImageState.self, from: data)
    }

    /// Best-effort persist — the state is advisory (it only gates prompts,
    /// never whether the image boots), so a write failure must not fail a
    /// build that already promoted successfully.
    public func writeImageState(_ state: BaseImageState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: imageStateURL, options: .atomic)
        }
    }

    /// One-time migration for images that predate image-state.json: those
    /// were built with the agents baked in by the old setup.sh, so every
    /// step in the *bundled baseline* catalog is de-facto applied. Only
    /// steps added to the catalog later should prompt.
    public func migrateLegacyImageStateIfNeeded() {
        guard hasBaseImage, loadImageState() == nil else { return }
        writeImageState(BaseImageState(
            imageUUID: nil,
            version: installedImageVersion ?? Self.imageVersion,
            appliedStepUUIDs: ImageCatalog.baseline.postinstall.map(\.uuid)))
    }

    // MARK: - Alpine netboot download

    private func downloadAlpineNetboot(progress: @escaping (String) -> Void) async throws {
        let tarballName = "alpine-netboot-\(Self.alpineRelease)-aarch64.tar.gz"
        let tarballURL = URL(string: "\(Self.releasesBase)/\(tarballName)")!
        let checksumURL = URL(string: "\(Self.releasesBase)/\(tarballName).sha256")!
        let tarballDest = storageDir.appendingPathComponent(tarballName)
        let checksumDest = storageDir.appendingPathComponent("\(tarballName).sha256")

        try await Self.downloadFile(from: checksumURL, to: checksumDest)
        let checksumLine = try String(contentsOf: checksumDest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedHash = String(checksumLine.split(separator: " ").first ?? "")
        guard expectedHash.count == 64 else {
            throw UbuntuImageError.checksumInvalid("expected 64 hex chars, got \(expectedHash.count)")
        }

        try await Self.downloadFile(from: tarballURL, to: tarballDest)

        let actualHash = try Self.sha256(of: tarballDest)
        guard actualHash == expectedHash else {
            try? FileManager.default.removeItem(at: tarballDest)
            throw UbuntuImageError.checksumInvalid("\(tarballName): expected \(expectedHash), got \(actualHash)")
        }

        // Extract kernel + initramfs.
        let extractDir = storageDir.appendingPathComponent("alpine-netboot-extract")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        try Self.runHost(
            tool: "/usr/bin/tar",
            args: ["xzf", tarballDest.path,
                   "-C", extractDir.path,
                   "boot/vmlinuz-virt", "boot/initramfs-virt"]
        )

        let extractedKernel = extractDir.appendingPathComponent("boot/vmlinuz-virt")
        let extractedInitrd = extractDir.appendingPathComponent("boot/initramfs-virt")

        // The Alpine vmlinuz is an EFI PE binary wrapping a gzip'd ARM64 Image.
        // VZLinuxBootLoader needs the raw Image, so we strip the EFI wrapper.
        try? FileManager.default.removeItem(at: alpineKernelURL)
        try Self.extractRawKernel(from: extractedKernel, to: alpineKernelURL)

        try? FileManager.default.removeItem(at: alpineInitrdURL)
        try FileManager.default.moveItem(at: extractedInitrd, to: alpineInitrdURL)

        try? FileManager.default.removeItem(at: extractDir)
        try? FileManager.default.removeItem(at: tarballDest)
        try? FileManager.default.removeItem(at: checksumDest)

        progress("Alpine netboot extracted.")
    }

    // MARK: - Installer VM

    /// Boot Alpine on the target disk and drive setup.sh over the serial
    /// console — the full Ubuntu install. Resolves on SANDBOX_SETUP_DONE;
    /// throws on failure marker, guest crash, or hard timeout.
    @MainActor
    private func runInstaller(
        targetDisk: URL,
        includeMacFonts: Bool,
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void
    ) async throws {
        let scale = Self.detectDisplayScale()
        try await runProvisioner(
            targetDisk: targetDisk,
            script: "setup.sh",
            scriptArgs: "\(scale)",
            extraShares: [],
            includeMacFonts: includeMacFonts,
            successMarker: "SANDBOX_SETUP_DONE",
            failureMarker: "SANDBOX_SETUP_FAILED:",
            markerTimeout: 30 * 60,
            hardTimeout: 45 * 60,
            progress: progress,
            output: output
        )
    }

    /// Boot Alpine against an already-installed Ubuntu disk and run
    /// postinstall.sh: chroot into the image and execute the given
    /// img-catalog steps, plus the macOS font copy when enabled. Internal
    /// so the download path (UbuntuImageManager+Remote.swift) drives it too.
    @MainActor
    func runPostinstall(
        steps: [PostinstallStep],
        targetDisk: URL,
        includeMacFonts: Bool,
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void
    ) async throws {
        // Materialise the steps as NNNN-<uuid8>.sh files in a temp dir the
        // guest mounts as the `postinstall` virtiofs share; lexical order
        // is execution order. Line 1 of each file is the human description
        // postinstall.sh echoes around the run.
        let fm = FileManager.default
        let shareDir = fm.temporaryDirectory
            .appendingPathComponent("bromure-postinstall-\(UUID().uuidString)", isDirectory: true)
        let stepsDir = shareDir.appendingPathComponent("steps", isDirectory: true)
        try fm.createDirectory(at: stepsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: shareDir) }

        for step in steps.sorted(by: { ($0.seq, $0.uuid) < ($1.seq, $1.uuid) }) {
            let file = stepsDir.appendingPathComponent(
                String(format: "%04d-%@.sh", step.seq, String(step.uuid.prefix(8))))
            let title = step.description.replacingOccurrences(of: "\n", with: " ")
            let body = "# \(title)\nset -e\n\(step.command)\n"
            try body.write(to: file, atomically: true, encoding: .utf8)
        }

        // The Alpine netboot may not be cached yet — on the download path
        // this runs on a fresh machine before any local build ever did.
        if !fm.fileExists(atPath: alpineKernelURL.path) ||
           !fm.fileExists(atPath: alpineInitrdURL.path) {
            progress("Downloading Alpine netboot installer…")
            try await downloadAlpineNetboot(progress: progress)
        }

        try await runProvisioner(
            targetDisk: targetDisk,
            script: "postinstall.sh",
            scriptArgs: "",
            extraShares: [("postinstall", shareDir)],
            includeMacFonts: includeMacFonts,
            successMarker: "SANDBOX_POSTINSTALL_DONE",
            failureMarker: "SANDBOX_POSTINSTALL_FAILED:",
            markerTimeout: 20 * 60,
            hardTimeout: 30 * 60,
            progress: progress,
            output: output
        )
    }

    /// Shared Alpine provisioning driver: boot the netboot installer with
    /// `targetDisk` attached as vda, log in over serial, mount the
    /// vm-setup share (+ any `extraShares`, read-only), run
    /// `/tmp/setup/<script>` and wait for its marker.
    @MainActor
    private func runProvisioner(
        targetDisk: URL,
        script: String,
        scriptArgs: String,
        extraShares: [(tag: String, url: URL)],
        includeMacFonts: Bool,
        successMarker: String,
        failureMarker: String,
        markerTimeout: TimeInterval,
        hardTimeout: TimeInterval,
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void
    ) async throws {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = Self.installerCPUs
        config.memorySize = Self.installerMemoryBytes

        // Start the HTTP→HTTPS proxy for Alpine packages. Guest TLS
        // stacks (apk-tools' OpenSSL, busybox-wget) are unreliable
        // over some VPN / MITM setups; the host's URLSession uses
        // Apple's TLS which handles them fine. Bind first so the URL
        // is known when we build the kernel cmdline; if the bind
        // fails (extremely rare with port=0) we fall back to direct
        // HTTP, which still beats HTTPS on these VPNs.
        let proxy = AlpinePackageProxy()
        do { try proxy.start() } catch {
            FileHandle.standardError.write(Data(
                "[bake] Alpine package proxy failed to start (\(error)) — falling back to direct HTTP\n".utf8))
        }
        defer { proxy.stop() }
        let alpineRepoBase = proxy.mirrorURL?.absoluteString
            ?? "http://dl-cdn.alpinelinux.org"

        // Build (or refresh) the shimmed initrd so the MTU clamp runs
        // BEFORE Alpine's /init does its modloop / apkovl / APKINDEX
        // fetches. The Linux kernel natively supports concatenated
        // cpio archives in initramfs — files in later segments win —
        // and `rdinit=` lets us point PID 1 at our shim instead of
        // Alpine's /init. Our shim sets MTU on each ethernet-style
        // sysfs node, then exec's /init to hand control to Alpine.
        let mtu = VMConfig.resolvedNICMTU()
        try InitrdShim.writeShimmedInitrd(
            original: alpineInitrdURL,
            mtu: mtu,
            to: shimmedInitrdURL
        )

        let bootLoader = VZLinuxBootLoader(kernelURL: alpineKernelURL)
        bootLoader.initialRamdiskURL = shimmedInitrdURL
        bootLoader.commandLine = [
            "console=hvc0",
            // No `ip=dhcp` here on purpose. Kernel autoconfig races
            // vmnet's bootpd, fails, and brings eth0 down — and if
            // Alpine's /init then redoes its own DHCP after our shim
            // sets MTU, that re-DHCP path was empirically still
            // breaking the modloop / APKINDEX fetch under VPN. Our
            // shim now does the single DHCP + MTU clamp itself; with
            // no ip= on the cmdline, Alpine's /init sees the network
            // is already up and skips its own DHCP step.
            "rdinit=/init.bromure",
            // Plain HTTP through our in-process proxy. Guest's apk /
            // wget speak HTTP; the proxy speaks HTTPS upstream via
            // URLSession. Integrity is preserved at the apk layer
            // (RSA-signed packages + signed APKINDEX, keys in
            // alpine-keys which ships in our app bundle).
            "alpine_repo=\(alpineRepoBase)/alpine/v\(Self.alpineVersion)/main",
            // Same proxy handles the modloop fetch (both Alpine's
            // initramfs nlplug-findfs and the in-rootfs modloop
            // OpenRC service hit it).
            "modloop=\(alpineRepoBase)/alpine/v\(Self.alpineVersion)/releases/aarch64/netboot-\(Self.alpineRelease)/modloop-virt",
            "modules=loop,squashfs,virtio-net,virtio-blk,virtiofs",
            // Disable ARM Scalable Matrix Extension. Same option the
            // installed image's GRUB cmdline uses — without it some
            // M3+ hosts crash the guest kernel on init.
            "arm64.nosme",
        ].joined(separator: " ")
        config.bootLoader = bootLoader
        config.platform = VZGenericPlatformConfiguration()

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: targetDisk, readOnly: false
        )
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment),
        ]

        // Claim a MAC from the shared pool so the installer reuses a
        // small set of addresses instead of asking VZ for a random
        // one each bake, and so our DHCP server hands it a stable lease.
        // Makes successive bakes more reproducible (deterministic ARP /
        // NAT state on the host).
        let claimedInstallerMAC = MACAddressPool.shared.claim()
        defer {
            if let mac = claimedInstallerMAC {
                MACAddressPool.shared.release(mac)
            }
        }

        let net = VZVirtioNetworkDeviceConfiguration()
        // Attach to the process-wide software switch — same path a normal AC
        // VM takes — so the installer lands on our own DHCP/NAT segment: a
        // distinct lease that can't collide with a live AC VM, on a subnet
        // picked clear of the host's LAN. Fall back to Apple's NAT if vmnet
        // can't be brought up.
        let switchPort = VMNetSwitch.shared.attachPort()
        if let switchPort {
            net.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: switchPort)
        } else {
            net.attachment = VZNATNetworkDeviceAttachment()
        }
        defer {
            if let switchPort { VMNetSwitch.shared.detachPort(switchPort) }
        }
        if let mac = claimedInstallerMAC,
           let vzMAC = VZMACAddress(string: mac) {
            net.macAddress = vzMAC
        }
        config.networkDevices = [net]

        // VirtioFS share: setup.sh + any sibling files in vm-setup/.
        let setupFS = VZVirtioFileSystemDeviceConfiguration(tag: "setup")
        setupFS.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: setupDir, readOnly: true)
        )

        var shares: [VZDirectorySharingDeviceConfiguration] = [setupFS]

        // Share the host's macOS system + user fonts read-only so the
        // guest script can `cp -a` them into /usr/share/fonts/macos/.
        // After that, the fonts live on base.img — no runtime mount
        // needed. Skipped by the publish pipeline: Apple's fonts are not
        // redistributable and must never reach the published image.
        if includeMacFonts {
            let systemFontsURL = URL(fileURLWithPath: "/System/Library/Fonts")
            let macFontsFS = VZVirtioFileSystemDeviceConfiguration(tag: "macos-fonts")
            macFontsFS.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: systemFontsURL, readOnly: true)
            )
            shares.append(macFontsFS)

            let userFontsURL = URL(fileURLWithPath: "/Library/Fonts")
            if FileManager.default.fileExists(atPath: userFontsURL.path) {
                let userFontsFS = VZVirtioFileSystemDeviceConfiguration(tag: "macos-user-fonts")
                userFontsFS.share = VZSingleDirectoryShare(
                    directory: VZSharedDirectory(url: userFontsURL, readOnly: true)
                )
                shares.append(userFontsFS)
            }

            // Terminal.app bundles SF Mono (including "SF Mono Terminal"), which is
            // NOT in the system/user font directories above — it lives inside the
            // app bundle. Share it too so those families actually render in the
            // guest's kitty when a profile picks them.
            let terminalFontDirs = [
                "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts",
                "/Applications/Utilities/Terminal.app/Contents/Resources/Fonts",
            ]
            if let termFonts = terminalFontDirs.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                let termFontsFS = VZVirtioFileSystemDeviceConfiguration(tag: "macos-terminal-fonts")
                termFontsFS.share = VZSingleDirectoryShare(
                    directory: VZSharedDirectory(url: URL(fileURLWithPath: termFonts), readOnly: true)
                )
                shares.append(termFontsFS)
            }
        }

        // Caller-provided shares (e.g. the postinstall steps dir).
        for extra in extraShares {
            let fsDev = VZVirtioFileSystemDeviceConfiguration(tag: extra.tag)
            fsDev.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: extra.url, readOnly: true)
            )
            shares.append(fsDev)
        }
        config.directorySharingDevices = shares

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Serial: guest-side stdin (what we type into the VM) reads from
        // the read end of stdinPipe; guest stdout writes to stdoutPipe and
        // we tail it on the host.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: stdinPipe.fileHandleForReading,
            fileHandleForWriting: stdoutPipe.fileHandleForWriting
        )
        config.serialPorts = [serial]

        try config.validate()

        let vm = VZVirtualMachine(configuration: config)

        let buffer = ConsoleBuffer()
        // Tee guest serial output to stderr (for `bromure-ac init`),
        // the in-memory buffer (for marker waits), and the caller's
        // `output` callback (for the GUI's console-log view). All three
        // see the same byte stream.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            FileHandle.standardError.write(chunk)
            buffer.append(chunk)
            // `String(data:encoding:.utf8)` returns nil whenever a
            // chunk straddles a multi-byte UTF-8 codepoint at its
            // boundary — vastly common at 4 KB pipe-read sizes —
            // which silently dropped most of the install output
            // from the GUI's line counter. `String(decoding:as:)`
            // replaces invalid bytes with U+FFFD instead, so every
            // chunk gets through and lines are counted correctly.
            output(String(decoding: chunk, as: UTF8.self))
        }
        defer { stdoutPipe.fileHandleForReading.readabilityHandler = nil }

        let writer = stdinPipe.fileHandleForWriting
        let send: (String) -> Void = { writer.write(Data($0.utf8)) }

        // Race the driver against a hard timeout. We don't include a
        // stop-watcher task because the driver itself is responsible for
        // halting the VM cleanly at the end — having a watcher that throws
        // on guestDidStop would race the normal poweroff and mark a
        // successful install as a crash.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(hardTimeout) * 1_000_000_000)
                throw UbuntuImageError.installerTimeout
            }
            // Watch host free space while the guest writes the rootfs. When
            // the disk fills, the guest's apt/debootstrap writes fail and
            // retry, which otherwise surfaces only as the 30-min timeout
            // above with no explanation. Abort early with a clear diskFull
            // instead. Polled (every 10s) rather than event-driven — cheap,
            // and the build is minutes long.
            group.addTask { [storagePath = storageDir.path] in
                while true {
                    try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                    if let free = EphemeralDisk.freeBytes(at: storagePath),
                       free < EphemeralDisk.minimumFreeBytes {
                        throw SandboxError.diskFull(
                            availableMB: free / (1024 * 1024), path: storagePath)
                    }
                }
            }
            group.addTask { @MainActor in
                try await vm.start()

                progress("Waiting for Alpine login prompt…")
                try await buffer.wait(
                    for: "localhost login:",
                    timeout: 180,
                    failures: ["Kernel panic"]
                )

                progress("Logging in as root…")
                send("root\n")
                try await buffer.wait(for: "localhost:~#", timeout: 30, failures: [])

                // Probe the NIC by interface-name pattern instead of
                // "default route" — the latter only works after DHCP
                // has succeeded, and we may not have a lease yet (see
                // udhcpc retry below).
                send("NIC=$(ip -o link show | awk -F': ' '/^[0-9]+: (eth|enp|ens)/ {print $2; exit}')\n")
                try await buffer.wait(for: "localhost:~#", timeout: 10, failures: [])

                // Clamp the installer's interface MTU before any
                // download starts. VPNs (esp. WireGuard at 1420 and
                // many corporate IKEv2 tunnels) push the effective
                // path MTU below 1500 and PMTUD doesn't always
                // recover, blackholing apt/debootstrap mid-download.
                // Override via:
                //   defaults write io.bromure.agentic-coding vm.mtu -int <value>
                let mtu = VMConfig.resolvedNICMTU()
                progress("Clamping installer MTU to \(mtu)…")
                send("[ -n \"$NIC\" ] && ip link set dev \"$NIC\" mtu \(mtu) 2>/dev/null || true\n")
                try await buffer.wait(for: "localhost:~#", timeout: 10, failures: [])

                // Second-chance DHCP from userspace. Kernel-cmdline
                // `ip=dhcp` is one-shot and impatient (~30 s of
                // DHCPDISCOVERs in initramfs); if vmnet's
                // NetworkSharing daemon was slow to come up we land
                // here with the iface up but no lease, and `setup.sh`
                // would hang for ~10 min in apt before failing with a
                // confusing error. Alpine's busybox-udhcpc retries
                // and usually picks up the lease the second time the
                // host's DHCP server is ready.
                progress("Verifying DHCP lease (refresh if missing)…")
                send("if [ -n \"$NIC\" ] && ! ip -4 -o addr show dev \"$NIC\" | grep -q 'inet '; then udhcpc -i \"$NIC\" -q -n 2>/dev/null || true; fi\n")
                try await buffer.wait(for: "localhost:~#", timeout: 60, failures: [])

                // Dump the kernel cmdline + any bromure-shim kmsg
                // entries so the host serial log captures (a) whether
                // `rdinit=/init.bromure` actually reached the kernel
                // and (b) whether the shim ran. The shim's echo lines
                // go through /dev/kmsg, so dmesg has the ground truth
                // even if /dev/console output was suppressed earlier.
                send("echo '== /proc/cmdline =='; cat /proc/cmdline; echo '== dmesg | grep bromure =='; dmesg | grep -i bromure || echo '(no bromure entries found in dmesg)'\n")
                try await buffer.wait(for: "localhost:~#", timeout: 10, failures: [])

                // Echo the live MTU so the host log shows whether the
                // initramfs shim's clamp survived Alpine's userspace
                // network bring-up (Alpine's udhcpc default script
                // doesn't touch MTU, so it should). Cheap; runs once
                // per bake.
                send("[ -n \"$NIC\" ] && echo \"bromure: $NIC MTU=$(cat /sys/class/net/$NIC/mtu)\"\n")
                try await buffer.wait(for: "localhost:~#", timeout: 10, failures: [])

                // Probe distinct success / failure sentinels so the
                // driver can short-circuit BEFORE setup.sh runs —
                // saves the user from a 10+ minute apt-stalled wait
                // when vmnet's NAT path is genuinely wedged.
                send("if ip -4 -o addr show dev \"$NIC\" 2>/dev/null | grep -q 'inet '; then echo SANDBOX_NETWORK_OK; else echo SANDBOX_NO_NETWORK; fi\n")
                do {
                    try await buffer.wait(
                        for: "SANDBOX_NETWORK_OK",
                        timeout: 30,
                        failures: ["SANDBOX_NO_NETWORK"]
                    )
                } catch UbuntuImageError.installerReportedFailure(let msg)
                    where msg.contains("SANDBOX_NO_NETWORK") {
                    throw UbuntuImageError.noGuestNetwork
                }

                progress("Mounting host setup share…")
                send("modprobe virtiofs\n")
                try await buffer.wait(for: "localhost:~#", timeout: 30, failures: [])
                send("mkdir -p /tmp/setup && mount -t virtiofs setup /tmp/setup\n")
                try await buffer.wait(for: "localhost:~#", timeout: 60, failures: [])

                progress("Running \(script)…")
                // Pass the Alpine mirror URL (our proxy if it's up,
                // else direct CDN) so the guest script routes its
                // fetches via the same channel apk's main repo uses.
                send("ALPINE_REPO_BASE='\(alpineRepoBase)' sh /tmp/setup/\(script) \(scriptArgs)\n")
                // Beyond the script's own failure marker, watch for the
                // guest kernel dying (panic/Oops) — after one of those
                // the VM just hangs, and without these markers the only
                // signal would be the full markerTimeout expiring.
                try await buffer.wait(
                    for: successMarker,
                    timeout: markerTimeout,
                    failures: [failureMarker,
                               "Kernel panic",
                               "Internal error: Oops"]
                )

                progress("Powering off installer (Alpine OpenRC stop is 5-15s)…")
                send("poweroff\n")

                // Poll for clean stop, force-stop after 30s grace period.
                let deadline = Date().addingTimeInterval(30)
                while vm.state != .stopped && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if vm.state != .stopped {
                    progress("Force-stopping installer (Alpine took >30s to halt)…")
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        vm.stop(completionHandler: { _ in cont.resume() })
                    }
                }
                progress("Installer stopped cleanly.")
            }

            // Wait for the driver to finish; cancel the timeout.
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Boot verification

    /// Boot `diskURL` the way a real session does (EFI loader → GRUB on
    /// the disk's ESP) with a throwaway EFI variable store, and wait for
    /// the serial login prompt. The image's kernel cmdline carries
    /// `console=hvc0`, so systemd's getty-generator spawns
    /// serial-getty@hvc0 — its `login:` prompt is proof the disk gets
    /// through GRUB, the kernel, and systemd to multi-user.
    ///
    /// The publish pipeline runs this against an APFS clone of the
    /// freshly built image: booting dirties the disk (machine-id,
    /// journal), and the published artifact must stay byte-identical to
    /// what was checksummed.
    @MainActor
    public func verifyImageBoots(
        diskURL: URL,
        timeout: TimeInterval = 5 * 60,
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void = { _ in }
    ) async throws {
        let fm = FileManager.default
        let scratchEFI = fm.temporaryDirectory
            .appendingPathComponent("bromure-verify-efivars-\(UUID().uuidString).bin")
        let variableStore = try VZEFIVariableStore(creatingVariableStoreAt: scratchEFI, options: [])
        defer { try? fm.removeItem(at: scratchEFI) }

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = Self.installerCPUs
        config.memorySize = Self.installerMemoryBytes
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = variableStore
        config.bootLoader = bootLoader
        config.platform = VZGenericPlatformConfiguration()
        // No network device on purpose: every network mount/unit in the
        // image is nofail/non-blocking, so boot must reach the login
        // prompt fully offline — a stronger check than one that could
        // hide a boot-blocking network dependency behind CI's DHCP.
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL, readOnly: false
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: stdinPipe.fileHandleForReading,
            fileHandleForWriting: stdoutPipe.fileHandleForWriting
        )
        config.serialPorts = [serial]
        try config.validate()

        let vm = VZVirtualMachine(configuration: config)
        let buffer = ConsoleBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            FileHandle.standardError.write(chunk)
            buffer.append(chunk)
            output(String(decoding: chunk, as: UTF8.self))
        }
        defer { stdoutPipe.fileHandleForReading.readabilityHandler = nil }

        progress("Booting image for verification…")
        try await vm.start()
        do {
            // "contains a file system with errors": the image left the
            // bake with the ext4 error flag set. setup.sh/postinstall.sh
            // run a final e2fsck that clears (or fails on) it, so seeing
            // this at boot means the artifact under test is damaged —
            // reject it even though fsck would likely repair and boot.
            try await buffer.wait(
                for: "login:",
                timeout: timeout,
                failures: ["Kernel panic", "grub rescue", "GRUB rescue",
                           "contains a file system with errors"]
            )
        } catch {
            await Self.forceStop(vm)
            throw error
        }
        progress("Image booted to the login prompt — OK.")
        await Self.forceStop(vm)
    }

    @MainActor
    private static func forceStop(_ vm: VZVirtualMachine) async {
        guard vm.state != .stopped else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            vm.stop(completionHandler: { _ in cont.resume() })
        }
    }

    // MARK: - Disk + binary helpers

    private func createSparseDisk(at url: URL, sizeBytes: UInt64) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw UbuntuImageError.hostCommandFailed("open", Int32(errno))
        }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else {
            throw UbuntuImageError.hostCommandFailed("ftruncate", Int32(errno))
        }
    }

    /// Strip the EFI PE wrapper off Alpine's vmlinuz-virt to get the raw
    /// arm64 Image that VZLinuxBootLoader needs. The PE wraps a gzip stream.
    private static func extractRawKernel(from efi: URL, to dest: URL) throws {
        let data = try Data(contentsOf: efi)
        let magic: [UInt8] = [0x1F, 0x8B, 0x08]

        var offset: Int?
        for i in 0..<(data.count - 3) where
            data[i] == magic[0] && data[i+1] == magic[1] && data[i+2] == magic[2] {
            offset = i
            break
        }
        guard let off = offset else {
            throw UbuntuImageError.kernelExtractionFailed("no gzip stream found")
        }

        let scratch = dest.deletingLastPathComponent().appendingPathComponent("kernel-raw.gz")
        try data[off...].write(to: scratch)

        // gunzip exits non-zero with "trailing garbage ignored" because the
        // gzip stream is followed by the rest of the PE binary. The decoded
        // output is still correct — we check for the output file rather than
        // the exit status.
        let gunzip = Process()
        gunzip.executableURL = URL(filePath: "/usr/bin/gunzip")
        gunzip.arguments = ["-f", scratch.path]
        try gunzip.run()
        gunzip.waitUntilExit()

        let raw = scratch.deletingPathExtension()
        guard FileManager.default.fileExists(atPath: raw.path) else {
            throw UbuntuImageError.kernelExtractionFailed("gunzip produced no output")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: raw, to: dest)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func downloadFile(from src: URL, to dst: URL) async throws {
        let session = URLSession(configuration: .default)
        let (tmp, response) = try await session.download(from: src)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UbuntuImageError.downloadFailed(http.statusCode)
        }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    private static func runHost(tool: String, args: [String]) throws {
        let p = Process()
        p.launchPath = tool
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw UbuntuImageError.hostCommandFailed(tool, p.terminationStatus)
        }
    }

    /// 1 on a regular display, 2 on Retina. Matches the browser's pattern
    /// — passed into setup.sh so kitty's font size scales with the host.
    @MainActor
    private static func detectDisplayScale() -> Int {
        if let screen = NSScreen.main {
            return Int(screen.backingScaleFactor)
        }
        return 2  // Apple Silicon Macs all ship Retina
    }
}

// MARK: - Console buffer

/// Append-only buffer of guest serial output that supports
/// "wait for marker / fail on alternate marker" coordination.
private final class ConsoleBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    private func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Poll the buffer until `marker` appears, throwing if any of `failures`
    /// appears first or the timeout elapses.
    func wait(
        for marker: String,
        timeout: TimeInterval,
        failures: [String]
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = text()
            if snapshot.contains(marker) {
                return
            }
            for fail in failures where snapshot.contains(fail) {
                throw UbuntuImageError.installerReportedFailure(
                    "guest reported \(fail) before \(marker)"
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw UbuntuImageError.installerTimeout
    }
}

// MARK: - Errors

public enum UbuntuImageError: LocalizedError {
    case downloadFailed(Int)
    case checksumInvalid(String)
    case kernelExtractionFailed(String)
    case hostCommandFailed(String, Int32)
    case installerReportedFailure(String)
    case installerStoppedEarly
    case installerTimeout
    /// Installer VM came up but couldn't obtain a DHCP lease from
    /// vmnet — even after the userspace udhcpc retry. The caller is
    /// expected to offer the NetworkHealer (kickstart bootpd +
    /// NetworkSharing) and retry the build.
    case noGuestNetwork
    /// img-catalog.json could not be fetched (or names no image) — the
    /// prebuilt download path can't proceed. Callers offer the local
    /// build as fallback.
    case catalogUnavailable
    /// The catalog names a compression this build doesn't implement.
    case unsupportedCompression(String)
    /// Decompressing the downloaded disk image failed or produced the
    /// wrong size.
    case imageExpandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let code):
            return String(format: NSLocalizedString("Download failed (HTTP %d).",
                comment: "Base-image build: a download returned an HTTP error"), code)
        case .checksumInvalid(let why):
            return String(format: NSLocalizedString("Checksum invalid: %@",
                comment: "Base-image build: downloaded file failed checksum"), why)
        case .kernelExtractionFailed(let why):
            return String(format: NSLocalizedString("Could not extract Alpine kernel: %@",
                comment: "Base-image build: kernel extraction failed"), why)
        case .hostCommandFailed(let tool, let code):
            return String(format: NSLocalizedString("%@ exited with status %d.",
                comment: "Base-image build: a host command failed"), tool, code)
        case .installerReportedFailure(let msg):
            return String(format: NSLocalizedString("Installer reported failure: %@",
                comment: "Base-image build: the in-VM installer reported a failure"), msg)
        case .installerStoppedEarly:
            return NSLocalizedString("Installer VM stopped before reporting completion.",
                comment: "Base-image build: installer VM stopped unexpectedly")
        case .installerTimeout:
            return NSLocalizedString("Installer timed out.",
                comment: "Base-image build: installer exceeded its time budget")
        case .noGuestNetwork:
            return NSLocalizedString("Installer VM didn't get a network address from vmnet.",
                comment: "Base-image build: installer VM has no network")
        case .catalogUnavailable:
            return NSLocalizedString("The image catalog could not be downloaded.",
                comment: "Base-image download: img-catalog.json fetch failed")
        case .unsupportedCompression(let kind):
            return String(format: NSLocalizedString("Unsupported image compression: %@",
                comment: "Base-image download: catalog names an unknown compression"), kind)
        case .imageExpandFailed(let why):
            return String(format: NSLocalizedString("Could not expand the downloaded image: %@",
                comment: "Base-image download: decompression failed"), why)
        }
    }
}
