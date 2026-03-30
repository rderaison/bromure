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

    /// Active VPN mode for this session.
    public var vpnMode: VPNMode

    /// Convenience accessor — true when Cloudflare WARP is the active VPN.
    public var enableWarp: Bool { vpnMode == .cloudflareWarp }

    /// Whether to automatically connect WARP when the session starts.
    /// Only meaningful when ``vpnMode`` is ``.cloudflareWarp``.
    public var warpAutoConnect: Bool

    /// Raw WireGuard .conf file content to install in the guest.
    /// Only meaningful when ``vpnMode`` is ``.wireGuard``.
    public var wireGuardConfig: String?

    /// Whether to automatically bring up the WireGuard tunnel on session start.
    /// Only meaningful when ``vpnMode`` is ``.wireGuard``.
    public var wireGuardAutoConnect: Bool

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

    /// Whether zero-copy rasterization is enabled (reduces memory copies).
    public var enableZeroCopy: Bool

    /// Whether smooth scrolling is enabled.
    public var enableSmoothScrolling: Bool

    /// Whether to block known malware sites via Cloudflare DNS (1.1.1.2/1.0.0.2).
    public var blockMalwareSites: Bool

    /// Whether to enable file transfer between host and guest.
    public var enableFileTransfer: Bool

    /// Whether to warn about phishing when password fields are detected on suspicious sites.
    public var phishingWarning: Bool

    /// Whether to share the clipboard between host and guest via SPICE agent.
    public var enableClipboardSharing: Bool

    /// Whether to enable passkey (WebAuthn) support via macOS platform authenticator.
    public var enablePasskeys: Bool

    /// Whether to enable password autofill via iCloud Passwords / macOS Keychain.
    public var enablePasswords: Bool

    /// Whether to enable the "Send link to other session" Chrome extension.
    public var enableLinkSender: Bool

    /// Whether to share the host webcam with the guest via vsock + v4l2loopback.
    public var enableWebcam: Bool

    /// Webcam capture quality (maps to AVCaptureSession preset).
    public var webcamQuality: WebcamQuality

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

    /// Per-profile network interface override.
    /// nil = use the global setting from UserDefaults.
    /// "nat" = force NAT mode.
    /// An interface name (e.g. "en0") = force bridged mode on that interface.
    public var networkInterface: String?

    /// Custom HTTP proxy hostname (e.g. "proxy.example.com").
    public var proxyHost: String?

    /// Custom HTTP proxy port (e.g. 8080).
    public var proxyPort: Int?

    /// Username for proxy authentication (optional).
    public var proxyUsername: String?

    /// Password for proxy authentication (optional).
    public var proxyPassword: String?

    /// Block all file downloads inside the guest browser.
    /// When true, Chrome policy blocks downloads and an inotify guard deletes any
    /// files created outside dot-directories in /home/chrome.
    public var blockDownloads: Bool

    /// When true, Chromium starts with --remote-debugging-port and the CDP
    /// agent bridges DevTools Protocol to the host over vsock.
    /// This lets external tools (Puppeteer, Playwright, Claude, Codex) drive the browser.
    public var enableAutomation: Bool

    /// When true, the guest runs test-runner.sh instead of Chromium.
    /// Set via the BROMURE_TEST_SUITE environment variable on the host.
    public var testSuite: Bool

    /// Trace verbosity level. Controls how much HTTP traffic data the
    /// guest agent captures and sends to the host over vsock.
    public var traceLevel: TraceLevel

    /// Whether to dynamically sync the host's keyboard layout to the VM.
    public var matchKeyboardLayout: Bool

    /// Additional Linux kernel boot options appended to the command line.
    /// Default includes module loading and M4 CPU workarounds.
    public var extraKernelOptions: String

    public init(
        cpuCount: Int? = nil,
        memorySize: UInt64 = 4 * 1024 * 1024 * 1024,
        displayWidth: Int = 1920,
        displayHeight: Int = 1080,
        pixelsPerInch: Int = 144,
        enableAudio: Bool = true,
        audioVolume: Int = 100,
        vpnMode: VPNMode = .none,
        warpAutoConnect: Bool = false,
        wireGuardConfig: String? = nil,
        wireGuardAutoConnect: Bool = false,
        forceDarkMode: Bool = false,
        enableAdBlocking: Bool = false,
        swapCmdCtrl: Bool = true,
        homePage: String = "https://bromure.io/hello",
        enableGPU: Bool = true,
        enableWebGL: Bool = false,
        enableZeroCopy: Bool = true,
        enableSmoothScrolling: Bool = true,
        blockMalwareSites: Bool = false,
        enableFileTransfer: Bool = false,
        phishingWarning: Bool = false,
        enableClipboardSharing: Bool = false,
        enablePasskeys: Bool = false,
        enablePasswords: Bool = false,
        enableLinkSender: Bool = false,
        enableWebcam: Bool = false,
        webcamQuality: WebcamQuality = .high,
        enableMicrophone: Bool = false,
        webcamDeviceID: String? = nil,
        microphoneDeviceID: String? = nil,
        speakerDeviceID: String? = nil,
        webcamEffects: WebcamEffects = WebcamEffects(),
        rootCAs: [String] = [],
        isolateFromLAN: Bool = false,
        allowedPorts: String? = nil,
        networkInterface: String? = nil,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        proxyUsername: String? = nil,
        proxyPassword: String? = nil,
        blockDownloads: Bool = false,
        enableAutomation: Bool = false,
        testSuite: Bool = false,
        traceLevel: TraceLevel = .disabled,
        matchKeyboardLayout: Bool = true,
        extraKernelOptions: String = "arm64.nosme",
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
        self.vpnMode = vpnMode
        self.warpAutoConnect = warpAutoConnect
        self.wireGuardConfig = wireGuardConfig
        self.wireGuardAutoConnect = wireGuardAutoConnect
        self.forceDarkMode = forceDarkMode
        self.enableAdBlocking = enableAdBlocking
        self.swapCmdCtrl = swapCmdCtrl
        self.homePage = homePage
        self.enableGPU = enableGPU
        self.enableWebGL = enableWebGL
        self.enableZeroCopy = enableZeroCopy
        self.enableSmoothScrolling = enableSmoothScrolling
        self.blockMalwareSites = blockMalwareSites
        self.enableFileTransfer = enableFileTransfer
        self.phishingWarning = phishingWarning
        self.enableClipboardSharing = enableClipboardSharing
        self.enablePasskeys = enablePasskeys
        self.enablePasswords = enablePasswords
        self.enableLinkSender = enableLinkSender
        self.enableWebcam = enableWebcam
        self.webcamQuality = webcamQuality
        self.enableMicrophone = enableMicrophone
        self.webcamDeviceID = webcamDeviceID
        self.microphoneDeviceID = microphoneDeviceID
        self.speakerDeviceID = speakerDeviceID
        self.webcamEffects = webcamEffects
        self.rootCAs = rootCAs
        self.isolateFromLAN = isolateFromLAN
        self.allowedPorts = allowedPorts
        self.networkInterface = networkInterface
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.blockDownloads = blockDownloads
        self.enableAutomation = enableAutomation
        self.testSuite = testSuite
        self.traceLevel = traceLevel
        self.matchKeyboardLayout = matchKeyboardLayout
        self.extraKernelOptions = extraKernelOptions
        self.keyboardLayout = keyboardLayout ?? VMConfig.detectKeyboardLayout()
        self.naturalScrolling = naturalScrolling ?? VMConfig.detectNaturalScrolling()
        self.locale = locale ?? VMConfig.detectLocale()
    }

    /// Mapping from macOS keyboard layout names (lowercased, without `com.apple.keylayout.` prefix)
    /// to X11/XKB layout specifications.
    ///
    /// Plain values like `"fr"` are layout-only. Values with a colon like `"ch:fr"` encode
    /// `layout:variant` — the keyboard agent and xorg template split on `:` to pass
    /// `-layout ch -variant fr` to `setxkbmap`.
    ///
    /// Generated from the full output of `TISCreateInputSourceList(nil, true)` on macOS 26
    /// cross-referenced with `/usr/share/X11/xkb/rules/evdev.lst`.
    static let macOSToXkbMap: [String: String] = [
        // ── US / Generic Latin ────────────────────────────────────────────
        "us":                       "us",
        "u.s.":                     "us",       // legacy name
        "abc":                      "us",       // ABC is a US-QWERTY superset
        "abc-india":                "us",       // ABC - India (Latin QWERTY)
        "usextended":               "us",       // US Extended (dead-key compose)
        "usinternational-pc":       "us:intl",  // US International - PC
        "unicodehexinput":          "us",       // Unicode Hex Input (no XKB equivalent)
        "australian":               "us",       // Australian (same as US)
        "newzealand":               "us",       // New Zealand (same as US)
        "hawaiian":                 "us",       // Hawaiian (Latin QWERTY)
        "samoan":                   "us",       // Samoan (Latin QWERTY)
        "tongan":                   "us",       // Tongan (Latin QWERTY)
        "maori":                    "us",       // Māori (Latin QWERTY)

        // ── Alternative Latin layouts ─────────────────────────────────────
        "colemak":                  "us:colemak",
        "dvorak":                   "us:dvorak",
        "dvorak-left":              "us:dvorak-l",
        "dvorak-right":             "us:dvorak-r",
        "dvorak-qwertycmd":         "us:dvorak", // Dvorak QWERTY-⌘ (no XKB equivalent for cmd layer)

        // ── ABC layout variants (macOS 14+) ──────────────────────────────
        "abc-azerty":               "fr",
        "abc-qwertz":               "de",

        // ── British / Irish ───────────────────────────────────────────────
        "british":                  "gb",
        "british-pc":               "gb",
        "irish":                    "ie",
        "irishextended":            "ie",
        "welsh":                    "gb",       // Welsh (no dedicated XKB; gb is closest)

        // ── French ────────────────────────────────────────────────────────
        "french":                   "fr",
        "french-pc":                "fr",
        "french-numerical":         "fr",       // French Numerical (same base layout)

        // ── German ────────────────────────────────────────────────────────
        "german":                   "de",
        "german-din-2137":          "de",       // DIN 2137 variant
        "austrian":                 "at",

        // ── Swiss ─────────────────────────────────────────────────────────
        "swissfrench":              "ch:fr",
        "swissgerman":              "ch",

        // ── Canadian ──────────────────────────────────────────────────────
        "canadian":                 "ca",
        "canadian-csa":             "ca:multix", // Canadian French (CSA) → Canadian Multilingual
        "canadianfrench-pc":        "ca:fr-legacy",

        // ── Spanish ───────────────────────────────────────────────────────
        "spanish":                  "es",
        "spanish-iso":              "es",
        "latinamerican":            "latam",

        // ── Portuguese / Brazilian ────────────────────────────────────────
        "portuguese":               "pt",
        "brazilian":                "br",
        "brazilian-abnt2":          "br",
        "brazilian-pro":            "br",

        // ── Italian ───────────────────────────────────────────────────────
        "italian":                  "it",
        "italian-pro":              "it",

        // ── Dutch / Belgian ───────────────────────────────────────────────
        "dutch":                    "nl",
        "belgian":                  "be",

        // ── Nordic ────────────────────────────────────────────────────────
        "swedish":                  "se",
        "swedish-pro":              "se",
        "norwegian":                "no",
        "norwegianextended":        "no",
        "danish":                   "dk",
        "finnish":                  "fi",
        "finnishextended":          "fi",
        "faroese":                  "fo",
        "icelandic":                "is",

        // ── Sami layouts ──────────────────────────────────────────────────
        "northernsami":             "no:smi",
        "finnishsami-pc":           "fi:smi",
        "norwegiansami-pc":         "no:smi",
        "swedishsami-pc":           "se:smi",
        "inarisami":                "fi:smi",      // Inari Sami → Finnish Sami
        "skoltsami":                "fi:smi",      // Skolt Sami → Finnish Sami
        "julevsami":                "se:smi",      // Lule Sami (Sweden)
        "julevsami-norway":         "no:smi",      // Lule Sami (Norway)
        "pitesami":                 "se:smi",      // Pite Sami → Swedish Sami
        "southernsami":             "no:smi",      // Southern Sami → Norwegian Sami
        "umesami":                  "se:smi",      // Ume Sami → Swedish Sami
        "kildinsami":               "ru",          // Kildin Sami → Russian base
        "sami-pc":                  "no:smi",

        // ── Baltic ────────────────────────────────────────────────────────
        "estonian":                 "ee",
        "latvian":                  "lv",
        "lithuanian":               "lt",
        "lithuanian-lst1582":       "lt:std",      // LST 1582 → Lithuanian standard

        // ── Central / Eastern European ────────────────────────────────────
        "czech":                    "cz",
        "czech-qwerty":             "cz:qwerty",
        "polish":                   "pl",
        "polishpro":                "pl",
        "slovak":                   "sk",
        "slovak-qwerty":            "sk:qwerty",
        "hungarian":                "hu",
        "hungarian-qwerty":         "hu:qwerty",
        "slovenian":                "si",
        "croatian":                 "hr",
        "croatian-pc":              "hr",
        "romanian":                 "ro",
        "romanian-standard":        "ro:std",
        "serbian":                  "rs",
        "serbian-latin":            "rs:latin",
        "maltese":                  "mt",
        "albanian":                 "al",

        // ── Cyrillic ─────────────────────────────────────────────────────
        "russian":                  "ru",
        "russian-phonetic":         "ru:phonetic",
        "russianwin":               "ru",          // Russian - PC (same base)
        "ukrainian":                "ua",
        "ukrainian-pc":             "ua:winkeys",
        "ukrainian-qwerty":         "ua:phonetic",
        "byelorussian":             "by",
        "bulgarian":                "bg",
        "bulgarian-phonetic":       "bg:phonetic",
        "macedonian":               "mk",
        "mongolian-cyrillic":       "mn",
        "kazakh":                   "kz",
        "kyrgyz-cyrillic":          "kg",
        "tajik-cyrillic":           "tj",
        "uzbek-cyrillic":           "uz",
        "turkmen":                  "tm",
        "chuvash":                  "ru:cv",

        // ── Turkish / Azerbaijani ─────────────────────────────────────────
        "turkish":                  "tr",
        "turkish-qwerty":           "tr",
        "turkish-qwerty-pc":        "tr",
        "turkish-standard":         "tr:f",
        "azeri":                    "az",

        // ── Greek ─────────────────────────────────────────────────────────
        "greek":                    "gr",
        "greekpolytonic":           "gr:polytonic",

        // ── Georgian / Armenian ───────────────────────────────────────────
        "georgian-qwerty":          "ge",
        "armenian-hmqwerty":        "am",
        "armenian-westernqwerty":   "am:western",

        // ── Arabic ────────────────────────────────────────────────────────
        "arabic":                   "ara",
        "arabic-qwerty":            "ara:qwerty",
        "arabic-northafrica":       "ara",
        "arabic-azerty":            "ara:azerty",
        "arabicpc":                 "ara",

        // ── Hebrew ────────────────────────────────────────────────────────
        "hebrew":                   "il",
        "hebrew-pc":                "il",
        "hebrew-qwerty":            "il",

        // ── Persian / Dari / Pashto ───────────────────────────────────────
        "persian":                  "ir",
        "persian-isiri2901":        "ir",
        "persian-qwerty":           "ir",
        "afghandari":               "af",
        "afghanpashto":             "af:ps",
        "afghanuzbek":              "af:uz",

        // ── Kurdish ───────────────────────────────────────────────────────
        "kurdish-kurmanji":         "tr:ku",
        "kurdish-sorani":           "iq:ku",

        // ── Urdu / Sindhi ─────────────────────────────────────────────────
        "urdu":                     "pk",
        "sindhi":                   "pk:snd",
        "sindhi-devanagari":        "in",

        // ── Indic: Devanagari ─────────────────────────────────────────────
        "devanagari":               "in",
        "devanagari-qwerty":        "in",
        "marathi":                  "in",
        "nepali":                   "np",
        "nepali-is16350":           "np",
        "sanskrit":                 "in",
        "konkani":                  "in",
        "maithili":                 "in",
        "dogri":                    "in",
        "bodo":                     "in",
        "kashmiri-devanagari":      "in",
        "santali-devanagari":       "in",

        // ── Indic: Bangla / Assamese ──────────────────────────────────────
        "bangla":                   "bd",
        "bangla-qwerty":            "bd",
        "assamese":                 "in",
        "manipuri-bengali":         "in",

        // ── Indic: Tamil / Telugu / Kannada / Malayalam / Oriya ────────────
        "tamil99":                  "in",
        "telugu":                   "in",
        "telugu-qwerty":            "in",
        "kannada":                  "in",
        "kannada-qwerty":           "in",
        "malayalam":                "in",
        "malayalam-qwerty":         "in",
        "oriya":                    "in",
        "oriya-qwerty":             "in",

        // ── Indic: Gujarati / Gurmukhi ────────────────────────────────────
        "gujarati":                 "in",
        "gujarati-qwerty":          "in",
        "gurmukhi":                 "in",
        "gurmukhi-qwerty":          "in",
        "anjal":                    "in",          // Tamil Anjal

        // ── Indic: Transliteration ────────────────────────────────────────
        "transliteration-ar":       "ara",
        "transliteration-bn":       "bd",
        "transliteration-gu":       "in",
        "transliteration-hi":       "in",
        "transliteration-kn":       "in",
        "transliteration-ml":       "in",
        "transliteration-mr":       "in",
        "transliteration-pa":       "in",
        "transliteration-ta":       "in",
        "transliteration-te":       "in",
        "transliteration-ur":       "pk",

        // ── Indic: Other scripts ──────────────────────────────────────────
        "santali-olchiki":          "in",
        "manipuri-meeteimayek":     "in",

        // ── Sinhala ───────────────────────────────────────────────────────
        "sinhala":                  "lk",
        "sinhala-qwerty":           "lk:us",

        // ── Tibetan / Dzongkha ────────────────────────────────────────────
        "tibetan-qwerty":           "cn:tib",
        "tibetan-wylie":            "cn:tib",
        "tibetanotanius":           "cn:tib",
        "dzongkha":                 "bt",

        // ── Southeast Asian ───────────────────────────────────────────────
        "thai":                     "th",
        "thai-pattachote":          "th:pat",
        "thai-qwerty":              "th",          // Thai QWERTY overlay
        "khmer":                    "kh",
        "lao":                      "la",
        "myanmar":                  "mm",
        "myanmar-qwerty":           "mm",
        "vietnamese":               "vn",

        // ── Dhivehi (Maldives) ────────────────────────────────────────────
        "dhivehi-qwerty":           "mv",

        // ── CJK ───────────────────────────────────────────────────────────
        "japanese":                 "jp",
        "kana":                     "jp",
        "korean":                   "kr",
        "2sethangul":               "kr",
        "3sethangul":               "kr",
        "390hangul":                "kr",
        "gjcromaja":                "kr",
        "hncromaja":                "kr",

        // Chinese (layout-only)
        "pinyinkeyboard":           "cn",
        "traditionalpinyinkeyboard":"tw",
        "wubihuakeyboard":          "cn",
        "traditionalwubihuakeyboard":"tw",
        "zhuyinbopomofo":           "tw",
        "zhuyineten":               "tw",
        "cangjiekeyboard":          "tw",

        // ── Uyghur ────────────────────────────────────────────────────────
        "uyghur":                   "cn:ug",

        // ── African ───────────────────────────────────────────────────────
        "akan":                     "gh:akan",
        "hausa":                    "ng:hausa",
        "igbo":                     "ng:igbo",
        "yoruba":                   "ng:yoruba",
        "geez-qwerty":              "et",          // Geʿez (Amharic)

        // ── African: other ────────────────────────────────────────────────
        "kabyle-azerty":            "dz",          // Kabyle AZERTY → Algeria
        "kabyle-qwerty":            "dz",
        "tifinagh-azerty":          "ma:tifinagh", // Tifinagh → Morocco
        "haitian-creole":           "fr",          // Haitian Creole AZERTY base

        // ── Syriac / Mandaic ──────────────────────────────────────────────
        "syriac-arabic":            "sy:syc",
        "syriac-qwerty":            "sy:syc_phonetic",
        "mandaic-arabic":           "ara",
        "mandaic-qwerty":           "ara",

        // ── Yiddish ───────────────────────────────────────────────────────
        "yiddish-qwerty":           "il",

        // ── Inuit / Indigenous Canadian ────────────────────────────────────
        "inuktitut-qwerty":         "ca:ike",
        "inuktitut-nattilik":       "ca:ike",
        "inuktitut-nunavut":        "ca:ike",
        "inuktitut-nutaaq":         "ca:ike",
        "inuttitutnunavik":         "ca:ike",

        // ── Indigenous North American ─────────────────────────────────────
        "cherokee-nation":          "us:chr",
        "cherokee-qwerty":          "us:chr",
        "navajo":                   "us",          // Navajo (Latin QWERTY base)
        "lushootseed":              "us",
        "chickasaw":                "us",
        "choctaw":                  "us",
        "chochenyo":                "us",
        "mvskoke":                  "us",
        "nezperce":                 "us",
        "apache":                   "us",
        "mikmaw":                   "us",          // Mi'kmaw
        "wolastoqey":               "us",
        "osage-qwerty":             "us",
        "wixarika":                 "latam",       // Wixárika (Huichol)

        // ── Jawi / Malay ──────────────────────────────────────────────────
        "jawi-qwerty":              "my",

        // ── Other scripts ─────────────────────────────────────────────────
        "nko":                      "us",          // N'Ko (no standard XKB)
        "nko-qwerty":               "us",
        "adlam-qwerty":             "us",          // Adlam (no standard XKB)
        "rejang-qwerty":            "us",          // Rejang (no standard XKB)
        "wancho-qwerty":            "us",          // Wancho (no standard XKB)
        "hanifi-rohingya-qwerty":   "us",          // Hanifi Rohingya (no standard XKB)
        "pahawh-hmong":             "us",          // Pahawh Hmong (no standard XKB)
        "ingush":                   "ru",          // Ingush (Cyrillic base)
    ]

    /// Detect the macOS keyboard layout and map to X11 layout name.
    ///
    /// Reads `AppleCurrentKeyboardLayoutInputSourceID` from the HIToolbox
    /// preferences domain. This is updated by the system immediately when
    /// the user switches keyboards and is reliable on macOS 26.
    public static func detectKeyboardLayout() -> String {
        guard let raw = UserDefaults(suiteName: "com.apple.HIToolbox")?
                .string(forKey: "AppleCurrentKeyboardLayoutInputSourceID")
                ?? UserDefaults.standard.string(forKey: "AppleCurrentKeyboardLayoutInputSourceID") else {
            return "us"
        }
        // e.g. "com.apple.keylayout.US" → "us", "com.apple.keylayout.ABC-AZERTY" → "abc-azerty"
        let name = raw.replacingOccurrences(of: "com.apple.keylayout.", with: "").lowercased()
        return macOSToXkbMap[name] ?? "us"
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

    /// Default extra kernel boot options.
    public static let defaultExtraKernelOptions = "arm64.nosme"

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
