import AppKit
import Foundation
import SandboxEngine
import Virtualization

private let tabBridgeDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil
@inline(__always) private func tbLog(_ msg: @autoclosure () -> String) {
    if tabBridgeDebug { print(msg()) }
}

/// A single tab as reported by the guest's tab-agent.
public struct TabInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var url: String
    public var active: Bool
    public var faviconPNG: Data?
    /// Whether this tab currently has at least one active getUserMedia
    /// video track. Detected by injected JS that wraps the API.
    public var usingCamera: Bool
    /// Whether this tab currently has at least one active getUserMedia
    /// audio track.
    public var usingMicrophone: Bool

    public init(
        id: String,
        title: String = "",
        url: String = "",
        active: Bool = false,
        faviconPNG: Data? = nil,
        usingCamera: Bool = false,
        usingMicrophone: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.active = active
        self.faviconPNG = faviconPNG
        self.usingCamera = usingCamera
        self.usingMicrophone = usingMicrophone
    }
}

/// Bidirectional bridge between the host and the guest's `tab-agent.py`.
///
/// The guest connects to this listener (vsock port 5810) and streams newline-
/// delimited JSON events: `upsert` / `favicon` / `remove`. The host pushes
/// commands back on the same connection: `activate`, `close`, `new`,
/// `navigate`, `reload`, `back`, `forward`.
///
/// There is at most one live guest connection at a time; later connections
/// replace earlier ones (tab-agent reconnects after crashes).
@MainActor
public final class TabBridge: NSObject, @unchecked Sendable {
    public static let vsockPort: UInt32 = 5810

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: TabListenerDelegate?
    private var currentFD: Int32 = -1
    private var currentConn: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?
    private var pending = Data()

    /// Published tab list, in guest-reported order. Set on the main actor.
    public private(set) var tabs: [TabInfo] = [] {
        didSet { onTabsChanged?(tabs) }
    }

    /// The currently-active tab (if any).
    public var activeTab: TabInfo? { tabs.first(where: { $0.active }) }

    /// Fires on main actor whenever ``tabs`` changes.
    public var onTabsChanged: (([TabInfo]) -> Void)?

    /// Fires when the guest first connects (i.e. Chromium is up).
    public var onConnected: (() -> Void)?

    /// Fires synchronously inside `send(...)` before bytes hit the wire.
    /// BrowserSession wires this up to ``VMAutoSuspend.resumeForAPIRequest``
    /// so any host-initiated tab action (URL submit, ⌘T, ⌘W, click, …) on a
    /// paused VM kicks it awake — otherwise the command sits in the vsock
    /// buffer until the next focus event resumes the VM, and the user's
    /// click feels like it did nothing.
    public var onWillSend: (() -> Void)?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()

        tbLog("[TabBridge] listening on vsock :\(Self.vsockPort)")
        let delegate = TabListenerDelegate { [weak self] conn in
            self?.adopt(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
    }

    public func stop() {
        tbLog("[TabBridge] stop")
        readSource?.cancel()
        readSource = nil
        currentConn = nil
        currentFD = -1
        socketDevice?.removeSocketListener(forPort: Self.vsockPort)
        tabs = []
    }

    // MARK: - Host → guest commands

    public func activate(id: String) { send(["cmd": "activate", "id": id]) }
    public func close(id: String)    { send(["cmd": "close",    "id": id]) }
    /// Close whichever tab the guest currently sees as active. Used by
    /// ⌘W: the host's `active` flag is fed by a 400 ms /json poll and lags
    /// behind spontaneous Chromium tab switches (target=_blank, popups),
    /// so deferring the choice to the guest avoids closing the wrong tab.
    public func closeActive()        { send(["cmd": "close_active"]) }
    public func newTab(url: String)  { send(["cmd": "new",      "url": url]) }
    public func navigate(id: String, url: String) {
        send(["cmd": "navigate", "id": id, "url": url])
    }
    public func reload(id: String)  { send(["cmd": "reload",  "id": id]) }
    public func back(id: String)    { send(["cmd": "back",    "id": id]) }
    public func forward(id: String) { send(["cmd": "forward", "id": id]) }

    /// Tell the guest to "park" the mouse outside its viewport. Called when
    /// the macOS cursor moves from the visible content area into the host
    /// toolbar — without this, Chromium keeps thinking the cursor is at the
    /// very top of the page (because VZ's tracking area extends into the
    /// clipped-off inset) and triggers spurious hover dropdowns.
    public func parkMouse() { send(["cmd": "mouse_park"]) }

    // MARK: - Print request/response

    private var pendingPrintRequests: [String: (Data?) -> Void] = [:]

    /// Render the given target as a PDF via Chromium's `Page.printToPDF`.
    /// Returns `nil` on timeout or guest error. The PDF bytes never touch
    /// disk on the guest; they fly straight back over vsock to the host.
    public func printTab(id: String) async -> Data? {
        let requestId = UUID().uuidString
        return await withCheckedContinuation { cont in
            pendingPrintRequests[requestId] = { data in cont.resume(returning: data) }
            send(["cmd": "print", "id": id, "request_id": requestId])
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
                if let cb = self?.pendingPrintRequests.removeValue(forKey: requestId) {
                    cb(nil)
                }
            }
        }
    }

    // MARK: - Certificate request/response

    public typealias CertChain = [Data]
    private var pendingCertRequests: [String: (CertChain) -> Void] = [:]

    /// Ask the guest for the DER-encoded certificate chain serving `origin`
    /// (e.g. `"https://example.com"`). Returns an empty array on timeout
    /// or if the guest can't fetch it (non-HTTPS origin, network error,
    /// etc.). Internally fans out via vsock and correlates the response
    /// against a UUID; a 5 s timeout keeps the continuation from hanging.
    public func fetchCertificate(origin: String) async -> CertChain {
        let requestId = UUID().uuidString
        return await withCheckedContinuation { cont in
            pendingCertRequests[requestId] = { certs in cont.resume(returning: certs) }
            send(["cmd": "get_certificate", "origin": origin, "request_id": requestId])
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if let cb = self?.pendingCertRequests.removeValue(forKey: requestId) {
                    cb([])
                }
            }
        }
    }

    // MARK: - Connection lifecycle

    private func adopt(_ conn: VZVirtioSocketConnection) {
        // Tear down any previous connection — tab-agent reconnects, and we
        // only want the freshest one live.
        readSource?.cancel()
        readSource = nil
        pending.removeAll()

        let fd = conn.fileDescriptor
        currentConn = conn
        currentFD = fd
        tbLog("[TabBridge] guest connected (fd=\(fd))")

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource = src
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                tbLog("[TabBridge] guest EOF")
                self.readSource?.cancel()
                return
            }
            self.pending.append(contentsOf: buf[0..<n])
            if self.pending.count > 16 * 1024 * 1024 {
                // tab-agent shouldn't ever hand us >16 MB of buffered JSON —
                // something is pathological. Drop and disconnect.
                tbLog("[TabBridge] buffer overflow, dropping connection")
                self.readSource?.cancel()
                return
            }
            while let nl = self.pending.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = self.pending[self.pending.startIndex..<nl]
                self.pending = Data(self.pending[(nl + 1)...])
                if !lineData.isEmpty {
                    self.handleLine(Data(lineData))
                }
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.currentFD == fd {
                self.currentFD = -1
                self.currentConn = nil
                self.pending.removeAll()
                // Keep `tabs` as-is so UI doesn't flash empty during reconnects.
            }
        }
        src.activate()
        onConnected?()
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tbLog("[TabBridge] ignoring non-JSON line")
            return
        }
        let event = obj["event"] as? String
        switch event {
        case "upsert":
            guard let id = obj["id"] as? String else { return }
            let title = obj["title"] as? String ?? ""
            let url = obj["url"] as? String ?? ""
            let active = obj["active"] as? Bool ?? false
            let cam = obj["using_camera"] as? Bool ?? false
            let mic = obj["using_microphone"] as? Bool ?? false
            upsert(id: id, title: title, url: url, active: active,
                   usingCamera: cam, usingMicrophone: mic)
        case "remove":
            guard let id = obj["id"] as? String else { return }
            remove(id: id)
        case "favicon":
            guard let id = obj["id"] as? String,
                  let b64 = obj["data"] as? String,
                  let bytes = Data(base64Encoded: b64)
            else { return }
            setFavicon(id: id, data: bytes)
        case "certificate":
            guard let id = obj["request_id"] as? String else { return }
            let certB64s = obj["certs"] as? [String] ?? []
            let certs = certB64s.compactMap { Data(base64Encoded: $0) }
            if let cb = pendingCertRequests.removeValue(forKey: id) {
                cb(certs)
            }
        case "pdf":
            guard let id = obj["request_id"] as? String else { return }
            let b64 = obj["data"] as? String ?? ""
            let pdf = b64.isEmpty ? nil : Data(base64Encoded: b64)
            if let cb = pendingPrintRequests.removeValue(forKey: id) {
                cb(pdf)
            }
        default:
            tbLog("[TabBridge] unknown event: \(event ?? "nil")")
        }
    }

    private func upsert(
        id: String,
        title: String,
        url: String,
        active: Bool,
        usingCamera: Bool,
        usingMicrophone: Bool
    ) {
        var updated = tabs
        if let idx = updated.firstIndex(where: { $0.id == id }) {
            updated[idx].title = title
            updated[idx].url = url
            updated[idx].active = active
            updated[idx].usingCamera = usingCamera
            updated[idx].usingMicrophone = usingMicrophone
        } else {
            updated.append(TabInfo(
                id: id, title: title, url: url, active: active,
                usingCamera: usingCamera, usingMicrophone: usingMicrophone
            ))
        }
        // Enforce single-active-tab invariant: the guest tells us which one
        // is focused, and if another was previously marked active we clear
        // it rather than rendering two highlighted tabs.
        if active {
            for i in updated.indices where updated[i].id != id {
                if updated[i].active { updated[i].active = false }
            }
        }
        tabs = updated
    }

    private func remove(id: String) {
        tabs.removeAll { $0.id == id }
    }

    private func setFavicon(id: String, data: Data) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        var updated = tabs
        updated[idx].faviconPNG = data
        tabs = updated
    }

    // MARK: - Wire send

    private func send(_ obj: [String: Any]) {
        guard currentFD >= 0 else {
            tbLog("[TabBridge] drop send (no guest): \(obj)")
            return
        }
        // Wake the VM if it was auto-suspended — the guest can't read our
        // bytes off the vsock until it's running again.
        onWillSend?()
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        let fd = currentFD
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, base.advanced(by: offset), remaining)
                if n <= 0 { break }
                offset += n
                remaining -= n
            }
        }
    }
}

private final class TabListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        DispatchQueue.main.async { self.onConnection(connection) }
        return true
    }
}
