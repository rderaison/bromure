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

    /// Called by the app delegate when sessions need to be closed for image rebuild.
    var onCloseAllSessions: (() async -> Void)?

    init() {
        self.storageDir = VMConfig.defaultStorageDirectory
        self.imageManager = LinuxImageManager(storageDir: storageDir)
    }

    func checkState() {
        if imageManager.baseImageExists {
            phase = .warmingUp
            startPool()
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
    func restartPool() {
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
        let config = buildConfig()
        pool = VMPool(config: config, storageDir: storageDir)
        poolReady = false
        warmUpTask = Task {
            do {
                try await pool?.warmUp()
                guard !Task.isCancelled else { return }
                poolReady = true
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }

    func buildConfig() -> VMConfig {
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
            memorySize: UInt64(memGB > 0 ? memGB : 2) * 1024 * 1024 * 1024,
            enableAudio: defaults.object(forKey: "vm.enableAudio") as? Bool ?? true,
            enableWarp: defaults.object(forKey: "vm.enableWarp") as? Bool ?? false,
            forceDarkMode: forceDark,
            enableAdBlocking: defaults.object(forKey: "vm.enableAdBlocking") as? Bool ?? false,
            swapCmdCtrl: defaults.object(forKey: "vm.swapCmdCtrl") as? Bool ?? true,
            homePage: defaults.string(forKey: "vm.homePage") ?? "https://www.google.com"
        )
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
