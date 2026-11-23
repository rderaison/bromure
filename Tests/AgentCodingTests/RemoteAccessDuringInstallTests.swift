import Foundation
import Testing
@testable import bromure_ac

/// "Rebuilding the base image blocks the remote access": a rebuild, an image
/// update or new recommended packages stopped the SSH front door for the
/// whole build, so every fat client lost its connection -- running workspaces
/// included. The old image stays bootable until the new one is swapped in
/// whole, and a boot mid-swap is refused where every boot is.
@Suite("Remote access during a base-image install")
struct RemoteAccessDuringInstallTests {
    private static func src(_ path: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(path), encoding: .utf8)
    }

    private static func body(_ app: String, from signature: String, length: Int = 2500) throws -> String {
        let start = try #require(app.range(of: signature))
        return String(app[start.upperBound...].prefix(length))
    }

    @Test("an install keeps the server up, and starts it after only if it's down")
    func installsKeepItUp() throws {
        let app = try Self.src("Sources/AgentCoding/BromureAC.swift")
        #expect(!app.contains("SSH front door paused for base-image install"))
        for sig in ["private func startInit(force: Bool = false,", "private func startPostinstall(_ steps: [PostinstallStep]) {"] {
            let body = try Self.body(app, from: sig)
            #expect(!body.contains("stopRemoteAccess()"), "\(sig)")
            // A start restarts the server: never on a running one.
            #expect(body.contains("if !RemoteAccessServer.shared.isRunning { self.startRemoteAccessIfNeeded() }"), "\(sig)")
        }
    }

    @Test("the server waits only for a first image, not for an install in flight")
    func gate() throws {
        let app = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let start = try Self.body(app, from: "@MainActor func startRemoteAccessIfNeeded() {", length: 900)
        #expect(start.contains("guard imageManager.hasBaseImage else {"))
        #expect(!start.contains("installTask == nil"))
        #expect(app.contains("if enabled, !imageManager.hasBaseImage {"))
    }

    /// What keeps a remote boot off a half-swapped image: every VM's
    /// prepare() needs `hasBaseImage`, which a pending swap turns off.
    @Test("no boot while a new image is being swapped in")
    func swapRefusesBoots() throws {
        let vm = try Self.src("Sources/AgentCoding/UbuntuSandboxVM.swift")
        #expect(vm.contains("public func prepare() throws {\n        guard imageManager.hasBaseImage else {"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let im = UbuntuImageManager(storageDir: dir, setupDir: dir)
        for url in [im.baseDiskURL, im.efiVarsURL, im.versionStampURL] {
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        #expect(im.hasBaseImage)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".promotion.json").path, contents: Data("[]".utf8))
        #expect(!im.hasBaseImage, "mid-swap: no base to boot from")
    }
}
