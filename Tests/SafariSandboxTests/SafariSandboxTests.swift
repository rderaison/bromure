import Foundation
import Testing
@testable import SandboxEngine

// MARK: - VMConfig Tests

@Suite("VMConfig")
struct VMConfigTests {
    @Test("Default initializer uses sensible defaults")
    func defaultInit() {
        let config = VMConfig()
        #expect(config.cpuCount >= 2)
        #expect(config.memorySize == 4 * 1024 * 1024 * 1024)
        #expect(config.displayWidth == 1920)
        #expect(config.displayHeight == 1080)
        #expect(config.pixelsPerInch == 144)
        #expect(config.enableNetworking == true)
        #expect(config.enableAudio == true)
    }

    @Test("Custom initializer overrides all fields")
    func customInit() {
        let config = VMConfig(
            cpuCount: 8,
            memorySize: 8 * 1024 * 1024 * 1024,
            displayWidth: 2560,
            displayHeight: 1440,
            pixelsPerInch: 220,
            enableNetworking: false,
            enableAudio: false
        )
        #expect(config.cpuCount == 8)
        #expect(config.memorySize == 8 * 1024 * 1024 * 1024)
        #expect(config.displayWidth == 2560)
        #expect(config.displayHeight == 1440)
        #expect(config.pixelsPerInch == 220)
        #expect(config.enableNetworking == false)
        #expect(config.enableAudio == false)
    }

    @Test("CPU count defaults to at least 2")
    func cpuCountMinimum() {
        let config = VMConfig(cpuCount: nil)
        #expect(config.cpuCount >= 2)
    }

    @Test("Static paths are consistent within a storage directory")
    func staticPaths() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bromure-\(UUID().uuidString)")
        let baseImg = VMConfig.baseImageURL(in: dir)
        let baseAux = VMConfig.baseAuxURL(in: dir)
        let baseMeta = VMConfig.baseMetadataURL(in: dir)

        #expect(baseImg.lastPathComponent == "base.img")
        #expect(baseAux.lastPathComponent == "base-aux.img")
        #expect(baseMeta.lastPathComponent == "base.json")
        #expect(baseImg.deletingLastPathComponent().path == dir.path)
        #expect(baseAux.deletingLastPathComponent().path == dir.path)
        #expect(baseMeta.deletingLastPathComponent().path == dir.path)
    }

    @Test("Default storage directory is under Application Support")
    func defaultStorageDir() {
        let dir = VMConfig.defaultStorageDirectory
        #expect(dir.path.contains("Application Support"))
        #expect(dir.lastPathComponent == "Bromure")
    }
}

// MARK: - BaseImageMetadata Tests

@Suite("BaseImageMetadata")
struct BaseImageMetadataTests {
    @Test("Roundtrip encode/decode preserves all fields")
    func roundtrip() throws {
        let original = BaseImageMetadata(
            hardwareModelData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            machineIdentifierData: Data([0xCA, 0xFE, 0xBA, 0xBE]),
            macOSVersion: "15.2"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BaseImageMetadata.self, from: data)

        #expect(decoded.hardwareModelData == original.hardwareModelData)
        #expect(decoded.machineIdentifierData == original.machineIdentifierData)
        #expect(decoded.macOSVersion == original.macOSVersion)
        // createdAt should be close (ISO8601 may lose sub-second precision)
        #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 1.0)
    }

    @Test("Decoding invalid JSON throws")
    func invalidJSON() {
        let badData = Data("not json".utf8)
        let decoder = JSONDecoder()
        #expect(throws: (any Error).self) {
            try decoder.decode(BaseImageMetadata.self, from: badData)
        }
    }
}

// MARK: - SandboxError Tests

@Suite("SandboxError")
struct SandboxErrorTests {
    @Test("All error cases have non-empty descriptions")
    func errorDescriptions() {
        let errors: [SandboxError] = [
            .unsupportedHardware,
            .baseImageNotFound,
            .corruptMetadata("test detail"),
            .downloadFailed("test detail"),
            .diskCreationFailed("test detail"),
            .cloneFailed("test detail"),
            .vmStartFailed("test detail"),
        ]
        for error in errors {
            let desc = error.errorDescription ?? ""
            #expect(!desc.isEmpty, "Error \(error) should have a description")
        }
    }

    @Test("Error descriptions include detail strings")
    func detailsIncluded() {
        let detail = "something went wrong"
        #expect(SandboxError.corruptMetadata(detail).errorDescription!.contains(detail))
        #expect(SandboxError.downloadFailed(detail).errorDescription!.contains(detail))
        #expect(SandboxError.diskCreationFailed(detail).errorDescription!.contains(detail))
        #expect(SandboxError.cloneFailed(detail).errorDescription!.contains(detail))
        #expect(SandboxError.vmStartFailed(detail).errorDescription!.contains(detail))
    }
}

// MARK: - EphemeralDisk Tests

@Suite("EphemeralDisk")
struct EphemeralDiskTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createFakeBaseImage(in dir: URL) throws -> URL {
        let baseURL = dir.appendingPathComponent("base.img")
        // Create a small file to serve as a base image
        let data = Data(repeating: 0, count: 4096)
        try data.write(to: baseURL)
        return baseURL
    }

    @Test("Ephemeral mode uses temp directory and persist=false")
    func ephemeralMode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)

        let disk = EphemeralDisk(baseImageURL: baseURL)
        #expect(disk.persist == false)
        #expect(disk.ephemeralURL.path.contains("bromure"))
        #expect(disk.ephemeralURL.path.contains("session-"))
        #expect(disk.ephemeralAuxURL.path.contains("session-"))
        #expect(disk.ephemeralAuxURL.path.hasSuffix("-aux.img"))
    }

    @Test("Persist mode uses specified path and persist=true")
    func persistMode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)
        let persistURL = dir.appendingPathComponent("persisted.img")

        let disk = EphemeralDisk(baseImageURL: baseURL, persistAt: persistURL)
        #expect(disk.persist == true)
        #expect(disk.ephemeralURL == persistURL)
        #expect(disk.ephemeralAuxURL.lastPathComponent == "persisted.aux.img")
    }

    @Test("Create produces a CoW clone of the base image")
    func createClone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)

        let disk = EphemeralDisk(baseImageURL: baseURL)
        try disk.create()

        // Clone should exist and have the same size as the base
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: disk.ephemeralURL.path))

        let baseSize = try fm.attributesOfItem(atPath: baseURL.path)[.size] as! UInt64
        let cloneSize = try fm.attributesOfItem(atPath: disk.ephemeralURL.path)[.size] as! UInt64
        #expect(cloneSize == baseSize)

        // Clean up
        try disk.destroy()
        #expect(!fm.fileExists(atPath: disk.ephemeralURL.path))
    }

    @Test("Destroy removes ephemeral files in non-persist mode")
    func destroyNonPersist() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)

        let disk = EphemeralDisk(baseImageURL: baseURL)
        try disk.create()
        let path = disk.ephemeralURL.path

        try disk.destroy()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Destroy preserves files in persist mode")
    func destroyPersist() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)
        let persistURL = dir.appendingPathComponent("persisted.img")

        let disk = EphemeralDisk(baseImageURL: baseURL, persistAt: persistURL)
        try disk.create()

        try disk.destroy()
        // File should still exist in persist mode
        #expect(FileManager.default.fileExists(atPath: persistURL.path))

        // Clean up manually
        try? FileManager.default.removeItem(at: persistURL)
    }

    @Test("Double destroy is safe")
    func doubleDestroy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)

        let disk = EphemeralDisk(baseImageURL: baseURL)
        try disk.create()
        try disk.destroy()
        try disk.destroy() // should not throw
    }

    @Test("Create with missing base image fails")
    func createMissingBase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeBase = dir.appendingPathComponent("nonexistent.img")

        let disk = EphemeralDisk(baseImageURL: fakeBase)
        #expect(throws: SandboxError.self) {
            try disk.create()
        }
    }

    @Test("divergedBytes returns zero before creation")
    func divergedBytesBeforeCreate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)

        let disk = EphemeralDisk(baseImageURL: baseURL)
        #expect(disk.divergedBytes == 0)
    }

    @Test("Session ID creates unique ephemeral paths")
    func uniqueSessions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)

        let disk1 = EphemeralDisk(baseImageURL: baseURL, sessionID: "aaa")
        let disk2 = EphemeralDisk(baseImageURL: baseURL, sessionID: "bbb")
        #expect(disk1.ephemeralURL != disk2.ephemeralURL)
        #expect(disk1.ephemeralAuxURL != disk2.ephemeralAuxURL)
        #expect(disk1.ephemeralURL.path.contains("aaa"))
        #expect(disk2.ephemeralURL.path.contains("bbb"))
    }
}

// MARK: - BaseImageManager Tests

@Suite("BaseImageManager")
struct BaseImageManagerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("baseImageExists returns false for empty directory")
    func noBaseImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = BaseImageManager(storageDir: dir)
        #expect(manager.baseImageExists == false)
    }

    @Test("baseImageExists returns false when files are partial")
    func partialBaseImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Only create the disk image, not aux or metadata
        try Data().write(to: VMConfig.baseImageURL(in: dir))

        let manager = BaseImageManager(storageDir: dir)
        #expect(manager.baseImageExists == false)
    }

    @Test("baseImageExists returns true when all three files exist")
    func completeBaseImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: VMConfig.baseImageURL(in: dir))
        try Data().write(to: VMConfig.baseAuxURL(in: dir))
        try Data().write(to: VMConfig.baseMetadataURL(in: dir))

        let manager = BaseImageManager(storageDir: dir)
        #expect(manager.baseImageExists == true)
    }

    @Test("loadMetadata decodes saved metadata correctly")
    func loadMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let metadata = BaseImageMetadata(
            hardwareModelData: Data([1, 2, 3]),
            machineIdentifierData: Data([4, 5, 6]),
            macOSVersion: "15.0"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: VMConfig.baseMetadataURL(in: dir))

        let manager = BaseImageManager(storageDir: dir)
        let loaded = try manager.loadMetadata()
        #expect(loaded.hardwareModelData == Data([1, 2, 3]))
        #expect(loaded.machineIdentifierData == Data([4, 5, 6]))
        #expect(loaded.macOSVersion == "15.0")
    }

    @Test("loadMetadata throws for missing file")
    func loadMetadataMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = BaseImageManager(storageDir: dir)
        #expect(throws: (any Error).self) {
            try manager.loadMetadata()
        }
    }

    @Test("loadMetadata throws for corrupt JSON")
    func loadMetadataCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("not json".utf8).write(to: VMConfig.baseMetadataURL(in: dir))

        let manager = BaseImageManager(storageDir: dir)
        #expect(throws: (any Error).self) {
            try manager.loadMetadata()
        }
    }
}

// MARK: - SandboxVM State Tests

@Suite("SandboxVM State")
struct SandboxVMStateTests {
    @Test("Initial state is .created")
    func initialState() {
        let vm = SandboxVM(
            config: VMConfig(),
            storageDir: FileManager.default.temporaryDirectory
        )
        #expect(vm.state == .created)
        #expect(vm.vm == nil)
    }

    @Test("Prepare without base image throws baseImageNotFound")
    func prepareNoBase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = SandboxVM(config: VMConfig(), storageDir: dir)
        do {
            try vm.prepare()
            Issue.record("Expected prepare to throw")
        } catch let error as SandboxError {
            guard case .baseImageNotFound = error else {
                Issue.record("Expected baseImageNotFound, got \(error)")
                return
            }
        }
    }

    @Test("Start without prepare throws vmStartFailed")
    func startWithoutPrepare() async {
        let vm = SandboxVM(
            config: VMConfig(),
            storageDir: FileManager.default.temporaryDirectory
        )
        do {
            try await vm.start()
            Issue.record("Expected start to throw")
        } catch let error as SandboxError {
            if case .vmStartFailed = error {
                // expected
            } else {
                Issue.record("Expected vmStartFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("statusDescription includes state and config info")
    func statusDescription() {
        let config = VMConfig(cpuCount: 4, memorySize: 8 * 1024 * 1024 * 1024, enableNetworking: false)
        let vm = SandboxVM(config: config, storageDir: FileManager.default.temporaryDirectory)
        let desc = vm.statusDescription
        #expect(desc.contains("created"))
        #expect(desc.contains("cpus=4"))
        #expect(desc.contains("mem=8GB"))
        #expect(desc.contains("net=false"))
    }

    @Test("State enum raw values are human-readable")
    func stateRawValues() {
        #expect(SandboxVM.State.created.rawValue == "created")
        #expect(SandboxVM.State.starting.rawValue == "starting")
        #expect(SandboxVM.State.running.rawValue == "running")
        #expect(SandboxVM.State.stopped.rawValue == "stopped")
        #expect(SandboxVM.State.error.rawValue == "error")
    }

    @Test("State description matches raw value")
    func stateDescription() {
        for state in [SandboxVM.State.created, .starting, .running, .stopped, .error] {
            #expect(state.description == state.rawValue)
        }
    }

    @Test("EphemeralDisk is configured with correct base path")
    func ephemeralDiskConfig() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-dir")
        let vm = SandboxVM(config: VMConfig(), storageDir: dir)
        #expect(vm.ephemeralDisk.baseImageURL == VMConfig.baseImageURL(in: dir))
    }

    @Test("Persist mode passes through to EphemeralDisk")
    func persistMode() {
        let dir = FileManager.default.temporaryDirectory
        let persistURL = dir.appendingPathComponent("my-session.img")
        let vm = SandboxVM(config: VMConfig(), storageDir: dir, persistAt: persistURL)
        #expect(vm.ephemeralDisk.persist == true)
        #expect(vm.ephemeralDisk.ephemeralURL == persistURL)
    }
}
