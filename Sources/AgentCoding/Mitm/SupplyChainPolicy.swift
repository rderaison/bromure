import Foundation

/// Supply-chain security policy enforced host-side in the MITM proxy.
/// Sits on the same per-profile model as `GuardrailsPolicy`, but where
/// guardrails strips destructive operations the agent issues, supply-
/// chain protects the agent from acquiring compromised packages in
/// the first place.
///
/// Five distinct layers, each independently toggled:
///   1. **Age gate** — refuse versions younger than `ageGateDays`.
///      Default on, 2 days. Floating refs (`pkg@latest`, semver
///      ranges) silently resolve to the newest *allowed* version
///      by metadata rewriting; pinned references to too-fresh
///      versions get a 451 with a clear reason.
///   2. **OSV vulnerability lookup** (osv.dev). Free, no key.
///      Default OFF (off-by-default because workflows rarely
///      benefit from being interrupted by a low-severity XSS in
///      a transitive subpackage).
///   3. **socket.dev "compromised package" check** (BYO API key).
///      Default OFF. Catches typosquats, malware flags, suspicious
///      install scripts.
///   4. **socket.dev "known CVE" check** (same API key, distinct
///      filter on their `vulnerability` issue bucket). Default OFF
///      — same reasoning as OSV.
///   5. **Install-script stripping** — rewrites tarballs to remove
///      preinstall / install / postinstall / prepare hooks. Per-
///      package allowlist for genuine binding compilers
///      (better-sqlite3, node-canvas, etc.). Default OFF.
///   6. **Lockfile-pinned (npm ci / pip --require-hashes) bypass
///      prompt** — when the client fetches a tarball with integrity
///      pinned by a lockfile, we can't rewrite without breaking
///      hash verification. Default OFF: pass through unmodified.
///      When on, asks the user once per burst (via
///      SupplyChainConsentBroker) before passing through.
///
/// All policy decisions are enforced at the MITM proxy: the in-VM
/// `.npmrc` / `pip.conf` can only *further* restrict what the proxy
/// served, never loosen these settings.
public struct SupplyChainPolicy: Codable, Equatable, Sendable {

    /// Severity threshold used by both OSV and socket.dev CVE check.
    /// We block anything at or above the selected level.
    public enum Severity: String, Codable, CaseIterable, Sendable {
        case low, medium, high, critical

        public var displayName: String {
            switch self {
            case .low:      return NSLocalizedString("Low and above", comment: "")
            case .medium:   return NSLocalizedString("Medium and above", comment: "")
            case .high:     return NSLocalizedString("High and above", comment: "")
            case .critical: return NSLocalizedString("Critical only", comment: "")
            }
        }

        /// Ordering for comparison ("at or above this level"). Lower
        /// raw value = laxer.
        public var rank: Int {
            switch self {
            case .low: return 0
            case .medium: return 1
            case .high: return 2
            case .critical: return 3
            }
        }
    }

    // MARK: - Age gate

    /// Refuse versions younger than `ageGateDays`. Floating refs
    /// silently resolve to the newest allowed version; pinned refs
    /// to too-fresh versions get a 451.
    public var ageGateEnabled: Bool
    public var ageGateDays: Int
    /// Packages exempt from age gating, in `ecosystem:name` format
    /// (e.g. `npm:axios`, `pypi:requests`). A bare `name` matches
    /// the package in every ecosystem.
    public var ageGateAllowlist: [String]

    // MARK: - OSV

    public var osvEnabled: Bool
    public var osvSeverity: Severity

    // MARK: - socket.dev

    /// User's socket.dev API key. NEVER exported into the VM — the
    /// proxy reads it directly from the profile and calls
    /// `api.socket.dev` host-side. Empty = socket.dev features
    /// disabled regardless of the toggles below.
    public var socketAPIKey: String
    /// Block on `supplyChainRisk` issues (rogue postinstall, malware
    /// flag, typosquatting, telemetry, suspicious network access).
    /// Default OFF — only the age gate is on out of the box.
    public var socketBlockCompromised: Bool
    /// Block on `vulnerability` issues (known CVEs). Default OFF —
    /// otherwise a low-severity XSS in a transitive subpackage
    /// interrupts everything.
    public var socketBlockCVE: Bool
    public var socketCVESeverity: Severity

    // MARK: - Install-script stripping

    /// Strip preinstall / install / postinstall / prepare scripts
    /// from package tarballs before forwarding to the client. The
    /// integrity hash is recomputed and substituted into the
    /// registry metadata so npm's hash check still passes.
    public var stripInstallScripts: Bool
    /// Packages where install scripts are preserved (genuine binding
    /// compilers). Same `ecosystem:name` format as ageGateAllowlist.
    public var stripAllowlist: [String]

    // MARK: - Lockfile-pinned bypass prompt

    /// When true, lockfile-pinned tarball fetches (which we can't
    /// safely rewrite) trigger a `SupplyChainConsentBroker` prompt
    /// before being passed through. Default false: silently pass
    /// them through.
    public var lockfilePrompt: Bool

    // MARK: - Default / init

    /// All defaults baked in. Used both as the empty constructor
    /// (for Codable's "field missing → defaults" path) AND as the
    /// new-profile default. Only the age gate (2-day cooldown) is on
    /// out of the box; every other layer is opt-in.
    public init(
        ageGateEnabled: Bool = true,
        ageGateDays: Int = 2,
        ageGateAllowlist: [String] = [],
        osvEnabled: Bool = false,
        osvSeverity: Severity = .high,
        socketAPIKey: String = "",
        socketBlockCompromised: Bool = false,
        socketBlockCVE: Bool = false,
        socketCVESeverity: Severity = .high,
        stripInstallScripts: Bool = false,
        stripAllowlist: [String] = [],
        lockfilePrompt: Bool = false
    ) {
        self.ageGateEnabled = ageGateEnabled
        self.ageGateDays = ageGateDays
        self.ageGateAllowlist = ageGateAllowlist
        self.osvEnabled = osvEnabled
        self.osvSeverity = osvSeverity
        self.socketAPIKey = socketAPIKey
        self.socketBlockCompromised = socketBlockCompromised
        self.socketBlockCVE = socketBlockCVE
        self.socketCVESeverity = socketCVESeverity
        self.stripInstallScripts = stripInstallScripts
        self.stripAllowlist = stripAllowlist
        self.lockfilePrompt = lockfilePrompt
    }

    /// True if any layer of the policy is doing something. The proxy
    /// short-circuits the registry-intercept hot path when nothing's
    /// configured.
    public var isActive: Bool {
        ageGateEnabled
            || osvEnabled
            || (!socketAPIKey.isEmpty && (socketBlockCompromised || socketBlockCVE))
            || stripInstallScripts
            || lockfilePrompt
    }

    /// Whether socket.dev is usable at all (key plus at least one
    /// of the two filters enabled). The proxy reads this before
    /// dialling api.socket.dev.
    public var socketActive: Bool {
        !socketAPIKey.isEmpty && (socketBlockCompromised || socketBlockCVE)
    }

    // MARK: - Allowlist helpers

    /// Does `ecosystem:name` (or bare `name`) appear in the age
    /// gate allowlist? Allowlist entries can be `npm:axios` to
    /// restrict to one ecosystem, or just `axios` to apply across
    /// every ecosystem.
    public func ageGateAllows(ecosystem: String, name: String) -> Bool {
        Self.allowlistMatches(ageGateAllowlist, ecosystem: ecosystem, name: name)
    }

    public func scriptStripAllows(ecosystem: String, name: String) -> Bool {
        Self.allowlistMatches(stripAllowlist, ecosystem: ecosystem, name: name)
    }

    private static func allowlistMatches(_ list: [String],
                                          ecosystem: String,
                                          name: String) -> Bool {
        let lowerName = name.lowercased()
        let scoped = (ecosystem + ":" + name).lowercased()
        for entry in list {
            let e = entry.lowercased()
            if e == lowerName || e == scoped { return true }
        }
        return false
    }

    // MARK: - Codable (tolerant of missing fields)

    enum CodingKeys: String, CodingKey {
        case ageGateEnabled, ageGateDays, ageGateAllowlist
        case osvEnabled, osvSeverity
        case socketAPIKey, socketBlockCompromised, socketBlockCVE, socketCVESeverity
        case stripInstallScripts, stripAllowlist
        case lockfilePrompt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ageGateEnabled        = try c.decodeIfPresent(Bool.self, forKey: .ageGateEnabled) ?? true
        ageGateDays           = try c.decodeIfPresent(Int.self, forKey: .ageGateDays) ?? 2
        ageGateAllowlist      = try c.decodeIfPresent([String].self, forKey: .ageGateAllowlist) ?? []
        osvEnabled            = try c.decodeIfPresent(Bool.self, forKey: .osvEnabled) ?? false
        osvSeverity           = try c.decodeIfPresent(Severity.self, forKey: .osvSeverity) ?? .high
        socketAPIKey          = try c.decodeIfPresent(String.self, forKey: .socketAPIKey) ?? ""
        socketBlockCompromised = try c.decodeIfPresent(Bool.self, forKey: .socketBlockCompromised) ?? false
        socketBlockCVE        = try c.decodeIfPresent(Bool.self, forKey: .socketBlockCVE) ?? false
        socketCVESeverity     = try c.decodeIfPresent(Severity.self, forKey: .socketCVESeverity) ?? .high
        stripInstallScripts   = try c.decodeIfPresent(Bool.self, forKey: .stripInstallScripts) ?? false
        stripAllowlist        = try c.decodeIfPresent([String].self, forKey: .stripAllowlist) ?? []
        lockfilePrompt        = try c.decodeIfPresent(Bool.self, forKey: .lockfilePrompt) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Encode only non-default fields. Keeps profile.json small and
        // future-proofs default changes (a future bromure-AC with a
        // stricter default doesn't accidentally lock old profiles to
        // the previous laxer setting).
        if ageGateEnabled != true   { try c.encode(ageGateEnabled, forKey: .ageGateEnabled) }
        if ageGateDays != 2         { try c.encode(ageGateDays, forKey: .ageGateDays) }
        if !ageGateAllowlist.isEmpty { try c.encode(ageGateAllowlist, forKey: .ageGateAllowlist) }
        if osvEnabled != false      { try c.encode(osvEnabled, forKey: .osvEnabled) }
        if osvSeverity != .high     { try c.encode(osvSeverity, forKey: .osvSeverity) }
        if !socketAPIKey.isEmpty    { try c.encode(socketAPIKey, forKey: .socketAPIKey) }
        if socketBlockCompromised != false { try c.encode(socketBlockCompromised, forKey: .socketBlockCompromised) }
        if socketBlockCVE != false  { try c.encode(socketBlockCVE, forKey: .socketBlockCVE) }
        if socketCVESeverity != .high { try c.encode(socketCVESeverity, forKey: .socketCVESeverity) }
        if stripInstallScripts != false { try c.encode(stripInstallScripts, forKey: .stripInstallScripts) }
        if !stripAllowlist.isEmpty  { try c.encode(stripAllowlist, forKey: .stripAllowlist) }
        if lockfilePrompt != false   { try c.encode(lockfilePrompt, forKey: .lockfilePrompt) }
    }
}
