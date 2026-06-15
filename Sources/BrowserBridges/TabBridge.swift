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

    /// Commands issued before the guest's tab-agent has connected. The
    /// window opens as soon as the VM is claimed, but on a cold boot
    /// Chromium + tab-agent take a few more seconds to come up — dropping
    /// commands in that gap made a boot-time ⌘T a silent no-op that left
    /// the host's focus machinery armed against a tab that never came.
    /// Buffered and flushed in order on connect. Bounded so a guest that
    /// never connects can't grow the queue forever.
    private var queuedCommands: [[String: Any]] = []
    private static let maxQueuedCommands = 32

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

    /// Fires when the guest bounces a browser-chrome keyboard shortcut back to
    /// the host. While the VM holds keyboard focus the VZ view forwards every
    /// chord to the guest before AppKit can intercept it, so Openbox in the
    /// guest grabs ⌘T/⌘W/⌘L/⌘R/⌘P (consuming them so Chromium never reacts)
    /// and tab-agent relays the bare key letter here. The value is the
    /// single-character key ("t", "w", "l", "r", "p", "h", "[", "]", and
    /// "{" / "}" for ⇧⌘[ / ⇧⌘] previous/next tab).
    public var onShortcut: ((String) -> Void)?

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
        queuedCommands = []
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
    /// Inject a real browser-chrome accelerator into the guest via xdotool
    /// (e.g. "ctrl+shift+b", "ctrl+d"). For menu-bar clicks, which can't ride
    /// the VZ keyboard path. The guest allowlists the chord.
    public func sendChord(_ chord: String) { send(["cmd": "key_chord", "chord": chord]) }
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

    // MARK: - Bookmarks request/response

    /// A node in the guest Chromium's bookmark tree. A folder has `url == nil`
    /// and may carry `children`; a bookmark has a `url` and no children.
    public struct BookmarkNode: Sendable {
        public let name: String
        public let url: String?
        public let children: [BookmarkNode]
        public var isFolder: Bool { url == nil }
    }

    /// The two top-level bookmark roots Chrome surfaces in its menu: the
    /// bookmarks-bar contents (shown inline) and Other Bookmarks.
    public struct BookmarkTree: Sendable {
        public let bookmarkBar: [BookmarkNode]
        public let other: [BookmarkNode]
    }

    private var pendingBookmarkRequests: [String: (BookmarkTree?) -> Void] = [:]

    /// Ask the guest for the current bookmark tree (read from Chromium's
    /// `Bookmarks` JSON). Returns `nil` on timeout, or when the profile has
    /// no bookmarks file yet. 5 s timeout mirrors the certificate path.
    public func fetchBookmarks() async -> BookmarkTree? {
        let requestId = UUID().uuidString
        return await withCheckedContinuation { cont in
            pendingBookmarkRequests[requestId] = { tree in cont.resume(returning: tree) }
            send(["cmd": "get_bookmarks", "request_id": requestId])
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if let cb = self?.pendingBookmarkRequests.removeValue(forKey: requestId) {
                    cb(nil)
                }
            }
        }
    }

    private static func parseBookmarkNodes(_ arr: [[String: Any]]) -> [BookmarkNode] {
        arr.compactMap { dict in
            let name = GuestTextSanitizer.title(dict["name"] as? String ?? "")
            switch dict["type"] as? String {
            case "url":
                // Drop the whole bookmark if its URL isn't a safe, navigable
                // scheme (javascript:, data:, file:, … are rejected here).
                guard let url = GuestTextSanitizer.url(dict["url"] as? String ?? "") else { return nil }
                return BookmarkNode(name: name, url: url, children: [])
            case "folder":
                let kids = dict["children"] as? [[String: Any]] ?? []
                return BookmarkNode(name: name, url: nil, children: parseBookmarkNodes(kids))
            default:
                return nil
            }
        }
    }

    private static func parseBookmarkTree(_ dict: [String: Any]) -> BookmarkTree {
        BookmarkTree(
            bookmarkBar: parseBookmarkNodes(dict["bookmark_bar"] as? [[String: Any]] ?? []),
            other: parseBookmarkNodes(dict["other"] as? [[String: Any]] ?? [])
        )
    }

    // MARK: - History request/response

    /// One history row from the guest (recently closed or recently visited).
    public struct HistoryEntry: Sendable {
        public let title: String
        public let url: String
    }

    /// The two session-history lists the History menu mirrors.
    public struct HistoryLists: Sendable {
        public let recentlyClosed: [HistoryEntry]
        public let recentlyVisited: [HistoryEntry]
    }

    private var pendingHistoryRequests: [String: (HistoryLists?) -> Void] = [:]

    /// Fetch the guest's session history (recorded by tab-agent into a SQLite
    /// DB under Chromium's profile). Returns `nil` on timeout.
    public func fetchHistory() async -> HistoryLists? {
        let requestId = UUID().uuidString
        return await withCheckedContinuation { cont in
            pendingHistoryRequests[requestId] = { lists in cont.resume(returning: lists) }
            send(["cmd": "get_history", "request_id": requestId])
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if let cb = self?.pendingHistoryRequests.removeValue(forKey: requestId) {
                    cb(nil)
                }
            }
        }
    }

    private static func parseHistoryEntries(_ arr: [[String: Any]]) -> [HistoryEntry] {
        arr.compactMap { dict in
            guard let url = GuestTextSanitizer.url(dict["url"] as? String ?? "") else { return nil }
            let title = GuestTextSanitizer.title(dict["title"] as? String ?? "")
            return HistoryEntry(title: title, url: url)
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

        // Flush anything the host asked for while the agent was still
        // booting (⌘T right after the window opened, an early navigate…).
        // The agent only connects once CDP is up, so these are actionable
        // the moment they arrive.
        let queued = queuedCommands
        queuedCommands = []
        for cmd in queued {
            send(cmd)
        }
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
        case "bookmarks":
            guard let id = obj["request_id"] as? String else { return }
            // `tree` is null when the guest has no bookmarks file yet.
            let parsed = (obj["tree"] as? [String: Any]).map(Self.parseBookmarkTree)
            if let cb = pendingBookmarkRequests.removeValue(forKey: id) {
                cb(parsed)
            }
        case "history":
            guard let id = obj["request_id"] as? String else { return }
            let closed = Self.parseHistoryEntries(obj["recently_closed"] as? [[String: Any]] ?? [])
            let visited = Self.parseHistoryEntries(obj["recently_visited"] as? [[String: Any]] ?? [])
            if let cb = pendingHistoryRequests.removeValue(forKey: id) {
                cb(HistoryLists(recentlyClosed: closed, recentlyVisited: visited))
            }
        case "shortcut":
            // A browser-chrome chord Openbox grabbed in the guest and bounced
            // back because the VM had keyboard focus. Run the host action.
            if let key = obj["key"] as? String, !key.isEmpty {
                onShortcut?(key)
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
            tbLog("[TabBridge] queueing send (no guest yet): \(obj)")
            if queuedCommands.count < Self.maxQueuedCommands {
                queuedCommands.append(obj)
            }
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

extension TabBridge {
    /// Truncate a display string to the same bound bookmark/history titles use.
    /// Applied to the URL that the menu shows when a bookmark/history row has no
    /// title, so an unnamed entry with an enormous URL can't blow out a row.
    public static func truncatedMenuTitle(_ s: String) -> String {
        GuestTextSanitizer.truncate(s)
    }
}

/// Cleans bookmark/history strings before they reach an NSMenuItem or the
/// navigation sink. These titles and URLs originate inside the disposable VM,
/// which renders untrusted web content: a hostile page can write arbitrary
/// bytes into a bookmark title or push a crafted URL into session history.
/// Everything crossing this trust boundary is treated as adversarial.
enum GuestTextSanitizer {
    /// Max displayed length of a title. Menu rows clip well before this; the
    /// cap mainly bounds memory and defeats UI-flooding via giant titles.
    static let maxTitleLength = 100

    /// Schemes we are willing to navigate to from a menu click. Everything
    /// else — javascript:, data:, blob:, file:, vbscript:, chrome:, mailto:,
    /// … — is dropped so a poisoned entry can't run script, exfiltrate via a
    /// crafted URL, or reach the local filesystem.
    static let allowedSchemes: Set<String> = ["http", "https", "ftp"]

    /// Code points stripped from every title and URL: C0/C1 controls and DEL,
    /// the Unicode bidi controls used for "Trojan Source" / right-to-left
    /// spoofing, and zero-width / BOM characters that hide or fake content.
    private static let forbiddenScalars: CharacterSet = {
        var set = CharacterSet.controlCharacters // C0, C1, DEL
        for u in 0x202A...0x202E { set.insert(Unicode.Scalar(u)!) } // bidi embeddings/overrides
        for u in 0x2066...0x2069 { set.insert(Unicode.Scalar(u)!) } // bidi isolates
        set.insert(Unicode.Scalar(0x200E)!) // LRM
        set.insert(Unicode.Scalar(0x200F)!) // RLM
        set.insert(Unicode.Scalar(0x061C)!) // Arabic letter mark
        for u in [0x200B, 0x200C, 0x200D, 0xFEFF] { set.insert(Unicode.Scalar(u)!) } // zero-width + BOM
        return set
    }()

    private static func stripForbidden(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !forbiddenScalars.contains($0) }))
    }

    /// Sanitize a title for display: decode HTML entities (`&amp;` → `&`),
    /// drop control / bidi / zero-width characters, collapse whitespace runs to
    /// single spaces, and truncate. Entity decoding runs first so that an
    /// entity-encoded control char (e.g. `&#x202E;`) is caught by the strip.
    static func title(_ raw: String) -> String {
        var s = decodeHTMLEntities(raw)
        s = stripForbidden(s)
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return truncate(s)
    }

    /// Truncate `s` to `max` characters, appending an ellipsis when cut.
    static func truncate(_ s: String, max: Int = maxTitleLength) -> String {
        guard s.count > max else { return s }
        return s.prefix(max - 1) + "…"
    }

    /// Validate and clean a navigable URL. Returns `nil` when the scheme isn't
    /// in `allowedSchemes`, signalling the caller to drop the whole entry.
    static func url(_ raw: String) -> String? {
        let cleaned = stripForbidden(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let scheme = schemeOf(cleaned),
              allowedSchemes.contains(scheme) else { return nil }
        return cleaned
    }

    /// Extract a URL's scheme per RFC 3986 (`ALPHA *( ALPHA / DIGIT / "+" /
    /// "-" / "." )` before the first `:`), lowercased. `nil` if there's no
    /// well-formed scheme — which also rejects scheme-relative/relative URLs.
    private static func schemeOf(_ s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let scheme = s[s.startIndex..<colon]
        guard let first = scheme.first, first.isLetter else { return nil }
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return scheme.lowercased()
    }

    private static let namedEntities: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
    ]

    /// Decode a subset of HTML named entities plus decimal/hex numeric
    /// references in a single left-to-right pass, so already-decoded text is
    /// never re-decoded (e.g. `&amp;lt;` → `&lt;`, not `<`).
    static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "&" else {
                result.append(s[i])
                i = s.index(after: i)
                continue
            }
            // Look for a terminating ';' within a short window.
            guard let semi = s[i...].firstIndex(of: ";"),
                  s.distance(from: i, to: semi) <= 12,
                  let decoded = decodeEntity(String(s[s.index(after: i)..<semi])) else {
                result.append(s[i])
                i = s.index(after: i)
                continue
            }
            result.append(decoded)
            i = s.index(after: semi)
        }
        return result
    }

    private static func decodeEntity(_ name: String) -> Character? {
        if let c = namedEntities[name] { return c }
        guard name.first == "#" else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if let f = digits.first, f == "x" || f == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
        return Character(scalar)
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
