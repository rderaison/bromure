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
    var outputCapacity: Int { get }
    var isRendererRunning: Bool { get }
    var deliveredFrameCount: Int { get }
    var deliveredCursorCount: Int { get }
    var cursorMoveCount: Int { get }
    func logResourceUsage()
    func observeFrames(_ observer: @escaping (IOSurface?) -> Void)
    func observeCursor(_ observer: @escaping (HostGPUCursor?) -> Void)
    func resizeDisplay(width: Int, height: Int)
    func stop()
}

public extension HostGraphicsSession { var outputCapacity: Int { 1 } }

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
    public let scanoutCount: Int
    public var outputCapacity: Int { scanoutCount }
    private var outputObservers: [Int: (IOSurface?) -> Void] = [:]
    private var outputFrames: [Int: IOSurface] = [:]
    private var outputCursorObservers: [Int: (HostGPUCursor?) -> Void] = [:]
    private var outputCursors: [Int: HostGPUCursor] = [:]
    private var outputFrameCounts: [Int: Int] = [:]
    private var outputCursorCounts: [Int: Int] = [:]
    private var outputMoveCounts: [Int: Int] = [:]
    private let frameCounterLock = NSLock()
    private var frameCounter = 0
    private var cursorCounter = 0
    private var moveCounter = 0
    public var deliveredCursorCount: Int { frameCounterLock.lock(); defer { frameCounterLock.unlock() }; return cursorCounter }
    public var cursorMoveCount: Int { frameCounterLock.lock(); defer { frameCounterLock.unlock() }; return moveCounter }
    public var deliveredFrameCount: Int {
        frameCounterLock.lock(); defer { frameCounterLock.unlock() }; return frameCounter
    }
    private init(width: Int, height: Int, scanoutCount: Int) throws {
        self.scanoutCount = scanoutCount
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
            configurationData: Data([0,0,0,0, 0,0,0,0, UInt8(scanoutCount),0,0,0, 2,0,0,0]))
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: deviceQueue, delegate: self)
    }

    /// Capability validation finishes before the custom device enters a VM.
    public static func create(width: Int, height: Int, scanoutCount: Int = 1) async throws -> MacOS27GPUSession {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 33554432, (1...16).contains(scanoutCount) else { throw failure("Invalid GPU dimensions") }
        let session = try MacOS27GPUSession(width: width, height: height, scanoutCount: scanoutCount)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.processingQueue.async {
                do {
                    let processor = try RendererCommandProcessor(client: session.client, onDisplayFrame: { [weak session] output, surface in
                        guard let session else { return }
                        let token = session.processingGeneration
                        session.deviceQueue.async {
                            guard !session.stopped, session.generation == token else { return }
                            let index = Int(output)
                            session.frameCounterLock.lock()
                            session.frameCounter += 1; session.outputFrameCounts[index, default: 0] += 1
                            session.frameCounterLock.unlock()
                            session.outputFrames[index] = surface
                            if index == 0 { session.latestFrame = surface }
                            if !session.paused {
                                if index == 0 { session.observer?(surface) }
                                session.outputObservers[index]?(surface)
                            }
                        }
                    })
                    try processor.setScanoutCount(UInt32(scanoutCount))
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

    public func logResourceUsage() {
        processingQueue.async { [weak self] in self?.processor?.logResourceUsage() }
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

    public struct OutputGeometry {
        public let index: Int
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let enabled: Bool
        public init(index: Int, x: Int, y: Int, width: Int, height: Int, enabled: Bool) {
            self.index = index; self.x = x; self.y = y
            self.width = width; self.height = height; self.enabled = enabled
        }
    }

    /// Publish a complete trusted topology before the guest applies RandR modes.
    /// On failure the caller reconciles against the guest/controller's actual state.
    public func publishOutputs(_ outputs: [OutputGeometry]) async throws {
        guard outputs.count == scanoutCount, Set(outputs.map(\.index)) == Set(0..<scanoutCount) else {
            throw Self.failure("Incomplete output topology")
        }
        var rootWidth = 0, rootHeight = 0
        for output in outputs {
            guard output.x >= 0, output.y >= 0, output.width >= 64, output.height >= 64,
                  output.width <= 8192, output.height <= 8192, output.width % 8 == 0,
                  output.width * output.height <= 33554432,
                  output.x <= 8192 - output.width, output.y <= 8192 - output.height else {
                throw Self.failure("Invalid output geometry")
            }
            if output.enabled {
                rootWidth = max(rootWidth, output.x + output.width)
                rootHeight = max(rootHeight, output.y + output.height)
                for other in outputs where other.enabled && other.index < output.index {
                    guard output.x >= other.x + other.width || other.x >= output.x + output.width ||
                          output.y >= other.y + other.height || other.y >= output.y + output.height else {
                        throw Self.failure("Overlapping output topology")
                    }
                }
            }
        }
        guard rootWidth > 0, rootHeight > 0, rootWidth * rootHeight <= 67108864 else {
            throw Self.failure("Output topology exceeds root budget")
        }
        let root = (rootWidth, rootHeight)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            deviceQueue.async { [self] in
                guard !stopped, let device else { continuation.resume(throwing: Self.failure("GPU unavailable")); return }
                let epoch = generation
                processingQueue.async { [self] in
                    do {
                        guard let processor else { throw Self.failure("Renderer unavailable") }
                        try processor.setDisplay(width: UInt32(root.0), height: UInt32(root.1), rootOnly: true)
                        // Clear old metadata before enabling a changed layout, avoiding
                        // intermediate old+new extents exceeding the root budget.
                        for output in outputs {
                            try processor.setOutput(index: UInt32(output.index), width: UInt32(output.width),
                                height: UInt32(output.height), x: UInt32(output.x), y: UInt32(output.y), enabled: false)
                        }
                        for output in outputs where output.enabled {
                            try processor.setOutput(index: UInt32(output.index), width: UInt32(output.width),
                                height: UInt32(output.height), x: UInt32(output.x), y: UInt32(output.y), enabled: true)
                        }
                        deviceQueue.async { [self] in
                            guard !stopped, generation == epoch else {
                                continuation.resume(throwing: Self.failure("Stale output topology")); return
                            }
                            let data = Data([1,0,0,0, 0,0,0,0, UInt8(scanoutCount),0,0,0, 2,0,0,0])
                            device.update(VZVirtioDeviceSpecificConfiguration(configurationData: data)) { error in
                                if let error { continuation.resume(throwing: error) }
                                else { continuation.resume() }
                            }
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// Window adapters observe a crop, while the parent owns the renderer and VM.
    /// Their resize callback goes through the complete desktop topology controller.
    public func outputSession(index: Int, onResize: @escaping (Int, Int) -> Void) -> HostGraphicsSession? {
        guard (0..<scanoutCount).contains(index) else { return nil }
        return OutputSession(parent: self, index: index, onResize: onResize)
    }

    private final class OutputSession: HostGraphicsSession {
        let parent: MacOS27GPUSession
        let index: Int
        let onResize: (Int, Int) -> Void
        init(parent: MacOS27GPUSession, index: Int, onResize: @escaping (Int, Int) -> Void) {
            self.parent = parent; self.index = index; self.onResize = onResize
        }
        var backendName: String { parent.backendName }
        var isRendererRunning: Bool { parent.isRendererRunning }
        private func count(_ values: [Int: Int]) -> Int { values[index, default: 0] }
        var deliveredFrameCount: Int {
            parent.frameCounterLock.lock(); defer { parent.frameCounterLock.unlock() }
            return count(parent.outputFrameCounts)
        }
        var deliveredCursorCount: Int {
            parent.frameCounterLock.lock(); defer { parent.frameCounterLock.unlock() }
            return count(parent.outputCursorCounts)
        }
        var cursorMoveCount: Int {
            parent.frameCounterLock.lock(); defer { parent.frameCounterLock.unlock() }
            return count(parent.outputMoveCounts)
        }
        func logResourceUsage() { parent.logResourceUsage() }
        func observeFrames(_ observer: @escaping (IOSurface?) -> Void) {
            parent.deviceQueue.async { [parent, index] in
                parent.outputObservers[index] = observer
                if !parent.paused { observer(parent.outputFrames[index]) }
            }
        }
        func observeCursor(_ observer: @escaping (HostGPUCursor?) -> Void) {
            parent.deviceQueue.async { [parent, index] in
                parent.outputCursorObservers[index] = observer
                if !parent.paused { observer(parent.outputCursors[index]) }
            }
        }
        func resizeDisplay(width: Int, height: Int) { onResize(width, height) }
        func stop() {
            parent.deviceQueue.async { [parent, index] in
                parent.outputObservers.removeValue(forKey: index)?(nil)
                parent.outputCursorObservers.removeValue(forKey: index)?(nil)
            }
        }
    }

    public func resizeDisplay(width: Int, height: Int) {
        // Shared outputs resize only through their complete topology owner.
        guard scanoutCount == 1 else { return }
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
                        let data = Data([1,0,0,0, 0,0,0,0, UInt8(self.scanoutCount),0,0,0, 2,0,0,0])
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
        pending.removeAll(); completions.removeAll(); pendingBytes = 0; notifiedQueues.removeAll()
        latestFrame = nil; observer?(nil)
        latestCursor = nil; cursorObserver?(nil)
        outputFrames.removeAll(); outputCursors.removeAll()
        for callback in outputObservers.values { callback(nil) }
        for callback in outputCursorObservers.values { callback(nil) }
        device = nil
        client.stop()
        processingQueue.async { [self] in processor?.stop(); processor = nil }

    }

    public func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration,
                                          didCreateDevice device: VZCustomVirtioDevice) {
        self.device = device
        device.delegate = self
    }

    private var notifiedQueues: [Int: VZVirtioQueue] = [:]

    public func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        guard !stopped else { return }
        notifiedQueues[Int(queue.queueIndex)] = queue
        // Leave descriptors in the virtqueue until capacity is available.
        // Returning an unprocessed descriptor silently loses GPU commands.
        while pending.count < 256, pendingBytes <= 16777216 - 1048576,
              let element = queue.nextElement() {
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
        guard [UInt32(0x300), 0x301].contains(type), get32(snapshot, at: 24) < UInt32(scanoutCount) else {
            element.returnToQueue(); return
        }
        let output = Int(get32(snapshot, at: 24))
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
                if update && cursor != nil { cursorCounter += 1; outputCursorCounts[output, default: 0] += 1 }
                if !update { moveCounter += 1; outputMoveCounts[output, default: 0] += 1 }
                frameCounterLock.unlock()
                if update {
                    outputCursors[output] = cursor
                    if output == 0 { latestCursor = cursor }
                    if !paused {
                        if output == 0 { cursorObserver?(cursor) }
                        outputCursorObservers[output]?(cursor)
                    }
                }
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
        deviceQueue.async { [weak self] in
            guard let self, !self.stopped, !self.paused, let device = self.device else { return }
            for queue in self.notifiedQueues.values {
                self.customVirtioDevice(device, didReceiveNotificationFor: queue)
            }
        }
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
        for (index, callback) in outputObservers { callback(outputFrames[index]) }
        for (index, callback) in outputCursorObservers { callback(outputCursors[index]) }
    }
    public func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        state.lock(); generation += 1; state.broadcast(); state.unlock()
        let epoch = generation
        pending.removeAll(); completions.removeAll(); pendingBytes = 0; notifiedQueues.removeAll()
        latestFrame = nil; observer?(nil)
        latestCursor = nil; cursorObserver?(nil)
        outputFrames.removeAll(); outputCursors.removeAll()
        for callback in outputObservers.values { callback(nil) }
        for callback in outputCursorObservers.values { callback(nil) }
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
