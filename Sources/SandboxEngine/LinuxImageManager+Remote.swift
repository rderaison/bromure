import Darwin
import Foundation
@preconcurrency import Virtualization

// MARK: - Prebuilt browser-image download + postinstall
//
// The fast path for new Bromure Web installations: instead of the ~10 min
// local Alpine/Chromium build, fetch the prebuilt free-software image the
// weekly Jenkins pipeline publishes (browser-img-catalog.json →
// browser-images/<uuid>/{base.img.gz, vmlinuz.gz, initrd.gz} on
// dl.bromure.io), verify, expand, and apply the catalog's postinstall
// steps (the non-free software — Cloudflare WARP) plus the user-machine
// personalisation (macOS fonts, keyboard/locale) in a chroot via
// vm-setup/postinstall.sh.
//
// Lives in SandboxEngine — not the browser executable — so Bromure
// Agentic Coding can drive the exact same download + postinstall when the
// user opts into the embedded web browser (AC already boots this image
// via `hasBootFiles`).

extension LinuxImageManager {

    /// Free host space required before starting a download install: the
    /// 4.5 GB raw disk (dense — the Alpine image has no big holes) + the
    /// ~1.5-2 GB compressed download living side by side, plus headroom.
    public static let minimumDownloadFreeBytes: UInt64 = 8 * 1024 * 1024 * 1024  // 8 GB

    /// User-machine personalisation applied to a downloaded image (a
    /// published build bakes neutral defaults; the local build bakes
    /// these directly in setup.sh).
    public struct Personalization: Sendable {
        public var keyboardLayout: String?
        public var naturalScrolling: Bool?
        public var locale: String?

        public init(keyboardLayout: String? = nil,
                    naturalScrolling: Bool? = nil,
                    locale: String? = nil) {
            self.keyboardLayout = keyboardLayout
            self.naturalScrolling = naturalScrolling
            self.locale = locale
        }
    }

    // MARK: - Image state

    /// Records where the installed image came from (the catalog image
    /// uuid for downloads, nil for local builds) and which postinstall
    /// step uuids have been applied. The diff between the catalog's
    /// steps and `appliedStepUUIDs` drives the "new packages are
    /// recommended" flow.
    public var imageStateURL: URL { storageDir.appendingPathComponent("image-state.json") }

    public func loadImageState() -> BaseImageState? {
        guard let data = try? Data(contentsOf: imageStateURL) else { return nil }
        return try? JSONDecoder().decode(BaseImageState.self, from: data)
    }

    /// Best-effort persist — the state is advisory (it only gates the
    /// new-steps flow, never whether the image boots), so a write failure
    /// must not fail a build that already promoted successfully.
    public func writeImageState(_ state: BaseImageState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: imageStateURL, options: .atomic)
        }
    }

    /// One-time migration for images that predate image-state.json: those
    /// were built with everything baked in by the old setup.sh (WARP
    /// included), so every step in the *bundled baseline* catalog is
    /// de-facto applied. Only steps added to the catalog later should
    /// surface as new.
    public func migrateLegacyImageStateIfNeeded(baseline: ImageCatalog = ImageDistribution.browser.loadBaseline()) {
        guard hasBootFiles, loadImageState() == nil else { return }
        let stored = (try? String(contentsOf: imageVersionURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        writeImageState(BaseImageState(
            imageUUID: nil,
            version: stored ?? Self.imageVersion,
            appliedStepUUIDs: baseline.postinstall.map(\.uuid)))
    }

    // MARK: - Failure classification

    /// True when a `downloadBaseImage` failure is download-side — the
    /// catalog fetch, the transfer itself, checksum verification, or
    /// expansion — i.e. the cases where building the image locally is a
    /// genuine remedy. VM-side failures (the postinstall boot), disk
    /// space, and cancellation return false: a local bake runs the exact
    /// same machinery, so falling back would burn ~10 minutes before
    /// failing identically.
    public static func isDownloadSideFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is ImageFetchError { return true }
        return error is URLError
    }

    // MARK: - Download install

    /// End-to-end "new installation" download. Always fetches the latest
    /// browser-img-catalog.json first, then the three artifacts it names
    /// (disk + vmlinuz + initrd, each sha256-verified). Mirrors
    /// `createBaseImage`'s crash-safety: everything lands in .partial
    /// files, the live image is only touched by the final atomic swap.
    ///
    /// The download is retried (with a fresh catalog fetch in between) up
    /// to 3 times: the weekly publish deletes the previous build's objects
    /// right after the new catalog goes live, so a client that fetched the
    /// catalog just before the switch can see its download 404/truncate —
    /// the refetch lands on the new build.
    public func downloadBaseImage(
        catalogStore: ImageCatalogStore = .browser,
        personalization: Personalization = Personalization(),
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try EphemeralDisk.checkDiskSpace(at: storageDir.path,
                                         minimumFreeBytes: Self.minimumDownloadFreeBytes)

        let scratchGz = storageDir.appendingPathComponent("linux-base.img.gz.partial")
        let scratchDisk = storageDir.appendingPathComponent("linux-base.img.partial")
        let scratchKernelGz = storageDir.appendingPathComponent("vmlinuz.gz.partial")
        let scratchKernel = storageDir.appendingPathComponent("vmlinuz.partial")
        let scratchInitrdGz = storageDir.appendingPathComponent("initrd.gz.partial")
        let scratchInitrd = storageDir.appendingPathComponent("initrd.partial")
        let scratches = [scratchGz, scratchDisk, scratchKernelGz,
                         scratchKernel, scratchInitrdGz, scratchInitrd]

        let hadCompletePriorImage = hasBootFiles
        let text: (String) -> Void = { progress(.message($0)) }

        do {
            // 1. Catalog + artifacts, with the delete-race retry loop.
            var catalog: ImageCatalog?
            var lastError: Error = ImageFetchError.catalogUnavailable
            for attempt in 1...3 {
                if attempt > 1 { text("Retrying download (attempt \(attempt)/3)…") }
                text("Fetching image catalog…")
                guard let fetched = await catalogStore.refresh(),
                      let image = fetched.image else {
                    lastError = ImageFetchError.catalogUnavailable
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                do {
                    try await fetchArtifacts(
                        image: image,
                        scratchGz: scratchGz, scratchDisk: scratchDisk,
                        scratchKernelGz: scratchKernelGz, scratchKernel: scratchKernel,
                        scratchInitrdGz: scratchInitrdGz, scratchInitrd: scratchInitrd,
                        progress: progress
                    )
                    catalog = fetched
                    break
                } catch {
                    lastError = error
                    for f in scratches { try? fm.removeItem(at: f) }
                }
            }
            guard let catalog, let image = catalog.image else { throw lastError }

            // 2. Postinstall: every catalog step, unprompted — the setup
            //    screen the user clicked through is the consent for the
            //    initial set. Runs even with zero steps: the same boot
            //    also copies the user's macOS fonts, applies their
            //    keyboard/locale, and e2fsck-gates the downloaded image
            //    before promotion.
            let steps = catalog.sortedSteps
            progress(.stepStart("Personalizing image"))
            // The step count lets progress UIs weight the postinstall
            // segment (they watch for "…(N step(s))…" + the guest's
            // per-step BEGIN/END markers).
            text(steps.isEmpty
                ? "Personalizing image (fonts, keyboard, locale)…"
                : "Installing recommended packages (\(steps.count) step(s)) and personalizing…")
            try await runPostinstall(
                steps: steps,
                targetDisk: scratchDisk,
                copyFonts: true,
                personalize: personalization,
                progress: progress
            )
            progress(.stepDone("Personalizing image"))

            // 3. Promote all three artifacts, then stamp. The stamp is
            //    the app's own imageVersion constant — not the catalog's
            //    version — so the freshly installed image can never look
            //    stale to `baseImageExists` (the catalog's exact version,
            //    which may lead or lag the constant around release week,
            //    is recorded in image-state.json instead).
            try? fm.removeItem(at: linuxDiskURL)
            try fm.moveItem(at: scratchDisk, to: linuxDiskURL)
            try? fm.removeItem(at: linuxKernelURL)
            try fm.moveItem(at: scratchKernel, to: linuxKernelURL)
            try? fm.removeItem(at: linuxInitrdURL)
            try fm.moveItem(at: scratchInitrd, to: linuxInitrdURL)
            try Self.imageVersion.write(to: imageVersionURL, atomically: true, encoding: .utf8)
            writeImageState(BaseImageState(
                imageUUID: image.uuid,
                version: image.version,
                appliedStepUUIDs: steps.map(\.uuid)))

            text("Base image ready at \(linuxDiskURL.path) (\(image.description))")
        } catch {
            for f in scratches { try? fm.removeItem(at: f) }
            if !hadCompletePriorImage {
                try? fm.removeItem(at: linuxDiskURL)
                try? fm.removeItem(at: linuxKernelURL)
                try? fm.removeItem(at: linuxInitrdURL)
                try? fm.removeItem(at: imageVersionURL)
                try? fm.removeItem(at: imageStateURL)
            }
            throw error
        }
    }

    /// Apply newly-published browser-img-catalog postinstall steps to the
    /// existing linux-base.img. Works on an APFS clone and promotes
    /// atomically, so live sessions keep a bootable image throughout.
    /// The kernel/initrd are untouched (steps run in a chroot on the root
    /// filesystem only).
    public func applyPostinstallSteps(
        _ steps: [PostinstallStep],
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        guard !steps.isEmpty else { return }
        guard hasBootFiles else {
            throw SandboxError.diskCreationFailed("no base image to amend")
        }
        let fm = FileManager.default
        try EphemeralDisk.checkDiskSpace(at: storageDir.path,
                                         minimumFreeBytes: Self.minimumDownloadFreeBytes)

        let scratchDisk = storageDir.appendingPathComponent("linux-base.img.partial")
        try? fm.removeItem(at: scratchDisk)
        // clonefile(2): instant CoW copy; only diverged blocks cost space.
        if clonefile(linuxDiskURL.path, scratchDisk.path, 0) != 0 {
            try fm.copyItem(at: linuxDiskURL, to: scratchDisk)  // non-APFS fallback
        }

        do {
            progress(.stepStart("Installing recommended packages"))
            progress(.message("Installing recommended packages (\(steps.count) step(s))…"))
            try await runPostinstall(
                steps: steps,
                targetDisk: scratchDisk,
                copyFonts: false,
                personalize: nil,
                progress: progress
            )
            progress(.stepDone("Installing recommended packages"))

            try? fm.removeItem(at: linuxDiskURL)
            try fm.moveItem(at: scratchDisk, to: linuxDiskURL)

            var state = loadImageState()
                ?? BaseImageState(imageUUID: nil, version: Self.imageVersion,
                                  appliedStepUUIDs: [])
            state.appliedStepUUIDs = (Set(state.appliedStepUUIDs)
                .union(steps.map(\.uuid))).sorted()
            writeImageState(state)
        } catch {
            try? fm.removeItem(at: scratchDisk)
            throw error
        }
    }

    // MARK: - Artifact fetch

    private func fetchArtifacts(
        image: RemoteBaseImage,
        scratchGz: URL, scratchDisk: URL,
        scratchKernelGz: URL, scratchKernel: URL,
        scratchInitrdGz: URL, scratchInitrd: URL,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        // The browser image boots via VZLinuxBootLoader — a catalog
        // without both boot artifacts is unusable, so fail the download
        // path (and let the caller fall back to a local build) rather
        // than promote an unbootable install.
        guard let kernel = image.bootFile(named: "vmlinuz"),
              let initrd = image.bootFile(named: "initrd") else {
            throw ImageFetchError.expandFailed(
                "catalog names no vmlinuz/initrd boot artifacts")
        }
        let text: (String) -> Void = { progress(.message($0)) }

        try await ImageFetch.fetchVerifiedArtifact(
            path: image.disk.path,
            sha256: image.disk.sha256,
            compression: image.disk.compression,
            compressedBytes: image.disk.compressedBytes,
            uncompressedBytes: image.disk.uncompressedBytes,
            label: "\(image.description) image",
            scratchGz: scratchGz,
            destination: scratchDisk,
            progress: text
        )
        for (file, gz, dest) in [(kernel, scratchKernelGz, scratchKernel),
                                 (initrd, scratchInitrdGz, scratchInitrd)] {
            try await ImageFetch.fetchVerifiedArtifact(
                path: file.path,
                sha256: file.sha256,
                compression: file.compression,
                compressedBytes: file.compressedBytes,
                uncompressedBytes: file.uncompressedBytes,
                label: file.name,
                scratchGz: gz,
                destination: dest,
                progress: text
            )
        }
    }

    // MARK: - Postinstall provisioner

    /// Boot the Alpine netboot installer against an already-installed
    /// browser disk and run vm-setup/postinstall.sh: chroot into the
    /// image and execute the given catalog steps, optionally copying the
    /// user's macOS fonts and applying their keyboard/locale (both
    /// needed for downloaded images — a published build carries neither).
    @MainActor
    func runPostinstall(
        steps: [PostinstallStep],
        targetDisk: URL,
        copyFonts: Bool,
        personalize: Personalization?,
        progress: @escaping (ProgressEvent) -> Void
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
        let netbootKernel = storageDir.appendingPathComponent("netboot-vmlinuz")
        let netbootInitrd = storageDir.appendingPathComponent("netboot-initramfs")
        if !fm.fileExists(atPath: netbootKernel.path) ||
           !fm.fileExists(atPath: netbootInitrd.path) {
            progress(.message("Downloading Alpine netboot installer…"))
            try await downloadNetbootFiles(
                kernelDest: netbootKernel,
                initrdDest: netbootInitrd,
                progress: progress
            )
        }

        // Script arguments. A nil personalization keeps whatever the
        // image already carries (postinstall.sh treats "-" as "skip").
        let hostConfig = VMConfig()
        let fontsArg = copyFonts ? "1" : "0"
        let personalizeArgs: String
        if let p = personalize {
            let kb = Self.shellEscape(p.keyboardLayout ?? hostConfig.keyboardLayout)
            let nat = (p.naturalScrolling ?? hostConfig.naturalScrolling) ? "true" : "false"
            let loc = Self.shellEscape(p.locale ?? hostConfig.locale)
            personalizeArgs = "\(kb) \(nat) \(loc)"
        } else {
            personalizeArgs = "- - -"
        }

        try await runProvisioner(
            netbootKernel: netbootKernel,
            netbootInitrd: netbootInitrd,
            targetDisk: targetDisk,
            command: "sh /tmp/vm-setup/postinstall.sh \(fontsArg) \(personalizeArgs)",
            stepShareDir: shareDir,
            shareFonts: copyFonts,
            successMarker: "SANDBOX_POSTINSTALL_DONE",
            failureMarker: "SANDBOX_POSTINSTALL_FAILED",
            markerTimeout: 20 * 60,
            progress: progress
        )
    }

    /// Boot the Alpine netboot with `targetDisk` attached as vda, log in
    /// over serial, mount the vm-setup share (+ postinstall steps +
    /// fonts), run `command` and wait for its marker. A lean sibling of
    /// `installLinux` — no transfer disk, no package proxy (the browser
    /// bake has never proxied), and the target disk already carries a
    /// filesystem.
    @MainActor
    private func runProvisioner(
        netbootKernel: URL,
        netbootInitrd: URL,
        targetDisk: URL,
        command: String,
        stepShareDir: URL,
        shareFonts: Bool,
        successMarker: String,
        failureMarker: String,
        markerTimeout: TimeInterval,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        let vzConfig = VZVirtualMachineConfiguration()

        // Same MTU-clamping initramfs shim as the install boot — the
        // postinstall steps download packages, so a VPN-shrunk path MTU
        // would blackhole them identically. Pinned at 1280 (the IPv6
        // minimum — safe on any path) rather than resolvedNICMTU(): the
        // postinstall VM must succeed on VPN'd hosts regardless of the
        // vm.mtu preference, and throughput barely matters for its
        // ~100 MB of downloads.
        let installerMTU = 1280
        try InitrdShim.writeShimmedInitrd(
            original: netbootInitrd,
            mtu: installerMTU,
            to: netbootInitrdShimmedURL
        )

        // Same network path as the bake (VMNetSwitch + NetworkFilter,
        // honoring vm.networkMode / vm.dnsServers) — NOT Apple's NAT.
        // The postinstall steps download packages from inside the guest,
        // so this VM needs exactly the network reliability the bake VM
        // gets; Apple's bootpd/DNS is the documented-flaky last resort.
        let (net, networkFilter, guestProxyHost) = LinuxImageManager.makeProvisionerNetwork()
        vzConfig.networkDevices = [net]
        defer {
            withExtendedLifetime(networkFilter) { networkFilter?.stop() }
        }

        // Host-side HTTP→HTTPS package proxy, exactly like the bake: the
        // netboot's modloop fetch and the chroot's package downloads
        // (apk, the pinned WARP deb) ride plain HTTP to this in-process
        // listener, which re-emits them as HTTPS through Apple's stack —
        // the proven channel on VPN'd hosts and the build server. Falls
        // back to guest-direct HTTPS when the proxy can't start or the
        // interface is bridged.
        let proxy = AlpinePackageProxy()
        var alpineRepoBase: String?
        if let host = guestProxyHost {
            do {
                try proxy.start()
                alpineRepoBase = proxy.guestBase(host: host)?.absoluteString
            } catch {
                print("[postinstall] Alpine package proxy failed to start (\(error)) — guest fetches go direct")
            }
        }
        defer { proxy.stop() }
        let repoBase = alpineRepoBase ?? "https://dl-cdn.alpinelinux.org"

        let bootLoader = VZLinuxBootLoader(kernelURL: netbootKernel)
        bootLoader.initialRamdiskURL = netbootInitrdShimmedURL
        bootLoader.commandLine = "console=hvc0 rdinit=/init.bromure alpine_repo=\(repoBase)/alpine/v\(LinuxImageManager.alpineVersion)/main modloop=\(repoBase)/alpine/v\(LinuxImageManager.alpineVersion)/releases/aarch64/netboot-\(LinuxImageManager.alpineRelease)/modloop-virt modules=loop,squashfs,virtio-net,virtio-blk"
        vzConfig.bootLoader = bootLoader

        vzConfig.platform = VZGenericPlatformConfiguration()
        vzConfig.cpuCount = max(2, ProcessInfo.processInfo.processorCount / 2)
        vzConfig.memorySize = 2 * 1024 * 1024 * 1024

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: targetDisk, readOnly: false
        )
        vzConfig.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment),
        ]

        let consolePipe = Pipe()
        let inputPipe = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: consolePipe.fileHandleForWriting
        )
        vzConfig.serialPorts = [serial]
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Shares: vm-setup (postinstall.sh + configs), the step files,
        // and — for downloaded images — the user's macOS fonts.
        guard let setupDir = Self.resourceBundle.url(forResource: "vm-setup", withExtension: nil) else {
            throw SandboxError.diskCreationFailed("vm-setup resources not found in bundle")
        }
        let setupFS = VZVirtioFileSystemDeviceConfiguration(tag: "setup")
        setupFS.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: setupDir, readOnly: true))
        let stepsFS = VZVirtioFileSystemDeviceConfiguration(tag: "postinstall")
        stepsFS.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: stepShareDir, readOnly: true))
        var shares: [VZDirectorySharingDeviceConfiguration] = [setupFS, stepsFS]
        if shareFonts {
            let fontsFS = VZVirtioFileSystemDeviceConfiguration(tag: "fonts")
            fontsFS.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(
                    url: URL(fileURLWithPath: "/System/Library/Fonts"), readOnly: true))
            shares.append(fontsFS)
            let userFontsURL = URL(fileURLWithPath: "/Library/Fonts")
            if FileManager.default.fileExists(atPath: userFontsURL.path) {
                let userFontsFS = VZVirtioFileSystemDeviceConfiguration(tag: "userfonts")
                userFontsFS.share = VZSingleDirectoryShare(
                    directory: VZSharedDirectory(url: userFontsURL, readOnly: true))
                shares.append(userFontsFS)
            }
        }
        vzConfig.directorySharingDevices = shares

        try vzConfig.validate()

        let vm = VZVirtualMachine(configuration: vzConfig)

        // Same main-thread pump as installLinux: VZ needs the real main
        // run loop serviced while we await on the main actor.
        let runLoopPump = DispatchSource.makeTimerSource(queue: .main)
        runLoopPump.schedule(deadline: .now(), repeating: .milliseconds(100))
        runLoopPump.setEventHandler {
            RunLoop.main.run(mode: .default, before: Date())
        }
        runLoopPump.resume()
        defer { runLoopPump.cancel() }

        try await vm.start()

        let consoleOutput = ConsoleBuffer()
        consolePipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                consoleOutput.append(text)
                progress(.consoleOutput(text))
                if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
                    FileHandle.standardError.write(data)
                }
            }
        }
        defer { consolePipe.fileHandleForReading.readabilityHandler = nil }

        let writer = inputPipe.fileHandleForWriting

        progress(.message("Waiting for Alpine to boot..."))
        do {
            try await consoleOutput.waitFor(
                marker: "localhost login:", timeout: 120, progress: progress,
                failMarkers: [
                    (marker: "Kernel panic", error: .diskCreationFailed(
                        "The postinstall VM crashed while booting.")),
                ]
            )

            progress(.message("Logging in..."))
            writer.write(Data("root\n".utf8))
            try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 30, progress: progress)

            // Authoritative MTU clamp via `ip link set` AFTER login (and
            // after the shim's DHCP), so whatever the lease carried, the
            // interface runs the postinstall at 1280. Same belt-and-
            // suspenders pattern as installLinux.
            writer.write(Data("NIC=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'); [ -n \"$NIC\" ] && ip link set dev \"$NIC\" mtu \(installerMTU) 2>/dev/null || true\n".utf8))
            try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 10, progress: progress)

            progress(.message("Mounting setup files via VirtioFS..."))
            writer.write(Data("modprobe virtiofs\n".utf8))
            try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 30, progress: progress)
            writer.write(Data("mkdir -p /tmp/vm-setup && mount -t virtiofs setup /tmp/vm-setup\n".utf8))
            try await consoleOutput.waitFor(marker: "localhost:~#", timeout: 60, progress: progress)

            progress(.message("Running postinstall…"))
            // ALPINE_REPO_BASE routes the chroot's package downloads
            // (apk, the pinned WARP deb) through the host proxy; unset,
            // postinstall.sh goes direct.
            let envPrefix = alpineRepoBase.map { "ALPINE_REPO_BASE='\($0)' " } ?? ""
            writer.write(Data("\(envPrefix)\(command)\n".utf8))
            try await consoleOutput.waitFor(
                marker: successMarker,
                timeout: markerTimeout,
                progress: progress,
                failMarkers: [
                    (marker: failureMarker, error: .diskCreationFailed(
                        "Postinstall failed inside the VM. Check your internet connection and try again.")),
                    (marker: "Kernel panic", error: .diskCreationFailed(
                        "The postinstall VM crashed.")),
                    (marker: "Internal error: Oops", error: .diskCreationFailed(
                        "The postinstall VM crashed.")),
                ]
            )
        } catch {
            writer.write(Data("poweroff\n".utf8))
            try? await Task.sleep(for: .seconds(2))
            if vm.state != .stopped { try? await vm.stop() }
            throw error
        }

        progress(.message("Shutting down postinstall VM..."))
        writer.write(Data("poweroff\n".utf8))
        try await Task.sleep(for: .seconds(3))
        let deadline = Date().addingTimeInterval(30)
        while vm.state != .stopped && Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        if vm.state != .stopped {
            try? await vm.stop()
        }
    }

    // MARK: - Boot verification

    /// Boot a browser disk the way a real session does (direct kernel
    /// boot via VZLinuxBootLoader) and wait for the root shell prompt on
    /// the serial console — the image's inittab auto-logs-in root on
    /// hvc0, so the prompt is proof the kernel, initramfs, root
    /// filesystem, and OpenRC all came up.
    ///
    /// The publish pipeline runs this against an APFS clone of the
    /// freshly built image with the real kernel/initrd artifacts:
    /// booting dirties the disk, and the published artifact must stay
    /// byte-identical to what was checksummed.
    @MainActor
    public func verifyImageBoots(
        diskURL: URL,
        kernelURL: URL,
        initrdURL: URL,
        timeout: TimeInterval,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        let vzConfig = VZVirtualMachineConfiguration()

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initrdURL
        // Same cmdline shape as a real session boot (buildLinuxVMConfig),
        // minus the user's extra options — the verify must gate the
        // published artifact, not the local host's tweaks.
        bootLoader.commandLine = "console=tty1 console=hvc0 root=/dev/vda rootfstype=ext4 modules=virtio_blk,virtiofs,loop,dm-crypt rw"
        vzConfig.bootLoader = bootLoader

        vzConfig.platform = VZGenericPlatformConfiguration()
        vzConfig.cpuCount = 2
        vzConfig.memorySize = 2 * 1024 * 1024 * 1024

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL, readOnly: false
        )
        vzConfig.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment),
        ]
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        vzConfig.networkDevices = [net]
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let consolePipe = Pipe()
        let inputPipe = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: consolePipe.fileHandleForWriting
        )
        vzConfig.serialPorts = [serial]

        try vzConfig.validate()
        let vm = VZVirtualMachine(configuration: vzConfig)

        let runLoopPump = DispatchSource.makeTimerSource(queue: .main)
        runLoopPump.schedule(deadline: .now(), repeating: .milliseconds(100))
        runLoopPump.setEventHandler {
            RunLoop.main.run(mode: .default, before: Date())
        }
        runLoopPump.resume()
        defer { runLoopPump.cancel() }

        try await vm.start()

        let consoleOutput = ConsoleBuffer()
        consolePipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                consoleOutput.append(text)
                progress(.consoleOutput(text))
                if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
                    FileHandle.standardError.write(data)
                }
            }
        }
        defer { consolePipe.fileHandleForReading.readabilityHandler = nil }

        progress(.message("Booting image (waiting for the root serial prompt)…"))
        do {
            // The image's inittab spawns `/bin/login -f root` on hvc0;
            // Alpine's /etc/profile sets PS1 to `\h:\w\$ `. The image
            // never configures a hostname (config-agent deliberately
            // avoids the kernel hostname), so match only the `:~#` tail —
            // it covers `localhost:~#` and `(none):~#` alike.
            try await consoleOutput.waitFor(
                marker: ":~#",
                timeout: timeout,
                progress: progress,
                failMarkers: [
                    (marker: "Kernel panic", error: .vmStartFailed(
                        "Kernel panic during boot verification.")),
                    (marker: "Internal error: Oops", error: .vmStartFailed(
                        "Guest kernel crashed during boot verification.")),
                ]
            )
        } catch {
            if vm.state != .stopped { try? await vm.stop() }
            throw error
        }

        progress(.message("Boot verified — powering off…"))
        inputPipe.fileHandleForWriting.write(Data("poweroff\n".utf8))
        let deadline = Date().addingTimeInterval(30)
        while vm.state != .stopped && Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        if vm.state != .stopped {
            try? await vm.stop()
        }
    }
}
