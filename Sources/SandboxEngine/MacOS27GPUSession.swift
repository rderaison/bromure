import Foundation
import IOSurface
import Virtualization

/// The stable app-facing interface keeps macOS 27 device types out of WarmVM.
public protocol HostGraphicsSession: AnyObject {
    var backendName: String { get }
    var deliveredFrameCount: Int { get }
    func observeFrames(_ observer: @escaping (IOSurface?) -> Void)
    func stop()
}

@available(macOS 27.0, *)
public final class MacOS27GPUSession: NSObject, HostGraphicsSession,
    VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
    public let backendName = "virgl"
    public let configuration: VZCustomVirtioDeviceConfiguration
    private let client: MacOS27RendererClient
    private let deviceQueue = DispatchQueue(label: "io.bromure.gpu.device")
    private let processingQueue = DispatchQueue(label: "io.bromure.gpu.processing")
    private let state = NSCondition()
    private var generation = 0
    private var paused = false
    private var stopped = false
    private var processor: RendererCommandProcessor?
    // Only accessed on processingQueue, including surface callbacks.
    private var processingGeneration = 0
    private var pending: [UUID: VZVirtioQueueElement] = [:]
    private var completions: [UUID: Data] = [:]
    private var pendingBytes = 0
    private var observer: ((IOSurface?) -> Void)?
    private var latestFrame: IOSurface?
    private let frameCounterLock = NSLock()
    private var frameCounter = 0
    public var deliveredFrameCount: Int {
        frameCounterLock.lock(); defer { frameCounterLock.unlock() }; return frameCounter
    }
    private static let ownership = NSLock()
    private static var owned = false
    private var ownsRenderer = false

    private init(width: Int, height: Int) throws {
        Self.ownership.lock()
        if Self.owned { Self.ownership.unlock(); throw Self.failure("Experimental renderer already in use") }
        Self.owned = true
        Self.ownership.unlock()
        do { client = try MacOS27RendererClient() }
        catch {
            Self.ownership.lock(); Self.owned = false; Self.ownership.unlock()
            throw error
        }
        configuration = VZCustomVirtioDeviceConfiguration()
        super.init()
        ownsRenderer = true
        configuration.deviceID = 16
        configuration.pciClassID = 3
        configuration.pciSubclassID = 0
        configuration.virtioQueueCount = 2
        configuration.optionalFeatures.subset0 |= 1
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: Data([0,0,0,0, 0,0,0,0, 1,0,0,0, 2,0,0,0]))
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: deviceQueue, delegate: self)
    }

    /// Capability validation finishes before the custom device enters a VM.
    public static func create(width: Int, height: Int) async throws -> MacOS27GPUSession {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw failure("Invalid GPU dimensions") }
        let session = try MacOS27GPUSession(width: width, height: height)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.processingQueue.async {
                do {
                    let processor = try RendererCommandProcessor(client: session.client) { [weak session] surface in
                        guard let session else { return }
                        let token = session.processingGeneration
                        session.deviceQueue.async {
                            guard !session.stopped, session.generation == token else { return }
                            session.frameCounterLock.lock(); session.frameCounter += 1; session.frameCounterLock.unlock()
                            session.latestFrame = surface
                            if !session.paused { session.observer?(surface) }
                        }
                    }
                    try processor.setDisplay(width: UInt32(width), height: UInt32(height))
                    session.processor = processor
                    continuation.resume()
                } catch { session.stop(); continuation.resume(throwing: error) }
            }
        }
        return session
    }

    deinit {
        client.stop()
        if ownsRenderer { Self.ownership.lock(); Self.owned = false; Self.ownership.unlock() }
    }

    public func observeFrames(_ observer: @escaping (IOSurface?) -> Void) {
        deviceQueue.async { [self] in
            self.observer = observer
            if !paused { observer(latestFrame) }
        }
    }

    public func stop() {
        deviceQueue.async { [self] in terminate() }
    }

    private func terminate() {
        guard !stopped else { return }
        state.lock(); stopped = true; generation += 1; paused = false; state.broadcast(); state.unlock()
        pending.removeAll(); completions.removeAll(); pendingBytes = 0
        latestFrame = nil; observer?(nil)
        client.stop()
        processingQueue.async { [self] in processor?.stop(); processor = nil }
        if ownsRenderer {
            ownsRenderer = false
            // Let the disconnected embedded service finish exiting before reuse.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                Self.ownership.lock(); Self.owned = false; Self.ownership.unlock()
            }
        }
    }

    public func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration,
                                          didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = self
    }

    public func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        guard !stopped else { return }
        while let element = queue.nextElement() {
            let count = element.readBuffersAvailableByteCount
            guard queue.queueIndex == 0, count >= 24, count <= 65536,
                  pending.count < 256, pendingBytes <= 16777216 - count else {
                element.returnToQueue(); continue
            }
            do {
                let snapshot = try element.readBytes(withExactLength: count)
                let token = UUID(), epoch = generation
                pending[token] = element; pendingBytes += count
                processingQueue.async { [self] in
                    processingGeneration = epoch
                    let response: Data
                    do {
                        guard let processor else { throw Self.failure("Renderer stopped") }
                        response = try processor.forward(snapshot, readGuest: { address, length in
                            try self.withMapping(device, epoch: epoch, address: address, length: length) { mapping in
                                Data(bytes: mapping.mutableBytes, count: length)
                            }
                        }, writeGuest: { address, data in
                            try self.withMapping(device, epoch: epoch, address: address, length: data.count) { mapping in
                                data.withUnsafeBytes { bytes in
                                    mapping.mutableBytes.copyMemory(from: bytes.baseAddress!, byteCount: data.count)
                                }
                            }
                        })
                        if get32(response, at: 0) >= 0x1200 {
                            print("[GPU] Rejected command type=\(get32(snapshot, at: 0)) context=\(get32(snapshot, at: 16)) bytes=\(snapshot.count) firstWord=\(snapshot.count >= 36 ? get32(snapshot, at: 32) : 0) response=\(get32(response, at: 0))")
                        }
                    } catch {
                        response = Self.errorReply(snapshot)
                        print("[GPU] Request failed: \(error)")
                    }
                    deviceQueue.async { [self] in
                        guard !stopped, generation == epoch, pending[token] != nil else { return }
                        pendingBytes -= count
                        if paused { completions[token] = response }
                        else { complete(token, response: response) }
                    }
                }
            } catch { element.returnToQueue() }
        }
    }

    private func withMapping<T>(_ device: VZCustomVirtioDevice, epoch: Int, address: UInt64, length: Int,
                                body: (VZGuestMemoryMapping) throws -> T) throws -> T {
        while true {
            state.lock()
            while paused && !stopped && generation == epoch { state.wait() }
            let valid = !stopped && generation == epoch
            state.unlock()
            guard valid else { throw Self.failure("Stale guest memory generation") }
            let result: Result<T, Error>? = deviceQueue.sync {
                guard !stopped, generation == epoch else { return .failure(Self.failure("Stale guest mapping")) }
                if paused { return nil }
                guard let mapping = device.guestMemoryMapping(atPhysicalAddress: address, length: length),
                      mapping.length == length else { return .failure(Self.failure("Invalid guest memory range")) }
                return Result { try body(mapping) }
            }
            if let result { return try result.get() }
        }
    }

    private func complete(_ token: UUID, response: Data) {
        guard let element = pending.removeValue(forKey: token) else { return }
        if response.count <= element.writeBuffersAvailableByteCount { try? element.write(response) }
        element.returnToQueue()
    }

    public func customVirtioDeviceWillPause(_ device: VZCustomVirtioDevice) {
        state.lock(); paused = true; state.unlock()
    }
    public func customVirtioDeviceWillResume(_ device: VZCustomVirtioDevice) {
        state.lock(); paused = false; state.broadcast(); state.unlock()
        for (token, response) in completions { complete(token, response: response) }
        completions.removeAll()
        observer?(latestFrame)
    }
    public func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        state.lock(); generation += 1; state.broadcast(); state.unlock()
        let epoch = generation
        pending.removeAll(); completions.removeAll(); pendingBytes = 0
        latestFrame = nil; observer?(nil)
        processingQueue.async { [self] in
            processingGeneration = epoch
            do { try processor?.reset() }
            catch { print("[GPU] Reset failed: \(error)"); stop() }
        }
    }
    public func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) { terminate() }

    private static func errorReply(_ snapshot: Data) -> Data {
        var response = Data(snapshot.prefix(24))
        put32(0x1200, at: 0, into: &response)
        put32(get32(response, at: 4) & 1, at: 4, into: &response)
        put32(0, at: 20, into: &response)
        return response
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "BromureGPU", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
