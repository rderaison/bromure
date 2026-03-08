import Foundation
import Virtualization

/// Manages the lifecycle of an ephemeral sandboxed macOS VM.
///
/// Each SandboxVM instance:
/// - Creates a CoW clone of the base image
/// - Boots a fully isolated macOS guest
/// - Provides a VZVirtualMachine for display attachment
/// - Cleans up the clone on teardown
public final class SandboxVM: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    /// The underlying virtual machine. Attach to a VZVirtualMachineView for display.
    public private(set) var vm: VZVirtualMachine?

    /// The ephemeral disk backing this session.
    public let ephemeralDisk: EphemeralDisk

    /// Runtime configuration.
    public let config: VMConfig

    /// Current state of the sandbox.
    public enum State: String, CustomStringConvertible {
        case created
        case starting
        case running
        case stopped
        case error

        public var description: String { rawValue }
    }

    public private(set) var state: State = .created

    /// Called when the VM stops (either cleanly or due to error).
    public var onStopped: ((Error?) -> Void)?

    private let storageDir: URL
    private let baseManager: BaseImageManager

    public init(
        config: VMConfig = VMConfig(),
        storageDir: URL? = nil,
        persistAt: URL? = nil
    ) {
        self.config = config
        self.storageDir = storageDir ?? VMConfig.defaultStorageDirectory
        self.baseManager = BaseImageManager(storageDir: self.storageDir)

        self.ephemeralDisk = EphemeralDisk(
            baseImageURL: VMConfig.baseImageURL(in: self.storageDir),
            persistAt: persistAt
        )

        super.init()
    }

    // MARK: - Lifecycle

    /// Prepare the VM: clone the base image and configure the virtual machine.
    public func prepare() throws {
        guard baseManager.baseImageExists else {
            throw SandboxError.baseImageNotFound
        }

        let metadata = try baseManager.loadMetadata()

        guard let hardwareModel = VZMacHardwareModel(
            dataRepresentation: metadata.hardwareModelData
        ) else {
            throw SandboxError.corruptMetadata("Invalid hardware model")
        }

        // Create the CoW clone
        try ephemeralDisk.create()

        // Clone the base aux storage (contains boot records from installation)
        let baseAuxURL = VMConfig.baseAuxURL(in: storageDir)
        try ephemeralDisk.cloneBaseAuxStorage(from: baseAuxURL)
        let auxStorage = VZMacAuxiliaryStorage(
            contentsOf: ephemeralDisk.ephemeralAuxURL
        )
        let machineIdentifier = VZMacMachineIdentifier()

        // Build VM configuration
        let vzConfig = try baseManager.buildVMConfig(
            diskURL: ephemeralDisk.ephemeralURL,
            auxStorage: auxStorage,
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier,
            config: config,
            readOnlyDisk: false
        )
        try vzConfig.validate()

        let virtualMachine = VZVirtualMachine(configuration: vzConfig)
        virtualMachine.delegate = self
        self.vm = virtualMachine
    }

    /// Start the VM. Call `prepare()` first.
    @MainActor
    public func start() async throws {
        guard let vm = vm else {
            throw SandboxError.vmStartFailed("VM not prepared. Call prepare() first.")
        }
        state = .starting
        try await vm.start()
        state = .running
    }

    /// Start the VM with a completion handler (for use when the main run loop
    /// must keep spinning, e.g. when hosting an NSApplication).
    /// Must be called on the main thread.
    public func start(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let vm = vm else {
            completion(.failure(SandboxError.vmStartFailed("VM not prepared. Call prepare() first.")))
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

    /// Request a clean shutdown via the guest OS.
    /// The guest will receive a power button event, equivalent to pressing the
    /// power button on a real Mac. The guest OS decides how to handle it
    /// (typically shows a shutdown dialog or shuts down immediately).
    public func requestShutdown() throws {
        guard let vm = vm, state == .running else { return }
        try vm.requestStop()
    }

    /// Force stop the VM immediately. Data may be lost.
    public func forceStop() async throws {
        guard let vm = vm else { return }
        try await vm.stop()
        state = .stopped
    }

    /// Clean up: stop the VM if running, destroy the ephemeral disk.
    public func teardown() async throws {
        if state == .running {
            try await forceStop()
        }
        try ephemeralDisk.destroy()
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

    /// Human-readable status line.
    public var statusDescription: String {
        let diskInfo: String
        if state == .running || state == .stopped {
            let mb = ephemeralDisk.divergedBytes / (1024 * 1024)
            diskInfo = ", \(mb) MB diverged from base"
        } else {
            diskInfo = ""
        }
        return "[\(state)] cpus=\(config.cpuCount) mem=\(config.memorySize / (1024*1024*1024))GB net=\(config.enableNetworking)\(diskInfo)"
    }
}
