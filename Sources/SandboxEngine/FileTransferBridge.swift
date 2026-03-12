import Foundation
import Virtualization

private let ftDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Bidirectional file transfer between host (macOS) and guest (Linux VM) over vsock.
///
/// Uses a single vsock port:
/// - Port 5100: file transfer (bidirectional)
///
/// Binary protocol (length-prefixed frames):
///
///   Each frame: [type: u8] [reserved: 7 bytes] [length: u64be] [payload: length bytes]
///
///   Type 0x01 — FILE_META:  filename(UTF-8) + NUL + filesize(u64be)
///   Type 0x02 — FILE_DATA:  raw binary chunk (follows a FILE_META)
///   Type 0x03 — FILE_END:   empty payload (marks end of file)
///   Type 0x04 — LIST_REQ:   empty payload (host → guest)
///   Type 0x05 — LIST_RESP:  NUL-separated filenames (guest → host)
@MainActor
public final class FileTransferBridge: NSObject, @unchecked Sendable {
    private static let transferPort: UInt32 = 5100

    // Frame types
    private static let typeMeta:     UInt8 = 0x01
    private static let typeData:     UInt8 = 0x02
    private static let typeEnd:      UInt8 = 0x03
    private static let typeListReq:  UInt8 = 0x04
    private static let typeListResp: UInt8 = 0x05

    private static let headerSize = 16  // 1 byte type + 7 reserved + 8 bytes length (u64be)
    private static let sendChunkSize = 1024 * 1024  // 1 MB raw chunks

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: ListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?

    // Receive state machine
    private var pendingData = Data()
    private var rxFilename: String?
    private var rxFileSize: Int = 0
    private var rxData = Data()

    /// Called when a file is received from the guest.
    /// Parameters: filename, file data.
    public var onFileReceived: ((String, Data) -> Void)?

    /// Called when a file list response is received from the guest.
    public var onFileListReceived: (([String]) -> Void)?

    /// Called when the connection state changes (guest connects/disconnects).
    public var onConnectionChanged: ((Bool) -> Void)?

    /// Called during transfer with progress (filename, bytesReceived, totalBytes).
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

        let fd = conn.fileDescriptor
        let filename = url.lastPathComponent

        // Send FILE_META
        var metaPayload = Data(filename.utf8)
        metaPayload.append(0) // NUL separator
        var size = UInt64(fileData.count).bigEndian
        metaPayload.append(Data(bytes: &size, count: 8))
        writeFrame(fd: fd, type: Self.typeMeta, payload: metaPayload)

        // Send FILE_DATA chunks
        var offset = 0
        while offset < fileData.count {
            let end = min(offset + Self.sendChunkSize, fileData.count)
            writeFrame(fd: fd, type: Self.typeData, payload: fileData[offset..<end])
            offset = end
        }

        // Send FILE_END
        writeFrame(fd: fd, type: Self.typeEnd, payload: Data())

        if ftDebug { print("[FileTransfer] sendFile: sent \(filename) (\(fileData.count) bytes)") }
    }

    /// Request a file listing from the guest.
    public func requestFileList() {
        guard let conn = connection else {
            if ftDebug { print("[FileTransfer] requestFileList: no connection") }
            return
        }
        writeFrame(fd: conn.fileDescriptor, type: Self.typeListReq, payload: Data())
        if ftDebug { print("[FileTransfer] requestFileList: sent") }
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if ftDebug { print("[FileTransfer] guest connected (fd=\(conn.fileDescriptor))") }

        // Tear down previous connection
        readSource?.cancel()
        connection = conn
        pendingData = Data()
        rxFilename = nil
        rxFileSize = 0
        rxData = Data()
        onConnectionChanged?(true)

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1_048_576) // 1MB read buffer
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if ftDebug { print("[FileTransfer] connection closed") }
                source.cancel()
                return
            }
            self?.pendingData.append(contentsOf: buf[0..<n])
            self?.drainFrames()
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

    /// Process complete frames from the receive buffer.
    private func drainFrames() {
        while pendingData.count >= Self.headerSize {
            let s = pendingData.startIndex
            let frameType = pendingData[s]
            // Bytes 1..7 are reserved (skip them), 8..15 are length (u64be)
            let payloadLen = readU64BE(pendingData, offset: s + 8)

            let totalFrameSize = Self.headerSize + payloadLen
            guard pendingData.count >= totalFrameSize else { break }

            let payload = pendingData[(s + Self.headerSize) ..< (s + totalFrameSize)]
            pendingData = Data(pendingData[(s + totalFrameSize)...])

            handleFrame(type: frameType, payload: Data(payload))
        }
    }

    private func handleFrame(type: UInt8, payload: Data) {
        switch type {
        case Self.typeMeta:
            // Parse: filename(UTF-8) + NUL + filesize(u64be)
            guard let nulIndex = payload.firstIndex(of: 0),
                  payload.count >= nulIndex - payload.startIndex + 1 + 8 else {
                if ftDebug { print("[FileTransfer] FILE_META: invalid payload") }
                return
            }
            let nameData = payload[payload.startIndex..<nulIndex]
            let filename = String(data: nameData, encoding: .utf8) ?? "unknown"
            let sizeOffset = nulIndex + 1
            let fileSize = readU64BE(payload, offset: sizeOffset)

            if filename.hasSuffix(".crdownload") {
                if ftDebug { print("[FileTransfer] ignoring temp file: \(filename)") }
                rxFilename = nil
                return
            }

            rxFilename = filename
            rxFileSize = fileSize
            rxData = Data()
            rxData.reserveCapacity(fileSize)
            if ftDebug { print("[FileTransfer] FILE_META: \(filename) (\(fileSize) bytes)") }

        case Self.typeData:
            guard let filename = rxFilename else { return }
            rxData.append(payload)
            if ftDebug && rxData.count % (5 * 1024 * 1024) < payload.count {
                print("[FileTransfer] FILE_DATA: \(rxData.count)/\(rxFileSize) bytes")
            }
            onTransferProgress?(filename, rxData.count, rxFileSize)

        case Self.typeEnd:
            guard let filename = rxFilename else { return }
            if ftDebug { print("[FileTransfer] FILE_END: \(filename) (\(rxData.count) bytes)") }
            onFileReceived?(filename, rxData)
            rxFilename = nil
            rxFileSize = 0
            rxData = Data()

        case Self.typeListResp:
            let files = String(data: payload, encoding: .utf8)?
                .split(separator: "\0")
                .map(String.init) ?? []
            if ftDebug { print("[FileTransfer] file list: \(files)") }
            onFileListReceived?(files)

        default:
            if ftDebug { print("[FileTransfer] unknown frame type: 0x\(String(type, radix: 16))") }
        }
    }

    // MARK: - Helpers

    /// Read a big-endian UInt64 from Data at the given absolute index.
    private func readU64BE(_ data: Data, offset: Data.Index) -> Int {
        var val: UInt64 = 0
        for i in 0..<8 {
            val = val << 8 | UInt64(data[offset + i])
        }
        return Int(val)
    }

    // MARK: - Wire format

    /// Write a single frame: [type: u8][reserved: 7][length: u64be][payload].
    private func writeFrame(fd: Int32, type: UInt8, payload: some DataProtocol) {
        let payloadCount = payload.count
        var header = Data(count: Self.headerSize)  // zero-initialized (reserved bytes = 0)
        header[0] = type
        // Bytes 1..7 reserved (already zero)
        header[8] = UInt8((payloadCount >> 56) & 0xFF)
        header[9] = UInt8((payloadCount >> 48) & 0xFF)
        header[10] = UInt8((payloadCount >> 40) & 0xFF)
        header[11] = UInt8((payloadCount >> 32) & 0xFF)
        header[12] = UInt8((payloadCount >> 24) & 0xFF)
        header[13] = UInt8((payloadCount >> 16) & 0xFF)
        header[14] = UInt8((payloadCount >> 8) & 0xFF)
        header[15] = UInt8(payloadCount & 0xFF)

        writeAll(fd: fd, data: header)
        if payloadCount > 0 {
            writeAll(fd: fd, data: Data(payload))
        }
    }

    /// Write all bytes, retrying on partial writes.
    private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { ptr in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, ptr.baseAddress! + offset, data.count - offset)
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
