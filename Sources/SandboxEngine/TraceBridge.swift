import Foundation
import Virtualization

private let traceDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG_TRACE"] != nil

/// Receives HTTP trace events from the guest VM over vsock and stores them in SQLite.
///
/// Protocol: newline-delimited JSON on vsock port 5900.
///
/// Each line is a JSON-encoded ``TraceEvent``. Events are persisted to a temporary
/// SQLite database via ``TraceStore``.
@MainActor
public final class TraceBridge: NSObject, @unchecked Sendable {
    private static let tracePort: UInt32 = 5900

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: TraceListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?

    /// Whether the guest trace agent is connected.
    public var isConnected: Bool { connection != nil }

    /// SQLite-backed event storage.
    public private(set) var store: TraceStore

    /// Whether tracing is actively recording. When paused, incoming events are dropped.
    public var isRecording: Bool = true

    /// Called on the main queue whenever a new event is received.
    public var onNewEvent: ((TraceEvent) -> Void)?

    /// Current trace events (oldest first).
    public var traceEvents: [TraceEvent] { store.queryEvents(filter: .all) }

    /// Return events with a timestamp strictly greater than the given value.
    public func eventsSince(timestamp: Double) -> [TraceEvent] {
        return store.queryEvents(filter: TraceFilter(timeStart: timestamp))
    }

    /// Remove all stored events and recreate the database.
    public func clearTrace() {
        store.destroy()
    }

    /// Serialize all stored events as a JSON array.
    public func exportAsJSON() -> Data {
        store.exportAsJSON()
    }

    /// Copy the SQLite database file to the given URL.
    public func exportDatabase(to url: URL) throws {
        try store.exportDatabase(to: url)
    }

    /// Return all distinct hostnames seen in events.
    public func distinctHostnames() -> [String] {
        store.distinctHostnames()
    }

    // MARK: - Lifecycle

    public init(
        socketDevice: VZVirtioSocketDevice,
        sessionID: String = UUID().uuidString,
        inMemory: Bool = false,
    ) {
        self.socketDevice = socketDevice
        self.store = TraceStore(sessionID: sessionID, inMemory: inMemory)
        super.init()

        if traceDebug { print("[Trace] init: setting up vsock listener on port \(Self.tracePort)") }

        let delegate = TraceListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.tracePort)
    }

    public func stop() {
        if traceDebug { print("[Trace] stop") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.tracePort)
        connection = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if traceDebug { print("[Trace] guest connected (fd=\(conn.fileDescriptor))") }

        readSource?.cancel()
        connection = conn

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if traceDebug { print("[Trace] connection closed") }
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            // Cap buffer to prevent abuse (4 MB — events can carry response bodies)
            if pendingData.count > 4_194_304 {
                if traceDebug { print("[Trace] buffer overflow, disconnecting") }
                source.cancel()
                return
            }

            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingData[pendingData.startIndex..<newlineIndex]
                pendingData = Data(pendingData[(newlineIndex + 1)...])

                if !lineData.isEmpty {
                    self?.handleMessage(Data(lineData))
                }
            }
        }

        source.setCancelHandler { [weak self] in
            if traceDebug { print("[Trace] dispatch source cancelled") }
            self?.readSource = nil
            self?.connection = nil
        }

        readSource = source
        source.activate()
    }

    private func handleMessage(_ data: Data) {
        guard isRecording else { return }  // paused — drop events

        let decoder = JSONDecoder()
        guard let event = try? decoder.decode(TraceEvent.self, from: data) else {
            if traceDebug { print("[Trace] ignoring invalid message (\(data.count) bytes)") }
            return
        }

        if traceDebug { print("[Trace] \(event.method) \(event.url) \u{2192} \(event.statusCode.map(String.init) ?? "pending")") }

        store.insert(event: event)

        onNewEvent?(event)
    }
}

// MARK: - Listener delegate

private final class TraceListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if traceDebug { print("[Trace] listener: accepting connection") }
        onConnection(connection)
        return true
    }
}
