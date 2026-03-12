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
            case (.initializing(let a, _), .initializing(let b, _)):
                return a == b
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

    init() {
        self.storageDir = VMConfig.defaultStorageDirectory
        self.imageManager = LinuxImageManager(storageDir: storageDir)
        self.profileManager = ProfileManager(storageDir: storageDir)

        // Profiles load asynchronously (iCloud discovery happens in background).
        // Defer migration and default-profile creation until profiles are ready.
        profileManager.onReady = { [weak self] in
            guard let self else { return }
            // Migrate v1.0.x UserDefaults settings into a Default profile
            if let migrated = self.profileManager.migrateFromUserDefaults() {
                self.selectedProfileID = migrated.id
            }
            // Ensure a Default profile always exists
            if self.profileManager.allProfiles.isEmpty {
                let defaultProfile = self.profileManager.createProfile(name: "Default", color: nil)
                self.selectedProfileID = defaultProfile.id
            }
            // Select first profile if none selected
            if self.selectedProfileID == nil {
                self.selectedProfileID = self.profileManager.allProfiles.first?.id
            }
        }
    }

    func checkState() {
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

        initTask = Task {
            do {
                try await imageManager.createBaseImage(
                    diskSizeGB: 4,
                    keyboardLayout: keyboard,
                    naturalScrolling: scrolling,
                    displayScale: scale
                ) { [weak self] event in
                    Task { @MainActor in
                        self?.handleProgress(event)
                    }
                }
                guard !Task.isCancelled else { return }
                self.phase = .warmingUp
                self.startPool()
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .error(error.localizedDescription)
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
            consoleLog += text
            // Keep only the last 8KB to avoid unbounded growth
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
        Task {
            await pool?.shutdown()
            pool = nil
            poolReady = false
            startPool()
        }
    }

    func startPool() {
        let config = buildBaseConfig()
        pool = VMPool(config: config, storageDir: storageDir)
        poolReady = false
        if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
            // Skip pre-warming in debug mode to keep logs clean.
            // The pool is still needed for bootDedicated() — just don't warm up.
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
                phase = .error(error.localizedDescription)
            }
        }
    }

    /// Minimal config for booting a VM (hardware only — no browser-specific flags).
    /// Always enables vsock so clipboard/file-transfer are available regardless of profile.
    /// Software config (chrome-env, services) is applied at claim time.
    func buildBaseConfig() -> VMConfig {
        let defaults = UserDefaults.standard
        let memGB = defaults.integer(forKey: "vm.memoryGB")
        let cpus = defaults.integer(forKey: "vm.cpuCount")
        return VMConfig(
            cpuCount: cpus > 0 ? cpus : nil,
            memorySize: UInt64(memGB > 0 ? memGB : 2) * 1024 * 1024 * 1024,
            enableAudio: true,
            enableFileTransfer: true,
            enableClipboardSharing: true
        )
    }

    /// Build a VMConfig from a profile's settings (merges with app-wide hardware settings).
    func buildConfig(for profile: Profile) -> VMConfig {
        profile.settings.toVMConfig()
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
