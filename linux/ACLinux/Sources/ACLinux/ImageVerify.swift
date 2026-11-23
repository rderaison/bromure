import CACLinuxShims
import Foundation
import Glibc

/// The publish pipeline's gate before an image goes to the CDN (macOS:
/// `bromure-ac verify-image`): the disk is installed as a client would
/// install it, then booted offline to the login prompt. The disk under test
/// is copied first (a reflink where the filesystem has them, holes kept):
/// booting dirties a disk, and the published artifact must stay
/// byte-identical to what was checksummed.
// @port-skip linux-only: the Linux image's publish gate (macOS: VerifyImage + UbuntuImageManager.verifyImageBoots)
public enum ImageVerify {
    /// The two gates, in `workDir` (removed after): the client install (the
    /// download path's postinstall boot with no steps: DHCP, login,
    /// virtiofs, e2fsck, and the kernel and initrd copied out, which a
    /// Linux client needs to boot it at all), then the offline boot.
    // partial: the client-install gate is the Linux download's own postinstall boot (macOS's is the published provisioner, which the amd64 channel doesn't ship)
    // @port VerifyImage.run() h=7c892cfd05c6e460 @1d74379cb
    public static func verify(disk: String, version: String, workDir: String, vmSetupDir: String, cacheDir: String,
                              timeout: TimeInterval, progress: @escaping @Sendable (String) -> Void,
                              output: @escaping @Sendable (Data) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: disk) else { throw BakeError.staging("no disk image at \(disk)") }
        try? fm.removeItem(atPath: workDir)
        try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: workDir) }
        let installed = workDir + "/image"
        try fm.createDirectory(atPath: installed, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = installed + "/base.img.download"
        progress("Copying the disk under test…")
        try await ChildProcess.run("/usr/bin/cp", ["--reflink=auto", "--sparse=always", disk, copy])

        progress("Installing it as a client would (no steps)…")
        var o = InterimBake.Options(outputDir: installed, cacheDir: cacheDir, vmSetupDir: vmSetupDir,
                                    imageVersion: InterimBake.majorVersion(of: version))
        o.postinstallSteps = []
        o.downloaded = .init(disk: copy, imageUUID: "verify", version: version)
        _ = try await InterimBake.bake(o, progress: progress, output: output)

        try await verifyImageBoots(imageDir: installed, timeout: timeout, progress: progress, output: output)
    }

    /// Boots an installed image (base.img, vmlinuz, initrd.img, cmdline)
    /// with no network and requires the serial login prompt: every network
    /// mount and unit in the image is nofail, so boot must get there
    /// offline. A file system the bake left flagged with errors fails it,
    /// though fsck would likely repair it: the artifact itself is damaged.
    // partial: Firecracker's direct kernel boot (the kernel and initrd the install copied out) instead of EFI/GRUB, so no "grub rescue" can show
    // @port UbuntuImageManager.verifyImageBoots(diskURL: URL, timeout: TimeInterval, progress: @escaping(String)->Void, output: @escaping(String)->Void) h=4d1fb74f4a3948a3 @7bae22e1e
    public static func verifyImageBoots(imageDir: String, timeout: TimeInterval,
                                        progress: @escaping @Sendable (String) -> Void,
                                        output: @escaping @Sendable (Data) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let runBase = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        var tmpl = Array((runBase as NSString).appendingPathComponent("bromure-verify.XXXXXX").utf8CString)
        guard let runDirC = mkdtemp(&tmpl) else { throw MachineError.io("mkdtemp", errno) }
        let runDir = String(cString: runDirC)
        defer { try? fm.removeItem(atPath: runDir) }

        var c = try MachineConfig(name: "bromure-verify", bakedImage: imageDir, overlay: "", vsockCID: 3, runDirectory: runDir)
        c.writeBaseInPlace = true
        c.vsock = false
        c.network = .none
        c.cpus = 2
        c.memoryMiB = 2048
        var toGuest: [Int32] = [-1, -1], fromGuest: [Int32] = [-1, -1]
        guard acl_pipe_cloexec(&toGuest) == 0, acl_pipe_cloexec(&fromGuest) == 0 else {
            let e = errno
            for fd in toGuest + fromGuest where fd >= 0 { Glibc.close(fd) }
            throw MachineError.io("pipe", e)
        }
        c.consolePipes = (input: toGuest[0], output: fromGuest[1])
        c.serialLog = nil
        let console = SerialConsole(readFD: fromGuest[0], writeFD: toGuest[1], log: runDir + "/serial.log", output: output)
        defer { console.close() }
        let vm = FirecrackerMachine(config: c)
        progress("Booting image for verification…")
        try await vm.start()
        do {
            try await console.buffer.wait(for: "login:", timeout: timeout,
                                          failures: ["Kernel panic", "contains a file system with errors"])
        } catch {
            await vm.kill()
            throw error
        }
        progress("Image booted to the login prompt — OK.")
        await vm.kill()
    }
}
