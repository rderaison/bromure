import Foundation

// MARK: - Self-contained Alpine provisioner
//
// Both prebuilt-image channels run their client-side postinstall
// (postinstall.sh: mount the image, chroot, run the catalog steps) in a
// one-shot Alpine VM. That VM used to be the Alpine netboot, which fetches
// the netboot tarball, modloop-virt, APKINDEX and alpine-base from
// dl-cdn.alpinelinux.org on every install. The publish pipelines now build
// a self-contained provisioner instead (vm-setup/build-provisioner.sh, run
// in the netboot): the netboot kernel + ONE initramfs carrying that
// kernel's modules and e2fsprogs, published next to the image as the
// catalog's `provisioner-vmlinuz` / `provisioner-initrd` boot artifacts.
// It keeps the netboot's serial contract (`localhost login:` → root →
// `localhost:~#`), so each channel's driver boots either one unchanged —
// the provisioner just gets no alpine_repo=/modloop= and fetches nothing.

/// What a one-shot provisioning VM boots.
public enum InstallerEnvironment: Sendable {
    /// Alpine netboot: fetches modloop + alpine-base from the Alpine CDN
    /// at boot. Required by the local bakes (setup.sh apk-adds its
    /// toolchain); the postinstall fallback.
    case netboot
    /// The published self-contained initramfs — no boot-time fetches.
    case provisioner(kernel: URL, initrd: URL)
}

public enum Provisioner {
    /// Catalog `boot` artifact names, and the file names the pair is
    /// cached under in a channel's storage dir.
    public static let kernelName = "provisioner-vmlinuz"
    public static let initrdName = "provisioner-initrd"

    /// SandboxEngine's vm-setup resources, home of build-provisioner.sh
    /// (shared by both channels' builders).
    public static var setupDir: URL? {
        LinuxImageManager.resourceBundle.url(forResource: "vm-setup", withExtension: nil)
    }

    /// Download + verify `image`'s provisioner boot artifacts to
    /// `kernelDest` / `initrdDest`, replacing any cached pair. Best-effort:
    /// catalogs published before the provisioner existed carry neither,
    /// and any failure leaves the caller on the netboot path. Kernel and
    /// initramfs are only valid as a pair (the modules match one
    /// `uname -r`), so the old pair is dropped before the new one lands —
    /// a missing file falls back to the netboot, a mixed pair wouldn't.
    public static func fetch(
        from image: RemoteBaseImage,
        kernelDest: URL,
        initrdDest: URL,
        progress: @escaping (String) -> Void
    ) async {
        guard let kernel = image.bootFile(named: kernelName),
              let initrd = image.bootFile(named: initrdName) else {
            return
        }
        let fm = FileManager.default
        let pairs = [(kernel, kernelDest), (initrd, initrdDest)]
        var fetched: [(partial: URL, final: URL)] = []
        do {
            for (file, dest) in pairs {
                let partial = dest.appendingPathExtension("partial")
                let gz = dest.appendingPathExtension("gz.partial")
                defer { try? fm.removeItem(at: gz) }
                try await ImageFetch.fetchVerifiedArtifact(
                    path: file.path,
                    sha256: file.sha256,
                    compression: file.compression,
                    compressedBytes: file.compressedBytes,
                    uncompressedBytes: file.uncompressedBytes,
                    label: "Alpine provisioner (\(file.name))",
                    scratchGz: gz,
                    destination: partial,
                    progress: progress
                )
                fetched.append((partial, dest))
            }
            for (_, dest) in pairs { try? fm.removeItem(at: dest) }
            for (partial, dest) in fetched {
                try fm.moveItem(at: partial, to: dest)
            }
        } catch {
            for (partial, _) in fetched { try? fm.removeItem(at: partial) }
            progress("Alpine provisioner download failed (\(error.localizedDescription)) — using the Alpine netboot instead.")
        }
    }
}
