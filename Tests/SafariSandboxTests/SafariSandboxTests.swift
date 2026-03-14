import CommonCrypto
import Foundation
import Testing
@testable import SandboxEngine

// MARK: - ProfileColor Tests

@Suite("ProfileColor")
struct ProfileColorTests {
    @Test("All cases have capitalized labels")
    func labels() {
        #expect(ProfileColor.blue.label == "Blue")
        #expect(ProfileColor.red.label == "Red")
        #expect(ProfileColor.green.label == "Green")
        #expect(ProfileColor.orange.label == "Orange")
        #expect(ProfileColor.purple.label == "Purple")
        #expect(ProfileColor.pink.label == "Pink")
        #expect(ProfileColor.teal.label == "Teal")
        #expect(ProfileColor.gray.label == "Gray")
    }

    @Test("CaseIterable returns all 8 colors")
    func allCases() {
        #expect(ProfileColor.allCases.count == 8)
    }

    @Test("Codable roundtrip preserves value")
    func codable() throws {
        for color in ProfileColor.allCases {
            let data = try JSONEncoder().encode(color)
            let decoded = try JSONDecoder().decode(ProfileColor.self, from: data)
            #expect(decoded == color)
        }
    }
}

// MARK: - WebcamEffects Tests

@Suite("WebcamEffects")
struct WebcamEffectsTests {
    @Test("Default effects has no effect configured")
    func defaultEmpty() {
        let effects = WebcamEffects()
        #expect(!effects.hasAnyEffect)
        #expect(effects.cityName.isEmpty)
        #expect(effects.displayName.isEmpty)
        #expect(effects.logoPNGData == nil)
        #expect(effects.fontFamily == "Helvetica Neue")
        #expect(effects.fontSizePercent == 4.5)
    }

    @Test("hasAnyEffect detects cityName")
    func cityName() {
        var effects = WebcamEffects()
        effects.cityName = "Paris"
        #expect(effects.hasAnyEffect)
    }

    @Test("hasAnyEffect detects displayName")
    func displayName() {
        var effects = WebcamEffects()
        effects.displayName = "John Doe"
        #expect(effects.hasAnyEffect)
    }

    @Test("hasAnyEffect detects logo")
    func logo() {
        var effects = WebcamEffects()
        effects.logoPNGData = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(effects.hasAnyEffect)
    }

    @Test("Codable roundtrip preserves all fields")
    func codable() throws {
        var effects = WebcamEffects()
        effects.cityName = "New York"
        effects.timeZoneIdentifier = "America/New_York"
        effects.displayName = "Jane"
        effects.logoPNGData = Data([1, 2, 3])
        effects.fontFamily = "SF Pro"
        effects.fontSizePercent = 6.0

        let data = try JSONEncoder().encode(effects)
        let decoded = try JSONDecoder().decode(WebcamEffects.self, from: data)
        #expect(decoded == effects)
    }
}

// MARK: - ProfileSettings Tests

@Suite("ProfileSettings", .serialized)
struct ProfileSettingsTests {
    @Test("Defaults are sensible")
    func defaults() {
        let s = ProfileSettings()
        #expect(s.homePage == "https://www.google.com")
        #expect(s.enableGPU == true)
        #expect(s.enableWebGL == false)
        #expect(s.enableAdBlocking == false)
        #expect(s.enableWarp == false)
        #expect(s.proxyHost.isEmpty)
        #expect(s.proxyPort == 0)
        #expect(!s.hasProxy)
        #expect(s.enableClipboardSharing == false)
        #expect(s.canUpload == false)
        #expect(s.canDownload == false)
        #expect(s.virusTotalEnabled == false)
        #expect(s.blockThreats == true)
        #expect(s.blockUnscannable == false)
        #expect(s.blockMalwareSites == false)
        #expect(s.phishingWarning == false)
        #expect(s.enableLinkSender == false)
        #expect(s.isolateFromLAN == false)
        #expect(s.restrictPorts == false)
        #expect(s.allowedPorts == "80,443")
        #expect(s.enableAudio == true)
        #expect(s.audioVolume == 100)
        #expect(s.enableWebcam == false)
        #expect(s.enableMicrophone == false)
        #expect(s.persistent == false)
        #expect(s.encryptOnDisk == false)
        #expect(s.locale == nil)
    }

    @Test("hasProxy requires both host and port")
    func hasProxy() {
        var s = ProfileSettings()
        s.proxyHost = "proxy.example.com"
        #expect(!s.hasProxy) // port still 0

        s.proxyPort = 8080
        #expect(s.hasProxy)

        s.proxyHost = ""
        #expect(!s.hasProxy) // host empty
    }

    @Test("Decoding with missing fields uses defaults")
    func backwardCompatible() throws {
        // Minimal JSON — only one field set
        let json = """
        {"homePage": "https://example.com"}
        """
        let data = Data(json.utf8)
        let s = try JSONDecoder().decode(ProfileSettings.self, from: data)
        #expect(s.homePage == "https://example.com")
        #expect(s.enableGPU == true) // default
        #expect(s.enableAudio == true) // default
        #expect(s.allowedPorts == "80,443") // default
    }

    @Test("Decoding empty JSON uses all defaults")
    func emptyJSON() throws {
        let data = Data("{}".utf8)
        let s = try JSONDecoder().decode(ProfileSettings.self, from: data)
        #expect(s == ProfileSettings())
    }

    @Test("Codable roundtrip preserves all fields")
    func roundtrip() throws {
        var s = ProfileSettings()
        s.homePage = "https://duckduckgo.com"
        s.enableGPU = false
        s.enableWebGL = true
        s.enableAdBlocking = true
        s.enableWarp = true
        s.proxyHost = "proxy.local"
        s.proxyPort = 3128
        s.proxyUsername = "user"
        s.proxyPassword = "pass"
        s.enableClipboardSharing = true
        s.canUpload = true
        s.canDownload = true
        s.virusTotalEnabled = true
        s.virusTotalAPIKey = "abc123"
        s.blockThreats = false
        s.blockUnscannable = true
        s.blockMalwareSites = true
        s.phishingWarning = true
        s.enableLinkSender = true
        s.isolateFromLAN = true
        s.restrictPorts = true
        s.allowedPorts = "80,443,8080"
        s.enableAudio = false
        s.audioVolume = 50
        s.enableWebcam = true
        s.enableMicrophone = true
        s.webcamDeviceID = "cam-1"
        s.microphoneDeviceID = "mic-1"
        s.speakerDeviceID = "spk-1"
        s.locale = "fr_FR"
        s.persistent = true
        s.encryptOnDisk = true

        let encoded = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ProfileSettings.self, from: encoded)
        #expect(decoded == s)
    }

    @Test("toVMConfig: proxy disables WARP and ad blocking")
    func proxyOverridesWarpAndAds() {
        // Set UserDefaults for this test
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "vm.memoryGB")
        defaults.removeObject(forKey: "vm.cpuCount")
        defaults.removeObject(forKey: "vm.appearance")
        defaults.removeObject(forKey: "vm.swapCmdCtrl")

        var s = ProfileSettings()
        s.enableWarp = true
        s.enableAdBlocking = true
        s.proxyHost = "proxy.example.com"
        s.proxyPort = 8080

        let config = s.toVMConfig()
        #expect(config.enableWarp == false)
        #expect(config.enableAdBlocking == false)
        #expect(config.proxyHost == "proxy.example.com")
        #expect(config.proxyPort == 8080)
    }

    @Test("toVMConfig: no proxy preserves WARP and ad blocking")
    func noProxyKeepsSettings() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "vm.memoryGB")
        defaults.removeObject(forKey: "vm.cpuCount")
        defaults.set("light", forKey: "vm.appearance")

        var s = ProfileSettings()
        s.enableWarp = true
        s.enableAdBlocking = true

        let config = s.toVMConfig()
        #expect(config.enableWarp == true)
        #expect(config.enableAdBlocking == true)
        #expect(config.proxyHost == nil)
        #expect(config.proxyPort == nil)

        defaults.removeObject(forKey: "vm.appearance")
    }

    @Test("toVMConfig: file transfer derived from upload/download flags")
    func fileTransferFlags() {
        var s = ProfileSettings()
        #expect(s.toVMConfig().enableFileTransfer == false)
        #expect(s.toVMConfig().blockDownloads == true)

        s.canUpload = true
        #expect(s.toVMConfig().enableFileTransfer == true)
        #expect(s.toVMConfig().blockDownloads == true) // still can't download

        s.canDownload = true
        #expect(s.toVMConfig().blockDownloads == false)
    }

    @Test("toVMConfig: port restriction only when enabled")
    func portRestriction() {
        var s = ProfileSettings()
        s.allowedPorts = "80,443,8080"

        // restrictPorts is false, so allowedPorts should be nil in config
        #expect(s.toVMConfig().allowedPorts == nil)

        s.restrictPorts = true
        #expect(s.toVMConfig().allowedPorts == "80,443,8080")
    }

    @Test("toVMConfig: proxy credentials only when proxy is configured")
    func proxyCredentials() {
        var s = ProfileSettings()
        s.proxyUsername = "user"
        s.proxyPassword = "pass"

        // No proxy host/port → credentials should not appear in config
        let noProxy = s.toVMConfig()
        #expect(noProxy.proxyUsername == nil)
        #expect(noProxy.proxyPassword == nil)

        s.proxyHost = "proxy.local"
        s.proxyPort = 3128
        let withProxy = s.toVMConfig()
        #expect(withProxy.proxyUsername == "user")
        #expect(withProxy.proxyPassword == "pass")
    }

    @Test("toVMConfig: explicit dark/light appearance respected")
    func appearancePref() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "vm.appearance")
        defer {
            if let v = original { defaults.set(v, forKey: "vm.appearance") }
            else { defaults.removeObject(forKey: "vm.appearance") }
        }

        defaults.set("dark", forKey: "vm.appearance")
        defaults.synchronize()
        #expect(ProfileSettings().toVMConfig().forceDarkMode == true)

        defaults.set("light", forKey: "vm.appearance")
        defaults.synchronize()
        #expect(ProfileSettings().toVMConfig().forceDarkMode == false)

        // "system" falls through to detectDarkMode() — just verify it doesn't crash
        defaults.set("system", forKey: "vm.appearance")
        defaults.synchronize()
        _ = ProfileSettings().toVMConfig().forceDarkMode
    }

    @Test("toVMConfig: root CAs PEM strings extracted")
    func rootCAs() {
        var s = ProfileSettings()
        s.rootCAs = [
            CustomRootCA(name: "My CA", pem: "-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----"),
            CustomRootCA(name: "Other CA", pem: "-----BEGIN CERTIFICATE-----\nXYZ\n-----END CERTIFICATE-----"),
        ]
        let config = s.toVMConfig()
        #expect(config.rootCAs.count == 2)
        #expect(config.rootCAs[0].contains("ABC"))
        #expect(config.rootCAs[1].contains("XYZ"))
    }
}

// MARK: - Profile Tests

@Suite("Profile")
struct ProfileTests {
    @Test("Init sets ID, name, and defaults")
    func basicInit() {
        let p = Profile(name: "Test")
        #expect(p.name == "Test")
        #expect(p.comments.isEmpty)
        #expect(p.color == .blue)
        #expect(!p.isPersistent)
        #expect(!p.isEncrypted)
        #expect(p.lastUsedAt == nil)
    }

    @Test("isPersistent reflects settings.persistent")
    func isPersistent() {
        var p = Profile(name: "P")
        #expect(!p.isPersistent)
        p.settings.persistent = true
        #expect(p.isPersistent)
    }

    @Test("isEncrypted requires both persistent and encryptOnDisk")
    func isEncrypted() {
        var p = Profile(name: "P")
        p.settings.persistent = true
        #expect(!p.isEncrypted)

        p.settings.encryptOnDisk = true
        #expect(p.isEncrypted)

        p.settings.persistent = false
        #expect(!p.isEncrypted)
    }

    @Test("Codable roundtrip preserves all fields")
    func roundtrip() throws {
        var p = Profile(name: "My Profile", comments: "Test notes", color: .purple)
        p.settings.homePage = "https://example.com"
        p.settings.persistent = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(p)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Profile.self, from: data)

        #expect(decoded.id == p.id)
        #expect(decoded.name == "My Profile")
        #expect(decoded.comments == "Test notes")
        #expect(decoded.color == .purple)
        #expect(decoded.settings.homePage == "https://example.com")
        #expect(decoded.isPersistent)
        #expect(abs(decoded.createdAt.timeIntervalSince(p.createdAt)) < 1.0)
    }

    @Test("Legacy isPersistent migrates to persistent + encryptOnDisk")
    func legacyMigration() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy Profile",
            "isPersistent": true,
            "settings": {}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(Profile.self, from: Data(json.utf8))

        #expect(p.name == "Legacy Profile")
        #expect(p.settings.persistent == true)
        #expect(p.settings.encryptOnDisk == true)
        #expect(p.isPersistent)
        #expect(p.isEncrypted)
    }

    @Test("Legacy isPersistent=false does not enable persistence")
    func legacyFalse() throws {
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "name": "Ephemeral",
            "isPersistent": false,
            "settings": {}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(Profile.self, from: Data(json.utf8))

        #expect(!p.isPersistent)
        #expect(!p.isEncrypted)
    }

    @Test("Missing optional fields decode to defaults")
    func minimalJSON() throws {
        let json = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "name": "Minimal"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(Profile.self, from: Data(json.utf8))

        #expect(p.name == "Minimal")
        #expect(p.comments.isEmpty)
        #expect(p.color == nil)
        #expect(p.settings == ProfileSettings())
        #expect(p.lastUsedAt == nil)
    }

    @Test("Encode does not emit legacy isPersistent key")
    func noLegacyKey() throws {
        let p = Profile(name: "New")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(p)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["isPersistent"] == nil)
    }
}

// MARK: - CustomRootCA Tests

@Suite("CustomRootCA")
struct CustomRootCATests {
    @Test("Codable roundtrip")
    func roundtrip() throws {
        let ca = CustomRootCA(name: "Corp CA", pem: "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----")
        let data = try JSONEncoder().encode(ca)
        let decoded = try JSONDecoder().decode(CustomRootCA.self, from: data)
        #expect(decoded.name == ca.name)
        #expect(decoded.pem == ca.pem)
    }
}

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
        #expect(config.enableAudio == true)
        #expect(config.audioVolume == 100)
        #expect(config.enableWarp == false)
        #expect(config.forceDarkMode == false)
        #expect(config.enableAdBlocking == false)
        #expect(config.swapCmdCtrl == true)
        #expect(config.homePage == "https://www.google.com")
        #expect(config.enableGPU == true)
        #expect(config.enableWebGL == false)
        #expect(config.blockMalwareSites == false)
        #expect(config.enableFileTransfer == false)
        #expect(config.phishingWarning == false)
        #expect(config.enableClipboardSharing == false)
        #expect(config.enableLinkSender == false)
        #expect(config.enableWebcam == false)
        #expect(config.enableMicrophone == false)
        #expect(config.isolateFromLAN == false)
        #expect(config.allowedPorts == nil)
        #expect(config.proxyHost == nil)
        #expect(config.blockDownloads == false)
    }

    @Test("Custom init overrides all fields")
    func customInit() {
        let config = VMConfig(
            cpuCount: 8,
            memorySize: 8 * 1024 * 1024 * 1024,
            displayWidth: 2560,
            displayHeight: 1440,
            pixelsPerInch: 220,
            enableAudio: false,
            audioVolume: 50,
            enableWarp: true,
            forceDarkMode: true,
            enableAdBlocking: true,
            swapCmdCtrl: false,
            homePage: "https://example.com",
            enableGPU: false,
            enableWebGL: true,
            blockMalwareSites: true,
            enableFileTransfer: true,
            phishingWarning: true,
            enableClipboardSharing: true,
            enableLinkSender: true,
            enableWebcam: true,
            enableMicrophone: true,
            isolateFromLAN: true,
            allowedPorts: "80,443",
            proxyHost: "proxy.local",
            proxyPort: 3128,
            blockDownloads: true
        )
        #expect(config.cpuCount == 8)
        #expect(config.memorySize == 8 * 1024 * 1024 * 1024)
        #expect(config.displayWidth == 2560)
        #expect(config.enableAudio == false)
        #expect(config.audioVolume == 50)
        #expect(config.enableWarp == true)
        #expect(config.forceDarkMode == true)
        #expect(config.enableAdBlocking == true)
        #expect(config.swapCmdCtrl == false)
        #expect(config.homePage == "https://example.com")
        #expect(config.enableWebGL == true)
        #expect(config.blockMalwareSites == true)
        #expect(config.enableFileTransfer == true)
        #expect(config.phishingWarning == true)
        #expect(config.isolateFromLAN == true)
        #expect(config.allowedPorts == "80,443")
        #expect(config.proxyHost == "proxy.local")
        #expect(config.proxyPort == 3128)
        #expect(config.blockDownloads == true)
    }

    @Test("CPU auto-calculation: min 2, max processorCount, scaled by memory")
    func cpuAutoCalc() {
        let cores = ProcessInfo.processInfo.processorCount

        // 1 GB → max(2, 2) = 2, capped at cores
        let c1 = VMConfig(memorySize: 1 * 1024 * 1024 * 1024)
        #expect(c1.cpuCount == min(2, cores))

        // 4 GB (default) → max(2, 8) = 8, capped at cores
        let c4 = VMConfig(memorySize: 4 * 1024 * 1024 * 1024)
        #expect(c4.cpuCount == min(8, cores))

        // 16 GB → max(2, 32) = 32, capped at cores
        let c16 = VMConfig(memorySize: 16 * 1024 * 1024 * 1024)
        #expect(c16.cpuCount == min(32, cores))

        // Explicit CPU count overrides auto-calc
        let explicit = VMConfig(cpuCount: 3, memorySize: 16 * 1024 * 1024 * 1024)
        #expect(explicit.cpuCount == 3)
    }

    @Test("Static paths are consistent within a directory")
    func staticPaths() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bromure-\(UUID().uuidString)")
        #expect(VMConfig.baseImageURL(in: dir).lastPathComponent == "base.img")
        #expect(VMConfig.baseAuxURL(in: dir).lastPathComponent == "base-aux.img")
        #expect(VMConfig.baseMetadataURL(in: dir).lastPathComponent == "base.json")
        #expect(VMConfig.baseImageURL(in: dir).deletingLastPathComponent().path == dir.path)
    }

    @Test("Default storage directory is under Application Support/Bromure")
    func defaultStorageDir() {
        let dir = VMConfig.defaultStorageDirectory
        #expect(dir.path.contains("Application Support"))
        #expect(dir.lastPathComponent == "Bromure")
    }

    @Test("savedStateURL includes guest OS name")
    func savedStateURL() {
        let dir = FileManager.default.temporaryDirectory
        #expect(VMConfig.savedStateURL(in: dir, guestOS: .linux).lastPathComponent == "linux-vm.state")
        #expect(VMConfig.savedStateURL(in: dir, guestOS: .macOS).lastPathComponent == "macOS-vm.state")
    }

    @Test("BridgedInterface displayName with localizedName")
    func bridgedDisplayWithName() {
        let iface = VMConfig.BridgedInterface(id: "en0", localizedName: "Wi-Fi")
        #expect(iface.displayName == "Wi-Fi (en0)")
    }

    @Test("BridgedInterface displayName without localizedName")
    func bridgedDisplayWithoutName() {
        let iface = VMConfig.BridgedInterface(id: "en0", localizedName: nil)
        #expect(iface.displayName == "en0")
    }

    @Test("detectDarkMode reads AppleInterfaceStyle")
    func detectDarkMode() {
        let defaults = UserDefaults.standard
        let originalValue = defaults.string(forKey: "AppleInterfaceStyle")
        defer { // restore
            if let v = originalValue { defaults.set(v, forKey: "AppleInterfaceStyle") }
            else { defaults.removeObject(forKey: "AppleInterfaceStyle") }
        }

        defaults.set("Dark", forKey: "AppleInterfaceStyle")
        #expect(VMConfig.detectDarkMode() == true)

        defaults.set("Light", forKey: "AppleInterfaceStyle")
        #expect(VMConfig.detectDarkMode() == false)

        defaults.removeObject(forKey: "AppleInterfaceStyle")
        #expect(VMConfig.detectDarkMode() == false)
    }
}

// MARK: - Locale Detection Tests

@Suite("VMConfig.detectLocale")
struct LocaleDetectionTests {
    // Note: detectLocale() reads Locale.preferredLanguages which we can't easily mock,
    // but we can test the static mapping logic by verifying known formats.
    // The function is deterministic given the system locale.

    @Test("Returns a POSIX locale format (lang_REGION)")
    func formatCheck() {
        let locale = VMConfig.detectLocale()
        #expect(locale.contains("_"))
        let parts = locale.split(separator: "_")
        #expect(parts.count == 2)
        // Language is lowercase, region is uppercase
        #expect(parts[0] == parts[0].lowercased())
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
        #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 1.0)
    }

    @Test("Decoding invalid JSON throws")
    func invalidJSON() {
        let badData = Data("not json".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BaseImageMetadata.self, from: badData)
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
            .corruptMetadata("test"),
            .downloadFailed("test"),
            .diskCreationFailed("test"),
            .cloneFailed("test"),
            .vmStartFailed("test"),
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

// MARK: - GuestOS Tests

@Suite("GuestOS")
struct GuestOSTests {
    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(GuestOS.macOS.rawValue == "macOS")
        #expect(GuestOS.linux.rawValue == "linux")
    }

    @Test("CaseIterable includes both variants")
    func allCases() {
        #expect(GuestOS.allCases.count == 2)
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
        try Data(repeating: 0, count: 4096).write(to: baseURL)
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
    }

    @Test("Persist mode uses specified path")
    func persistMode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)
        let persistURL = dir.appendingPathComponent("persisted.img")

        let disk = EphemeralDisk(baseImageURL: baseURL, persistAt: persistURL)
        #expect(disk.persist == true)
        #expect(disk.ephemeralURL == persistURL)
    }

    @Test("Create produces a CoW clone and destroy removes it")
    func createAndDestroy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)
        let fm = FileManager.default

        let disk = EphemeralDisk(baseImageURL: baseURL)
        try disk.create()
        #expect(fm.fileExists(atPath: disk.ephemeralURL.path))

        try disk.destroy()
        #expect(!fm.fileExists(atPath: disk.ephemeralURL.path))
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
        #expect(FileManager.default.fileExists(atPath: persistURL.path))
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
        try disk.destroy()
    }

    @Test("Create with missing base image fails")
    func createMissingBase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let disk = EphemeralDisk(baseImageURL: dir.appendingPathComponent("nonexistent.img"))
        #expect(throws: SandboxError.self) {
            try disk.create()
        }
    }

    @Test("Session ID creates unique ephemeral paths")
    func uniqueSessions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try createFakeBaseImage(in: dir)

        let disk1 = EphemeralDisk(baseImageURL: baseURL, sessionID: "aaa")
        let disk2 = EphemeralDisk(baseImageURL: baseURL, sessionID: "bbb")
        #expect(disk1.ephemeralURL != disk2.ephemeralURL)
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
        #expect(BaseImageManager(storageDir: dir).baseImageExists == false)
    }

    @Test("baseImageExists returns false when files are partial")
    func partialBaseImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: VMConfig.baseImageURL(in: dir))
        #expect(BaseImageManager(storageDir: dir).baseImageExists == false)
    }

    @Test("baseImageExists returns true when all three files exist")
    func completeBaseImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: VMConfig.baseImageURL(in: dir))
        try Data().write(to: VMConfig.baseAuxURL(in: dir))
        try Data().write(to: VMConfig.baseMetadataURL(in: dir))
        #expect(BaseImageManager(storageDir: dir).baseImageExists == true)
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
        try encoder.encode(metadata).write(to: VMConfig.baseMetadataURL(in: dir))

        let loaded = try BaseImageManager(storageDir: dir).loadMetadata()
        #expect(loaded.hardwareModelData == Data([1, 2, 3]))
        #expect(loaded.macOSVersion == "15.0")
    }

    @Test("loadMetadata throws for missing/corrupt file")
    func loadMetadataMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: (any Error).self) {
            try BaseImageManager(storageDir: dir).loadMetadata()
        }

        try Data("not json".utf8).write(to: VMConfig.baseMetadataURL(in: dir))
        #expect(throws: (any Error).self) {
            try BaseImageManager(storageDir: dir).loadMetadata()
        }
    }
}

// MARK: - SandboxVM State Tests

@Suite("SandboxVM State")
struct SandboxVMStateTests {
    @Test("Initial state is .created")
    func initialState() {
        let vm = SandboxVM(config: VMConfig(), storageDir: FileManager.default.temporaryDirectory)
        #expect(vm.state == .created)
        #expect(vm.vm == nil)
    }

    @Test("State enum raw values are human-readable")
    func stateRawValues() {
        #expect(SandboxVM.State.created.rawValue == "created")
        #expect(SandboxVM.State.starting.rawValue == "starting")
        #expect(SandboxVM.State.running.rawValue == "running")
        #expect(SandboxVM.State.stopped.rawValue == "stopped")
        #expect(SandboxVM.State.error.rawValue == "error")
    }

    @Test("statusDescription includes config info")
    func statusDescription() {
        let config = VMConfig(cpuCount: 4, memorySize: 8 * 1024 * 1024 * 1024, enableAudio: false)
        let vm = SandboxVM(config: config, storageDir: FileManager.default.temporaryDirectory)
        let desc = vm.statusDescription
        #expect(desc.contains("created"))
        #expect(desc.contains("cpus=4"))
        #expect(desc.contains("mem=8GB"))
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

// MARK: - ProfileDisk Command Tests

@Suite("ProfileDisk Commands")
struct ProfileDiskCommandTests {
    @Test("luksFormatCommand constructs correct command")
    func formatCommand() {
        let cmd = ProfileDisk.luksFormatCommand(key: "abcdef1234567890", device: "/dev/vdb")
        #expect(cmd.contains("echo -n 'abcdef1234567890'"))
        #expect(cmd.contains("cryptsetup luksFormat --batch-mode /dev/vdb"))
    }

    @Test("luksFormatCommand uses default device")
    func formatCommandDefault() {
        let cmd = ProfileDisk.luksFormatCommand(key: "key123")
        #expect(cmd.contains("/dev/vdb"))
    }

    @Test("luksUnlockAndMountCommand chains all steps")
    func unlockCommand() {
        let cmd = ProfileDisk.luksUnlockAndMountCommand(
            key: "mykey", device: "/dev/vdb", mountPoint: "/home/chrome/profile"
        )
        #expect(cmd.contains("cryptsetup open /dev/vdb profile_data"))
        #expect(cmd.contains("echo -n 'mykey'"))
        #expect(cmd.contains("mkdir -p /home/chrome/profile"))
        #expect(cmd.contains("mkfs.ext4"))
        #expect(cmd.contains("mount /dev/mapper/profile_data /home/chrome/profile"))
        #expect(cmd.contains("chown chrome:chrome /home/chrome/profile"))
        // All steps chained with &&
        #expect(cmd.components(separatedBy: " && ").count == 5)
    }

    @Test("luksCloseCommand unmounts and closes")
    func closeCommand() {
        let cmd = ProfileDisk.luksCloseCommand()
        #expect(cmd.contains("umount /home/chrome/profile"))
        #expect(cmd.contains("cryptsetup close profile_data"))
    }
}

// MARK: - HostNetworkInfo Tests

@Suite("HostNetworkInfo")
struct HostNetworkInfoTests {
    @Test("parseIPv4 valid addresses")
    func parseValid() {
        #expect(HostNetworkInfo.parseIPv4("192.168.1.1") == 0xC0A80101)
        #expect(HostNetworkInfo.parseIPv4("10.0.0.1") == 0x0A000001)
        #expect(HostNetworkInfo.parseIPv4("255.255.255.0") == 0xFFFFFF00)
        #expect(HostNetworkInfo.parseIPv4("0.0.0.0") == 0)
        #expect(HostNetworkInfo.parseIPv4("255.255.255.255") == 0xFFFFFFFF)
        #expect(HostNetworkInfo.parseIPv4("172.16.0.1") == 0xAC100001)
        #expect(HostNetworkInfo.parseIPv4("1.1.1.1") == 0x01010101)
    }

    @Test("parseIPv4 rejects invalid addresses")
    func parseInvalid() {
        #expect(HostNetworkInfo.parseIPv4("") == nil)
        #expect(HostNetworkInfo.parseIPv4("1.2.3") == nil)
        #expect(HostNetworkInfo.parseIPv4("1.2.3.4.5") == nil)
        #expect(HostNetworkInfo.parseIPv4("256.1.1.1") == nil)
        #expect(HostNetworkInfo.parseIPv4("abc") == nil)
        #expect(HostNetworkInfo.parseIPv4("1.2.3.abc") == nil)
    }

    @Test("formatIPv4 produces dotted decimal")
    func format() {
        #expect(HostNetworkInfo.formatIPv4(0xC0A80101) == "192.168.1.1")
        #expect(HostNetworkInfo.formatIPv4(0x0A000001) == "10.0.0.1")
        #expect(HostNetworkInfo.formatIPv4(0xFFFFFF00) == "255.255.255.0")
        #expect(HostNetworkInfo.formatIPv4(0) == "0.0.0.0")
        #expect(HostNetworkInfo.formatIPv4(0xFFFFFFFF) == "255.255.255.255")
    }

    @Test("parseIPv4 and formatIPv4 are inverses")
    func roundtrip() {
        let testIPs: [String] = [
            "192.168.1.1", "10.0.0.1", "172.16.0.1",
            "8.8.8.8", "1.1.1.1", "0.0.0.0", "255.255.255.255",
        ]
        for ip in testIPs {
            let parsed = HostNetworkInfo.parseIPv4(ip)!
            let formatted = HostNetworkInfo.formatIPv4(parsed)
            #expect(formatted == ip)
        }
    }
}

// MARK: - NetworkFilter Port Parsing Tests

@Suite("NetworkFilter.parsePortRanges")
struct PortParsingTests {
    @Test("Single port")
    func singlePort() {
        let ranges = NetworkFilter.parsePortRanges("80")
        #expect(ranges.count == 1)
        #expect(ranges[0] == 80...80)
    }

    @Test("Multiple ports")
    func multiplePorts() {
        let ranges = NetworkFilter.parsePortRanges("80,443")
        #expect(ranges.count == 2)
        #expect(ranges[0] == 80...80)
        #expect(ranges[1] == 443...443)
    }

    @Test("Port range")
    func portRange() {
        let ranges = NetworkFilter.parsePortRanges("8000-9000")
        #expect(ranges.count == 1)
        #expect(ranges[0] == 8000...9000)
    }

    @Test("Mixed ports and ranges")
    func mixed() {
        let ranges = NetworkFilter.parsePortRanges("80, 443, 8000-9000")
        #expect(ranges.count == 3)
        #expect(ranges[0] == 80...80)
        #expect(ranges[1] == 443...443)
        #expect(ranges[2] == 8000...9000)
    }

    @Test("Whitespace is trimmed")
    func whitespace() {
        let ranges = NetworkFilter.parsePortRanges("  80 , 443 , 8000 - 9000 ")
        #expect(ranges.count == 3)
    }

    @Test("Invalid port (too large) is skipped")
    func tooLarge() {
        let ranges = NetworkFilter.parsePortRanges("80,70000,443")
        #expect(ranges.count == 2)
        #expect(ranges[0] == 80...80)
        #expect(ranges[1] == 443...443)
    }

    @Test("Invalid range (lo > hi) is skipped")
    func reversedRange() {
        let ranges = NetworkFilter.parsePortRanges("9000-8000")
        #expect(ranges.count == 0)
    }

    @Test("Non-numeric input is skipped")
    func nonNumeric() {
        let ranges = NetworkFilter.parsePortRanges("abc,80,xyz-100")
        #expect(ranges.count == 1)
        #expect(ranges[0] == 80...80)
    }

    @Test("Empty string returns empty array")
    func emptyString() {
        #expect(NetworkFilter.parsePortRanges("").isEmpty)
    }

    @Test("Boundary values: port 0 and 65535")
    func boundaries() {
        let ranges = NetworkFilter.parsePortRanges("0,65535")
        #expect(ranges.count == 2)
        #expect(ranges[0] == 0...0)
        #expect(ranges[1] == 65535...65535)
    }

    @Test("Full range 0-65535")
    func fullRange() {
        let ranges = NetworkFilter.parsePortRanges("0-65535")
        #expect(ranges.count == 1)
        #expect(ranges[0] == 0...65535)
    }
}

// MARK: - VirusTotal Tests

@Suite("VirusTotalClient")
struct VirusTotalClientTests {
    @Test("sha256 produces correct hash for known input")
    func sha256Known() {
        // SHA-256 of empty data
        let emptyHash = VirusTotalClient.sha256(of: Data())
        #expect(emptyHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        // SHA-256 of "hello"
        let helloHash = VirusTotalClient.sha256(of: Data("hello".utf8))
        #expect(helloHash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test("sha256 returns 64-character lowercase hex string")
    func sha256Format() {
        let hash = VirusTotalClient.sha256(of: Data([0x42]))
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        #expect(hash.allSatisfy { $0.isHexDigit })
    }

    @Test("sha256 is deterministic")
    func sha256Deterministic() {
        let data = Data("test data".utf8)
        let hash1 = VirusTotalClient.sha256(of: data)
        let hash2 = VirusTotalClient.sha256(of: data)
        #expect(hash1 == hash2)
    }

    @Test("Init with empty API key throws missingAPIKey")
    func emptyKeyThrows() {
        #expect(throws: VirusTotalError.self) {
            try VirusTotalClient(apiKey: "")
        }
    }

    @Test("Init with valid API key succeeds")
    func validKey() throws {
        _ = try VirusTotalClient(apiKey: "test-api-key")
    }
}

@Suite("VirusTotalError")
struct VirusTotalErrorTests {
    @Test("All error cases have non-empty descriptions")
    func descriptions() {
        let errors: [VirusTotalError] = [
            .missingAPIKey,
            .invalidAPIKey,
            .rateLimited,
            .notFound,
            .uploadFailed(statusCode: 500),
            .fileTooLarge(sizeMB: 100),
            .analysisError("test"),
            .networkError(NSError(domain: "test", code: 0)),
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("uploadFailed includes status code")
    func uploadFailedCode() {
        let err = VirusTotalError.uploadFailed(statusCode: 403)
        #expect(err.errorDescription!.contains("403"))
    }

    @Test("fileTooLarge includes size")
    func fileTooLargeSize() {
        let err = VirusTotalError.fileTooLarge(sizeMB: 64)
        #expect(err.errorDescription!.contains("64"))
    }
}

@Suite("ScanStatus")
struct ScanStatusTests {
    @Test("Equatable works correctly")
    func equatable() {
        #expect(ScanStatus.pending == ScanStatus.pending)
        #expect(ScanStatus.scanning == ScanStatus.scanning)
        #expect(ScanStatus.clean == ScanStatus.clean)
        #expect(ScanStatus.threat(positives: 5, total: 70) == ScanStatus.threat(positives: 5, total: 70))
        #expect(ScanStatus.threat(positives: 5, total: 70) != ScanStatus.threat(positives: 3, total: 70))
        #expect(ScanStatus.clean != ScanStatus.pending)
    }
}

// MARK: - ProfileManager Tests

@Suite("ProfileManager")
struct ProfileManagerTests {
    private func makeTempManager() throws -> (ProfileManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-pm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pm = ProfileManager(storageDir: dir)
        // Wait for async init to complete (iCloud discovery)
        // ProfileManager loads synchronously from local dir as fallback
        Thread.sleep(forTimeInterval: 0.5)
        return (pm, dir)
    }

    @Test("Create and retrieve a profile")
    func createAndGet() throws {
        let (pm, dir) = try makeTempManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = pm.createProfile(name: "Test", color: .red)
        #expect(profile.name == "Test")
        #expect(profile.color == .red)

        let found = pm.profile(withID: profile.id)
        #expect(found != nil)
        #expect(found?.name == "Test")
    }

    @Test("allProfiles sorted by most recently used")
    func sorting() throws {
        let (pm, dir) = try makeTempManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let p1 = pm.createProfile(name: "Old")
        Thread.sleep(forTimeInterval: 0.01)
        let p2 = pm.createProfile(name: "New")

        let all = pm.allProfiles
        #expect(all.count == 2)
        // p2 was created later, should be first
        #expect(all[0].id == p2.id)
        #expect(all[1].id == p1.id)

        // Mark p1 as used — it should now be first
        pm.markUsed(id: p1.id)
        let updated = pm.allProfiles
        #expect(updated[0].id == p1.id)
    }

    @Test("Update a profile")
    func update() throws {
        let (pm, dir) = try makeTempManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        var p = pm.createProfile(name: "Original")
        p.name = "Updated"
        p.settings.homePage = "https://example.com"
        pm.updateProfile(p)

        let found = pm.profile(withID: p.id)
        #expect(found?.name == "Updated")
        #expect(found?.settings.homePage == "https://example.com")
    }

    @Test("Delete a profile")
    func delete() throws {
        let (pm, dir) = try makeTempManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = pm.createProfile(name: "ToDelete")
        #expect(pm.allProfiles.count == 1)

        pm.deleteProfile(id: p.id)
        #expect(pm.allProfiles.isEmpty)
        #expect(pm.profile(withID: p.id) == nil)
    }

    @Test("profileDiskURL computes expected path")
    func diskURL() throws {
        let (pm, dir) = try makeTempManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let url = pm.profileDiskURL(for: id)
        #expect(url.lastPathComponent == "profile.img")
        #expect(url.path.contains(id.uuidString))
        #expect(url.path.contains("image"))
    }

    @Test("Profiles persist to disk and survive reload")
    func persistence() throws {
        let (pm, dir) = try makeTempManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = pm.createProfile(name: "Persisted", color: .green)

        // Create a fresh manager pointing at the same directory
        let pm2 = ProfileManager(storageDir: dir)
        Thread.sleep(forTimeInterval: 0.5)

        let found = pm2.profile(withID: p.id)
        #expect(found != nil)
        #expect(found?.name == "Persisted")
        #expect(found?.color == .green)
    }
}

// MARK: - E2E CLI Tests

@Suite("E2E CLI")
struct E2ETests {
    static let binaryPath: String = {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return projectRoot
            .appendingPathComponent(".build/arm64-apple-macosx/release/bromure.app/Contents/MacOS/bromure")
            .path
    }()

    static let ensureBuilt: Bool = {
        let fm = FileManager.default
        if fm.fileExists(atPath: binaryPath) { return true }
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [projectRoot.appendingPathComponent("build.sh").path]
        process.currentDirectoryURL = projectRoot
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    private func run(
        _ arguments: [String] = [],
        timeout: TimeInterval = 30
    ) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        guard Self.ensureBuilt else { throw CocoaError(.fileNoSuchFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binaryPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        return (
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    @Test("--help prints usage and exits 0")
    func helpFlag() throws {
        let result = try run(["--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("bromure"))
        #expect(result.stdout.contains("USAGE"))
    }

    @Test("help shows subcommands")
    func helpShowsSubcommands() throws {
        let result = try run(["--help"])
        #expect(result.stdout.contains("init"))
        #expect(result.stdout.contains("run"))
        #expect(result.stdout.contains("setup"))
    }

    @Test("Invalid subcommand fails with non-zero exit")
    func invalidSubcommand() throws {
        let result = try run(["bogus"])
        #expect(result.exitCode != 0)
    }

    @Test("run without base image fails with helpful message")
    func runNoBaseImage() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try run(["run", "--storage-dir", tmpDir.path])
        #expect(result.exitCode != 0)
        let combined = result.stdout + result.stderr
        #expect(combined.contains("No base image found") || combined.contains("bromure init"))
    }
}
