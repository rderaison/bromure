import Foundation
import Observation
import SandboxEngine
import Virtualization

@MainActor
@Observable
final class AppState: @unchecked Sendable {
    enum Phase: Equatable {
        case checking
        case needsSetup
        case initializing(status: String, progress: Double?)
        case warmingUp
        case ready
        case error(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.checking, .checking), (.needsSetup, .needsSetup),
                 (.warmingUp, .warmingUp), (.ready, .ready):
                return true
            case (.initializing(let a, let ap), .initializing(let b, let bp)):
                return a == b && ap == bp
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    var phase: Phase = .checking
    var poolReady = false
    var sessionCount = 0
    var profileVersion = 0
    var isLaunching = false
    var initSteps: [InitStep] = []
    var consoleLog: String = ""

    /// Last-observed managed-profile sync state, surfaced in Settings.
    var managedSyncStatus: String = ""
    var managedLastSyncedAt: Date?
    var managedSyncInFlight: Bool = false

    struct InitStep: Identifiable {
        let id = UUID()
        let name: String
        var done: Bool
    }

    private(set) var pool: VMPool?
    private let imageManager: LinuxImageManager
    private let storageDir: URL
    private var warmUpTask: Task<Void, Never>?
    private var initTask: Task<Void, Never>?

    /// Profile management
    let profileManager: ProfileManager
    var selectedProfileID: UUID?

    /// Called by the app delegate when sessions need to be closed for image rebuild.
    var onCloseAllSessions: (() async -> Void)?
    var onPoolReady: (() -> Void)?
    var onOpenProfileSettings: ((_ profileID: UUID, _ category: String?) -> Void)?

    /// Periodic managed-profile sync timer; invalidated at teardown.
    private var managedSyncTimer: Timer?

    init() {
        self.storageDir = VMConfig.defaultStorageDirectory
        self.imageManager = LinuxImageManager(storageDir: storageDir)
        self.profileManager = ProfileManager(storageDir: storageDir)

        // Refresh the sidebar whenever sync writes to disk.
        ManagedProfileSync.onSyncComplete = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.profileManager.reloadManaged()
                self.profileVersion &+= 1
            }
        }

        // Profiles load asynchronously (iCloud discovery happens in background).
        // Defer migration and default-profile creation until profiles are ready.
        profileManager.onReady = { [weak self] in
            guard let self else { return }
            // Migrate v1.0.x UserDefaults settings into a Default profile
            if let migrated = self.profileManager.migrateFromUserDefaults() {
                self.selectedProfileID = migrated.id
            }
            // Ensure a Private Browsing profile always exists
            if self.profileManager.allProfiles.isEmpty {
                var settings = ProfileSettings()
                settings.enableGPU = true
                settings.enableAudio = true
                settings.enableClipboardSharing = true
                settings.enableLinkSender = true
                settings.allowAutomation = true
                let defaultProfile = self.profileManager.createProfile(
                    name: "Private Browsing",
                    comments: "Fully stateless browsing. Nothing is saved between sessions \u{2014} no cookies, no history, no cache. Only the clipboard is shared with your Mac.",
                    color: nil,
                    settings: settings
                )
                self.selectedProfileID = defaultProfile.id
            }
            // Select first profile if none selected
            if self.selectedProfileID == nil {
                self.selectedProfileID = self.profileManager.allProfiles.first?.id
            }
        }
    }

    // MARK: - Managed profile sync

    /// Kick off an initial sync (no-op if not enrolled) and schedule a
    /// periodic refresh every 15 min while the app is running.
    func startManagedSync() {
        syncManagedProfiles(trigger: "launch")
        managedSyncTimer?.invalidate()
        managedSyncTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncManagedProfiles(trigger: "timer") }
        }
    }

    /// Fire a manual sync, e.g. after the user enrolls or clicks "Sync now".
    func syncManagedProfiles(trigger: String) {
        guard InstallIdentityStore.load() != nil else {
            managedSyncStatus = ""
            return
        }
        guard !managedSyncInFlight else { return }
        managedSyncInFlight = true
        managedSyncStatus = "Syncing…"
        Task { @MainActor in
            defer { self.managedSyncInFlight = false }
            do {
                let profiles = try await ManagedProfileSync.shared.syncProfiles()
                self.managedLastSyncedAt = Date()
                self.managedSyncStatus = profiles.isEmpty
                    ? "Enrolled — no profiles assigned."
                    : "Synced \(profiles.count) profile\(profiles.count == 1 ? "" : "s")."
                self.profileManager.reloadManaged()
                self.profileVersion &+= 1
                print("[managed] sync (\(trigger)) ok: \(profiles.count) profile(s)")
            } catch {
                self.managedSyncStatus = "Sync failed: \(error.localizedDescription)"
                print("[managed] sync (\(trigger)) failed: \(error)")
            }
        }
    }

    func enrollManagedProfile(code: String, serverURL: URL?) async throws {
        managedSyncInFlight = true
        defer { managedSyncInFlight = false }
        let url = serverURL ?? ManagedProfileSync.defaultServerURL
        _ = try await ManagedProfileSync.shared.enroll(code: code, serverURL: url)
        managedLastSyncedAt = Date()
        profileManager.reloadManaged()
        profileVersion &+= 1
    }

    func unenrollManagedProfile() {
        ManagedProfileSync.shared.destroyLocalState()
        managedLastSyncedAt = nil
        managedSyncStatus = ""
        profileManager.reloadManaged()
        profileVersion &+= 1
    }

    func checkState() {
        if pool != nil {
            return
        }
        if imageManager.baseImageExists {
            phase = .warmingUp
            startPool()
        } else if imageManager.hasImageFiles {
            // Image files exist but version mismatch — auto-rebuild
            deleteImageFiles()
            startInit()
        } else {
            phase = .needsSetup
        }
    }

    func startInit() {
        // Cancel any in-progress warm-up
        warmUpTask?.cancel()
        warmUpTask = nil

        phase = .initializing(status: "Preparing...", progress: nil)
        initSteps = []
        consoleLog = ""

        let defaults = UserDefaults.standard
        let keyboard = defaults.string(forKey: "vm.keyboardLayout")
        let scrolling = defaults.object(forKey: "vm.naturalScrolling") as? Bool
        let scale = defaults.object(forKey: "vm.displayScale") as? Int
        let kernelOpts = defaults.string(forKey: "vm.extraKernelOptions") ?? VMConfig.defaultExtraKernelOptions

        initTask = Task {
            do {
                try await imageManager.createBaseImage(
                    diskSizeMB: 4608,
                    keyboardLayout: keyboard,
                    naturalScrolling: scrolling,
                    displayScale: scale,
                    extraKernelOptions: kernelOpts
                ) { [weak self] event in
                    DispatchQueue.main.async {
                        self?.handleProgress(event)
                    }
                }
                guard !Task.isCancelled else { return }
                self.phase = .warmingUp
                self.startPool()
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .error(Self.localizedMessage(for: error))
            }
        }
    }

    private func handleProgress(_ event: ProgressEvent) {
        switch event {
        case .stepStart(let text):
            initSteps.append(InitStep(name: text, done: false))
            phase = .initializing(status: text, progress: nil)
        case .stepDone(let text):
            if let idx = initSteps.lastIndex(where: { $0.name == text }) {
                initSteps[idx].done = true
            }
            phase = .initializing(status: text, progress: nil)
        case .message(let text):
            phase = .initializing(status: text, progress: nil)
        case .download(let received, let total):
            if total > 0 {
                let pct = Double(received) / Double(total)
                phase = .initializing(status: "Downloading...", progress: pct)
            } else {
                let mb = Double(received) / 1_000_000
                phase = .initializing(status: String(format: "Downloaded %.0f MB", mb), progress: nil)
            }
        case .install(let fraction):
            phase = .initializing(status: "Installing...", progress: fraction)
        case .consoleOutput(let text):
            consoleLog.append(text)
            if consoleLog.count > 8192 {
                consoleLog = String(consoleLog.suffix(4096))
            }
        }
    }

    /// Shut down the current pool and start a fresh one with updated config.
    /// No-op if an image build is in progress (no base image to warm up).
    func restartPool() {
        if case .initializing = phase { return }
        guard imageManager.baseImageExists else {
            // Image was deleted or never created — show setup screen
            warmUpTask?.cancel()
            warmUpTask = nil
            pool = nil
            poolReady = false
            phase = .needsSetup
            return
        }
        warmUpTask?.cancel()
        warmUpTask = nil
        poolReady = false
        Task {
            await pool?.shutdown()
            pool = nil
            startPool()
        }
    }

    func startPool() {
        let config = buildBaseConfig()
        pool = VMPool(config: config, storageDir: storageDir)
        poolReady = false
        let env = ProcessInfo.processInfo.environment
        if env["BROMURE_DEBUG"] != nil && env["BROMURE_DEBUG_PREWARM"] == nil {
            // Skip pre-warming in debug mode to keep logs clean.
            // The pool is still needed for bootDedicated() — just don't warm up.
            // Set BROMURE_DEBUG_PREWARM=1 to re-enable pre-warming in debug mode.
            poolReady = true
            phase = .ready
            return
        }
        warmUpTask = Task {
            do {
                try await pool?.warmUp()
                guard !Task.isCancelled else { return }
                poolReady = true
                phase = .ready
                onPoolReady?()
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(Self.localizedMessage(for: error))
            }
        }
    }

    static func localizedMessage(for error: Error) -> String {
        if let sandbox = error as? SandboxError {
            switch sandbox {
            case .diskFull(let mb, _):
                return String(
                    format: NSLocalizedString(
                        "Not enough disk space (%llu MB available). Free up space and try again.",
                        comment: "Error shown when the host disk is nearly full"
                    ),
                    mb
                )
            case .networkFilterFailed:
                return NSLocalizedString(
                    "Failed to initialize networking. Please quit and reopen Bromure.",
                    comment: "Error shown when vmnet entitlement is not yet effective"
                )
            default:
                break
            }
        }
        return error.localizedDescription
    }

    /// Minimal config for booting a VM (hardware only — no browser-specific flags).
    /// Always enables vsock so clipboard/file-transfer are available regardless of profile.
    /// Software config (chrome-env, services) is applied at claim time.
    func buildBaseConfig() -> VMConfig {
        let defaults = UserDefaults.standard
        let memGB = defaults.integer(forKey: "vm.memoryGB")
        let cpus = defaults.integer(forKey: "vm.cpuCount")
        let defaultMemGB: Int = {
            let hostMemGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
            if hostMemGB < 18 { return 2 }
            if hostMemGB < 36 { return 3 }
            return 4
        }()
        return VMConfig(
            cpuCount: cpus > 0 ? cpus : nil,
            memorySize: UInt64(memGB > 0 ? memGB : defaultMemGB) * 1024 * 1024 * 1024,
            enableAudio: true,
            enableFileTransfer: true,
            enableClipboardSharing: true
        )
    }

    /// Build a VMConfig from a profile's settings (merges with app-wide hardware settings).
    func buildConfig(for profile: Profile) -> VMConfig {
        profile.settings.toVMConfig(profileID: profile.id)
    }

    /// Build a default VMConfig when no profile is selected.
    func buildDefaultConfig() -> VMConfig {
        ProfileSettings().toVMConfig()
    }

    /// Close all sessions, delete the base image, and rebuild with new settings.
    func regenerateImage() {
        // Cancel any in-progress operations
        warmUpTask?.cancel()
        warmUpTask = nil
        initTask?.cancel()
        initTask = nil

        Task {
            // Close all browser sessions first
            await onCloseAllSessions?()

            // Shut down pool
            await pool?.shutdown()
            pool = nil
            poolReady = false

            // Delete old image files
            deleteImageFiles()

            // Rebuild
            startInit()
        }
    }

    func resetBaseImage() {
        // Cancel any in-progress operations
        warmUpTask?.cancel()
        warmUpTask = nil
        initTask?.cancel()
        initTask = nil

        Task {
            await onCloseAllSessions?()
            await pool?.shutdown()
            pool = nil
            poolReady = false
        }
        deleteImageFiles()
        initSteps = []
        phase = .needsSetup
    }

    private func deleteImageFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: storageDir.appendingPathComponent("linux-base.img"))
        try? fm.removeItem(at: storageDir.appendingPathComponent("vmlinuz"))
        try? fm.removeItem(at: storageDir.appendingPathComponent("initrd"))
        try? fm.removeItem(at: storageDir.appendingPathComponent("image-version"))
    }

    /// Current keyboard layout stored in preferences (or auto-detected).
    var currentKeyboardLayout: String {
        UserDefaults.standard.string(forKey: "vm.keyboardLayout")
            ?? VMConfig.detectKeyboardLayout()
    }

    /// Current natural scrolling stored in preferences (or auto-detected).
    var currentNaturalScrolling: Bool {
        UserDefaults.standard.object(forKey: "vm.naturalScrolling") as? Bool
            ?? VMConfig.detectNaturalScrolling()
    }

    /// Current display scale stored in preferences (or auto-detected).
    var currentDisplayScale: Int {
        UserDefaults.standard.object(forKey: "vm.displayScale") as? Int
            ?? VMConfig.detectDisplayScale()
    }

    var diskUsage: String {
        let fm = FileManager.default
        let paths = ["linux-base.img", "vmlinuz", "initrd"]
        var total: UInt64 = 0
        for name in paths {
            let url = storageDir.appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64 {
                total += size
            }
        }
        if total == 0 { return "No base image" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(total))
    }
}
