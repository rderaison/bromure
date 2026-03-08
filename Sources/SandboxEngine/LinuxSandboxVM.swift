import Foundation
import Virtualization

/// Manages the lifecycle of an ephemeral Linux sandbox VM with optional
/// state save/restore for instant boot.
///
/// On first run, boots Alpine Linux with Chromium from the base image.
/// After Chromium is ready, saves VM state to disk. Subsequent runs
/// restore from that snapshot for sub-second startup.
public final class LinuxSandboxVM: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    /// The underlying virtual machine.
    public private(set) var vm: VZVirtualMachine?

    /// The ephemeral disk backing this session.
    public let ephemeralDisk: EphemeralDisk

    /// Runtime configuration.
    public let config: VMConfig

    /// Current state.
    public enum State: String, CustomStringConvertible {
        case created, starting, running, stopped, error
        public var description: String { rawValue }
    }

    public private(set) var state: State = .created

    /// Called when the VM stops.
    public var onStopped: ((Error?) -> Void)?

    private let storageDir: URL
    private let imageManager: LinuxImageManager

    // Serial console pipes — kept alive for the VM's lifetime
    private var serialInputPipe: Pipe?
    private var serialOutputPipe: Pipe?

    public init(
        config: VMConfig = VMConfig(),
        storageDir: URL? = nil,
        persistAt: URL? = nil
    ) {
        self.config = config
        self.storageDir = storageDir ?? VMConfig.defaultStorageDirectory
        self.imageManager = LinuxImageManager(storageDir: self.storageDir)

        self.ephemeralDisk = EphemeralDisk(
            baseImageURL: imageManager.linuxDiskURL,
            persistAt: persistAt
        )

        super.init()
    }

    // MARK: - Lifecycle

    /// Prepare the VM: clone the base disk and configure.
    public func prepare() throws {
        guard imageManager.baseImageExists else {
            throw SandboxError.baseImageNotFound
        }

        // Create the CoW clone of the Linux disk
        try ephemeralDisk.create()

        // Build VM configuration
        let vzConfig = try imageManager.buildLinuxVMConfig(
            diskURL: ephemeralDisk.ephemeralURL,
            config: config
        )

        // Add serial console for boot logging
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        vzConfig.serialPorts = [serial]
        self.serialInputPipe = inputPipe
        self.serialOutputPipe = outputPipe

        // Log serial output to stderr
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                FileHandle.standardError.write(data)
            }
        }

        try vzConfig.validate()

        let virtualMachine = VZVirtualMachine(configuration: vzConfig)
        virtualMachine.delegate = self
        self.vm = virtualMachine
    }

    /// Whether a saved VM state exists for instant restore.
    public var hasSavedState: Bool {
        FileManager.default.fileExists(
            atPath: VMConfig.savedStateURL(in: storageDir, guestOS: .linux).path
        )
    }

    /// Start the VM with a completion handler.
    public func start(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let vm = vm else {
            completion(.failure(SandboxError.vmStartFailed("VM not prepared.")))
            return
        }
        state = .starting
        vm.start { result in
            switch result {
            case .success:
                self.state = .running
                completion(.success(()))
            case .failure(let error):
                self.state = .error
                completion(.failure(error))
            }
        }
    }

    /// Save VM state to disk for instant restore on next run.
    @MainActor
    public func saveState() async throws {
        guard let vm = vm, vm.canPause else { return }
        let stateURL = VMConfig.savedStateURL(in: storageDir, guestOS: .linux)
        try await vm.pause()
        try await vm.saveMachineStateTo(url: stateURL)
        try await vm.resume()
    }

    /// Restore VM from saved state for instant boot.
    @MainActor
    public func restoreState() async throws {
        guard let vm = vm else {
            throw SandboxError.vmStartFailed("VM not prepared.")
        }
        let stateURL = VMConfig.savedStateURL(in: storageDir, guestOS: .linux)
        state = .starting
        try await vm.start()
        try await vm.restoreMachineStateFrom(url: stateURL)
        state = .running
    }

    /// Request shutdown.
    public func requestShutdown() throws {
        guard let vm = vm, state == .running else { return }
        try vm.requestStop()
    }

    /// Force stop.
    @MainActor
    public func forceStop() async throws {
        guard let vm = vm, state == .running || state == .starting else { return }
        try await vm.stop()
        state = .stopped
    }

    /// Clean up.
    @MainActor
    public func teardown() async throws {
        if state == .running || state == .starting {
            try? await forceStop()
        }
        serialOutputPipe?.fileHandleForReading.readabilityHandler = nil
        serialInputPipe = nil
        serialOutputPipe = nil
        if !ephemeralDisk.persist {
            try? ephemeralDisk.destroy()
        }
        state = .stopped
    }

    // MARK: - VZVirtualMachineDelegate

    public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: Error
    ) {
        state = .error
        cleanupAndNotify(error: error)
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        state = .stopped
        cleanupAndNotify(error: nil)
    }

    private func cleanupAndNotify(error: Error?) {
        if !ephemeralDisk.persist {
            try? ephemeralDisk.destroy()
        }
        onStopped?(error)
    }

    // MARK: - Info

    public var statusDescription: String {
        let diskInfo: String
        if state == .running || state == .stopped {
            let mb = ephemeralDisk.divergedBytes / (1024 * 1024)
            diskInfo = ", \(mb) MB diverged from base"
        } else {
            diskInfo = ""
        }
        return "[linux/\(state)] cpus=\(config.cpuCount) mem=\(config.memorySize / (1024*1024*1024))GB net=\(config.enableNetworking)\(diskInfo)"
    }
}
