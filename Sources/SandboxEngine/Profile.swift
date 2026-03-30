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

/// VPN mode for the browser session.
public enum VPNMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// No VPN — direct connection.
    case none
    /// Cloudflare WARP (SOCKS5 proxy inside the guest).
    case cloudflareWarp
    /// WireGuard (full network tunnel inside the guest, works with any provider).
    case wireGuard
}

/// Trace verbosity level for HTTP session recording.
public enum TraceLevel: Int, Codable, CaseIterable, Sendable {
    case disabled = 0
    case basic = 1     // timestamp, method, URL, status, duration
    case headers = 2   // basic + request/response headers + post data
    case full = 3      // headers + response body
}

/// Webcam capture quality — maps to AVCaptureSession presets.
public enum WebcamQuality: String, Codable, CaseIterable, Sendable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    public var label: String {
        switch self {
        case .low: "Low (640\u{00d7}480)"
        case .medium: "Medium (1280\u{00d7}720)"
        case .high: "High (1920\u{00d7}1080)"
        }
    }
}

/// Webcam overlay effects (city/time, name badge, logo, face swap).
public struct WebcamEffects: Codable, Equatable, Sendable {
    /// City name shown in the top-left corner.
    public var cityName: String = ""
    /// IANA time zone identifier (e.g. "America/New_York").
    public var timeZoneIdentifier: String = ""
    /// Display name shown in the bottom-right corner (TV anchor style).
    public var displayName: String = ""
    /// Job title shown below the name in the badge (black text on white).
    public var displayTitle: String = ""
    /// PNG data for the logo shown in the top-right corner.
    public var logoPNGData: Data?
    /// Font family name (e.g. "Helvetica Neue", "SF Pro").
    public var fontFamily: String = "Helvetica Neue"
    /// Font size as a percentage of video height (default 4.5 ≈ height/22).
    public var fontSizePercent: Double = 4.5

    /// Whether face swap is enabled.
    public var faceSwapEnabled: Bool = false
    /// PNG data of the face image to swap onto the user's face.
    public var faceSwapImageData: Data?

    public init() {}

    /// Whether any effect is configured.
    public var hasAnyEffect: Bool {
        !cityName.isEmpty || !displayName.isEmpty || !displayTitle.isEmpty || logoPNGData != nil || faceSwapActive
    }

    /// Whether face swap is fully configured and ready.
    public var faceSwapActive: Bool {
        faceSwapEnabled && faceSwapImageData != nil
    }
}

/// Per-profile settings. Hardware settings (memory, CPU, audio) are app-wide
/// and read from UserDefaults at VM creation time.
public struct ProfileSettings: Codable, Equatable {
    // Browser
    public var homePage: String = "https://bromure.io/hello"
    public var enableGPU: Bool = true
    public var enableWebGL: Bool = false
    public var enableZeroCopy: Bool = true
    public var enableSmoothScrolling: Bool = true

    // Network
    public var enableAdBlocking: Bool = false
    /// VPN mode — replaces the legacy `enableWarp` bool.
    public var vpnMode: VPNMode = .none
    /// Auto-connect WARP on session start (only used when vpnMode == .cloudflareWarp).
    public var warpAutoConnect: Bool = true
    /// Raw WireGuard .conf file content (only used when vpnMode == .wireGuard).
    public var wireGuardConfig: String = ""
    /// Auto-connect WireGuard on session start (only used when vpnMode == .wireGuard).
    public var wireGuardAutoConnect: Bool = true

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

    // Integration — Keychain
    public var keychainPasskeys: Bool = false
    public var keychainPasswords: Bool = false

    // Security — screen capture
    public var blockScreenCapture: Bool = false

    // Cross-session
    public var enableLinkSender: Bool = false

    // Network isolation
    public var isolateFromLAN: Bool = false
    public var restrictPorts: Bool = false
    public var allowedPorts: String = "80,443"

    // Per-profile network interface override.
    // "" = use global setting, "nat" = force NAT, interface name (e.g. "en0") = bridge on that interface.
    public var networkInterface: String = ""

    // Media
    public var enableAudio: Bool = true
    public var audioVolume: Int = 100
    public var enableWebcam: Bool = false
    public var webcamQuality: WebcamQuality = .high
    public var enableMicrophone: Bool = false
    public var webcamDeviceID: String?
    public var microphoneDeviceID: String?
    public var speakerDeviceID: String?

    // Webcam effects
    public var webcamEffects: WebcamEffects = WebcamEffects()

    // Certificates
    public var rootCAs: [CustomRootCA] = []

    // Input
    public var matchKeyboardLayout: Bool = true  // dynamically sync host keyboard layout

    // Locale
    public var locale: String?  // nil = auto-detect from OS

    // Automation
    public var allowAutomation: Bool = false

    // Trace
    public var traceLevel: TraceLevel = .disabled
    public var traceAutoStart: Bool = true  // start tracing when session opens

    // Advanced
    public var persistent: Bool = false
    public var encryptOnDisk: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case homePage, enableGPU, enableWebGL, enableZeroCopy, enableSmoothScrolling
        case enableAdBlocking, enableWarp, warpAutoConnect
        case vpnMode, wireGuardConfig, wireGuardAutoConnect
        case proxyHost, proxyPort, proxyUsername, proxyPassword
        case enableClipboardSharing
        case canUpload, canDownload, virusTotalEnabled, virusTotalAPIKey, blockThreats, blockUnscannable
        case blockMalwareSites, phishingWarning
        case keychainPasskeys, keychainPasswords
        case keychainIntegration  // legacy: migrated to keychainPasskeys + keychainPasswords
        case blockScreenCapture, enableLinkSender
        case isolateFromLAN, restrictPorts, allowedPorts, networkInterface
        case enableAudio, audioVolume, enableWebcam, webcamQuality, enableMicrophone
        case webcamDeviceID, microphoneDeviceID, speakerDeviceID, webcamEffects
        case rootCAs, matchKeyboardLayout, locale, allowAutomation
        case traceLevel, traceAutoStart, persistent, encryptOnDisk
    }

    // Custom decoder so that adding new fields doesn't break existing profiles.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProfileSettings()
        homePage = try c.decodeIfPresent(String.self, forKey: .homePage) ?? defaults.homePage
        enableGPU = try c.decodeIfPresent(Bool.self, forKey: .enableGPU) ?? defaults.enableGPU
        enableWebGL = try c.decodeIfPresent(Bool.self, forKey: .enableWebGL) ?? defaults.enableWebGL
        enableZeroCopy = try c.decodeIfPresent(Bool.self, forKey: .enableZeroCopy) ?? defaults.enableZeroCopy
        enableSmoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .enableSmoothScrolling) ?? defaults.enableSmoothScrolling
        enableAdBlocking = try c.decodeIfPresent(Bool.self, forKey: .enableAdBlocking) ?? defaults.enableAdBlocking
        // Migration: legacy enableWarp bool → vpnMode enum
        let legacyEnableWarp = try c.decodeIfPresent(Bool.self, forKey: .enableWarp) ?? false
        if let decoded = try c.decodeIfPresent(VPNMode.self, forKey: .vpnMode) {
            vpnMode = decoded
        } else {
            vpnMode = legacyEnableWarp ? .cloudflareWarp : .none
        }
        warpAutoConnect = try c.decodeIfPresent(Bool.self, forKey: .warpAutoConnect) ?? defaults.warpAutoConnect
        wireGuardConfig = try c.decodeIfPresent(String.self, forKey: .wireGuardConfig) ?? defaults.wireGuardConfig
        wireGuardAutoConnect = try c.decodeIfPresent(Bool.self, forKey: .wireGuardAutoConnect) ?? defaults.wireGuardAutoConnect
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
        keychainPasskeys = try c.decodeIfPresent(Bool.self, forKey: .keychainPasskeys) ?? defaults.keychainPasskeys
        keychainPasswords = try c.decodeIfPresent(Bool.self, forKey: .keychainPasswords) ?? defaults.keychainPasswords
        // Migrate legacy keychainIntegration → both passkeys + passwords
        if let legacy = try c.decodeIfPresent(Bool.self, forKey: .keychainIntegration), legacy {
            keychainPasskeys = true
            keychainPasswords = true
        }
        blockScreenCapture = try c.decodeIfPresent(Bool.self, forKey: .blockScreenCapture) ?? defaults.blockScreenCapture
        enableLinkSender = try c.decodeIfPresent(Bool.self, forKey: .enableLinkSender) ?? defaults.enableLinkSender
        isolateFromLAN = try c.decodeIfPresent(Bool.self, forKey: .isolateFromLAN) ?? defaults.isolateFromLAN
        restrictPorts = try c.decodeIfPresent(Bool.self, forKey: .restrictPorts) ?? defaults.restrictPorts
        allowedPorts = try c.decodeIfPresent(String.self, forKey: .allowedPorts) ?? defaults.allowedPorts
        networkInterface = try c.decodeIfPresent(String.self, forKey: .networkInterface) ?? defaults.networkInterface
        enableAudio = try c.decodeIfPresent(Bool.self, forKey: .enableAudio) ?? defaults.enableAudio
        audioVolume = try c.decodeIfPresent(Int.self, forKey: .audioVolume) ?? defaults.audioVolume
        enableWebcam = try c.decodeIfPresent(Bool.self, forKey: .enableWebcam) ?? defaults.enableWebcam
        webcamQuality = try c.decodeIfPresent(WebcamQuality.self, forKey: .webcamQuality) ?? defaults.webcamQuality
        enableMicrophone = try c.decodeIfPresent(Bool.self, forKey: .enableMicrophone) ?? defaults.enableMicrophone
        webcamDeviceID = try c.decodeIfPresent(String.self, forKey: .webcamDeviceID)
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        speakerDeviceID = try c.decodeIfPresent(String.self, forKey: .speakerDeviceID)
        webcamEffects = try c.decodeIfPresent(WebcamEffects.self, forKey: .webcamEffects) ?? defaults.webcamEffects
        rootCAs = try c.decodeIfPresent([CustomRootCA].self, forKey: .rootCAs) ?? defaults.rootCAs
        matchKeyboardLayout = try c.decodeIfPresent(Bool.self, forKey: .matchKeyboardLayout) ?? defaults.matchKeyboardLayout
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        allowAutomation = try c.decodeIfPresent(Bool.self, forKey: .allowAutomation) ?? defaults.allowAutomation
        traceLevel = try c.decodeIfPresent(TraceLevel.self, forKey: .traceLevel) ?? defaults.traceLevel
        traceAutoStart = try c.decodeIfPresent(Bool.self, forKey: .traceAutoStart) ?? defaults.traceAutoStart
        persistent = try c.decodeIfPresent(Bool.self, forKey: .persistent) ?? defaults.persistent
        encryptOnDisk = try c.decodeIfPresent(Bool.self, forKey: .encryptOnDisk) ?? defaults.encryptOnDisk
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(homePage, forKey: .homePage)
        try c.encode(enableGPU, forKey: .enableGPU)
        try c.encode(enableWebGL, forKey: .enableWebGL)
        try c.encode(enableZeroCopy, forKey: .enableZeroCopy)
        try c.encode(enableSmoothScrolling, forKey: .enableSmoothScrolling)
        try c.encode(enableAdBlocking, forKey: .enableAdBlocking)
        try c.encode(vpnMode, forKey: .vpnMode)
        // Keep encoding enableWarp for compatibility with older app versions reading this profile
        try c.encode(vpnMode == .cloudflareWarp, forKey: .enableWarp)
        try c.encode(warpAutoConnect, forKey: .warpAutoConnect)
        try c.encode(wireGuardConfig, forKey: .wireGuardConfig)
        try c.encode(wireGuardAutoConnect, forKey: .wireGuardAutoConnect)
        try c.encode(proxyHost, forKey: .proxyHost)
        try c.encode(proxyPort, forKey: .proxyPort)
        try c.encode(proxyUsername, forKey: .proxyUsername)
        try c.encode(proxyPassword, forKey: .proxyPassword)
        try c.encode(enableClipboardSharing, forKey: .enableClipboardSharing)
        try c.encode(canUpload, forKey: .canUpload)
        try c.encode(canDownload, forKey: .canDownload)
        try c.encode(virusTotalEnabled, forKey: .virusTotalEnabled)
        try c.encodeIfPresent(virusTotalAPIKey, forKey: .virusTotalAPIKey)
        try c.encode(blockThreats, forKey: .blockThreats)
        try c.encode(blockUnscannable, forKey: .blockUnscannable)
        try c.encode(blockMalwareSites, forKey: .blockMalwareSites)
        try c.encode(phishingWarning, forKey: .phishingWarning)
        try c.encode(keychainPasskeys, forKey: .keychainPasskeys)
        try c.encode(keychainPasswords, forKey: .keychainPasswords)
        // Don't encode legacy keychainIntegration
        try c.encode(blockScreenCapture, forKey: .blockScreenCapture)
        try c.encode(enableLinkSender, forKey: .enableLinkSender)
        try c.encode(isolateFromLAN, forKey: .isolateFromLAN)
        try c.encode(restrictPorts, forKey: .restrictPorts)
        try c.encode(allowedPorts, forKey: .allowedPorts)
        try c.encode(networkInterface, forKey: .networkInterface)
        try c.encode(enableAudio, forKey: .enableAudio)
        try c.encode(audioVolume, forKey: .audioVolume)
        try c.encode(enableWebcam, forKey: .enableWebcam)
        try c.encode(webcamQuality, forKey: .webcamQuality)
        try c.encode(enableMicrophone, forKey: .enableMicrophone)
        try c.encodeIfPresent(webcamDeviceID, forKey: .webcamDeviceID)
        try c.encodeIfPresent(microphoneDeviceID, forKey: .microphoneDeviceID)
        try c.encodeIfPresent(speakerDeviceID, forKey: .speakerDeviceID)
        try c.encode(webcamEffects, forKey: .webcamEffects)
        try c.encode(rootCAs, forKey: .rootCAs)
        try c.encode(matchKeyboardLayout, forKey: .matchKeyboardLayout)
        try c.encodeIfPresent(locale, forKey: .locale)
        try c.encode(allowAutomation, forKey: .allowAutomation)
        try c.encode(traceLevel, forKey: .traceLevel)
        try c.encode(traceAutoStart, forKey: .traceAutoStart)
        try c.encode(persistent, forKey: .persistent)
        try c.encode(encryptOnDisk, forKey: .encryptOnDisk)
    }

    /// Convert to a VMConfig for VM creation.
    /// Merges per-profile settings with app-wide hardware settings from UserDefaults.
    public func toVMConfig() -> VMConfig {
        let defaults = UserDefaults.standard
        let memGB = defaults.integer(forKey: "vm.memoryGB")
        let cpus = defaults.integer(forKey: "vm.cpuCount")
        let defaultMemGB: Int = {
            let hostMemGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
            if hostMemGB < 18 { return 2 }
            if hostMemGB < 36 { return 3 }
            return 4
        }()

        let appearancePref = defaults.string(forKey: "vm.appearance") ?? "system"
        let forceDark: Bool
        switch appearancePref {
        case "dark": forceDark = true
        case "light": forceDark = false
        default: forceDark = VMConfig.detectDarkMode()
        }

        // Custom proxy overrides VPN and ad blocking
        let effectiveVPNMode: VPNMode = hasProxy ? .none : vpnMode
        let effectiveAdBlocking = hasProxy ? false : enableAdBlocking

        let isTestSuite = ProcessInfo.processInfo.environment["BROMURE_TEST_SUITE"] != nil

        return VMConfig(
            cpuCount: cpus > 0 ? cpus : nil,
            memorySize: UInt64(max(memGB > 0 ? memGB : defaultMemGB, 1)) * 1024 * 1024 * 1024,
            enableAudio: enableAudio,
            audioVolume: audioVolume,
            vpnMode: effectiveVPNMode,
            warpAutoConnect: effectiveVPNMode == .cloudflareWarp && warpAutoConnect,
            wireGuardConfig: effectiveVPNMode == .wireGuard && !wireGuardConfig.isEmpty ? wireGuardConfig : nil,
            wireGuardAutoConnect: effectiveVPNMode == .wireGuard && wireGuardAutoConnect,
            forceDarkMode: forceDark,
            enableAdBlocking: effectiveAdBlocking,
            swapCmdCtrl: defaults.object(forKey: "vm.swapCmdCtrl") as? Bool ?? true,
            homePage: homePage,
            enableGPU: enableGPU,
            enableWebGL: enableGPU ? enableWebGL : false,  // WebGL requires GPU
            enableZeroCopy: enableZeroCopy,
            enableSmoothScrolling: enableSmoothScrolling,
            blockMalwareSites: blockMalwareSites,
            enableFileTransfer: canUpload || canDownload,
            phishingWarning: phishingWarning,
            enableClipboardSharing: enableClipboardSharing,
            enablePasskeys: keychainPasskeys,
            enablePasswords: keychainPasswords,
            enableLinkSender: enableLinkSender,
            enableWebcam: enableWebcam,
            webcamQuality: webcamQuality,
            enableMicrophone: enableMicrophone,
            webcamDeviceID: webcamDeviceID,
            microphoneDeviceID: microphoneDeviceID,
            speakerDeviceID: speakerDeviceID,
            webcamEffects: webcamEffects,
            rootCAs: rootCAs.map(\.pem),
            isolateFromLAN: isolateFromLAN,
            allowedPorts: restrictPorts ? allowedPorts : nil,
            networkInterface: networkInterface.isEmpty ? nil : networkInterface,
            proxyHost: hasProxy ? proxyHost : nil,
            proxyPort: hasProxy ? proxyPort : nil,
            proxyUsername: hasProxy && !proxyUsername.isEmpty ? proxyUsername : nil,
            proxyPassword: hasProxy && !proxyPassword.isEmpty ? proxyPassword : nil,
            blockDownloads: !canDownload,
            enableAutomation: defaults.bool(forKey: "automation.enabled"),
            testSuite: isTestSuite,
            traceLevel: traceLevel,
            matchKeyboardLayout: matchKeyboardLayout,
            extraKernelOptions: defaults.string(forKey: "vm.extraKernelOptions") ?? VMConfig.defaultExtraKernelOptions,
            locale: locale
        )
    }
}
