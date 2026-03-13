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
    public var comments: String
    public var color: ProfileColor?
    public var settings: ProfileSettings
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(name: String, comments: String = "", color: ProfileColor? = .blue, settings: ProfileSettings = ProfileSettings()) {
        self.id = UUID()
        self.name = name
        self.comments = comments
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
        case id, name, comments, color, settings, createdAt, lastUsedAt
        case isPersistent  // legacy key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        comments = try c.decodeIfPresent(String.self, forKey: .comments) ?? ""
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
        try c.encode(comments, forKey: .comments)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(settings, forKey: .settings)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }
}

/// A custom root CA certificate stored as PEM in the profile JSON.
public struct CustomRootCA: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var pem: String

    public init(name: String, pem: String) {
        self.name = name
        self.pem = pem
    }
}

/// Webcam overlay effects (city/time, name badge, logo).
public struct WebcamEffects: Codable, Equatable {
    /// City name shown in the top-left corner.
    public var cityName: String = ""
    /// IANA time zone identifier (e.g. "America/New_York").
    public var timeZoneIdentifier: String = ""
    /// Display name shown in the bottom-right corner (TV anchor style).
    public var displayName: String = ""
    /// PNG data for the logo shown in the top-right corner.
    public var logoPNGData: Data?
    /// Font family name (e.g. "Helvetica Neue", "SF Pro").
    public var fontFamily: String = "Helvetica Neue"
    /// Font size as a percentage of video height (default 4.5 ≈ height/22).
    public var fontSizePercent: Double = 4.5

    public init() {}

    /// Whether any effect is configured.
    public var hasAnyEffect: Bool {
        !cityName.isEmpty || !displayName.isEmpty || logoPNGData != nil
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

    // Proxy
    public var proxyHost: String = ""
    public var proxyPort: Int = 0
    public var proxyUsername: String = ""
    public var proxyPassword: String = ""

    /// Whether a custom proxy is configured.
    public var hasProxy: Bool {
        !proxyHost.isEmpty && proxyPort > 0
    }

    // Security — clipboard
    public var enableClipboardSharing: Bool = false

    // Security — file transfer
    public var canUpload: Bool = false
    public var canDownload: Bool = false
    public var virusTotalEnabled: Bool = false
    public var virusTotalAPIKey: String?
    public var blockThreats: Bool = true
    public var blockUnscannable: Bool = false

    // Security — network
    public var blockMalwareSites: Bool = false

    // Security — phishing
    public var phishingWarning: Bool = false

    // Cross-session
    public var enableLinkSender: Bool = false

    // Network isolation
    public var isolateFromLAN: Bool = false
    public var restrictPorts: Bool = false
    public var allowedPorts: String = "80,443"

    // Media
    public var enableAudio: Bool = true
    public var audioVolume: Int = 100
    public var enableWebcam: Bool = false
    public var enableMicrophone: Bool = false
    public var webcamDeviceID: String?
    public var microphoneDeviceID: String?
    public var speakerDeviceID: String?

    // Webcam effects
    public var webcamEffects: WebcamEffects = WebcamEffects()

    // Certificates
    public var rootCAs: [CustomRootCA] = []

    // Locale
    public var locale: String?  // nil = auto-detect from OS

    // Advanced
    public var persistent: Bool = false
    public var encryptOnDisk: Bool = false

    public init() {}

    // Custom decoder so that adding new fields doesn't break existing profiles.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProfileSettings()
        homePage = try c.decodeIfPresent(String.self, forKey: .homePage) ?? defaults.homePage
        enableGPU = try c.decodeIfPresent(Bool.self, forKey: .enableGPU) ?? defaults.enableGPU
        enableWebGL = try c.decodeIfPresent(Bool.self, forKey: .enableWebGL) ?? defaults.enableWebGL
        enableAdBlocking = try c.decodeIfPresent(Bool.self, forKey: .enableAdBlocking) ?? defaults.enableAdBlocking
        enableWarp = try c.decodeIfPresent(Bool.self, forKey: .enableWarp) ?? defaults.enableWarp
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? defaults.proxyHost
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? defaults.proxyPort
        proxyUsername = try c.decodeIfPresent(String.self, forKey: .proxyUsername) ?? defaults.proxyUsername
        proxyPassword = try c.decodeIfPresent(String.self, forKey: .proxyPassword) ?? defaults.proxyPassword
        enableClipboardSharing = try c.decodeIfPresent(Bool.self, forKey: .enableClipboardSharing) ?? defaults.enableClipboardSharing
        canUpload = try c.decodeIfPresent(Bool.self, forKey: .canUpload) ?? defaults.canUpload
        canDownload = try c.decodeIfPresent(Bool.self, forKey: .canDownload) ?? defaults.canDownload
        virusTotalEnabled = try c.decodeIfPresent(Bool.self, forKey: .virusTotalEnabled) ?? defaults.virusTotalEnabled
        virusTotalAPIKey = try c.decodeIfPresent(String.self, forKey: .virusTotalAPIKey)
        blockThreats = try c.decodeIfPresent(Bool.self, forKey: .blockThreats) ?? defaults.blockThreats
        blockUnscannable = try c.decodeIfPresent(Bool.self, forKey: .blockUnscannable) ?? defaults.blockUnscannable
        blockMalwareSites = try c.decodeIfPresent(Bool.self, forKey: .blockMalwareSites) ?? defaults.blockMalwareSites
        phishingWarning = try c.decodeIfPresent(Bool.self, forKey: .phishingWarning) ?? defaults.phishingWarning
        enableLinkSender = try c.decodeIfPresent(Bool.self, forKey: .enableLinkSender) ?? defaults.enableLinkSender
        isolateFromLAN = try c.decodeIfPresent(Bool.self, forKey: .isolateFromLAN) ?? defaults.isolateFromLAN
        restrictPorts = try c.decodeIfPresent(Bool.self, forKey: .restrictPorts) ?? defaults.restrictPorts
        allowedPorts = try c.decodeIfPresent(String.self, forKey: .allowedPorts) ?? defaults.allowedPorts
        enableAudio = try c.decodeIfPresent(Bool.self, forKey: .enableAudio) ?? defaults.enableAudio
        audioVolume = try c.decodeIfPresent(Int.self, forKey: .audioVolume) ?? defaults.audioVolume
        enableWebcam = try c.decodeIfPresent(Bool.self, forKey: .enableWebcam) ?? defaults.enableWebcam
        enableMicrophone = try c.decodeIfPresent(Bool.self, forKey: .enableMicrophone) ?? defaults.enableMicrophone
        webcamDeviceID = try c.decodeIfPresent(String.self, forKey: .webcamDeviceID)
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        speakerDeviceID = try c.decodeIfPresent(String.self, forKey: .speakerDeviceID)
        webcamEffects = try c.decodeIfPresent(WebcamEffects.self, forKey: .webcamEffects) ?? defaults.webcamEffects
        rootCAs = try c.decodeIfPresent([CustomRootCA].self, forKey: .rootCAs) ?? defaults.rootCAs
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        persistent = try c.decodeIfPresent(Bool.self, forKey: .persistent) ?? defaults.persistent
        encryptOnDisk = try c.decodeIfPresent(Bool.self, forKey: .encryptOnDisk) ?? defaults.encryptOnDisk
    }

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

        // Custom proxy overrides WARP and ad blocking
        let effectiveWarp = hasProxy ? false : enableWarp
        let effectiveAdBlocking = hasProxy ? false : enableAdBlocking

        return VMConfig(
            cpuCount: cpus > 0 ? cpus : nil,
            memorySize: UInt64(max(memGB > 0 ? memGB : 2, 1)) * 1024 * 1024 * 1024,
            enableAudio: enableAudio,
            audioVolume: audioVolume,
            enableWarp: effectiveWarp,
            forceDarkMode: forceDark,
            enableAdBlocking: effectiveAdBlocking,
            swapCmdCtrl: defaults.object(forKey: "vm.swapCmdCtrl") as? Bool ?? true,
            homePage: homePage,
            enableGPU: enableGPU,
            enableWebGL: enableWebGL,
            blockMalwareSites: blockMalwareSites,
            enableFileTransfer: canUpload || canDownload,
            phishingWarning: phishingWarning,
            enableClipboardSharing: enableClipboardSharing,
            enableLinkSender: enableLinkSender,
            enableWebcam: enableWebcam,
            enableMicrophone: enableMicrophone,
            webcamDeviceID: webcamDeviceID,
            microphoneDeviceID: microphoneDeviceID,
            speakerDeviceID: speakerDeviceID,
            webcamEffects: webcamEffects,
            rootCAs: rootCAs.map(\.pem),
            isolateFromLAN: isolateFromLAN,
            allowedPorts: restrictPorts ? allowedPorts : nil,
            proxyHost: hasProxy ? proxyHost : nil,
            proxyPort: hasProxy ? proxyPort : nil,
            proxyUsername: hasProxy && !proxyUsername.isEmpty ? proxyUsername : nil,
            proxyPassword: hasProxy && !proxyPassword.isEmpty ? proxyPassword : nil,
            locale: locale
        )
    }
}
