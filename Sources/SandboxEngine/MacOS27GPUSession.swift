import Foundation
import IOSurface
import Virtualization

public struct HostGPUCursor {
    public let rgba: Data
    public let width: Int
    public let height: Int
    public let hotX: Int
    public let hotY: Int
}

/// The stable app-facing interface keeps macOS 27 device types out of WarmVM.
public protocol HostGraphicsSession: AnyObject {
    var backendName: String { get }
    var isRendererRunning: Bool { get }
    var deliveredFrameCount: Int { get }
    var deliveredCursorCount: Int { get }
    var cursorMoveCount: Int { get }
    func observeFrames(_ observer: @escaping (IOSurface?) -> Void)
    func observeCursor(_ observer: @escaping (HostGPUCursor?) -> Void)
    func resizeDisplay(width: Int, height: Int)
    func stop()
}

@available(macOS 27.0, *)
public final class MacOS27GPUSession: NSObject, HostGraphicsSession,
    VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
    public let backendName = "virgl"
    public var isRendererRunning: Bool { client.isRunning }
    public let configuration: VZCustomVirtioDeviceConfiguration
    private let client: MacOS27RendererClient
    private let deviceQueue = DispatchQueue(label: "io.bromure.gpu.device")
    private let processingQueue = DispatchQueue(label: "io.bromure.gpu.processing")
    private let state = NSCondition()
    private var generation = 0
    private var paused = false
    private var stopped = false
    private var device: VZCustomVirtioDevice?
    private var displaySize: (Int, Int) = (0, 0)
    private var processor: RendererCommandProcessor?
    // Only accessed on processingQueue, including surface callbacks.
    private var processingGeneration = 0
    private var pending: [UUID: VZVirtioQueueElement] = [:]
    private var completions: [UUID: Data] = [:]
    private var pendingBytes = 0
    private var observer: ((IOSurface?) -> Void)?
    private var latestFrame: IOSurface?
    private var cursorObserver: ((HostGPUCursor?) -> Void)?
    private var latestCursor: HostGPUCursor?
    private let frameCounterLock = NSLock()
    private var frameCounter = 0
    private var cursorCounter = 0
    private var moveCounter = 0
    public var deliveredCursorCount: Int { frameCounterLock.lock(); defer { frameCounterLock.unlock() }; return cursorCounter }
    public var cursorMoveCount: Int { frameCounterLock.lock(); defer { frameCounterLock.unlock() }; return moveCounter }
    public var deliveredFrameCount: Int {
        frameCounterLock.lock(); defer { frameCounterLock.unlock() }; return frameCounter
    }
    private init(width: Int, height: Int) throws {
        client = try MacOS27RendererClient()
        configuration = VZCustomVirtioDeviceConfiguration()
        super.init()
        displaySize = (width, height)
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
    }

    public func observeFrames(_ observer: @escaping (IOSurface?) -> Void) {
        deviceQueue.async { [self] in
            self.observer = observer
            if !paused { observer(latestFrame) }
        }
    }

    public func observeCursor(_ observer: @escaping (HostGPUCursor?) -> Void) {
        deviceQueue.async { [self] in cursorObserver = observer; if !paused { observer(latestCursor) } }
    }

    public func resizeDisplay(width: Int, height: Int) {
        guard width >= 64, height >= 64, width <= 8192, height <= 8192,
              width * height <= 33554432 else { return }
        self.deviceQueue.async { [weak self] in
            guard let self, !self.stopped, let device = self.device,
                  self.displaySize.0 != width || self.displaySize.1 != height else { return }
            self.displaySize = (width, height)
            let epoch = self.generation
            self.processingQueue.async { [self] in
                do {
                    try self.processor?.setDisplay(width: UInt32(width), height: UInt32(height))
                    self.deviceQueue.async { [self] in
                        guard !self.stopped, self.generation == epoch else { return }
                        // VIRTIO_GPU_EVENT_DISPLAY; the guest re-reads display info.
                        let data = Data([1,0,0,0, 0,0,0,0, 1,0,0,0, 2,0,0,0])
                        device.update(VZVirtioDeviceSpecificConfiguration(configurationData: data)) { error in
                            if let error { print("[GPU] Display resize failed: \(error)") }
                        }
                    }
                } catch {
                    self.state.lock(); let active = !self.stopped && self.generation == epoch; self.state.unlock()
                    if active { print("[GPU] Display resize failed: \(error)") }
                }
            }
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
        latestCursor = nil; cursorObserver?(nil)
        device = nil
        client.stop()
        processingQueue.async { [self] in processor?.stop(); processor = nil }

    }

    public func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration,
                                          didCreateDevice device: VZCustomVirtioDevice) {
        self.device = device
        device.delegate = self
    }

    public func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        guard !stopped else { return }
        while let element = queue.nextElement() {
            let count = element.readBuffersAvailableByteCount
            if queue.queueIndex == 1 {
                // Cursor commands have no writable reply and a fixed wire size.
                if count == 56, pending.count < 256, pendingBytes <= 16777216 - count,
                   let snapshot = try? element.readBytes(withExactLength: count) {
                    handleCursor(snapshot, element: element, device: device)
                } else { element.returnToQueue() }
                continue
            }
            guard queue.queueIndex == 0, count >= 24, count <= 1048576,
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
                            if get32(snapshot, at: 0) == 0x204 {
                                print("[GPU] Resource fields: \(stride(from: 24, to: 72, by: 4).map { get32(snapshot, at: $0) })")
                            }
                            if get32(snapshot, at: 0) == 0x206 {
                                print("[GPU] Transfer fields: \(stride(from: 24, to: 72, by: 4).map { get32(snapshot, at: $0) })")
                            }
                            print("[GPU] Rejected command type=\(get32(snapshot, at: 0)) context=\(get32(snapshot, at: 16)) bytes=\(snapshot.count) firstWord=\(snapshot.count >= 36 ? get32(snapshot, at: 32) : 0) response=\(get32(response, at: 0))")
                        }
                    } catch {
                        response = Self.errorReply(snapshot)
                        state.lock(); let active = !stopped && generation == epoch; state.unlock()
                        if active { print("[GPU] Request failed: \(error)") }
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

    private func handleCursor(_ snapshot: Data, element: VZVirtioQueueElement, device: VZCustomVirtioDevice) {
        let type = get32(snapshot, at: 0)
        guard [UInt32(0x300), 0x301].contains(type), get32(snapshot, at: 24) == 0 else {
            element.returnToQueue(); return
        }
        let token = UUID(), epoch = generation
        pending[token] = element; pendingBytes += snapshot.count
        processingQueue.async { [self] in
            var cursor: HostGPUCursor?
            let update = type == 0x300
            if update, get32(snapshot, at: 40) != 0 {
                do {
                    guard let processor else { throw Self.failure("Renderer stopped") }
                    let (pixels, width, height) = try processor.cursorImage(resource: get32(snapshot, at: 40)) { address, length in
                        try self.withMapping(device, epoch: epoch, address: address, length: length) { mapping in
                            Data(bytes: mapping.mutableBytes, count: length)
                        }
                    }
                    let hotX = Int(get32(snapshot, at: 44)), hotY = Int(get32(snapshot, at: 48))
                    guard hotX < width, hotY < height else { throw Self.failure("Invalid cursor hotspot") }
                    cursor = HostGPUCursor(rgba: pixels, width: width, height: height, hotX: hotX, hotY: hotY)
                } catch { print("[GPU] Cursor update failed: \(error)") }
            }
            deviceQueue.async { [self] in
                guard !stopped, generation == epoch, pending[token] != nil else { return }
                pendingBytes -= snapshot.count
                frameCounterLock.lock()
                if update && cursor != nil { cursorCounter += 1 }
                if !update { moveCounter += 1 }
                frameCounterLock.unlock()
                if update { latestCursor = cursor; if !paused { cursorObserver?(cursor) } }
                if paused { completions[token] = Data() }
                else { complete(token, response: Data()) }
            }
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
        cursorObserver?(latestCursor)
    }
    public func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        state.lock(); generation += 1; state.broadcast(); state.unlock()
        let epoch = generation
        pending.removeAll(); completions.removeAll(); pendingBytes = 0
        latestFrame = nil; observer?(nil)
        latestCursor = nil; cursorObserver?(nil)
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
