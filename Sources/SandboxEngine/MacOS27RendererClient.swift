import Foundation
import IOSurface

@objc(BromureRendererService)
public protocol RendererServiceProtocol: NSObjectProtocol {
    @objc(processCommand:reply:)
    func processCommand(_ command: Data, reply: @escaping (Data?, IOSurface?, NSError?) -> Void)
}

/// Host transport for the embedded renderer. New renderer libraries stay in
/// the macOS 27 XPC service, separate from the macOS 14 application process.
@available(macOS 27.0, *)
public final class MacOS27RendererClient {
    public struct Reply {
        public let command: Data
        public let surface: IOSurface?
    }

    private let connection: NSXPCConnection
    private let queue = DispatchQueue(label: "io.bromure.renderer.client")
    private var pending: [UUID: (Result<Reply, Error>) -> Void] = [:]
    private var pendingBytes = 0
    private var stopped = false

    public init(bundle: Bundle = .main) throws {
        let service = bundle.bundleURL.appendingPathComponent("Contents/XPCServices/io.bromure.gpu.renderer.xpc")
        guard FileManager.default.fileExists(atPath: service.path) else {
            throw Self.failure("Embedded GPU renderer is missing")
        }
        connection = NSXPCConnection(serviceName: "io.bromure.gpu.renderer")
        connection.remoteObjectInterface = NSXPCInterface(with: RendererServiceProtocol.self)
        connection.invalidationHandler = { [weak self] in self?.stop() }
        connection.interruptionHandler = { [weak self] in self?.stop() }
        connection.resume()
    }

    deinit { connection.invalidate() }

    /// Completion occurs on the transport queue. Callers dispatch guest-memory
    /// access to their device queue and presentation to the main queue.
    public func execute(_ command: Data, completion: @escaping (Result<Reply, Error>) -> Void) {
        let snapshot = Data(command)
        queue.async { [self] in
            guard !stopped, snapshot.count >= 24, snapshot.count <= 65536,
                  pending.count < 256, pendingBytes <= 16777216 - snapshot.count else {
                completion(.failure(Self.failure("Renderer request budget exceeded or renderer stopped")))
                return
            }
            let token = UUID()
            pendingBytes += snapshot.count
            pending[token] = completion
            let finish: (Result<Reply, Error>) -> Void = { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard let callback = self.pending.removeValue(forKey: token) else { return }
                    self.pendingBytes -= snapshot.count
                    callback(result)
                }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in finish(.failure(error)) }
            guard let renderer = proxy as? RendererServiceProtocol else {
                finish(.failure(Self.failure("Renderer XPC interface unavailable"))); return
            }
            renderer.processCommand(snapshot) { response, surface, error in
                if let error { finish(.failure(error)); return }
                guard let response, response.count >= 24, response.count <= 65536,
                      Self.validReply(response, request: snapshot), Self.validSurface(surface),
                      surface == nil || [UInt32(0x103), 0x104, 0xffff0003].contains(Self.word(snapshot, 0)) else {
                    finish(.failure(Self.failure("Malformed renderer reply"))); return
                }
                finish(.success(Reply(command: response, surface: surface)))
            }
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.pending[token] != nil else { return }
                self.failAll(Self.failure("GPU renderer timed out"))
                self.connection.invalidate()
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            failAll(Self.failure("GPU renderer stopped"))
            connection.invalidate()
        }
    }

    private func failAll(_ error: Error) {
        guard !stopped else { return }
        stopped = true
        let callbacks = Array(pending.values)
        pending.removeAll(); pendingBytes = 0
        for callback in callbacks { callback(.failure(error)) }
    }

    private static func validSurface(_ surface: IOSurface?) -> Bool {
        guard let surface else { return true }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        return width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
            width * height <= 33554432 && IOSurfaceGetPixelFormat(surface) == 0x42475241 &&
            IOSurfaceGetBytesPerRow(surface) >= width * 4 &&
            IOSurfaceGetAllocSize(surface) <= 268435456 && IOSurfaceGetPlaneCount(surface) == 0
    }

    private static func validReply(_ response: Data, request: Data) -> Bool {
        let type = word(response, 0), flags = word(request, 4) & 1
        let expected: UInt32
        switch word(request, 0) {
        case 0x100: expected = 0x1101
        case 0x108: expected = 0x1102
        case 0x109: expected = 0x1103
        default: expected = 0x1100
        }
        guard type == expected || (0x1200...0x1205).contains(type),
              word(response, 4) == flags, word(response, 16) == word(request, 16),
              word(response, 20) == 0 else { return false }
        if flags != 0 && response[8..<16] != request[8..<16] { return false }
        if (0x1200...0x1205).contains(type) && response.count != 24 { return false }
        return true
    }

    private static func word(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "BromureRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
