import AppKit
import Foundation
import UniformTypeIdentifiers
import Virtualization

/// Routes guest file-upload dialogs through the host's native macOS file picker.
///
/// Listens on vsock port 5600 for lightweight JSON control messages.
/// The actual file data is sent via the existing FileTransferBridge (port 5100).
///
/// Protocol: newline-delimited JSON on vsock port 5600.
///
///   Guest → Host:  {"type":"pick","accept":"image/*,.pdf","requestId":"..."}
///   Host → Guest:  {"type":"pick_result","requestId":"...","status":"ok",
///                    "filename":"photo.jpg","mimeType":"image/jpeg"}
///             OR:  {"type":"pick_result","requestId":"...","status":"cancelled"}
///
/// After sending "ok", the host transfers the file via FileTransferBridge.
/// The guest agent waits for the file to appear on disk before notifying Chrome.
@MainActor
public final class FilePickerBridge: NSObject, @unchecked Sendable {
    private static let pickerPort: UInt32 = 5600

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: PickerListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?
    private var pendingData = Data()

    /// Whether an NSOpenPanel is currently being shown.
    private var panelOpen = false

    /// Queued pick requests that arrived while the panel was open.
    private var requestQueue: [[String: Any]] = []

    /// Called when a file needs to be sent to the guest via the file transfer bridge.
    /// Parameter: file URL to send.
    public var onSendFile: ((URL) -> Void)?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        print("[FilePicker] init: setting up vsock listener on port \(Self.pickerPort)")

        let delegate = PickerListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.pickerPort)
    }

    public func stop() {
        print("[FilePicker] stop")
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.pickerPort)
        connection = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        print("[FilePicker] guest connected (fd=\(conn.fileDescriptor))")

        readSource?.cancel()
        connection = conn
        pendingData = Data()

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                print("[FilePicker] connection closed (read returned \(n))")
                source.cancel()
                return
            }
            self?.pendingData.append(contentsOf: buf[0..<n])
            self?.drainMessages()
        }

        source.setCancelHandler { [weak self] in
            print("[FilePicker] dispatch source cancelled")
            self?.readSource = nil
            self?.connection = nil
        }

        source.resume()
        readSource = source
    }

    /// Process complete newline-delimited JSON messages from the receive buffer.
    private func drainMessages() {
        while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pendingData[pendingData.startIndex..<newlineIndex]
            pendingData = Data(pendingData[(newlineIndex + 1)...])

            if pendingData.count > 1_048_576 {
                print("[FilePicker] buffer overflow, disconnecting")
                readSource?.cancel()
                return
            }

            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            if type == "pick" {
                if panelOpen {
                    let requestId = json["requestId"] as? String ?? "?"
                    print("[FilePicker] panel already open, queuing request \(requestId)")
                    requestQueue.append(json)
                } else {
                    handlePickRequest(json)
                }
            }
        }
    }

    private func handlePickRequest(_ json: [String: Any]) {
        let requestId = json["requestId"] as? String ?? ""
        let accept = json["accept"] as? String ?? ""

        print("[FilePicker] pick request: accept=\(accept) requestId=\(requestId)")

        panelOpen = true

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Upload File"
        panel.prompt = "Upload"

        let allowedTypes = Self.parseAcceptAttribute(accept)
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }

        panel.begin { [weak self] response in
            guard let self = self else { return }

            self.panelOpen = false

            if response == .OK, let url = panel.url {
                print("[FilePicker] user selected: \(url.lastPathComponent)")
                self.sendPickResult(url: url, requestId: requestId)
            } else {
                print("[FilePicker] user cancelled")
                self.sendCancelResponse(requestId: requestId)
            }

            // Process next queued request
            if !self.requestQueue.isEmpty {
                let next = self.requestQueue.removeFirst()
                let nextId = next["requestId"] as? String ?? "?"
                print("[FilePicker] processing queued request \(nextId)")
                self.handlePickRequest(next)
            }
        }
    }

    private func sendCancelResponse(requestId: String) {
        guard let conn = connection else {
            print("[FilePicker] sendCancel: no connection!")
            return
        }
        let resp: [String: Any] = [
            "type": "pick_result",
            "requestId": requestId,
            "status": "cancelled",
        ]
        sendJSON(fd: conn.fileDescriptor, json: resp)
        print("[FilePicker] sent cancel for \(requestId)")
    }

    private func sendPickResult(url: URL, requestId: String) {
        guard let conn = connection else {
            print("[FilePicker] sendPickResult: no connection!")
            return
        }

        let filename = url.lastPathComponent
        let mimeType = Self.mimeType(for: url)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        // Send the file via the existing file transfer bridge (port 5100)
        print("[FilePicker] sending file via FileTransferBridge: \(filename) (\(fileSize) bytes)")
        onSendFile?(url)

        // Send JSON metadata on the control channel (port 5600)
        // Include size so the guest can wait for the exact byte count
        let resp: [String: Any] = [
            "type": "pick_result",
            "requestId": requestId,
            "status": "ok",
            "filename": filename,
            "mimeType": mimeType,
            "size": fileSize,
        ]
        sendJSON(fd: conn.fileDescriptor, json: resp)
        print("[FilePicker] sent pick_result for \(requestId): \(filename)")
    }

    // MARK: - Helpers

    private func sendJSON(fd: Int32, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              var line = String(data: data, encoding: .utf8)
        else {
            print("[FilePicker] sendJSON: serialization failed")
            return
        }
        line += "\n"
        line.withCString { ptr in
            var offset = 0
            let len = Int(strlen(ptr))
            while offset < len {
                let written = Darwin.write(fd, ptr + offset, len - offset)
                if written <= 0 {
                    print("[FilePicker] sendJSON write error at \(offset)/\(len)")
                    break
                }
                offset += written
            }
        }
    }

    /// Parse an HTML accept attribute (e.g. "image/*,.pdf,video/mp4") into UTTypes.
    static func parseAcceptAttribute(_ accept: String) -> [UTType] {
        guard !accept.isEmpty else { return [] }

        var types = [UTType]()
        for token in accept.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix(".") {
                let ext = String(trimmed.dropFirst())
                if let uttype = UTType(filenameExtension: ext) {
                    types.append(uttype)
                }
            } else if trimmed.hasSuffix("/*") {
                let category = String(trimmed.dropLast(2))
                switch category {
                case "image": types.append(.image)
                case "video": types.append(.video)
                case "audio": types.append(.audio)
                case "text": types.append(.text)
                default: break
                }
            } else {
                if let uttype = UTType(mimeType: trimmed) {
                    types.append(uttype)
                }
            }
        }
        return types
    }

    /// Get MIME type for a file URL.
    static func mimeType(for url: URL) -> String {
        if let uttype = UTType(filenameExtension: url.pathExtension) {
            return uttype.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}

// MARK: - Listener delegate

private final class PickerListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        print("[FilePicker] listener: accepting connection")
        onConnection(connection)
        return true
    }
}
