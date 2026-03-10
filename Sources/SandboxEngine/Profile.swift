import Foundation

/// Preset profile colors.
public enum ProfileColor: String, Codable, CaseIterable, Equatable {
    case blue, red, green, orange, purple, pink, teal, gray

    /// Display name for the UI.
    public var label: String {
        rawValue.capitalized
    }
}

/// A named browser profile with its own settings and optional persistent storage.
public struct Profile: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var color: ProfileColor?
    public var settings: ProfileSettings
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(name: String, color: ProfileColor? = .blue, settings: ProfileSettings = ProfileSettings()) {
        self.id = UUID()
        self.name = name
        self.color = color
        self.settings = settings
        self.createdAt = Date()
    }

    /// Whether this profile keeps data between sessions.
    public var isPersistent: Bool {
        settings.persistent
    }

    /// Whether this profile uses encrypted persistent storage.
    public var isEncrypted: Bool {
        settings.persistent && settings.encryptOnDisk
    }

    // Migration: decode old `isPersistent` field as `encryptOnDisk`
    enum CodingKeys: String, CodingKey {
        case id, name, color, settings, createdAt, lastUsedAt
        case isPersistent  // legacy key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(ProfileColor.self, forKey: .color)
        settings = try c.decodeIfPresent(ProfileSettings.self, forKey: .settings) ?? ProfileSettings()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)

        // Migrate legacy isPersistent → persistent + encryptOnDisk
        if let legacy = try c.decodeIfPresent(Bool.self, forKey: .isPersistent), legacy {
            settings.persistent = true
            settings.encryptOnDisk = true
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(settings, forKey: .settings)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }
}

/// Per-profile settings. Hardware settings (memory, CPU, audio) are app-wide
/// and read from UserDefaults at VM creation time.
public struct ProfileSettings: Codable, Equatable {
    // Browser
    public var homePage: String = "https://www.google.com"
    public var enableGPU: Bool = true
    public var enableWebGL: Bool = false

    // Network
    public var enableAdBlocking: Bool = false
    public var enableWarp: Bool = false

    // Security — clipboard
    public var enableClipboardSharing: Bool = false

    // Security — file transfer
    public var canUpload: Bool = false
    public var canDownload: Bool = false
    public var virusTotalEnabled: Bool = false
    public var virusTotalAPIKey: String?

    // Security — network
    public var blockMalwareSites: Bool = false

    // Security — phishing
    public var phishingWarning: Bool = false

    // Advanced
    public var persistent: Bool = false
    public var encryptOnDisk: Bool = false

    public init() {}

    /// Convert to a VMConfig for VM creation.
    /// Merges per-profile settings with app-wide hardware settings from UserDefaults.
    public func toVMConfig() -> VMConfig {
        let defaults = UserDefaults.standard
        let memGB = defaults.integer(forKey: "vm.memoryGB")
        let cpus = defaults.integer(forKey: "vm.cpuCount")

        let appearancePref = defaults.string(forKey: "vm.appearance") ?? "system"
        let forceDark: Bool
        switch appearancePref {
        case "dark": forceDark = true
        case "light": forceDark = false
        default: forceDark = VMConfig.detectDarkMode()
        }

        return VMConfig(
            cpuCount: cpus > 0 ? cpus : nil,
            memorySize: UInt64(max(memGB > 0 ? memGB : 2, 1)) * 1024 * 1024 * 1024,
            enableAudio: defaults.object(forKey: "vm.enableAudio") as? Bool ?? true,
            enableWarp: enableWarp,
            forceDarkMode: forceDark,
            enableAdBlocking: enableAdBlocking,
            swapCmdCtrl: defaults.object(forKey: "vm.swapCmdCtrl") as? Bool ?? true,
            homePage: homePage,
            enableGPU: enableGPU,
            enableWebGL: enableWebGL,
            blockMalwareSites: blockMalwareSites,
            enableFileTransfer: canUpload || canDownload,
            phishingWarning: phishingWarning,
            enableClipboardSharing: enableClipboardSharing
        )
    }
}
