import Foundation
import Virtualization

private let ftDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Bidirectional file transfer between host (macOS) and guest (Linux VM) over vsock.
///
/// Uses a single vsock port:
/// - Port 5100: file transfer (bidirectional)
///
/// Protocol: newline-delimited JSON (one JSON object per line).
///
/// Message types:
/// - "file_upload"   (host → guest): push a file into the guest ~/Downloads
/// - "file_download" (guest → host): guest sends a file to the host
/// - "file_list"     (host → guest): request listing of guest ~/Downloads
/// - "file_list_response" (guest → host): response with file listing
///
/// JSON envelope:
/// ```
/// {"type":"file_upload","filename":"example.pdf","size":12345,"data":"<base64>"}
/// ```
@MainActor
public final class FileTransferBridge: NSObject, @unchecked Sendable {
    private static let transferPort: UInt32 = 5100

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: ListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?

    // Chunked transfer state
    private var chunkedFilename: String?
    private var chunkedSize: Int = 0
    private var chunkedData = Data()

    /// Called when a file is received from the guest.
    /// Parameters: filename, file data.
    public var onFileReceived: ((String, Data) -> Void)?

    /// Called when a file list response is received from the guest.
    public var onFileListReceived: (([String]) -> Void)?

    /// Called when the connection state changes (guest connects/disconnects).
    public var onConnectionChanged: ((Bool) -> Void)?

    /// Called during chunked transfer with progress (filename, bytesReceived, totalBytes).
    public var onTransferProgress: ((String, Int, Int) -> Void)?

    /// Start file transfer bridging on the given socket device.
    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        if ftDebug { print("[FileTransfer] init: setting up vsock listener on port \(Self.transferPort)") }

        let delegate = ListenerDelegate(label: "ft") { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.transferPort)

        if ftDebug { print("[FileTransfer] init: listener registered") }
    }

    public func stop() {
        if ftDebug { print("[FileTransfer] stop: tearing down") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.transferPort)
        connection = nil
    }

    /// Whether the guest agent is connected.
    public var isConnected: Bool { connection != nil }

    // MARK: - Send file to guest

    /// Send a file from the host to the guest VM.
    public func sendFile(url: URL) {
        guard let conn = connection else {
            if ftDebug { print("[FileTransfer] sendFile: no connection") }
            return
        }
        guard let fileData = try? Data(contentsOf: url) else {
            if ftDebug { print("[FileTransfer] sendFile: could not read \(url.path)") }
            return
        }

        let envelope: [String: Any] = [
            "type": "file_upload",
            "filename": url.lastPathComponent,
            "size": fileData.count,
            "data": fileData.base64EncodedString(),
        ]

        sendMessage(envelope, on: conn)
        if ftDebug { print("[FileTransfer] sendFile: sent \(url.lastPathComponent) (\(fileData.count) bytes)") }
    }

    /// Request a file listing from the guest.
    public func requestFileList() {
        guard let conn = connection else {
            if ftDebug { print("[FileTransfer] requestFileList: no connection") }
            return
        }

        let envelope: [String: Any] = [
            "type": "file_list",
        ]

        sendMessage(envelope, on: conn)
        if ftDebug { print("[FileTransfer] requestFileList: sent") }
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if ftDebug { print("[FileTransfer] guest connected (fd=\(conn.fileDescriptor), src=\(conn.sourcePort), dst=\(conn.destinationPort))") }

        // Tear down previous connection
        readSource?.cancel()
        connection = conn
        onConnectionChanged?(true)

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1_048_576) // 1MB read buffer
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if ftDebug { print("[FileTransfer] connection closed") }
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            // Process complete newline-delimited JSON messages
            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingData[pendingData.startIndex..<newlineIndex]
                pendingData = Data(pendingData[(newlineIndex + 1)...])

                if !lineData.isEmpty {
                    self?.handleMessage(Data(lineData))
                }
            }
        }

        source.setCancelHandler { [weak self] in
            if ftDebug { print("[FileTransfer] dispatch source cancelled") }
            self?.readSource = nil
            self?.connection = nil
            self?.onConnectionChanged?(false)
        }

        source.resume()
        readSource = source
    }

    private func handleMessage(_ jsonData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = json["type"] as? String else {
            if ftDebug { print("[FileTransfer] invalid JSON message") }
            return
        }

        switch type {
        case "file_download":
            // Single-shot transfer (small files)
            guard let filename = json["filename"] as? String,
                  let base64 = json["data"] as? String,
                  let fileData = Data(base64Encoded: base64) else {
                if ftDebug { print("[FileTransfer] file_download: missing fields") }
                return
            }
            if filename.hasSuffix(".crdownload") {
                if ftDebug { print("[FileTransfer] ignoring temp file: \(filename)") }
                return
            }
            if ftDebug { print("[FileTransfer] received file: \(filename) (\(fileData.count) bytes)") }
            onFileReceived?(filename, fileData)

        case "file_start":
            // Begin chunked transfer
            guard let filename = json["filename"] as? String,
                  let size = json["size"] as? Int else {
                if ftDebug { print("[FileTransfer] file_start: missing fields") }
                return
            }
            if filename.hasSuffix(".crdownload") {
                if ftDebug { print("[FileTransfer] ignoring temp file: \(filename)") }
                chunkedFilename = nil
                return
            }
            chunkedFilename = filename
            chunkedSize = size
            chunkedData = Data()
            chunkedData.reserveCapacity(size)
            if ftDebug { print("[FileTransfer] file_start: \(filename) (\(size) bytes)") }

        case "file_chunk":
            guard let filename = chunkedFilename,
                  let base64 = json["data"] as? String,
                  let chunkData = Data(base64Encoded: base64) else { return }
            chunkedData.append(chunkData)
            if ftDebug, let seq = json["seq"] as? Int {
                print("[FileTransfer] file_chunk #\(seq): +\(chunkData.count) bytes (total: \(chunkedData.count)/\(chunkedSize))")
            }
            onTransferProgress?(filename, chunkedData.count, chunkedSize)

        case "file_end":
            guard let filename = chunkedFilename else { return }
            if ftDebug { print("[FileTransfer] file_end: \(filename) (\(chunkedData.count) bytes)") }
            onFileReceived?(filename, chunkedData)
            chunkedFilename = nil
            chunkedSize = 0
            chunkedData = Data()

        case "file_list_response":
            let files = json["files"] as? [String] ?? []
            if ftDebug { print("[FileTransfer] file list: \(files)") }
            onFileListReceived?(files)

        default:
            if ftDebug { print("[FileTransfer] unknown message type: \(type)") }
        }
    }

    // MARK: - Wire format

    /// Send a JSON message as a newline-terminated line.
    private func sendMessage(_ envelope: [String: Any], on conn: VZVirtioSocketConnection) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope) else {
            if ftDebug { print("[FileTransfer] sendMessage: JSON serialization failed") }
            return
        }

        var frame = jsonData
        frame.append(UInt8(ascii: "\n"))

        let fd = conn.fileDescriptor
        frame.withUnsafeBytes { ptr in
            var offset = 0
            while offset < frame.count {
                let written = Darwin.write(fd, ptr.baseAddress! + offset, frame.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}

// MARK: - VZVirtioSocketListenerDelegate

private final class ListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let label: String
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(label: String, onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.label = label
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if ftDebug { print("[FileTransfer] \(label) listener: accepting connection from port \(connection.sourcePort) -> \(connection.destinationPort)") }
        onConnection(connection)
        return true
    }
}
