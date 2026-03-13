import AppKit
import Foundation
import Virtualization

/// The guest operating system type.
public enum GuestOS: String, Codable, CaseIterable {
    case macOS
    case linux
}

/// Persistent metadata about a base image, saved alongside it as JSON.
public struct BaseImageMetadata: Codable {
    public let hardwareModelData: Data
    public let machineIdentifierData: Data
    public let createdAt: Date
    public let macOSVersion: String

    public init(
        hardwareModelData: Data,
        machineIdentifierData: Data,
        macOSVersion: String
    ) {
        self.hardwareModelData = hardwareModelData
        self.machineIdentifierData = machineIdentifierData
        self.createdAt = Date()
        self.macOSVersion = macOSVersion
    }
}

/// Runtime configuration for a sandbox VM session.
public struct VMConfig {
    /// Number of CPUs to allocate to the guest.
    public var cpuCount: Int

    /// Memory in bytes.
    public var memorySize: UInt64

    /// Display width in pixels.
    public var displayWidth: Int

    /// Display height in pixels.
    public var displayHeight: Int

    /// Pixels per inch for the virtual display.
    public var pixelsPerInch: Int

    /// Whether to attach audio devices.
    public var enableAudio: Bool

    /// Audio output volume (0-100%).
    public var audioVolume: Int

    /// Whether to enable Cloudflare WARP VPN in proxy mode.
    public var enableWarp: Bool

    /// Whether to force dark mode in the browser.
    public var forceDarkMode: Bool

    /// Whether to enable ad blocking (Pi-hole + Squid proxy).
    public var enableAdBlocking: Bool

    /// X11 keyboard layout (e.g. "us", "fr", "de", "gb").
    public var keyboardLayout: String

    /// Whether to use natural (macOS-style) scrolling.
    public var naturalScrolling: Bool

    /// OS language/locale (e.g. "en_US").
    public var locale: String

    /// Whether to swap Command and Control keys (macOS-like shortcuts).
    public var swapCmdCtrl: Bool

    /// Home page URL for the browser.
    public var homePage: String

    /// Whether GPU acceleration is enabled in the browser.
    public var enableGPU: Bool

    /// Whether WebGL and WebGPU are enabled in the browser.
    public var enableWebGL: Bool

    /// Whether to block known malware sites via Cloudflare DNS (1.1.1.2/1.0.0.2).
    public var blockMalwareSites: Bool

    /// Whether to enable file transfer between host and guest.
    public var enableFileTransfer: Bool

    /// Whether to warn about phishing when password fields are detected on suspicious sites.
    public var phishingWarning: Bool

    /// Whether to share the clipboard between host and guest via SPICE agent.
    public var enableClipboardSharing: Bool

    /// Whether to enable the "Send link to other session" Chrome extension.
    public var enableLinkSender: Bool

    /// Whether to share the host webcam with the guest via vsock + v4l2loopback.
    public var enableWebcam: Bool

    /// Whether to share the host microphone with the guest via virtio-snd.
    public var enableMicrophone: Bool

    /// Unique ID of the camera device to use (nil = default camera).
    public var webcamDeviceID: String?

    /// Unique ID of the microphone device to use (nil = default microphone).
    public var microphoneDeviceID: String?

    /// Unique ID of the speaker device to use (nil = default speaker).
    public var speakerDeviceID: String?

    /// Webcam overlay effects (city/time, name badge, logo).
    public var webcamEffects: WebcamEffects

    /// PEM-encoded custom root CA certificates to install in the guest.
    public var rootCAs: [String]

    /// Block VM traffic to the host's local network (RFC 1918).
    /// Uses vmnet + packet filtering on the host side (requires vmnet entitlement).
    public var isolateFromLAN: Bool

    /// If set, only these outgoing TCP/UDP ports are allowed (e.g. "80,443,8000-9000").
    /// UDP/53 (DNS) is always allowed regardless of this setting.
    /// nil means all ports are allowed.
    public var allowedPorts: String?

    /// Custom HTTP proxy hostname (e.g. "proxy.example.com").
    public var proxyHost: String?

    /// Custom HTTP proxy port (e.g. 8080).
    public var proxyPort: Int?

    /// Username for proxy authentication (optional).
    public var proxyUsername: String?

    /// Password for proxy authentication (optional).
    public var proxyPassword: String?

    public init(
        cpuCount: Int? = nil,
        memorySize: UInt64 = 4 * 1024 * 1024 * 1024,
        displayWidth: Int = 1920,
        displayHeight: Int = 1080,
        pixelsPerInch: Int = 144,
        enableAudio: Bool = true,
        audioVolume: Int = 100,
        enableWarp: Bool = false,
        forceDarkMode: Bool = false,
        enableAdBlocking: Bool = false,
        swapCmdCtrl: Bool = true,
        homePage: String = "https://www.google.com",
        enableGPU: Bool = true,
        enableWebGL: Bool = false,
        blockMalwareSites: Bool = false,
        enableFileTransfer: Bool = false,
        phishingWarning: Bool = false,
        enableClipboardSharing: Bool = false,
        enableLinkSender: Bool = false,
        enableWebcam: Bool = false,
        enableMicrophone: Bool = false,
        webcamDeviceID: String? = nil,
        microphoneDeviceID: String? = nil,
        speakerDeviceID: String? = nil,
        webcamEffects: WebcamEffects = WebcamEffects(),
        rootCAs: [String] = [],
        isolateFromLAN: Bool = false,
        allowedPorts: String? = nil,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        proxyUsername: String? = nil,
        proxyPassword: String? = nil,
        keyboardLayout: String? = nil,
        naturalScrolling: Bool? = nil,
        locale: String? = nil
    ) {
        let memGB = Int(memorySize / (1024 * 1024 * 1024))
        self.cpuCount = cpuCount ?? min(max(2, memGB * 2), ProcessInfo.processInfo.processorCount)
        self.memorySize = memorySize
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.pixelsPerInch = pixelsPerInch
        self.enableAudio = enableAudio
        self.audioVolume = audioVolume
        self.enableWarp = enableWarp
        self.forceDarkMode = forceDarkMode
        self.enableAdBlocking = enableAdBlocking
        self.swapCmdCtrl = swapCmdCtrl
        self.homePage = homePage
        self.enableGPU = enableGPU
        self.enableWebGL = enableWebGL
        self.blockMalwareSites = blockMalwareSites
        self.enableFileTransfer = enableFileTransfer
        self.phishingWarning = phishingWarning
        self.enableClipboardSharing = enableClipboardSharing
        self.enableLinkSender = enableLinkSender
        self.enableWebcam = enableWebcam
        self.enableMicrophone = enableMicrophone
        self.webcamDeviceID = webcamDeviceID
        self.microphoneDeviceID = microphoneDeviceID
        self.speakerDeviceID = speakerDeviceID
        self.webcamEffects = webcamEffects
        self.rootCAs = rootCAs
        self.isolateFromLAN = isolateFromLAN
        self.allowedPorts = allowedPorts
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.keyboardLayout = keyboardLayout ?? VMConfig.detectKeyboardLayout()
        self.naturalScrolling = naturalScrolling ?? VMConfig.detectNaturalScrolling()
        self.locale = locale ?? VMConfig.detectLocale()
    }

    /// Detect the macOS keyboard layout and map to X11 layout name.
    public static func detectKeyboardLayout() -> String {
        guard let raw = UserDefaults.standard.string(forKey: "AppleCurrentKeyboardLayoutInputSourceID")
                ?? (UserDefaults(suiteName: "com.apple.HIToolbox")?.string(forKey: "AppleCurrentKeyboardLayoutInputSourceID")) else {
            return "us"
        }
        // e.g. "com.apple.keylayout.US" → "us", "com.apple.keylayout.French" → "fr"
        let name = raw.replacingOccurrences(of: "com.apple.keylayout.", with: "").lowercased()
        let map: [String: String] = [
            "us": "us", "u.s.": "us", "abc": "us",
            "british": "gb", "french": "fr", "german": "de",
            "spanish": "es", "italian": "it", "portuguese": "pt",
            "swedish": "se", "norwegian": "no", "danish": "dk",
            "finnish": "fi", "dutch": "nl", "belgian": "be",
            "swiss french": "ch(fr)", "swiss german": "ch(de)",
            "canadian french": "ca(fr)", "czech": "cz",
            "polish": "pl", "russian": "ru", "japanese": "jp",
            "korean": "kr", "turkish": "tr", "arabic": "ara",
            "hebrew": "il", "brazilian": "br",
            "australian": "us", "irish": "ie",
            "colemak": "us(colemak)", "dvorak": "us(dvorak)",
        ]
        return map[name] ?? "us"
    }

    /// Detect macOS natural scrolling preference.
    public static func detectNaturalScrolling() -> Bool {
        // defaults read NSGlobalDomain com.apple.swipescrolldirection
        // Returns true (1) for natural scrolling (macOS default)
        let val = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection")
        // Default to true (natural scrolling) if not set
        return (val as? Bool) ?? true
    }

    /// Detect the display scale factor (1 for non-Retina, 2 for Retina).
    public static func detectDisplayScale() -> Int {
        // NSScreen.main requires main thread; safe to call from settings/init
        if let screen = NSScreen.main {
            return Int(screen.backingScaleFactor)
        }
        return 2 // Default to Retina on Apple Silicon
    }

    /// Detect whether macOS is in dark mode.
    public static func detectDarkMode() -> Bool {
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return style == "Dark"
    }

    /// Detect macOS language and map to Linux locale.
    ///
    /// macOS uses BCP 47 tags like "en-US", "zh-Hant-TW", "zh-Hans-CN", "pt-BR".
    /// Linux expects POSIX locales like "en_US", "zh_TW", "zh_CN", "pt_BR".
    /// The script subtag (Hant/Hans) must be stripped and mapped to a region.
    static func detectLocale() -> String {
        let langs = Locale.preferredLanguages
        guard let first = langs.first else { return "en_US" }

        let parts = first.split(separator: "-")
        let lang = String(parts[0])  // "en", "zh", "pt", etc.

        // Script-based locales (e.g. "zh-Hant", "zh-Hant-TW", "zh-Hans-CN")
        if parts.count >= 2 {
            let second = String(parts[1])
            // If the second component is a script (4 letters), map it to a region
            if second.count == 4 {
                // Use explicit region if present (e.g. "zh-Hant-TW" → "zh_TW")
                if parts.count >= 3 {
                    return "\(lang)_\(parts[2])"
                }
                // Map script to default region
                switch "\(lang)-\(second)" {
                case "zh-Hant": return "zh_TW"
                case "zh-Hans": return "zh_CN"
                default: return "\(lang)_\(second)"
                }
            }
            // Normal lang-region (e.g. "en-US", "pt-BR")
            return "\(lang)_\(second)"
        }

        // Language only (e.g. "fr", "de") — add default region
        let defaultRegions = [
            "en": "US", "fr": "FR", "de": "DE", "es": "ES", "it": "IT",
            "pt": "BR", "ja": "JP", "ko": "KR", "zh": "CN",
            "nl": "NL", "sv": "SE", "nb": "NO", "da": "DK", "fi": "FI",
            "pl": "PL", "cs": "CZ", "tr": "TR", "ru": "RU", "ar": "SA",
            "he": "IL",
        ]
        let region = defaultRegions[lang] ?? lang.uppercased()
        return "\(lang)_\(region)"
    }

    /// Default storage directory: ~/Library/Application Support/Bromure
    public static var defaultStorageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Bromure", isDirectory: true)
    }

    /// Path to the golden base disk image.
    public static func baseImageURL(in storageDir: URL? = nil) -> URL {
        let dir = storageDir ?? defaultStorageDirectory
        return dir.appendingPathComponent("base.img")
    }

    /// Path to the base image auxiliary storage.
    public static func baseAuxURL(in storageDir: URL? = nil) -> URL {
        let dir = storageDir ?? defaultStorageDirectory
        return dir.appendingPathComponent("base-aux.img")
    }

    /// Path to the base image metadata JSON.
    public static func baseMetadataURL(in storageDir: URL? = nil) -> URL {
        let dir = storageDir ?? defaultStorageDirectory
        return dir.appendingPathComponent("base.json")
    }

    /// Network interface suitable for bridged mode.
    public struct BridgedInterface: Identifiable {
        public let id: String          // e.g. "en0"
        public let localizedName: String? // e.g. "Wi-Fi"

        public var displayName: String {
            if let name = localizedName {
                return "\(name) (\(id))"
            }
            return id
        }
    }

    /// List available network interfaces for bridged networking.
    public static func bridgedInterfaces() -> [BridgedInterface] {
        VZBridgedNetworkInterface.networkInterfaces.map {
            BridgedInterface(id: $0.identifier, localizedName: $0.localizedDisplayName)
        }
    }

    /// Path to the saved VM state (for instant restore).
    public static func savedStateURL(in storageDir: URL? = nil, guestOS: GuestOS = .linux) -> URL {
        let dir = storageDir ?? defaultStorageDirectory
        return dir.appendingPathComponent("\(guestOS.rawValue)-vm.state")
    }

}
