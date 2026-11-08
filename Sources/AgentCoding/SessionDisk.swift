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
    /// The profile this session was launched with. Mutable so a live
    /// refresh (env-var / credential / guardrail edit on a running
    /// session) can swap in the edited profile and re-emit the meta
    /// share without a reboot. The `id` never changes, so all
    /// path/MAC derivations stay stable across a refresh.
    public private(set) var profile: Profile
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

    /// True only for a "Register with …" throwaway VM. Emits
    /// `BROMURE_AC_REGISTER=1` into the guest env so `.bashrc` auto-launches the
    /// agent (to start its OAuth login). Normal sessions leave this false and
    /// land at a plain shell.
    public var registrationMode = false

    /// Worktree branches ("wt/<slug>") of the host's automation runs, staged
    /// as retired-worktrees.txt: the guest drops them from its boot-restore
    /// registry instead of reopening a tab (and a session) for each old run.
    public var retiredWorktreeBranches: [String] = []
    /// Extra NO_PROXY entries for proxy.env — the VM subnet and the node
    /// addresses of the Kubernetes clusters this workspace may use. kubectl
    /// honours HTTPS_PROXY, and the host MITM can't dial into the VM LAN, so
    /// those destinations must bypass the cooperative proxy.
    public var extraNoProxy: [String] = []
    /// Plain-HTTP registries ("<ip>:<port>") this workspace may push to —
    /// the bromure registries its access lists allow. Staged as
    /// docker-registries.txt for the guest agent's dockerd config; the first
    /// one is also exported as BROMURE_REGISTRY for agents and scripts.
    public var extraInsecureRegistries: [String] = []

    public struct MitmSessionAssets: Sendable {
        public let caCertificatePEM: String
        public let bridgeScriptURL: URL
        /// AWS `credential_process` helper. Referenced from the
        /// per-profile ~/.aws/config; pulls JSON creds on demand from
        /// the bridge's Unix socket.
        public let awsCredsHelperURL: URL?
        /// Claude subscription-token agent. Reads/writes
        /// ~/.claude/.credentials.json under host instruction over
        /// vsock 8446. nil = managed-mode subscription swap not
        /// available (e.g., no AC bundle / older base image).
        public let claudeTokenAgentURL: URL?
        /// Codex subscription-token agent. Same delivery pattern as
        /// `claudeTokenAgentURL`, talks vsock 8447, edits
        /// ~/.codex/auth.json.
        public let codexTokenAgentURL: URL?
        /// Shell-exec agent. Vsock 5800. Always shipped now; powers
        /// `bromure-ac exec` and the control socket's /vms/{id}/exec route.
        /// The exec surface is gated host-side by the owner-only control socket.
        public let shellAgentURL: URL?
        /// Loopback-callback relay. Vsock 5010 (guest listens, host
        /// connects). Lets the host reach a 127.0.0.1:<port> listener the
        /// guest opened — used to deliver OAuth redirect callbacks (grok-cli,
        /// gh, gcloud, …) back into the in-VM CLI. nil = no AC bundle.
        public let loopbackRelayAgentURL: URL?
        /// The consolidated guest daemon (bromure-agentd.py). Staged every
        /// session prep; the running daemon watches this file's hash and
        /// exits for systemd to respawn the new version (hot upgrade).
        public let agentdURL: URL?
        public init(caCertificatePEM: String,
                    bridgeScriptURL: URL,
                    awsCredsHelperURL: URL? = nil,
                    claudeTokenAgentURL: URL? = nil,
                    codexTokenAgentURL: URL? = nil,
                    shellAgentURL: URL? = nil,
                    loopbackRelayAgentURL: URL? = nil,
                    agentdURL: URL? = nil) {
            self.caCertificatePEM = caCertificatePEM
            self.bridgeScriptURL = bridgeScriptURL
            self.awsCredsHelperURL = awsCredsHelperURL
            self.claudeTokenAgentURL = claudeTokenAgentURL
            self.codexTokenAgentURL = codexTokenAgentURL
            self.shellAgentURL = shellAgentURL
            self.loopbackRelayAgentURL = loopbackRelayAgentURL
            self.agentdURL = agentdURL
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

    // MARK: - Home storage model

    /// How this boot provides /home/ubuntu.
    public enum HomeAttachMode: String {
        /// Legacy: virtiofs share of the host home dir (pre-upgrade profiles).
        case virtiofs
        /// Sparse ext4 image as a second virtio-blk device; the virtiofs
        /// `bromure-home` tag carries only the tiny bootstrap home.
        case ext4
        /// One-time upgrade boot: BOTH the old virtiofs home and a blank
        /// image are attached; the guest agent copies across, then mounts
        /// the image over /home/ubuntu for the rest of the session.
        case migrate
    }

    /// Set by the launcher when the user accepted the storage upgrade
    /// for this boot. Cleared implicitly on the next launch (the profile
    /// is stamped `.ext4` once the guest reports the copy done).
    public var migrateHomeThisBoot = false

    public var homeAttachMode: HomeAttachMode {
        if migrateHomeThisBoot { return .migrate }
        return profile.homeModel == .ext4 ? .ext4 : .virtiofs
    }

    public var homeImageURL: URL { store.homeImageURL(for: profile) }
    public var bootstrapHomeDirectory: URL { store.bootstrapHomeDirectory(for: profile) }

    /// Write (or refresh) the bootstrap home dir shared as `bromure-home`
    /// on ext4-model boots. See ProfileStore.prepareBootstrapHomeDirectory.
    public func prepareBootstrapHomeDirectory() throws {
        try store.prepareBootstrapHomeDirectory(for: profile)
    }

    /// Apparent (guest-visible) size of a freshly-created home image, GiB:
    /// `vm.homeImageGB` when set, else scaled to `freeBytes` (the free space
    /// on the volume the workspaces live on; nil = unknown, the full default).
    /// The host file is sparse, so this costs nothing up front -- but it is
    /// how far the guest can fill the host's disk; growing it later is an
    /// online truncate + resize2fs, shrinking is not supported.
    /// Override: defaults write io.bromure.agentic-coding vm.homeImageGB -int 128
    public static func resolvedHomeImageGB(freeBytes: UInt64? = nil) -> Int {
        min(1024, max(8, homeImageOverrideGB ?? scaledHomeImageGB(freeBytes: freeBytes)))
    }

    /// The size a new home gets on THIS Mac (its `vm.homeImageGB`, else its
    /// free space where the workspaces live): what a workspace with no size of
    /// its own is created with here. A workspace on another Mac is sized by
    /// that Mac — its editor shows the server's (`GET /storage/defaults`).
    public static func newHomeDefaultGB() -> Int {
        resolvedHomeImageGB(freeBytes: freeBytes(near: ProfileStore().profilesDirectory))
    }

    /// `vm.homeImageGB`, when the user set it.
    static var homeImageOverrideGB: Int? {
        UserDefaults.standard.object(forKey: "vm.homeImageGB") as? Int
    }

    /// A new home's size for the free space it will draw on (HomeImageSizing).
    public static func scaledHomeImageGB(freeBytes: UInt64?) -> Int {
        HomeImageSizing.scaledGB(freeBytes: freeBytes)
    }

    /// Free space where `url` is, or at its nearest existing parent (a new
    /// workspace's directory doesn't exist yet).
    static func freeBytes(near url: URL) -> UInt64? {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        return EphemeralDisk.freeBytes(at: dir.path)
    }

    /// The largest a new home gets, GiB, unless `vm.homeImageGB` says otherwise.
    public static let defaultHomeImageGB = HomeImageSizing.defaultGB
    /// A legacy (virtiofs) home is copied into a fresh image on its next
    /// boot, and that home can hold far more than a new one starts with: a
    /// workspace with no size of its own migrates into the size the image
    /// default had before it dropped to 16 GB (a copy that doesn't fit fails
    /// and retries every boot).
    public static let migrationHomeImageGB = 64

    /// Create the sparse home image if missing. ftruncate on APFS makes an
    /// all-holes file — apparent size fixed, allocated size ~0. The guest
    /// agent detects the blank device and mkfs.ext4's it on first boot.
    public func ensureHomeImageExists() throws {
        guard !fm.fileExists(atPath: homeImageURL.path) else { return }
        try fm.createDirectory(at: homeImageURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try EphemeralDisk.checkDiskSpace(at: homeImageURL.deletingLastPathComponent().path)
        guard fm.createFile(atPath: homeImageURL.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: homeImageURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }
        try handle.truncate(atOffset: homeImageTargetBytes)
        ProfileStore.homeImageChanged(profile.id)
    }

    /// The home image's guest-visible size: the workspace's own setting,
    /// else the app-wide default for the free space where it lives (at least
    /// `migrationHomeImageGB` for a legacy home's migration).
    public var homeImageTargetBytes: UInt64 {
        let free = Self.freeBytes(near: homeImageURL.deletingLastPathComponent())
        let gb = profile.homeImageGB.map { min(1024, max(8, $0)) }
            ?? (migrateHomeThisBoot ? max(Self.migrationHomeImageGB, Self.resolvedHomeImageGB(freeBytes: free))
                                    : Self.resolvedHomeImageGB(freeBytes: free))
        return UInt64(gb) * 1024 * 1024 * 1024
    }

    /// Whether an existing home follows `homeImageTargetBytes` up: a size of
    /// its own, or a migration. Not the app-wide default, free-space scaled or
    /// `vm.homeImageGB` (which the manual says sizes new homes only): a home
    /// made 8 GB on a full disk would otherwise grow at whichever cold boot
    /// found more room, and a grow drops the home's checkpoints.
    var homeGrowsToTarget: Bool {
        profile.homeImageGB != nil || migrateHomeThisBoot
    }

    /// Grow an existing home image to its target size (never shrinks). The
    /// file stays sparse; the guest agent runs resize2fs after mounting.
    /// Cold boots only: a saved state was taken against the old geometry.
    /// Returns what it did, for the log — a grow that doesn't happen must
    /// say why (a cold boot once left a 128 GB setting at 64 GB, silently).
    @discardableResult
    public func growHomeImageIfNeeded() throws -> String {
        let gib = { (b: UInt64) in "\(b >> 30) GiB" }
        let target = homeImageTargetBytes
        guard let attrs = try? fm.attributesOfItem(atPath: homeImageURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            return "home image unreadable at \(homeImageURL.path) — not grown (target \(gib(target)))"
        }
        guard size < target else {
            return "home image \(gib(size)) (setting \(profile.homeImageGB.map { "\($0) GB" } ?? "default"), target \(gib(target))) — nothing to grow"
        }
        guard homeGrowsToTarget else {
            return "home image \(gib(size)) (default size, kept: the default only sizes a new home) — nothing to grow"
        }
        try EphemeralDisk.checkDiskSpace(at: homeImageURL.deletingLastPathComponent().path)
        guard let handle = FileHandle(forWritingAtPath: homeImageURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }
        try handle.truncate(atOffset: target)
        ProfileStore.homeImageChanged(profile.id)
        // The checkpoints of the smaller home go, once it has grown: one from
        // before is the old home (rewinding to it undoes the resize), and on a
        // server whose 128 GB home had grown over time, its full set is what
        // stalled APFS. Not when the size is saved: the grow waits for a cold
        // boot (a saved state defers it, the size can be set back), and until
        // it happens they're the only rollback points. The delete is marked
        // before this returns, so no revert reads one meanwhile. Off the main
        // thread.
        let stale = ProfileStore.checkpointFiles(in: [store.homeCheckpointsDirectory(for: profile)])
        if !stale.isEmpty {
            ProfileStore.purgeCheckpointsInBackground(stale, of: profile.id, name: profile.name,
                                                      why: "home grown to \(gib(target))")
        }
        let now = ((try? fm.attributesOfItem(atPath: homeImageURL.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        return "home image grown \(gib(size)) → \(gib(now)) (target \(gib(target)))"
    }

    /// Saved-state file path for VM suspend/restore. Lives in the profile
    /// directory so it survives across app launches. The matching
    /// configuration is reconstructed deterministically from the
    /// per-profile MAC + machine identifier files, so no sidecar JSON
    /// is needed.
    public var savedStateURL: URL {
        store.profileDirectory(for: profile).appendingPathComponent("vm.state", isDirectory: false)
    }
    public var hasSavedState: Bool {
        fm.fileExists(atPath: savedStateURL.path)
    }

    /// Marker file written when the proxy detected an outbound
    /// credential leak from this profile's VM and the user picked
    /// either "Shut Down" or "Save for Investigation". The next
    /// launch refuses to boot until the user confirms a wipe — the
    /// disk + home are presumed contaminated; only the profile's
    /// declared tokens / config (which live in profile.json, NOT
    /// here) are kept.
    public var compromisedFlagURL: URL {
        store.profileDirectory(for: profile).appendingPathComponent("compromised.flag")
    }
    public var isCompromised: Bool {
        fm.fileExists(atPath: compromisedFlagURL.path)
    }
    public func markCompromised() {
        let dir = compromisedFlagURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: compromisedFlagURL, options: .atomic)
        try? fm.removeItem(at: compromiseResolutionURL)
    }
    public func clearCompromised() {
        try? fm.removeItem(at: compromisedFlagURL)
    }

    /// How the latest mark went away: a wipe, or a clear as a false alarm.
    /// A wipe or a clear confirmed while the other one ran finds the mark
    /// gone, and this tells it whether the disk was erased. nil: never
    /// marked, or the mark predates the record.
    public var compromiseResolutionURL: URL {
        store.profileDirectory(for: profile).appendingPathComponent("compromise.resolved")
    }
    public var lastCompromiseResolution: CompromiseRemedy? {
        (try? String(contentsOf: compromiseResolutionURL, encoding: .utf8)).flatMap(CompromiseRemedy.init(rawValue:))
    }
    private func recordCompromiseResolution(_ how: CompromiseRemedy) {
        try? Data(how.rawValue.utf8).write(to: compromiseResolutionURL, options: .atomic)
    }

    /// "Clear Compromised Mark…": a false alarm, the disk is kept.
    public func clearCompromisedAsFalseAlarm() {
        clearCompromised()
        recordCompromiseResolution(.clear)
    }

    /// Static lookup used by the picker to badge profiles whose
    /// per-profile dir holds a compromised flag — saves the picker
    /// from having to construct a SessionDisk just to read one bit.
    public static func isCompromised(profile: Profile, store: ProfileStore) -> Bool {
        FileManager.default.fileExists(atPath: compromiseMarkURL(profile: profile, store: store).path)
    }

    public static func compromiseMarkURL(profile: Profile, store: ProfileStore) -> URL {
        store.profileDirectory(for: profile).appendingPathComponent("compromised.flag", isDirectory: false)
    }

    /// Wipe everything that could carry contamination from a
    /// compromised session: the system disk, the persistent home,
    /// the saved RAM snapshot, the tab state, the per-launch meta
    /// share + outbox. Profile config (profile.json, MAC binding,
    /// machine-identifier) is intentionally left alone — the user
    /// keeps their tokens and ssh material so they can immediately
    /// re-launch a fresh VM after the wipe.
    ///
    /// Shared folders (the user's project dirs) are NOT touched —
    /// they live outside Bromure's storage and may legitimately
    /// hold the user's source. The caller surfaces a warning about
    /// this in the wipe-confirmation alert.
    ///
    /// The boot checkpoints (disk and home) go too: they are copies of the
    /// same images, and Rewind would put them back once the mark is gone.
    /// The mark is cleared only when everything is gone; anything left
    /// throws, and the workspace stays marked.
    public func wipeForCompromise() throws {
        let dir = store.profileDirectory(for: profile)
        let contaminated = [
            diskURL, homeDirectory,
            // ext4-model home + its bootstrap dir + any pre-migration backup
            // are all just as contaminated as the virtiofs home was.
            homeImageURL, bootstrapHomeDirectory, store.homeBackupDirectory(for: profile),
            // Rollback images of both (checkpoints/ holds home/).
            store.checkpointsDirectory(for: profile),
            // The saved RAM image + its fingerprint, and the EFI variable
            // store the guest could write (the next boot copies the base's).
            savedStateURL, savedStateURL.appendingPathExtension("json"), efiVarsURL,
            dir.appendingPathComponent("tabs.json"),
            dir.appendingPathComponent("meta-share"),
            dir.appendingPathComponent("outbox"),
        ]
        let hadHomeImage = fm.fileExists(atPath: homeImageURL.path)
        for url in contaminated { try? fm.removeItem(at: url) }
        if hadHomeImage { ProfileStore.homeImageChanged(profile.id) }
        let left = contaminated.filter { fm.fileExists(atPath: $0.path) }
        guard left.isEmpty else { throw WipeIncomplete(left: left) }
        clearCompromised()
        recordCompromiseResolution(.wipe)
    }

    /// A compromise wipe that couldn't erase everything: still marked.
    public struct WipeIncomplete: Error, Equatable {
        public let left: [URL]
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
    /// The outbox's folder for URL relay requests (`urls/url-*.txt`).
    public static let outboxURLRelayFolder = GuestOutboxPaths.urlRelayFolder
    /// The outbox's folder for the agents' hooks (agent-status.sh): tab
    /// status (`agent-status-<win>.txt`), tool-call lineage
    /// (`agent-tool-<win>.jsonl`) and its own owed-note marks. The hooks run
    /// inside the OpenShell sandbox when one is on, which may write here
    /// (bromure-sandboxd) and nowhere else in the outbox.
    public static let outboxAgentFolder = GuestOutboxPaths.agentFolder

    /// True if `ensureDiskExists()` had to clonefile() a fresh disk on the
    /// most recent call. Caller uses this to stamp the profile with the
    /// base-image version that was just cloned, for drift detection later.
    public private(set) var didCloneOnLastEnsure: Bool = false

    public var sharedFolders: [SharedFolder] { Self.sharedFolders(profile.folderPaths) }


    // MARK: - EFI variable store

    /// This workspace's own EFI variable store. Every VM used to boot on the
    /// one `efivars.bin` beside the base image, which VZ writes in place;
    /// macOS 27 holds it for the running VM, so a second VM failed with
    /// "Invalid virtual machine configuration. The boot loader is invalid."
    public var efiVarsURL: URL {
        diskURL.deletingLastPathComponent().appendingPathComponent("efivars.bin")
    }

    /// The store this boot uses: the workspace's own, copied from the base
    /// store the first time. A suspended VM with no copy yet resumes on the
    /// shared one it was saved with (a different store is a different
    /// configuration); its next cold boot takes its own.
    public func efiVariableStoreURL(base: URL) throws -> URL {
        if fm.fileExists(atPath: efiVarsURL.path) { return efiVarsURL }
        if hasSavedState { return base }
        try fm.createDirectory(at: efiVarsURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: base, to: efiVarsURL)
        return efiVarsURL
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
        // The clone starts at ~0 bytes (CoW) but grows as the guest writes,
        // so a nearly-full host will wedge the session mid-run. Refuse to
        // launch with a clear message rather than booting into a disk that
        // can't be written to. Throws SandboxError.diskFull, which the
        // session-launch site surfaces via showError().
        try EphemeralDisk.checkDiskSpace(at: diskURL.deletingLastPathComponent().path)
        // clonefile is the APFS CoW primitive. Falls back to copyItem on
        // non-APFS volumes (slow but correct).
        let result = clonefile(baseDiskURL.path, diskURL.path, 0)
        if result != 0 {
            try fm.copyItem(at: baseDiskURL, to: diskURL)
        }
        // A fresh disk from the base: its EFI variables come from the base
        // again too (re-copied on this boot).
        try? fm.removeItem(at: efiVarsURL)
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
    /// `forRestore` toggles whether stale files are cleared before
    /// rewriting. On fresh boot we clear them so files from older
    /// versions can't leak in; on restore we keep them, since the
    /// resumed guest's already-running processes may reference them.
    ///
    /// Either way the directory itself is preserved — never
    /// removed+recreated. Swapping the inode confuses virtiofs: an
    /// already-running guest (restore) or the just-stopped VM's
    /// still-draining virtiofs daemon (reboot) keeps pointing at the
    /// old node, so host writes silently land where the guest can't
    /// see them — wedging the post-reboot kitty on a black screen.
    /// See `clearContents`.
    /// The guest's cooperative HTTP proxy (bromure-agentd's vm-bridge
    /// listener). 65534: out of the way of anything people run (8080 was
    /// forever colliding with dev servers and containers) and above the
    /// kernel's ephemeral range. 8080 is what daemons before it listened on.
    static let guestProxyPort = GuestPorts.guestProxyPort
    static let legacyGuestProxyPort = GuestPorts.legacyGuestProxyPort

    /// Which port this boot's guest proxy listens on, recorded when the
    /// machine cold-boots so a snapshot restore — or a live re-stage of the
    /// share — keeps pointing proxy.env at the daemon actually running. A
    /// snapshot from before the record existed ran a daemon on 8080.
    private var guestProxyPortURL: URL {
        store.profileDirectory(for: profile).appendingPathComponent("guest-proxy-port")
    }

    private func guestProxyPort(coldBoot: Bool) -> Int {
        if coldBoot {
            try? String(Self.guestProxyPort).writeIfChanged(to: guestProxyPortURL)
            return Self.guestProxyPort
        }
        if let raw = try? String(contentsOf: guestProxyPortURL, encoding: .utf8),
           let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(n) {
            return n
        }
        return Self.legacyGuestProxyPort
    }

    @MainActor
    public func prepareMetadataShare(forRestore: Bool = false) throws -> URL {
        let tmp = store.profileDirectory(for: profile)
            .appendingPathComponent("meta-share", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        if !forRestore {
            clearContents(of: tmp)
        }
        // The daemon reads the port from here; proxy.env below points at it.
        let proxyPort = guestProxyPort(coldBoot: !forRestore)
        try String(proxyPort).writeIfChanged(to: tmp.appendingPathComponent("proxy_port"))

        // api_key.env — sourced by .bashrc inside the guest (apiKeyEnvLines,
        // shared with the Linux daemon).
        try Self.apiKeyEnvLines(profile: profile, tokenPlan: tokenPlan, registrationMode: registrationMode)
            .joined(separator: "\n").appending("\n").writeIfChanged(to: tmp.appendingPathComponent("api_key.env"))

        // MITM assets (if configured): CA cert + bridge script +
        // proxy.env. The xinitrc / bashrc snippets in Profile reach
        // into the meta share to pick these up at boot.
        if let assets = mitmAssets {
            try assets.caCertificatePEM.writeIfChanged(to: tmp.appendingPathComponent("bromure-ca.pem"))
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

            if let awsURL = assets.awsCredsHelperURL {
                let awsDest = tmp.appendingPathComponent("bromure-aws-creds.py")
                try? fm.removeItem(at: awsDest)
                try fm.copyItem(at: awsURL, to: awsDest)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: awsDest.path)
            }

            if let tokURL = assets.claudeTokenAgentURL {
                let tokDest = tmp.appendingPathComponent("claude-token-agent.py")
                try? fm.removeItem(at: tokDest)
                try fm.copyItem(at: tokURL, to: tokDest)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: tokDest.path)
            }

            if let cxURL = assets.codexTokenAgentURL {
                let cxDest = tmp.appendingPathComponent("codex-token-agent.py")
                try? fm.removeItem(at: cxDest)
                try fm.copyItem(at: cxURL, to: cxDest)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: cxDest.path)
            }

            if let lrURL = assets.loopbackRelayAgentURL {
                let lrDest = tmp.appendingPathComponent("loopback-relay-agent.py")
                try? fm.removeItem(at: lrDest)
                try fm.copyItem(at: lrURL, to: lrDest)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: lrDest.path)
            }

            // Consolidated guest daemon. Only rewrite when the content
            // actually changed: the running daemon re-hashes on mtime
            // change and exits to upgrade — a byte-identical rewrite is
            // harmless, but skipping it keeps resume-from-suspend quiet.
            if let adURL = assets.agentdURL {
                let adDest = tmp.appendingPathComponent("bromure-agentd.py")
                let newData = try Data(contentsOf: adURL)
                if (try? Data(contentsOf: adDest)) != newData {
                    try newData.write(to: adDest, options: .atomic)
                    try fm.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o755)],
                        ofItemAtPath: adDest.path)
                }
                // The guest sandbox's files (GuestSandboxFiles.swift, shared
                // with the Linux daemon); its kernel modules from the
                // verified CDN cache.
                try Self.writeSandboxFiles(into: tmp, profile: profile, setupDir: adURL.deletingLastPathComponent(),
                                           workdirs: sharedFolders.map { "/home/ubuntu/\($0.mountName)" }) { sentryDest in
                    SentryModuleStore.shared.stageKnown(for: profile.id, setupDir: adURL.deletingLastPathComponent(),
                                                        into: sentryDest)
                }
            }

            if let shURL = assets.shellAgentURL {
                let shDest = tmp.appendingPathComponent("shell-agent.py")
                try? fm.removeItem(at: shDest)
                try fm.copyItem(at: shURL, to: shDest)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: shDest.path)
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
            // The registries dockerd may talk plain HTTP to (guest agent →
            // /etc/docker/daemon.json). Always written so a removal lands too.
            try (extraInsecureRegistries.joined(separator: "\n") + "\n").writeIfChanged(to: tmp.appendingPathComponent("docker-registries.txt"))
            // The lines themselves: proxyEnvLines (GuestEnv.swift, shared
            // with the Linux daemon).
            let proxyLines = Self.proxyEnvLines(profile: profile, tokenPlan: tokenPlan, proxyPort: proxyPort,
                                                extraNoProxy: extraNoProxy,
                                                extraInsecureRegistries: extraInsecureRegistries)
            try proxyLines.joined(separator: "\n").appending("\n").writeIfChanged(to: tmp.appendingPathComponent("proxy.env"))
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
        try welcome.writeIfChanged(to: tmp.appendingPathComponent("welcome.txt"))

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
        try Self.sanitizeHostname(profile.name).appending("\n").writeIfChanged(to: tmp.appendingPathComponent("hostname.txt"))

        // tz — host's current TimeZone identifier (e.g. "Europe/Paris").
        // xinitrc passes it to timedatectl so date/log timestamps inside
        // the VM match what the user sees on macOS. Re-read each session
        // so DST transitions and travel are reflected without rebuilds.
        let tzID = TimeZone.current.identifier
        try "\(tzID)\n".writeIfChanged(to: tmp.appendingPathComponent("tz"))

        // mtu — clamp for the VM's primary NIC. Default 1280 covers most
        // VPNs (WireGuard ~1420, IKEv2 ~1400) plus the corp-network paths
        // that push effective PMTU below 1400 (DMVPN, Cisco AnyConnect,
        // 6-in-4 tunnels). Override via:
        //   defaults write io.bromure.agentic-coding vm.mtu -int <value>
        let mtu = VMConfig.resolvedNICMTU(default: 1280)
        try "\(mtu)\n".writeIfChanged(to: tmp.appendingPathComponent("mtu"))

        // natural_scroll — host's macOS preference. xinitrc applies
        // via `xinput set-prop "libinput Natural Scrolling Enabled"`
        // so wheel events from VZ's USB HID end up in the right
        // direction inside the terminal (libinput defaults to OFF
        // regardless of the host).
        let natural = VMConfig.detectNaturalScrolling() ? "1" : "0"
        try "\(natural)\n".writeIfChanged(to: tmp.appendingPathComponent("natural_scroll"))

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
        try "\(kr.delayMs) \(kr.rateHz)\n".writeIfChanged(to: tmp.appendingPathComponent("key_repeat"))

        // The agents' MCP configs and the built-in servers (GuestMCPShims.swift).
        try Self.writeMCPConfigs(into: tmp, profile: profile, tokenPlan: tokenPlan)

        // The guests' MCP shims and the plan-stream driver (GuestMCPShims.swift).
        try Self.writeGuestMCPShims(into: tmp)
        try retiredWorktreeBranches.map { $0 + "\n" }.joined()
            .write(to: tmp.appendingPathComponent("retired-worktrees.txt"),
                   atomically: true, encoding: .utf8)

        // terminal-graphics-enabled — opt-in marker (defaults write
        // io.bromure.agentic-coding terminal.allowGraphics -bool YES): agentd
        // flips tmux allow-passthrough on so kitty-graphics escapes reach the
        // host surface, whose ghostty config likewise lifts its image-protocol
        // block (see TerminalAppDefaults.terminalGraphicsAllowed). Absent (the
        // default) = guest bytes can never render as host-side images.
        let gfxMarker = tmp.appendingPathComponent("terminal-graphics-enabled")
        if TerminalAppDefaults.terminalGraphicsAllowed() {
            try "".write(to: gfxMarker, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: gfxMarker)
        }

        try Self.writeAgentConfigs(into: tmp, profile: profile, tokenPlan: tokenPlan)

        // home.mode — tells the guest agent how /home/ubuntu arrives this
        // boot: "virtiofs" (legacy, agent does nothing), "ext4" (format if
        // blank + mount + seed), or "migrate" (copy the virtiofs home into
        // the blank image first). Rewritten every prep — it's derived
        // state, and a restore's mode can't differ from the saved boot's.
        try (homeAttachMode.rawValue + "\n").write(
            to: tmp.appendingPathComponent("home.mode"),
            atomically: true, encoding: .utf8)

        // env.generation — the counter the guest's .bashrc PROMPT_COMMAND
        // polls to know when to re-source the env files. Only *initialize*
        // it here (1 on a fresh boot, where the wipe removed it; left as-is
        // on resume so resumed shells don't see a phantom bump). The
        // explicit live-refresh path is what increments it.
        ensureEnvGeneration(in: tmp)
        // seed.generation — same pattern for the home-seed dir: the guest
        // agent re-applies the seed when this bumps (live refresh of
        // .git-credentials & co. on an ext4 home the host can't write to).
        ensureGenerationCounter(named: "seed.generation", in: tmp)

        self.metadataDirectory = tmp
        return tmp
    }

    /// Create `env.generation` with a starting value of 1 if it's missing.
    /// Never overwrites an existing counter — a resume preserves the dir,
    /// and rewriting would falsely signal a refresh to resumed shells.
    private func ensureEnvGeneration(in dir: URL) {
        ensureGenerationCounter(named: "env.generation", in: dir)
    }

    /// Create a generation counter file with a starting value of 1 if it's
    /// missing. Never overwrites an existing counter — a resume preserves
    /// the dir, and rewriting would falsely signal a refresh.
    private func ensureGenerationCounter(named name: String, in dir: URL) {
        let url = dir.appendingPathComponent(name)
        guard !fm.fileExists(atPath: url.path) else { return }
        try? "1\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Read the current `env.generation` value (0 if absent/garbage) and
    /// write back `value + 1`. Strictly increasing regardless of the wall
    /// clock, so two refreshes never collide on the same token.
    private func bumpEnvGeneration(in dir: URL) {
        bumpGenerationCounter(named: "env.generation", in: dir)
    }

    private func bumpGenerationCounter(named name: String, in dir: URL) {
        let url = dir.appendingPathComponent(name)
        let current = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        try? "\(current + 1)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Signal the guest agent to re-apply the home seed (ext4 homes only;
    /// the virtiofs path writes dotfiles straight into the host dir and
    /// needs no signal). Call after rewriting `home-seed/` on a running
    /// session.
    public func bumpSeedGeneration() {
        guard let dir = metadataDirectory else { return }
        bumpGenerationCounter(named: "seed.generation", in: dir)
    }

    /// The home-seed directory inside the (already prepared) meta share.
    /// nil before `prepareMetadataShare()` ran for this launch.
    public var homeSeedDirectory: URL? {
        metadataDirectory?.appendingPathComponent("home-seed", isDirectory: true)
    }

    /// Re-emit the metadata share for a *running* session after an env-var,
    /// credential, or guardrail edit — no reboot. Swaps in the edited
    /// profile + freshly-minted token plan, rewrites api_key.env / proxy.env
    /// / MCP configs into the stable share directory (without wiping it, so
    /// the guest's virtiofs mount stays valid), and bumps env.generation so
    /// in-VM shells re-source on their next prompt.
    ///
    /// The already-running agent process keeps its launch-time environment
    /// (Unix env is frozen at exec); only new shells and newly-spawned
    /// child processes pick up the change.
    @MainActor
    public func refreshMetadataShare(profile newProfile: Profile,
                                     tokenPlan newPlan: SessionTokenPlan?) throws {
        precondition(newProfile.id == profile.id,
                     "refreshMetadataShare must keep the same profile id")
        self.profile = newProfile
        self.tokenPlan = newPlan
        let dir = try prepareMetadataShare(forRestore: true)
        bumpEnvGeneration(in: dir)
    }

    // MARK: - Built-in browser MCP server
    /// Host vsock port the guest browser-MCP stdio shim connects to (host CID
    /// 2). The host serves line-delimited JSON-RPC (BrowserMCPServer) there.
    public static let browserMCPVsockPort = GuestPorts.browserMCPVsockPort
    /// Host vsock port for the coding-board MCP (TaskBoardMCPServer): the
    /// task tools coding-task agents get (set plan, create subtasks, hand to
    /// review). Sibling of the browser MCP, one port over.
    public static let taskBoardMCPVsockPort = GuestPorts.taskBoardMCPVsockPort
    /// The automations MCP (AutomationMCPServer): every agent in the
    /// workspace can list / create / edit / delete / run ITS automations.
    public static let automationMCPVsockPort = GuestPorts.automationMCPVsockPort
    /// The infrastructure MCP (KubeMCPServer): what clusters / registries
    /// this workspace can use and how, plus creating new ones.
    public static let kubeMCPVsockPort = GuestPorts.kubeMCPVsockPort
    /// The delegation MCP (DelegationMCPServer): an agent hands work to
    /// another agent's session and hears back. Every agent tab gets it.
    public static let delegationMCPVsockPort = GuestPorts.delegationMCPVsockPort
    /// The Switchboard's MCP (SwitchboardMCPServer): the delegation shim — same
    /// window announcement, since the host checks the caller is the
    /// Switchboard's tab — on its own port.
    public static let switchboardMCPVsockPort = GuestPorts.switchboardMCPVsockPort
    static let switchboardMCPShimGuestPath = GuestMetaPaths.switchboardMCPShimGuestPath
    static let switchboardMCPConfigGuestPath = GuestMetaPaths.switchboardMCPConfigGuestPath
    /// Host vsock port for the plan-stream channel (plan-stream protocol
    /// v1): guest plan drivers connect here and exchange NDJSON events/
    /// commands with the host's planning UI. One port over from the board
    /// MCP.
    public static let planStreamVsockPort = GuestPorts.planStreamVsockPort







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
        try? fm.removeItem(at: savedStateURL.appendingPathExtension("json"))
        // tabs.json is only meaningful paired with a saved RAM
        // snapshot — without one the recorded UUIDs reference
        // kittys that no longer exist on a fresh boot.
        try? fm.removeItem(at: tabsURL)
    }

    /// Build the writable outbox dir for this launch. World-writable so
    /// the guest's `ubuntu` user (UID 1000) can write to it regardless of
    /// how virtiofs maps host UID 501.
    ///
    /// Same stable-path + inode-preservation rationale as
    /// `prepareMetadataShare()`: the directory is reused in place and
    /// only its contents are cleared (on fresh boot / reboot), never
    /// removed+recreated. See `clearContents` for the inode-swap race
    /// this avoids — on the reboot relaunch the just-stopped VM's
    /// virtiofs daemon is still releasing its handles, and swapping
    /// the inode out from under it left the new guest's first kitty
    /// wedged on a black screen until a second reboot.
    public func prepareOutboxDirectory(forRestore: Bool = false) throws -> URL {
        let tmp = store.profileDirectory(for: profile)
            .appendingPathComponent("outbox", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o777)])
        if !forRestore {
            clearContents(of: tmp)
        } else {
            // On restore the outbox is intentionally preserved (the resumed
            // guest's live processes + the just-stopped VM's still-draining
            // virtiofs daemon — see clearContents). But one-shot guest→host
            // *event* files (closed-<uuid> / diag-<uuid>) are stale by
            // definition on a new launch, and restored tabs reuse their
            // UUIDs — so a leftover closed-* reads as "the user closed this
            // tab" and powers the VM off right after it resumes. Purge just
            // those; leave the live roster (tabs-alive.txt) and host commands.
            purgeStaleEvents(in: tmp)
        }
        // Where the guest's URL relay (bromure-open, xdg-open, $BROWSER)
        // drops its requests: a folder of its own, so a sandboxed agent can
        // be let write there (bromure-sandboxd) and nowhere else in the
        // outbox, where agentd's own signals (tabs, status, liveness) live.
        try? fm.createDirectory(at: tmp.appendingPathComponent(Self.outboxURLRelayFolder, isDirectory: true),
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: NSNumber(value: 0o777)])
        // Same for the agents' hooks (status, tool calls): they run in the
        // sandbox too, so they get a folder of their own.
        try? fm.createDirectory(at: tmp.appendingPathComponent(Self.outboxAgentFolder, isDirectory: true),
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: NSNumber(value: 0o777)])
        outboxDirectory = tmp
        return tmp
    }

    /// Remove stale one-shot guest→host event files (closed-*, diag-*,
    /// shortcut-*) left in the outbox by a prior session. See
    /// `prepareOutboxDirectory`. `shortcut-*` is a host-owned keychord the
    /// guest bounced (⌘T/⌘W/⌘N/⌘1-9); a leftover one means the VM was
    /// suspended in the sub-tick window before the host drained it, and
    /// replaying a pre-suspend chord after resume (a phantom ⌘T) is wrong —
    /// so it's stale-by-definition here too.
    private func purgeStaleEvents(in dir: URL) {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("closed-") || name.hasPrefix("diag-")
                || name.hasPrefix("shortcut-") || name == "reboot-intent" {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Empty a directory in place without removing the directory
    /// itself, preserving its inode. Removing+recreating swaps the
    /// inode, which races a still-draining virtiofs daemon (a resumed
    /// guest's live processes, or the just-stopped VM's daemon on a
    /// reboot relaunch): host writes can land in a node the guest's
    /// mount no longer sees. Clearing contents gives the same
    /// "no stale files" guarantee a wipe did, without the swap.
    private func clearContents(of dir: URL) {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }

    private func makeWelcomeMessage() -> String {
        var s = "Bromure Agentic Coding — workspace: \(profile.name)\n"
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
            case .bedrock:
                s += "• `\(spec.tool.rawValue)` — using AWS Bedrock credentials.\n"
            case .local:
                s += "• `\(spec.tool.rawValue)` — using the local model (on-device).\n"
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
