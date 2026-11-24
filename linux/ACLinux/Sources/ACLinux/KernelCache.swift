import Crypto
import Foundation
import Glibc
import NIOConcurrencyHelpers

/// The guest kernel uncompressed, so Firecracker boots it as is: the image's
/// `vmlinuz` is a compressed bzImage (Ubuntu's: zstd), and its decompression,
/// before the guest's clock even starts, is ~70 ms of every boot. Firecracker
/// takes the ELF `vmlinux` inside it directly.
///
/// Extracted once per kernel into the daemon's own state (the image is
/// root's and read-only on a multi-user server), keyed by the compressed
/// kernel's sha256, so an image update is a new key. A boot never waits for
/// it: a missing one boots `vmlinuz` and has it extracted in the background
/// for the next. Anything unexpected (no decompressor, not an ELF for this
/// machine) leaves `vmlinuz`.
// @port-skip linux-only: Firecracker's kernel (macOS boots the image through EFI)
public final class KernelCache: Sendable {
    public static let shared = KernelCache()

    /// Hash by (path, size, mtime): computed once per kernel file.
    private let hashes = NIOLockedValueBox<[String: String]>([:])
    /// Keys being extracted.
    private let pending = NIOLockedValueBox<Set<String>>([])

    // @port-skip linux-only: see KernelCache
    public init() {}

    /// The kernel to boot: the uncompressed one when it's extracted, else
    /// `vmlinuz` (and its extraction started).
    // @port-skip linux-only: see KernelCache
    public func bootKernel(for vmlinuz: String, cacheDir: String) -> String {
        guard Self.extractsHere, let key = key(of: vmlinuz) else { return vmlinuz }
        let cached = cacheDir + "/\(key).vmlinux"
        if FileManager.default.isReadableFile(atPath: cached) { return cached }
        let start = pending.withLockedValue { $0.insert(key).inserted }
        if start {
            Thread.detachNewThread { [self] in
                Self.extract(vmlinuz, to: cached, cacheDir: cacheDir)
                pending.withLockedValue { _ = $0.remove(key) }
            }
        }
        return vmlinuz
    }

    /// x86_64: Firecracker boots an ELF vmlinux. (aarch64 takes an
    /// uncompressed Image instead, not handled here.)
    // @port-skip linux-only: see KernelCache
    static var extractsHere: Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }

    // @port-skip linux-only: see KernelCache
    private func key(of path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = a[.size] as? Int, let mtime = a[.modificationDate] as? Date else { return nil }
        let id = "\(path)\u{0}\(size)\u{0}\(mtime.timeIntervalSince1970)"
        if let h = hashes.withLockedValue({ $0[id] }) { return h }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        hashes.withLockedValue { $0[id] = h }
        return h
    }

    /// The compressed payload's offset and the command that decompresses it
    /// (stdin to stdout), by its magic: zstd, then xz, gzip.
    // @port-skip linux-only: see KernelCache
    static func payload(in data: Data) -> (offset: Int, command: [String])? {
        let magics: [([UInt8], [String])] = [
            ([0x28, 0xB5, 0x2F, 0xFD], ["zstd", "-dcq"]),
            ([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], ["xz", "-dcq"]),
            ([0x1F, 0x8B, 0x08], ["gzip", "-dcq"]),
        ]
        for (magic, cmd) in magics {
            if let r = data.firstRange(of: Data(magic)) { return (r.lowerBound - data.startIndex, cmd) }
        }
        return nil
    }

    /// An ELF64 executable for this machine (x86-64).
    // @port-skip linux-only: see KernelCache
    static func isBootableELF(_ head: Data) -> Bool {
        guard head.count >= 20 else { return false }
        let b = [UInt8](head.prefix(20))
        // \x7fELF, 64-bit, little endian, e_machine 62 (x86-64).
        return b[0] == 0x7F && b[1] == 0x45 && b[2] == 0x4C && b[3] == 0x46 && b[4] == 2 && b[5] == 1
            && b[18] == 62 && b[19] == 0
    }

    /// `name` on PATH (absolute), or nil.
    // @port-skip linux-only: see KernelCache
    static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // @port-skip linux-only: see KernelCache
    static func extract(_ vmlinuz: String, to cached: String, cacheDir: String) {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: vmlinuz), let (offset, command) = payload(in: data) else { return }
        try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = cached + ".partial.\(getpid())"
        defer { try? fm.removeItem(atPath: staged) }
        let input = staged + ".in"
        defer { try? fm.removeItem(atPath: input) }
        guard fm.createFile(atPath: input, contents: data.subdata(in: (data.startIndex + offset)..<data.endIndex)) else { return }
        // The decompressor exits non-zero on the bzImage's trailing bytes
        // after the stream: what counts is what came out. ChildProcess, not
        // Foundation's Process (which on Linux can lose a short child's exit).
        guard let exe = which(command[0]) else { return }
        let inFD = open(input, O_RDONLY | O_CLOEXEC)
        let outFD = open(staged, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        defer { if inFD >= 0 { close(inFD) }; if outFD >= 0 { close(outFD) } }
        guard inFD >= 0, outFD >= 0,
              let p = try? ChildProcess(name: command[0], executable: exe, arguments: Array(command.dropFirst()),
                                        logPath: nil, standardInput: inFD, standardOutput: outFD) else { return }
        do { try p.start() } catch { return }
        let done = DispatchSemaphore(value: 0)
        Task { _ = await p.waitForExit(); done.signal() }
        guard done.wait(timeout: .now() + 120) == .success else { _ = p.signal(SIGKILL); return }
        guard let h = FileHandle(forReadingAtPath: staged) else { return }
        let head = (try? h.read(upToCount: 20)) ?? Data()
        try? h.close()
        guard isBootableELF(head) else { return }
        chmod(staged, 0o644)
        guard rename(staged, cached) == 0 else { return }
        FileHandle.standardError.write(Data("bromure-ac daemon: guest kernel uncompressed for faster boots (\(cached))\n".utf8))
    }
}
