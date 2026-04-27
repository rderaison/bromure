import AppKit
import Foundation
import SandboxEngine

/// Manages a profile's persistent disk and the per-launch metadata share.
///
/// The disk is a CoW clone of the base image — first-launch creates it via
/// APFS clonefile (instant, no copy). Subsequent launches reuse the
/// clone, which keeps any modifications the user (or claude) made.
///
/// The metadata share is a small temp directory recreated each launch.
/// It carries the API key (api_key.env), the profile's SSH keys, and an
/// init script the guest sources on login.
public final class SessionDisk {
    public let profile: Profile
    private let store: ProfileStore
    private let baseDiskURL: URL
    private let fm = FileManager.default

    /// The fake↔real token plan for this session. Populated by the
    /// caller before `prepareMetadataShare()` so the meta share carries
    /// fakes (not the real values). nil = no MITM rewriting (used by
    /// the smoke-test path that bypasses the engine).
    public var tokenPlan: SessionTokenPlan?

    /// CA + bridge resources to drop into the meta share. Populated by
    /// the caller alongside `tokenPlan`. nil = MITM not configured for
    /// this session.
    public var mitmAssets: MitmSessionAssets?

    public struct MitmSessionAssets: Sendable {
        public let caCertificatePEM: String
        public let bridgeScriptURL: URL
        /// Optional keyboard agent script URL — copied into the meta
        /// share so the guest's xinitrc can launch it. nil = no
        /// keyboard layout matching for this session.
        public let keyboardAgentURL: URL?
        /// Optional scroll agent script URL. Same delivery pattern as
        /// the keyboard agent — copied to the meta share, launched
        /// from xinitrc, listens on vsock 5008 for batched scroll
        /// directions from the host's `ScrollBridge`.
        public let scrollAgentURL: URL?
        /// AWS `credential_process` helper. Referenced from the
        /// per-profile ~/.aws/config; pulls JSON creds on demand from
        /// the bridge's Unix socket.
        public let awsCredsHelperURL: URL?
        public init(caCertificatePEM: String,
                    bridgeScriptURL: URL,
                    keyboardAgentURL: URL? = nil,
                    scrollAgentURL: URL? = nil,
                    awsCredsHelperURL: URL? = nil) {
            self.caCertificatePEM = caCertificatePEM
            self.bridgeScriptURL = bridgeScriptURL
            self.keyboardAgentURL = keyboardAgentURL
            self.scrollAgentURL = scrollAgentURL
            self.awsCredsHelperURL = awsCredsHelperURL
        }
    }

    public init(profile: Profile, store: ProfileStore, baseDiskURL: URL) {
        self.profile = profile
        self.store = store
        self.baseDiskURL = baseDiskURL
    }

    public var diskURL: URL { store.diskURL(for: profile) }

    /// Persistent host-side /home/ubuntu mirror, shared into the guest.
    public var homeDirectory: URL { store.homeDirectory(for: profile) }

    /// Saved-state file path for VM suspend/restore. Lives in the profile
    /// directory so it survives across app launches. The matching
    /// configuration is reconstructed deterministically from the
    /// per-profile MAC + machine identifier files, so no sidecar JSON
    /// is needed.
    public var savedStateURL: URL {
        store.profileDirectory(for: profile).appendingPathComponent("vm.state")
    }
    public var hasSavedState: Bool {
        fm.fileExists(atPath: savedStateURL.path)
    }

    /// Per-tab snapshot persisted alongside `vm.state` so the host
    /// can rebuild its tab bar with the same UUIDs the in-VM kittys
    /// were started under (`--class bromure-<UUID>`). Without this,
    /// every restore spawned a brand-new kitty even though the
    /// resumed snapshot already had the originals running.
    public struct TabSnapshot: Codable {
        public let id: UUID
        public var label: String
    }

    public struct TabsState: Codable {
        public var tabs: [TabSnapshot]
        public var activeIndex: Int
    }

    public var tabsURL: URL {
        store.profileDirectory(for: profile).appendingPathComponent("tabs.json")
    }

    /// Snapshot the host's tab model alongside `vm.state` so restore
    /// can rebuild it. No-ops on encode failures — losing the tab
    /// snapshot just means restore falls back to spawning a fresh
    /// first tab, which is the old behaviour.
    public func saveTabs(_ state: TabsState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let dir = tabsURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: tabsURL, options: .atomic)
    }

    /// Read the saved tabs file, or nil if missing / unreadable.
    /// Callers should only consume this when `hasSavedState` is true —
    /// a tabs.json without a matching vm.state is stale (the kittys
    /// it references don't exist on a fresh boot).
    public func loadTabs() -> TabsState? {
        guard fm.fileExists(atPath: tabsURL.path),
              let data = try? Data(contentsOf: tabsURL),
              let state = try? JSONDecoder().decode(TabsState.self, from: data)
        else { return nil }
        return state
    }

    /// Stable per-profile VZGenericMachineIdentifier persisted on disk.
    /// `VZGenericMachineIdentifier()` returns a fresh random ID on each
    /// call — using that meant every `prepare()` got a different machine
    /// identity, which made `restoreMachineStateFrom` fail with VZ
    /// Code 12 (invalid argument) because the saved RAM expects the
    /// original ID. Generating once + persisting fixes that AND gives
    /// the guest a stable machine-id across launches.
    public var machineIdentifierURL: URL {
        store.profileDirectory(for: profile)
            .appendingPathComponent("machine-identifier.bin")
    }

    /// Load (or mint + persist) the deterministic MAC for this profile.
    /// Backed by `MACBindings` — a single `profile-macs.json` keyed by
    /// profile UUID, so the mapping is inspectable in one place.
    public func persistentMACAddress() -> String {
        MACBindings.shared.macAddress(for: profile.id)
    }

    /// Per-launch directory shared into the guest as the "bromure-meta"
    /// virtiofs tag. Wiped + recreated on each call so old API keys / SSH
    /// keys don't leak across reset cycles.
    public private(set) var metadataDirectory: URL?

    /// Per-launch writable directory shared into the guest as the
    /// "bromure-outbox" virtiofs tag. The guest drops one file per URL it
    /// wants the host to open (e.g. when the user clicks a URL in kitty);
    /// the host polls + relays to NSWorkspace.
    public private(set) var outboxDirectory: URL?

    /// True if `ensureDiskExists()` had to clonefile() a fresh disk on the
    /// most recent call. Caller uses this to stamp the profile with the
    /// base-image version that was just cloned, for drift detection later.
    public private(set) var didCloneOnLastEnsure: Bool = false

    /// Resolved set of (host folder URL, guest mount basename) pairs for
    /// every folder this profile shares into the VM. Capped at 8 to match
    /// the base image's pre-allocated fstab slots.
    public struct SharedFolder: Sendable {
        public let url: URL
        public let mountName: String  // basename used for ~ubuntu/<name>
    }

    public var sharedFolders: [SharedFolder] {
        var seen: Set<String> = []
        var result: [SharedFolder] = []
        for path in profile.folderPaths.prefix(8) {
            let url = URL(fileURLWithPath: path)
            var name = url.lastPathComponent
            if name.isEmpty { name = "share" }
            // De-dup basenames so two folders named "src" don't both
            // try to symlink to ~ubuntu/src.
            var unique = name
            var n = 2
            while seen.contains(unique) {
                unique = "\(name)-\(n)"
                n += 1
            }
            seen.insert(unique)
            result.append(SharedFolder(url: url, mountName: unique))
        }
        return result
    }

    // MARK: - Disk

    /// Create the per-profile disk if it doesn't exist. Uses APFS
    /// clonefile() for an instant zero-cost copy of base.img.
    public func ensureDiskExists() throws {
        if fm.fileExists(atPath: diskURL.path) {
            didCloneOnLastEnsure = false
            return
        }
        try fm.createDirectory(
            at: diskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // clonefile is the APFS CoW primitive. Falls back to copyItem on
        // non-APFS volumes (slow but correct).
        let result = clonefile(baseDiskURL.path, diskURL.path, 0)
        if result != 0 {
            try fm.copyItem(at: baseDiskURL, to: diskURL)
        }
        didCloneOnLastEnsure = true
    }

    // MARK: - Metadata share

    /// Build the metadata share for this launch. Returns the directory
    /// to share via virtiofs (read-only is fine — the guest only reads).
    ///
    /// The path is **stable per-profile** (under the profile dir, not /tmp)
    /// so VZ's saveMachineStateTo / restoreMachineStateFrom configuration
    /// matches across launches when the profile is set to suspend on
    /// close.
    ///
    /// `forRestore` toggles whether to wipe the directory before
    /// rewriting. On fresh boot we wipe so stale files from older
    /// versions can't leak in. On restore we preserve the directory
    /// inode — recreating it has been observed to confuse the
    /// resumed guest's virtiofs cache, so file writes from
    /// already-running guest processes (the kitty wrapper subshell,
    /// for instance) silently land somewhere the host can't see them.
    @MainActor
    public func prepareMetadataShare(forRestore: Bool = false) throws -> URL {
        let tmp = store.profileDirectory(for: profile)
            .appendingPathComponent("meta-share", isDirectory: true)
        if !forRestore {
            try? fm.removeItem(at: tmp)
        }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // api_key.env — sourced by .bashrc inside the guest. Exports
        // the env var for every enabled tool in token mode. The values
        // are FAKE tokens minted by SessionTokenPlan: the host's MITM
        // engine swaps each fake for the real key on the wire. The VM
        // only ever holds the fake, so the worst case of a guest leak
        // is a useless string.
        var lines: [String] = ["# Generated by Bromure AC; do not edit."]
        for spec in profile.allToolSpecs {
            guard spec.authMode == .token, let real = spec.apiKey, !real.isEmpty else { continue }
            let value: String
            switch spec.tool {
            case .claude:
                value = tokenPlan?.fakeForAnthropic() ?? real
            case .codex:
                value = tokenPlan?.fakeForOpenAI() ?? real
            }
            lines.append("export \(spec.tool.apiKeyEnvVar)=\(shellQuote(value))")
        }
        // Manual tokens defined in the editor's Advanced section.
        // Same trick as above: we inject the fake; the host swaps it
        // for the real value at the proxy.
        if let plan = tokenPlan {
            for (envName, fake) in plan.manualEnvExports {
                lines.append("export \(envName)=\(shellQuote(fake))")
            }
        }

        lines.append("export BROMURE_AC_TOOL=\(profile.tool.rawValue)")
        lines.append("export BROMURE_AC_AUTH=\(profile.authMode.rawValue)")
        try lines.joined(separator: "\n").appending("\n").write(
            to: tmp.appendingPathComponent("api_key.env"),
            atomically: true, encoding: .utf8
        )

        // MITM assets (if configured): CA cert + bridge script +
        // proxy.env. The xinitrc / bashrc snippets in Profile reach
        // into the meta share to pick these up at boot.
        if let assets = mitmAssets {
            try assets.caCertificatePEM.write(
                to: tmp.appendingPathComponent("bromure-ca.pem"),
                atomically: true, encoding: .utf8)
            // Copy bridge.py from the SPM resource bundle into the meta
            // share so the guest sees it under a stable path. We
            // explicitly remove any prior copy first because on
            // restore we no longer wipe the share dir, so a previous
            // launch's file would still be sitting at the destination
            // and `copyItem` errors on a pre-existing target.
            let scriptDest = tmp.appendingPathComponent("bromure-vm-bridge.py")
            try? fm.removeItem(at: scriptDest)
            try fm.copyItem(at: assets.bridgeScriptURL, to: scriptDest)
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: scriptDest.path)

            if let kbURL = assets.keyboardAgentURL {
                let kbDest = tmp.appendingPathComponent("keyboard-agent.py")
                try? fm.removeItem(at: kbDest)
                try fm.copyItem(at: kbURL, to: kbDest)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: kbDest.path)
            }

            if let scURL = assets.scrollAgentURL {
                let scDest = tmp.appendingPathComponent("scroll-agent.py")
                try? fm.removeItem(at: scDest)
                try fm.copyItem(at: scURL, to: scDest)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: scDest.path)
            }

            if let awsURL = assets.awsCredsHelperURL {
                let awsDest = tmp.appendingPathComponent("bromure-aws-creds.py")
                try? fm.removeItem(at: awsDest)
                try fm.copyItem(at: awsURL, to: awsDest)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: awsDest.path)
            }

            // proxy.env — sourced by .bashrc to set HTTPS_PROXY etc.
            // for every shell. Also set the per-language CA bundle
            // hints so node, python, go, rust, curl all trust our CA.
            //
            // For each git HTTPS cred, we ALSO export the matching
            // gh/glab env-var token. These take priority over the
            // YAML config files (whose schema gh has changed across
            // versions), so `gh auth status` / `gh api …` works even
            // if hosts.yml is stale or in the wrong format. Values
            // are FAKES — proxy swaps them on the wire.
            var ghEnv: [String] = []
            if let plan = tokenPlan {
                for cred in profile.gitHTTPSCredentials where cred.isUsable {
                    guard let fake = plan.fakeForGitHTTPS(host: cred.host,
                                                          username: cred.username) else {
                        continue
                    }
                    let h = cred.host.lowercased()
                    if h == "github.com" || h.hasSuffix(".github.com") {
                        ghEnv.append("export GH_TOKEN=\(shellQuote(fake))")
                        ghEnv.append("export GITHUB_TOKEN=\(shellQuote(fake))")
                    } else if h == "gitlab.com" || h.hasPrefix("gitlab.") {
                        ghEnv.append("export GITLAB_TOKEN=\(shellQuote(fake))")
                        ghEnv.append("export GLAB_TOKEN=\(shellQuote(fake))")
                    }
                }
                // DigitalOcean: doctl + most terraform / SDK clients
                // honour DIGITALOCEAN_ACCESS_TOKEN — env beats the
                // ~/.config/doctl/config.yaml path.
                if let doFake = plan.fakeForDigitalOcean() {
                    ghEnv.append("export DIGITALOCEAN_ACCESS_TOKEN=\(shellQuote(doFake))")
                }
            }
            // AWS: secret stays on host. The SDK pulls credentials on
            // demand via the `credential_process` line in ~/.aws/config,
            // which shells out to /mnt/bromure-meta/bromure-aws-creds.py.
            // We must NOT export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
            // / AWS_SESSION_TOKEN here: env vars beat credential_process
            // in the SDK's chain, and they'd also defeat the
            // no-secret-on-disk guarantee (envs leak via /proc, ps -E,
            // and shell history). Region is fine — it's not a secret.
            let aws = profile.awsCredentials
            if aws.isUsable {
                let region = aws.region.trimmingCharacters(in: .whitespaces)
                if !region.isEmpty {
                    ghEnv.append("export AWS_DEFAULT_REGION=\(shellQuote(region))")
                    ghEnv.append("export AWS_REGION=\(shellQuote(region))")
                }
            }

            var proxyLines: [String] = [
                "# Generated by Bromure AC; do not edit.",
                "export http_proxy=http://127.0.0.1:8080",
                "export https_proxy=http://127.0.0.1:8080",
                "export HTTP_PROXY=http://127.0.0.1:8080",
                "export HTTPS_PROXY=http://127.0.0.1:8080",
                "export NO_PROXY=localhost,127.0.0.1,::1",
                "export no_proxy=localhost,127.0.0.1,::1",
                "export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/bromure-ca.pem",
                "export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
                "export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
                "export CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt",
                "export GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt",
                // No private key in the VM — use the host-bridged agent.
                "export SSH_AUTH_SOCK=/tmp/bromure-agent.sock",
            ]
            proxyLines.append(contentsOf: ghEnv)
            try proxyLines.joined(separator: "\n").appending("\n").write(
                to: tmp.appendingPathComponent("proxy.env"),
                atomically: true, encoding: .utf8)
        }

        // ssh keys (if any) — copied into ~/.ssh by the init script.
        let sshSrc = store.sshDirectory(for: profile)
        if fm.fileExists(atPath: sshSrc.path) {
            let sshDst = tmp.appendingPathComponent("ssh", isDirectory: true)
            // Same no-pre-existing-target rule as the bridge script
            // above — drop any leftover from a previous launch.
            try? fm.removeItem(at: sshDst)
            try fm.copyItem(at: sshSrc, to: sshDst)
        }

        // welcome.txt — printed at first session login. Includes setup
        // hints based on auth mode.
        let welcome = makeWelcomeMessage()
        try welcome.write(
            to: tmp.appendingPathComponent("welcome.txt"),
            atomically: true, encoding: .utf8
        )

        // shares.txt — one share per line: "<slot-index> <basename>".
        // Read by xinitrc to symlink /mnt/bromure-share-N → ~/<basename>.
        let shareLines: [String] = sharedFolders.enumerated().map { (i, share) in
            "\(i + 1) \(share.mountName)"
        }
        let sharesContent: String = shareLines.isEmpty
            ? ""
            : shareLines.joined(separator: "\n") + "\n"
        try sharesContent.write(
            to: tmp.appendingPathComponent("shares.txt"),
            atomically: true,
            encoding: String.Encoding.utf8
        )

        // hostname.txt — sanitized profile name, applied at boot by
        // xinitrc via `sudo hostname` + /etc/hosts patch. Hostname
        // limits: lowercase a-z 0-9 hyphen, no leading/trailing
        // hyphens, capped at 32 chars (well under POSIX 64).
        try Self.sanitizeHostname(profile.name).appending("\n").write(
            to: tmp.appendingPathComponent("hostname.txt"),
            atomically: true, encoding: .utf8)

        // display_scale.txt — host's backingScaleFactor. xinitrc passes
        // it to `xrandr --dpi` so kitty's pt → px conversion produces a
        // visually similar font size to Terminal.app at the same pt.
        let scale = Self.detectDisplayScale()
        try "\(scale)\n".write(
            to: tmp.appendingPathComponent("display_scale.txt"),
            atomically: true, encoding: .utf8
        )

        // tz — host's current TimeZone identifier (e.g. "Europe/Paris").
        // xinitrc passes it to timedatectl so date/log timestamps inside
        // the VM match what the user sees on macOS. Re-read each session
        // so DST transitions and travel are reflected without rebuilds.
        let tzID = TimeZone.current.identifier
        try "\(tzID)\n".write(
            to: tmp.appendingPathComponent("tz"),
            atomically: true, encoding: .utf8
        )

        // mtu — clamp for the VM's primary NIC. Default 1400 covers most
        // VPNs (WireGuard ~1420, IKEv2 ~1400). Override via:
        //   defaults write io.bromure.agentic-coding vm.mtu -int <value>
        let mtu = VMConfig.resolvedNICMTU()
        try "\(mtu)\n".write(
            to: tmp.appendingPathComponent("mtu"),
            atomically: true, encoding: .utf8
        )

        // natural_scroll — host's macOS preference. xinitrc applies
        // via `xinput set-prop "libinput Natural Scrolling Enabled"`
        // so wheel events from VZ's USB HID end up in the right
        // direction inside the terminal (libinput defaults to OFF
        // regardless of the host).
        let natural = VMConfig.detectNaturalScrolling() ? "1" : "0"
        try "\(natural)\n".write(
            to: tmp.appendingPathComponent("natural_scroll"),
            atomically: true, encoding: .utf8
        )

        // key_repeat — macOS InitialKeyRepeat + KeyRepeat translated to
        // X11's `xset r rate <delay-ms> <rate-Hz>` format. Profile-
        // level overrides win over global defaults / NSEvent values.
        // Why per-profile: the X-server pipeline often makes the host's
        // own cadence feel laggier than typing in a Cocoa app, so users
        // bump the rate. ~2× the macOS value matches the perceived
        // speed for most setups.
        let kr = VMConfig.detectKeyRepeat(
            delayMsOverride: profile.keyRepeatDelayMs,
            rateHzOverride: profile.keyRepeatRateHz)
        try "\(kr.delayMs) \(kr.rateHz)\n".write(
            to: tmp.appendingPathComponent("key_repeat"),
            atomically: true, encoding: .utf8
        )

        self.metadataDirectory = tmp
        return tmp
    }

    /// Coerce an arbitrary profile name into a valid POSIX hostname.
    /// Lower-cases, **drops** every char outside `[a-z0-9-]`, strips
    /// leading/trailing hyphens, caps at 32 chars. Empty inputs fall
    /// back to `bromure`.
    ///
    /// "Renaud's Mac" → "renaudsmac"; "My Profile!" → "myprofile" —
    /// dropping is more readable than replacing every special char
    /// with a hyphen and ending up with run-on dashes.
    static func sanitizeHostname(_ name: String) -> String {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var s = String(name.lowercased().filter { allowed.contains($0) })
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        if s.isEmpty { s = "bromure" }
        if s.count > 32 { s = String(s.prefix(32)) }
        // Hostname must start with an alphanumeric (RFC 1123).
        if let first = s.first, !first.isLetter && !first.isNumber {
            s = "x" + s
        }
        return s
    }

    /// Host backingScaleFactor (1 on a regular display, 2 on Retina).
    /// MainActor because NSScreen access requires it.
    @MainActor
    private static func detectDisplayScale() -> Int {
        if let screen = NSScreen.main {
            return Int(screen.backingScaleFactor)
        }
        return 2
    }

    public func cleanupMetadataShare() {
        if let tmp = metadataDirectory {
            try? fm.removeItem(at: tmp)
        }
        metadataDirectory = nil
        if let tmp = outboxDirectory {
            try? fm.removeItem(at: tmp)
        }
        outboxDirectory = nil
    }

    /// Drop the saved-state file (if any). Called on full shutdown so
    /// the next launch boots fresh, and from `resetDisk` so a wiped
    /// disk image isn't paired with a stale RAM snapshot.
    public func clearSavedState() {
        try? fm.removeItem(at: savedStateURL)
        // tabs.json is only meaningful paired with a saved RAM
        // snapshot — without one the recorded UUIDs reference
        // kittys that no longer exist on a fresh boot.
        try? fm.removeItem(at: tabsURL)
    }

    /// Build the writable outbox dir for this launch. World-writable so
    /// the guest's `ubuntu` user (UID 1000) can write to it regardless of
    /// how virtiofs maps host UID 501.
    ///
    /// Same stable-path rationale as `prepareMetadataShare()`. On
    /// restore we keep the existing directory in place — the guest has
    /// in-flight processes (e.g. the kitty wrapper subshell) that
    /// captured the directory's inode when state was saved, and
    /// removing+recreating it on the host has been observed to make
    /// later writes from those processes invisible until the guest
    /// re-stat()s the path.
    public func prepareOutboxDirectory(forRestore: Bool = false) throws -> URL {
        let tmp = store.profileDirectory(for: profile)
            .appendingPathComponent("outbox", isDirectory: true)
        if !forRestore {
            try? fm.removeItem(at: tmp)
        }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o777)])
        outboxDirectory = tmp
        return tmp
    }

    private func makeWelcomeMessage() -> String {
        var s = "Bromure Agentic Coding — profile: \(profile.name)\n"
        let specs = profile.allToolSpecs
        if specs.count == 1 {
            let spec = specs[0]
            s += "Tool: \(spec.tool.displayName) (\(spec.authMode.displayName))\n"
        } else {
            s += "Tools:\n"
            for (i, spec) in specs.enumerated() {
                let tag = i == 0 ? " (primary, auto-launches)" : ""
                s += "  • \(spec.tool.displayName) — \(spec.authMode.displayName)\(tag)\n"
            }
        }
        let shares = sharedFolders
        if !shares.isEmpty {
            s += "Mounted folders:\n"
            for share in shares {
                s += "  ~/\(share.mountName) → \(share.url.path)\n"
            }
        }
        let usableCreds = profile.gitHTTPSCredentials.filter { $0.isUsable }
        if !usableCreds.isEmpty {
            s += "Git HTTPS auth configured for: "
            s += usableCreds.map { $0.host }.joined(separator: ", ")
            s += "\n"
        }
        if let plan = tokenPlan, !plan.manualEntries.isEmpty {
            s += "Manual token fakes (host swaps to real on the wire):\n"
            for entry in plan.manualEntries {
                if entry.envVarName.isEmpty {
                    s += "  • \(entry.name): \(entry.fake)\n"
                } else {
                    s += "  • \(entry.name) → $\(entry.envVarName)\n"
                }
            }
        }
        s += "\n"
        // Per-tool getting-started hints. Token-mode just runs;
        // subscription-mode needs a one-time login.
        for spec in specs {
            switch spec.authMode {
            case .token:
                s += "• `\(spec.tool.rawValue)` — API key already in env.\n"
            case .subscription:
                s += "• `\(spec.tool.rawValue) login` once, then `\(spec.tool.rawValue)`.\n"
            }
        }
        return s
    }
}

// MARK: - Helpers

private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// `clonefile(2)` is auto-imported from <sys/clonefile.h> by Foundation
// in modern SDKs — no shim needed. Older SDKs needed an
// @_silgen_name("clonefile") shim, but on macOS 14+ SDKs the C
// import collides with the shim (different optionality on the
// pointer args) and causes a function-type-mismatch build failure.
// `Sources/SandboxEngine/EphemeralDisk.swift` already uses the
// auto-import successfully; this file follows the same path.
