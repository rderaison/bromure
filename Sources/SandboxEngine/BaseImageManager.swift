import Foundation
import Virtualization

/// Manages creation and validation of the golden base macOS image.
public final class BaseImageManager {
    private let storageDir: URL

    public init(storageDir: URL? = nil) {
        self.storageDir = storageDir ?? VMConfig.defaultStorageDirectory
    }

    // MARK: - Public

    /// Whether a valid base image already exists.
    public var baseImageExists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: VMConfig.baseImageURL(in: storageDir).path)
            && fm.fileExists(atPath: VMConfig.baseAuxURL(in: storageDir).path)
            && fm.fileExists(atPath: VMConfig.baseMetadataURL(in: storageDir).path)
    }

    /// Load saved metadata for the base image.
    public func loadMetadata() throws -> BaseImageMetadata {
        let data = try Data(contentsOf: VMConfig.baseMetadataURL(in: storageDir))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BaseImageMetadata.self, from: data)
    }

    /// Create a new base image by downloading and installing macOS.
    /// This is a long-running operation — it downloads an IPSW and runs the installer.
    public func createBaseImage(
        diskSizeGB: UInt64 = 64,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)

        // 1. Fetch the latest supported restore image
        progress(.stepStart("Fetching latest macOS restore image metadata"))
        let restoreImage = try await fetchRestoreImage()
        progress(.stepDone("Fetching latest macOS restore image metadata"))

        guard let mostFeaturefulSupportedConfig = restoreImage
            .mostFeaturefulSupportedConfiguration else {
            throw SandboxError.unsupportedHardware
        }
        let hardwareModel = mostFeaturefulSupportedConfig.hardwareModel

        // 2. Download the IPSW
        let ipswURL = storageDir.appendingPathComponent("restore.ipsw")
        if !fm.fileExists(atPath: ipswURL.path) {
            progress(.download(bytesReceived: 0, totalBytes: 0))
            try await downloadIPSW(from: restoreImage.url, to: ipswURL, progress: progress)
            progress(.stepDone("Downloading macOS IPSW"))
        } else {
            progress(.stepDone("Using cached IPSW"))
        }

        // 3. Create disk image
        let diskURL = VMConfig.baseImageURL(in: storageDir)
        progress(.stepStart("Creating \(diskSizeGB)GB sparse disk image"))
        try createSparseDiskImage(at: diskURL, sizeGB: diskSizeGB)
        progress(.stepDone("Creating \(diskSizeGB)GB sparse disk image"))

        // 4. Create auxiliary storage
        let auxURL = VMConfig.baseAuxURL(in: storageDir)
        progress(.stepStart("Creating auxiliary storage"))
        let auxStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: auxURL,
            hardwareModel: hardwareModel,
            options: .allowOverwrite
        )
        _ = auxStorage
        progress(.stepDone("Creating auxiliary storage"))

        // 5. Build installer VM configuration
        let machineIdentifier = VZMacMachineIdentifier()
        let vmConfig = try buildInstallerConfig(
            diskURL: diskURL,
            auxStorage: auxStorage,
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier
        )
        try vmConfig.validate()

        // 6. Run installer (VZVirtualMachine must be used from the main thread)
        progress(.stepStart("Installing macOS"))
        try await installMacOS(vmConfig: vmConfig, ipswURL: ipswURL, progress: progress)
        progress(.stepDone("Installing macOS"))

        // 7. Save metadata
        progress(.stepStart("Saving base image metadata"))
        let metadata = BaseImageMetadata(
            hardwareModelData: hardwareModel.dataRepresentation,
            machineIdentifierData: machineIdentifier.dataRepresentation,
            macOSVersion: restoreImage.buildVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let metadataJSON = try encoder.encode(metadata)
        try metadataJSON.write(to: VMConfig.baseMetadataURL(in: storageDir))
        progress(.stepDone("Saving base image metadata"))

        progress(.message("Base image created at \(diskURL.path)"))
    }

    /// Boot the base image interactively (for completing setup or updates).
    /// Returns a configured VZVirtualMachine ready to be started and displayed.
    public func bootBaseImage(config: VMConfig = VMConfig()) throws -> VZVirtualMachine {
        let metadata = try loadMetadata()

        guard let hardwareModel = VZMacHardwareModel(
            dataRepresentation: metadata.hardwareModelData
        ) else {
            throw SandboxError.corruptMetadata("Invalid hardware model data")
        }

        let auxStorage = VZMacAuxiliaryStorage(
            contentsOf: VMConfig.baseAuxURL(in: storageDir)
        )

        // Use the original machine identifier for the base image
        guard let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: metadata.machineIdentifierData
        ) else {
            throw SandboxError.corruptMetadata("Invalid machine identifier data")
        }

        let vmConfig = try buildVMConfig(
            diskURL: VMConfig.baseImageURL(in: storageDir),
            auxStorage: auxStorage,
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier,
            config: config,
            readOnlyDisk: false
        )
        try vmConfig.validate()
        return VZVirtualMachine(configuration: vmConfig)
    }

    // MARK: - Private

    @MainActor
    private func installMacOS(
        vmConfig: VZVirtualMachineConfiguration,
        ipswURL: URL,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        let vm = VZVirtualMachine(configuration: vmConfig)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)

        let installProgress = installer.progress

        // Pump the Cocoa run loop from a main-queue GCD timer.
        // When `installer.install()` suspends the main actor, the Swift
        // concurrency executor drains the main dispatch queue — firing this
        // timer. Each firing runs one non-blocking iteration of the Cocoa
        // run loop, which lets Virtualization.framework flush boot records
        // to the auxiliary storage file. Without this, the CLI (which has
        // no NSApplication event loop) writes macOS to disk but the aux
        // storage never receives boot configuration, leaving the image
        // unbootable (permanent black screen on first boot).
        let runLoopPump = DispatchSource.makeTimerSource(queue: .main)
        runLoopPump.schedule(deadline: .now(), repeating: .milliseconds(100))
        runLoopPump.setEventHandler {
            RunLoop.main.run(mode: .default, before: Date())
            progress(.install(fraction: installProgress.fractionCompleted))
        }
        runLoopPump.resume()

        defer {
            runLoopPump.cancel()
            progress(.install(fraction: 1.0))
        }

        try await installer.install()
    }

    private func fetchRestoreImage() async throws -> VZMacOSRestoreImage {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                VZMacOSRestoreImage.fetchLatestSupported { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == "VZErrorDomain" && nsError.code == 10001 {
                throw SandboxError.downloadFailed(
                    "Failed to fetch restore image catalog. "
                    + "This usually means the binary is not code-signed with the "
                    + "com.apple.security.virtualization entitlement. "
                    + "Run via the app bundle (./build.sh first) or re-sign the binary. "
                    + "Original error: \(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func downloadIPSW(
        from url: URL,
        to destination: URL,
        progress: @escaping (ProgressEvent) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadProgressDelegate(
                destination: destination,
                progress: progress,
                completion: { result in continuation.resume(with: result) }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    private func createSparseDiskImage(at url: URL, sizeGB: UInt64) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw SandboxError.diskCreationFailed("Failed to create disk image: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        let size = Int64(sizeGB * 1024 * 1024 * 1024)
        let ret = ftruncate(fd, size)
        guard ret == 0 else {
            throw SandboxError.diskCreationFailed("Failed to set disk size: \(String(cString: strerror(errno)))")
        }
    }

    private func buildInstallerConfig(
        diskURL: URL,
        auxStorage: VZMacAuxiliaryStorage,
        hardwareModel: VZMacHardwareModel,
        machineIdentifier: VZMacMachineIdentifier
    ) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = auxStorage
        config.platform = platform

        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = max(2, ProcessInfo.processInfo.processorCount / 2)
        config.memorySize = 4 * 1024 * 1024 * 1024

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL, readOnly: false
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144
            )
        ]
        config.graphicsDevices = [graphics]

        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration()]

        return config
    }

    // MARK: - VM Configuration

    func buildVMConfig(
        diskURL: URL,
        auxStorage: VZMacAuxiliaryStorage,
        hardwareModel: VZMacHardwareModel,
        machineIdentifier: VZMacMachineIdentifier,
        config: VMConfig,
        readOnlyDisk: Bool
    ) throws -> VZVirtualMachineConfiguration {
        let vzConfig = VZVirtualMachineConfiguration()

        // Platform
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = auxStorage
        vzConfig.platform = platform

        vzConfig.bootLoader = VZMacOSBootLoader()
        vzConfig.cpuCount = config.cpuCount
        vzConfig.memorySize = config.memorySize

        // Storage
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL, readOnly: readOnlyDisk
        )
        vzConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // Network
        if config.enableNetworking {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            vzConfig.networkDevices = [net]
        }

        // Graphics
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.displayWidth,
                heightInPixels: config.displayHeight,
                pixelsPerInch: config.pixelsPerInch
            )
        ]
        vzConfig.graphicsDevices = [graphics]

        // Audio
        if config.enableAudio {
            let audio = VZVirtioSoundDeviceConfiguration()
            let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
            outputStream.sink = VZHostAudioOutputStreamSink()
            let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
            inputStream.source = VZHostAudioInputStreamSource()
            audio.streams = [outputStream, inputStream]
            vzConfig.audioDevices = [audio]
        }

        // Input
        vzConfig.keyboards = [VZMacKeyboardConfiguration()]
        vzConfig.pointingDevices = [VZMacTrackpadConfiguration()]

        // No file sharing — maximum isolation
        vzConfig.directorySharingDevices = []

        return vzConfig
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: (ProgressEvent) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private var completed = false

    init(
        destination: URL,
        progress: @escaping (ProgressEvent) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.destination = destination
        self.progress = progress
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(.download(
            bytesReceived: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown
                ? 0 : totalBytesExpectedToWrite
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(session, result: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            finish(session, result: .failure(error))
        } else if let http = task.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(session, result: .failure(
                SandboxError.downloadFailed("HTTP \(http.statusCode)")
            ))
        } else {
            finish(session, result: .success(()))
        }
    }

    private func finish(_ session: URLSession, result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        session.finishTasksAndInvalidate()
        completion(result)
    }
}
