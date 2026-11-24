import Foundation
import Testing
@testable import ACLinux

/// The uncompressed guest kernel Firecracker boots faster.
@Suite("Kernel cache", .serialized)
struct KernelCacheTests {
    @Test func theCompressedPayloadIsFoundByItsMagic() {
        let prefix = Data(repeating: 0x90, count: 100)
        #expect(KernelCache.payload(in: prefix + Data([0x28, 0xB5, 0x2F, 0xFD, 1, 2]))?.command.first == "zstd")
        #expect(KernelCache.payload(in: prefix + Data([0x28, 0xB5, 0x2F, 0xFD]))?.offset == 100)
        #expect(KernelCache.payload(in: prefix + Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]))?.command.first == "xz")
        #expect(KernelCache.payload(in: prefix + Data([0x1F, 0x8B, 0x08, 0]))?.command.first == "gzip")
        #expect(KernelCache.payload(in: prefix) == nil)
    }

    @Test func onlyAnELFForThisMachineIsBooted() {
        var elf = [UInt8](repeating: 0, count: 20)
        elf[0...5] = [0x7F, 0x45, 0x4C, 0x46, 2, 1]
        elf[18] = 62
        #expect(KernelCache.isBootableELF(Data(elf)))
        var arm = elf; arm[18] = 183
        #expect(!KernelCache.isBootableELF(Data(arm)), "aarch64 isn't this machine's")
        var elf32 = elf; elf32[4] = 1
        #expect(!KernelCache.isBootableELF(Data(elf32)))
        #expect(!KernelCache.isBootableELF(Data("ARMd".utf8)))
    }

    static let installed = "/var/lib/bromure-ac-image/vmlinuz"

    @Test(.enabled(if: FileManager.default.isReadableFile(atPath: installed) && KernelCache.which("zstd") != nil && KernelCache.extractsHere))
    func theImagesKernelIsExtractedOnceForTheNextBoot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kc-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = KernelCache()
        // First: the compressed kernel, its extraction under way.
        #expect(cache.bootKernel(for: Self.installed, cacheDir: dir) == Self.installed)
        var got = Self.installed
        for _ in 0..<100 where got == Self.installed {
            try await Task.sleep(for: .milliseconds(100))
            got = cache.bootKernel(for: Self.installed, cacheDir: dir)
        }
        #expect(got.hasPrefix(dir + "/") && got.hasSuffix(".vmlinux"), "then the uncompressed one: \(got)")
        let head = try #require(FileHandle(forReadingAtPath: got)).readData(ofLength: 20)
        #expect(KernelCache.isBootableELF(head))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == [(got as NSString).lastPathComponent], "no partial left")
    }

    @Test func somethingThatIsntAKernelStaysAsItIs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kc-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = dir + "/vmlinuz"
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: fake))
        let cache = KernelCache()
        #expect(cache.bootKernel(for: fake, cacheDir: dir + "/k") == fake)
        try await Task.sleep(for: .milliseconds(300))
        #expect(cache.bootKernel(for: fake, cacheDir: dir + "/k") == fake, "no payload: booted as is")
    }
}
