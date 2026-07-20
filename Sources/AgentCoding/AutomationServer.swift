import Foundation
import SandboxEngine

/// HTTP server exposing a JSON API for orchestrating Bromure Agentic Coding
/// from outside the process. Intended use cases:
///   - Tests/ac-e2e.mjs (the main client today)
///   - `bromure-ac mcp` (the MCP subcommand wraps this same surface)
///
/// Endpoints (v1):
///   GET    /health                — `{ "status": "ok", "service": "bromure-ac-automation" }`
///   GET    /profiles              — `{ "profiles": [{ id, name, color, tool, authMode }, …] }`
///   GET    /sessions              — `{ "sessions": [{ profileId, profileName, windowId, visible }, …] }`
///   POST   /sessions              — body: `{ "profile": "<name-or-uuid>" }`; returns the
///                                   `AutomationSessionInfo` for the new session
///   GET    /sessions/{id}         — single-session info (id is the profile UUID)
///   DELETE /sessions/{id}         — close any open session for that profile
///   GET    /app/state             — full app-state snapshot
///   POST   /sessions/{id}/exec    — run a shell command inside the guest
///   GET    /vms                   — list running VMs
///   POST   /vms                   — create + boot a VM (profile ref or inline spec)
///   DELETE /vms/{id}              — stop a VM (body: `{ "action": "shutdown"|"suspend" }`)
///   POST   /vms/{id}/attach       — open a window onto a running VM
///   POST   /vms/{id}/exec         — run a shell command inside the guest
///
/// The TCP listener binds 127.0.0.1 and gates exec / app-state / vm endpoints
/// behind BROMURE_DEBUG_CLAUDE. The owner-only Unix control socket
/// (`control.sock`, mode 0600) used by the `bromure-ac` CLI is trusted: the
/// socket file's permissions are the access gate, so no env var is required.
final class ACAutomationServer {
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    let port: UInt16
    let bindAddress: String
    /// When non-nil, bind an AF_UNIX socket at this path instead of TCP — the
    /// owner-only local control socket used by the `bromure-ac` CLI.
    let unixSocketPath: String?
    /// True for the Unix control socket: `exec` / `/app/state` / `/vms` routes
    /// are allowed without `BROMURE_DEBUG_CLAUDE`, because reaching a 0600
    /// socket already proves local ownership.
    let isTrustedLocal: Bool

    let debugEnabled: Bool

    /// Callbacks plumbed by the app delegate.
    var onListProfiles: (() -> [ACAutomationProfileInfo])?
    var onListSessions: (() -> [ACAutomationSessionInfo])?
    var onCreateSession: ((_ profileNameOrID: String) async -> ACAutomationSessionInfo?)?
    var onDestroySession: ((_ profileNameOrID: String) async -> Bool)?
    /// Git-worktree action for a session (SSH/CLI parity with the GUI's
    /// right-click menu): `action` ∈ create/merge/remove/resolve/terminal,
    /// `args` are the raw (un-encoded) fields the delegate base64-encodes into
    /// the guest command. Returns true if the command was queued.
    var onWorktreeCommand: ((_ profileNameOrID: String, _ action: String, _ args: [String]) -> Bool)?
    /// Tab command for a running session — SSH/CLI parity with the GUI. `action`
    /// ∈ new/select/close; `index` is the tmux window index (for select/close).
    /// Returns true if the command was queued.
    var onTabCommand: ((_ profileNameOrID: String, _ action: String, _ index: Int) -> Bool)?
    var onGetAppState: (() -> [String: Any])?
    /// Debug: render a window (`which` = "unified" | "picker" | "editor") to a
    /// PNG at the given path and return a dump of its subview frames. The app
    /// draws itself, so this needs no Screen Recording permission.
    var onUIShot: ((_ path: String, _ which: String) -> [String: Any])?
    /// Debug: drive the settings editor for the screenshot tool — `action` is
    /// "ensure-profile" | "open" | "category" | "close". Lets the doc-screenshot
    /// script navigate over the control socket instead of AppleScript.
    var onEditorDebug: ((_ params: [String: Any]) -> [String: Any])?
    /// E2E hook: drive a rich-client (fat-client) mirror window — see
    /// `RemoteHostWindow.debugPerform`. Resolves the target host + workspace and
    /// forwards the action.
    var onFatClientDebug: ((_ params: [String: Any]) -> [String: Any])?
    /// Fat-client board: dismiss a failed/blocked run from Needs Attention.
    var onAcknowledgeRun: ((_ runID: UUID) -> Bool)?
    /// Coding board: list tasks / upsert a task doc.
    var onListTasks: (() -> [String: Any])?
    var onUpsertTask: ((_ doc: [String: Any]) -> Bool)?
    /// Coding board verbs: start / send-back / merge / to-testing / comment /
    /// delete on one task. Returns a JSON-able result ("error" key on failure).
    var onTaskCommand: ((_ id: UUID, _ action: String, _ body: [String: Any]) -> [String: Any])?
    /// Returns a vsock connection wrapping a ShellBridge-dequeued one, or nil
    /// if no shell-agent connection is available for that session.
    var onGetShellConnection: ((_ profileID: String) -> ACShellProxyConnection?)?
    /// Resolve an id-or-name to the canonical profile UUID string, so interactive
    /// attach state is keyed the same way the consent broker queries it (by UUID).
    var onResolveProfileID: ((_ idOrName: String) -> String?)?

    // docker-style VM control plane (CLI). Each returns plain dicts/bools so
    // the server stays free of app types.
    var onListVMs: (() -> [[String: Any]])?
    var onStopVM: ((_ idOrName: String, _ action: String) async -> Bool)?
    var onAttachVM: ((_ idOrName: String) async -> Bool)?
    /// Create (boot) a VM from a profile ref or inline spec + mounts. Returns
    /// the new VM's info dict, or nil on failure.
    var onCreateVM: ((_ spec: [String: Any]) async -> [String: Any]?)?
    /// Disk + home rollback points (CLI `vm checkpoints` / `vm revert`). List
    /// returns newest-first dicts tagged `target: disk|home`; revert takes the
    /// same target and returns a result dict (with an `error` key on failure,
    /// e.g. the VM is still running).
    var onListCheckpoints: ((_ idOrName: String) -> [[String: Any]])?
    var onRevertCheckpoint: ((_ idOrName: String, _ checkpoint: String,
                              _ target: String) async -> [String: Any])?

    // Profile management (CLI `profiles …`).
    var onDescribeProfile: ((_ idOrName: String) -> [String: Any]?)?
    var onDeleteProfile: ((_ idOrName: String) -> [String: Any])?
    /// Full-fidelity Profile JSON (secrets blanked) for the `workspaces edit`
    /// round-trip + the TUI raw-JSON hatch. nil when the workspace is unknown.
    var onExportProfile: ((_ idOrName: String) -> [String: Any]?)?
    /// Create a workspace from a JSON document. Returns `{ok, id, …}` or
    /// `{ok:false, error}`.
    var onCreateProfile: ((_ doc: [String: Any]) -> [String: Any])?
    /// Update a workspace (full-document, secret-preserving). Returns
    /// `{ok, …}` or `{ok:false, error}`.
    var onUpdateProfile: ((_ idOrName: String, _ doc: [String: Any]) -> [String: Any])?
    /// Reboot a running workspace in place (`soft` | `hard`). Async — a fresh
    /// VM has to boot before it returns.
    var onRebootVM: ((_ idOrName: String, _ mode: String) async -> [String: Any])?

    // MITM trace inspection (CLI `trace …`) + fusion toggle (`vm fusion`).
    var onListTrace: ((_ profileKey: String?) -> [[String: Any]])?
    var onClearTrace: (() -> Int)?
    /// Full `TraceRecord`s (not the preview-only summary `onListTrace` gives the
    /// CLI) — backs the fat-client Trace Inspector, which needs swaps, bodyStored,
    /// timestamps, etc. to render the same detail pane a local window does.
    var onListTraceRecords: ((_ profileKey: String?) -> [TraceRecord])?
    /// Decrypt and return one record's request/response body. The bytes are
    /// AES-GCM-sealed with *this* host's SecretsVault key, so only the remote can
    /// read them — it decrypts and ships plaintext over the (encrypted) tunnel.
    var onLoadTraceBody: ((_ id: UUID, _ kind: TraceStore.BodyKind) -> Data?)?
    var onSetFusion: ((_ idOrName: String, _ engaged: Bool) -> [String: Any])?
    // Local-inference routing (vLLM.md): `vm routing`, `vm hybrid`, `model use`.
    var onSetRouting: ((_ idOrName: String, _ mode: String) -> [String: Any])?
    var onSetHybrid: ((_ idOrName: String, _ knob: String, _ value: Double) -> [String: Any])?
    var onSetModel: ((_ idOrName: String, _ modelID: String) -> [String: Any])?

    // Remote access (optional SSH front door) — CLI `remote …` + Preferences.
    var onRemoteStatus: (() -> [String: Any])?
    var onRemoteApply: ((_ spec: [String: Any]) -> [String: Any])?
    var onRemoteAddKey: ((_ publicKey: String) -> [String: Any])?
    var onRemoteRemoveKey: ((_ selector: String) -> [String: Any])?

    // Fat-client mirror (a remote bromure-ac reflecting this one 1:1).
    /// All workspaces (running or not) as sidebar rows.
    var onListWorkspaces: (() -> [[String: Any]])?
    /// The persisted grid (StageLayout): cells + focus/zoom.
    var onGetGridLayout: (() -> [String: Any])?
    /// Apply a whole grid layout (last-writer-wins).
    var onSetGridLayout: ((_ doc: [String: Any]) -> Bool)?
    /// Scheduled automations + run history.
    var onListAutomations: (() -> [String: Any])?
    /// Upsert / delete / run-now / toggle a scheduled automation.
    var onUpsertAutomation: ((_ doc: [String: Any]) -> Bool)?
    var onDeleteAutomation: ((_ id: String) -> Bool)?
    var onRunAutomation: ((_ id: String) -> Bool)?
    var onToggleAutomation: ((_ id: String) -> Bool)?
    /// One native file op ({"file": {...}}) in the VM's guest — the remote
    /// file browser's data plane (upload/download/list/delete as base64 JSON).
    var onGuestFileOp: ((_ idOrName: String, _ op: [String: Any], _ timeout: Int) async -> [String: Any])?
    /// A docker dashboard action (start/stop/remove/logs/attach/run/binfmt/
    /// watch) for the VM — validated host-side, then sent over the same
    /// outbox verb protocol the local GUI uses.
    var onDockerCommand: ((_ idOrName: String, _ doc: [String: Any]) -> [String: Any])?
    /// Decision prompts pending for a remote client (fat client), + answer.
    var onListPendingPrompts: (() -> [[String: Any]])?
    var onAnswerPrompt: ((_ id: String, _ choice: Int) -> Bool)?

    init(port: UInt16 = 9223, bindAddress: String = "127.0.0.1") {
        // 9223 (one off from the browser's 9222) so both apps can run side
        // by side during development without conflicting.
        self.port = port
        self.bindAddress = bindAddress
        self.unixSocketPath = nil
        self.isTrustedLocal = false
        self.debugEnabled = ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] != nil
    }

    /// Owner-only Unix-domain control socket for the local CLI. Always trusted
    /// — the 0600 socket file is the access gate.
    init(unixSocketPath: String) {
        self.port = 0
        self.bindAddress = ""
        self.unixSocketPath = unixSocketPath
        self.isTrustedLocal = true
        self.debugEnabled = ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] != nil
    }

    func start() {
        if let path = unixSocketPath { startUnix(path: path) } else { startTCP() }
    }

    private func startTCP() {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            print("[ACAutomation] ERROR: failed to create socket")
            return
        }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(bindAddress)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            print("[ACAutomation] ERROR: bind failed on \(bindAddress):\(port): \(String(cString: strerror(errno)))")
            Darwin.close(sock)
            return
        }

        Darwin.listen(sock, 32)
        beginAccepting(on: sock)
        print("[ACAutomation] listening on \(bindAddress):\(port)\(debugEnabled ? " (debug endpoints enabled)" : "")")
    }

    private func startUnix(path: String) {
        unlink(path)   // clear any stale socket from a previous run
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            print("[ACAutomation] ERROR: failed to create unix socket")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)   // 104 on Darwin
        guard pathBytes.count < cap else {
            print("[ACAutomation] ERROR: control socket path too long (\(pathBytes.count) ≥ \(cap))")
            Darwin.close(sock)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
                dst[pathBytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            print("[ACAutomation] ERROR: unix bind failed on \(path): \(String(cString: strerror(errno)))")
            Darwin.close(sock)
            return
        }
        chmod(path, 0o600)   // owner-only: the file mode is the access gate
        Darwin.listen(sock, 32)
        beginAccepting(on: sock)
        print("[ACAutomation] control socket listening on \(path)")
    }

    private func beginAccepting(on sock: Int32) {
        self.serverSocket = sock
        let unixPath = unixSocketPath
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [weak self] in
            if self?.serverSocket == sock { Darwin.close(sock) }
            if let unixPath { unlink(unixPath) }
        }
        source.resume()
        self.acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
        print("[ACAutomation] stopped")
    }

    // MARK: - Connection

    private func acceptConnection() {
        // Address-family-agnostic accept (works for both TCP and the Unix
        // control socket); we don't use the peer address.
        let clientFD = Darwin.accept(serverSocket, nil, nil)
        guard clientFD >= 0 else { return }

        var linger = Darwin.linger(l_onoff: 1, l_linger: 2)
        setsockopt(clientFD, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleRequest(fd: clientFD)
        }
    }

    private func handleRequest(fd: Int32) {
        // Read the whole request off the socket. Bytes arrive in multiple reads
        // — especially over the ssh tunnel, where the first read may hold only
        // part of the header block — so accumulate until the header terminator
        // (\r\n\r\n), then read exactly Content-Length body bytes. The previous
        // code assumed the first 64 KB read held the whole header block AND kept
        // its body loop bounded by that first buffer; when the tunnel split the
        // stream the body arrived truncated, its JSON failed to parse, and a
        // POST /vms/{id}/file upload reached the guest as an empty op → the
        // guest agent's "path must be absolute".
        var data = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)

        // Index just past the first "\r\n\r\n", or nil if not yet seen.
        func headerEndIndex() -> Int? {
            guard data.count >= 4 else { return nil }
            var i = 0
            while i <= data.count - 4 {
                if data[i] == 13, data[i + 1] == 10, data[i + 2] == 13, data[i + 3] == 10 {
                    return i + 4
                }
                i += 1
            }
            return nil
        }

        var bodyStart: Int? = nil
        while bodyStart == nil {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { Darwin.close(fd); return }
            data.append(contentsOf: chunk[0..<n])
            bodyStart = headerEndIndex()
            // A header block this large is bogus — bail rather than grow forever.
            if bodyStart == nil, data.count > (1 << 20) { Darwin.close(fd); return }
        }
        let start = bodyStart!

        let headerBlock = String(decoding: data[0..<start], as: UTF8.self)
        var contentLength = 0
        if let clRange = headerBlock.lowercased().range(of: "content-length:") {
            contentLength = Int(headerBlock.lowercased()[clRange.upperBound...]
                .drop(while: { $0 == " " }).prefix(while: { $0.isNumber })) ?? 0
        }
        // Memory guard against a bogus Content-Length; 16 MB clears a 6 MB raw
        // upload chunk (8 MB base64 + JSON) from POST /vms/{id}/file.
        contentLength = min(max(0, contentLength), 16 * 1024 * 1024)

        while data.count - start < contentLength {
            let want = min(chunk.count, contentLength - (data.count - start))
            let n = Darwin.read(fd, &chunk, want)
            if n <= 0 { break }   // peer closed / error mid-body
            data.append(contentsOf: chunk[0..<n])
        }

        let requestLine = headerBlock.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendResponse(fd: fd, status: 400, body: ["error": "Bad request"])
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var bodyJSON: [String: Any] = [:]
        let bodyBytes = data.count > start ? Array(data[start...]) : []
        if !bodyBytes.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: Data(bodyBytes)) as? [String: Any] {
            bodyJSON = json
        }
        // Truncation/parse-failure breadcrumb: a body shorter than declared, or
        // a non-empty body that didn't parse, is the "path must be absolute"
        // upload failure. Debug-gated so it can't spam a normal run.
        if debugEnabled, contentLength > 0 {
            if bodyBytes.count < contentLength {
                NSLog("[ac-http] %@ %@ TRUNCATED body: read %d of Content-Length %d",
                      method, path, bodyBytes.count, contentLength)
            } else if bodyJSON.isEmpty {
                NSLog("[ac-http] %@ %@ body parse FAILED (%d bytes, CL %d)",
                      method, path, bodyBytes.count, contentLength)
            }
        }

        route(fd: fd, method: method, path: path, bodyJSON: bodyJSON)
    }

    // MARK: - Routing

    private func route(fd: Int32, method: String, path: String, bodyJSON: [String: Any]) {
        switch (method, path) {
        case ("GET", "/health"):
            sendResponse(fd: fd, status: 200, body: [
                "status": "ok",
                "service": "bromure-ac-automation",
                "debugEnabled": debugEnabled,
            ])

        case ("GET", "/profiles"):
            let profiles = DispatchQueue.main.sync { self.onListProfiles?() ?? [] }
            sendResponse(fd: fd, status: 200, body: ["profiles": profiles.map { $0.toDict() }])

        case ("POST", "/profiles"):
            // Create a workspace from a JSON document (headless counterpart of
            // the SwiftUI editor). Owner-only, like every other mutation.
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let result = DispatchQueue.main.sync { self.onCreateProfile?(bodyJSON) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 201 : 400, body: result)

        case ("GET", "/sessions"):
            let sessions = DispatchQueue.main.sync { self.onListSessions?() ?? [] }
            sendResponse(fd: fd, status: 200, body: ["sessions": sessions.map { $0.toDict() }])

        case ("POST", "/sessions"):
            guard let profile = (bodyJSON["profile"] as? String) ?? (bodyJSON["profileId"] as? String),
                  !profile.isEmpty else {
                sendResponse(fd: fd, status: 400, body: ["error": "Missing 'profile' field"])
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            var result: ACAutomationSessionInfo?
            DispatchQueue.main.async {
                Task { @MainActor in
                    result = await self.onCreateSession?(profile)
                    semaphore.signal()
                }
            }
            semaphore.wait()
            if let info = result {
                sendResponse(fd: fd, status: 201, body: info.toDict())
            } else {
                sendResponse(fd: fd, status: 500, body: ["error": "Failed to create session"])
            }

        case ("GET", "/app/state"):
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            var state = DispatchQueue.main.sync { self.onGetAppState?() ?? [:] }
            state["debugEnabled"] = true
            sendResponse(fd: fd, status: 200, body: state)

        // Fat-client mirror endpoints. Trusted (control socket) only — they
        // carry no secrets but they are the fat client's whole state feed.
        // One-shot combined snapshot (the poll workhorse): workspaces + running
        // VMs + grid layout + automations in a single round trip.
        case ("GET", "/state"):
            guard isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            var snapshot: [String: Any] = DispatchQueue.main.sync {
                [
                    "version": FatClient.protocolVersion,
                    "workspaces": self.onListWorkspaces?() ?? [],
                    "vms": self.onListVMs?() ?? [],
                    "gridLayout": self.onGetGridLayout?() ?? ["cells": []],
                    "automations": self.onListAutomations?() ?? ["automations": [], "runs": []],
                    "tasks": self.onListTasks?() ?? ["tasks": []],
                    // Decision prompts awaiting a remote answer (storage
                    // upgrade, drift reset, …) — the fat client renders these
                    // as local alerts and answers via POST /prompts/{id}/answer.
                    "pendingPrompts": self.onListPendingPrompts?() ?? [],
                ]
            }
            // The workspace VM subnet, so a fat client can route/tunnel to it
            // (Phase 4). nil until the first VM boots the vmnet interface.
            if let subnet = SandboxEngine.VMNetSwitch.shared.subnet {
                snapshot["vmnetSubnet"] = subnet.cidrString
                snapshot["vmnetGateway"] = subnet.startAddressString
            }
            sendResponse(fd: fd, status: 200, body: snapshot)

        case ("GET", "/workspaces"):
            guard isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let ws = DispatchQueue.main.sync { self.onListWorkspaces?() ?? [] }
            sendResponse(fd: fd, status: 200, body: ["workspaces": ws])

        case ("GET", "/grid-layout"):
            guard isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let layout = DispatchQueue.main.sync { self.onGetGridLayout?() ?? ["cells": []] }
            sendResponse(fd: fd, status: 200, body: layout)

        case ("POST", "/grid-layout"):
            guard isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let ok = DispatchQueue.main.sync { self.onSetGridLayout?(bodyJSON) ?? false }
            sendResponse(fd: fd, status: ok ? 200 : 400, body: ["ok": ok])

        case ("GET", "/automations"):
            guard debugEnabled || isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let list = DispatchQueue.main.sync { self.onListAutomations?() ?? ["automations": [], "runs": []] }
            sendResponse(fd: fd, status: 200, body: list)

        case ("POST", "/automations"):
            guard debugEnabled || isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let ok = DispatchQueue.main.sync { self.onUpsertAutomation?(bodyJSON) ?? false }
            sendResponse(fd: fd, status: ok ? 200 : 400, body: ["ok": ok])

        // Answer a pending decision prompt (fat client). The id names the
        // prompt (from /state's pendingPrompts); the body carries the chosen
        // button index.
        case ("POST", let p) where p.hasPrefix("/prompts/") && p.hasSuffix("/answer"):
            guard isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let id = String(p.dropFirst("/prompts/".count).dropLast("/answer".count))
            let choice = (bodyJSON["choice"] as? Int) ?? -1
            let ok = DispatchQueue.main.sync { self.onAnswerPrompt?(id, choice) ?? false }
            sendResponse(fd: fd, status: ok ? 200 : 404, body: ["ok": ok])

        case (_, let p) where p == "/debug/ui-shot" || p.hasPrefix("/debug/ui-shot?"):
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Local only"])
                return
            }
            var pathParam = "/tmp/bromure-ui-shot.png"
            var whichParam = "unified"
            if let q = p.split(separator: "?", maxSplits: 1).dropFirst().first {
                for pair in q.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    let v = kv[1].removingPercentEncoding ?? String(kv[1])
                    if kv.first == "path" { pathParam = v }
                    if kv.first == "which" { whichParam = v }
                }
            }
            let dump = DispatchQueue.main.sync { self.onUIShot?(pathParam, whichParam) ?? ["error": "no handler"] }
            sendResponse(fd: fd, status: 200, body: dump)

        case ("POST", "/debug/editor"):
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Local only"])
                return
            }
            let r = DispatchQueue.main.sync { self.onEditorDebug?(bodyJSON) ?? ["error": "no handler"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        case ("POST", "/debug/fatclient"):
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Local only"])
                return
            }
            let r = DispatchQueue.main.sync { self.onFatClientDebug?(bodyJSON) ?? ["error": "no handler"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        // Run the prompt-injection detectors on supplied text and return a
        // verdict — a test/introspection hook so the e2e suite can exercise
        // the real detection code (heuristic scanner + ONNX models) with
        // known good/bad data, without booting a VM. Gated behind the debug
        // flag like the other introspection endpoints.
        case ("POST", "/detect/prompt-injection"):
            guard debugEnabled else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            let text = (bodyJSON["text"] as? String) ?? ""
            let kind = (bodyJSON["kind"] as? String) ?? "rules"
            sendResponse(fd: fd, status: 200, body: Self.runDetection(text: text, kind: kind))

        // docker-style VM control plane.
        case ("GET", "/vms"):
            let vms = DispatchQueue.main.sync { self.onListVMs?() ?? [] }
            sendResponse(fd: fd, status: 200, body: ["vms": vms])

        case ("POST", "/vms"):
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any]?
            DispatchQueue.main.async {
                Task { @MainActor in
                    result = await self.onCreateVM?(bodyJSON)
                    semaphore.signal()
                }
            }
            semaphore.wait()
            if let info = result {
                // A handler that returns an `error` key is a clean refusal
                // (e.g. the workspace's local model is still downloading).
                if let err = info["error"] as? String {
                    sendResponse(fd: fd, status: 409, body: ["error": err])
                } else {
                    sendResponse(fd: fd, status: 201, body: info)
                }
            } else {
                sendResponse(fd: fd, status: 500, body: ["error": "Failed to create VM"])
            }

        // Remote access control plane (CLI `remote …`). Owner-only socket.
        case ("GET", "/remote"):
            guard isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let s = DispatchQueue.main.sync { self.onRemoteStatus?() ?? [:] }
            sendResponse(fd: fd, status: 200, body: s)

        case ("POST", "/remote"):
            guard isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let r = DispatchQueue.main.sync { self.onRemoteApply?(bodyJSON) ?? ["error": "unavailable"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        case ("POST", "/remote/keys"):
            guard isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let key = (bodyJSON["key"] as? String) ?? ""
            let r = DispatchQueue.main.sync { self.onRemoteAddKey?(key) ?? ["error": "unavailable"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        case (let m, let p) where m == "DELETE" && p.hasPrefix("/remote/keys/"):
            guard isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            let sel = String(p.dropFirst("/remote/keys/".count)).removingPercentEncoding
                ?? String(p.dropFirst("/remote/keys/".count))
            let r = DispatchQueue.main.sync { self.onRemoteRemoveKey?(sel) ?? ["error": "unavailable"] }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        // Coding board: GET /tasks lists, POST /tasks upserts a task doc,
        // POST /tasks/{id}/{start|send-back|merge|to-testing|comment} and
        // DELETE /tasks/{id} drive one task. CLI/E2E/fat-client surface.
        case ("GET", "/tasks"):
            guard debugEnabled || isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let list = DispatchQueue.main.sync { self.onListTasks?() ?? ["tasks": []] }
            sendResponse(fd: fd, status: 200, body: list)

        case ("POST", "/tasks"):
            guard debugEnabled || isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let ok = DispatchQueue.main.sync { self.onUpsertTask?(bodyJSON) ?? false }
            sendResponse(fd: fd, status: ok ? 200 : 400, body: ["ok": ok])

        case (let m, let p) where p.hasPrefix("/tasks/"):
            guard debugEnabled || isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let rest = String(p.dropFirst("/tasks/".count))
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            guard let id = parts.first.flatMap({ $0.removingPercentEncoding })
                .flatMap(UUID.init(uuidString:)) else {
                sendResponse(fd: fd, status: 400, body: ["error": "Bad task id"]); return
            }
            let action = m == "DELETE" ? "delete" : (parts.count > 1 ? parts[1] : "")
            let r = DispatchQueue.main.sync {
                self.onTaskCommand?(id, action, bodyJSON) ?? ["error": "no handler"]
            }
            sendResponse(fd: fd, status: r["error"] == nil ? 200 : 400, body: r)

        // Fat-client automation RUN actions (id is a run id, not an
        // automation id): POST /automation-runs/{id}/acknowledge dismisses a
        // failed/blocked run from the board's Needs Attention column;
        // GET /automation-runs/{id}/transcript returns the archived Claude
        // transcript (base64) so a fat client can render the native view.
        case (let m, let p) where p.hasPrefix("/automation-runs/"):
            guard debugEnabled || isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let rest = String(p.dropFirst("/automation-runs/".count))
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            let idStr = parts.first.flatMap { $0.removingPercentEncoding } ?? ""
            let action = parts.count > 1 ? parts[1] : ""
            guard let runID = UUID(uuidString: idStr) else {
                sendResponse(fd: fd, status: 400, body: ["error": "Bad run id"]); return
            }
            switch (m, action) {
            case ("POST", "acknowledge"):
                let ok = DispatchQueue.main.sync { self.onAcknowledgeRun?(runID) ?? false }
                sendResponse(fd: fd, status: ok ? 200 : 404, body: ["ok": ok])
            case ("GET", "transcript"):
                guard let data = try? Data(
                    contentsOf: AutomationRunArchive.transcriptURL(for: runID)) else {
                    sendResponse(fd: fd, status: 404, body: ["error": "No transcript"]); return
                }
                sendResponse(fd: fd, status: 200,
                             body: ["transcript": data.base64EncodedString()])
            default:
                sendResponse(fd: fd, status: 404, body: ["error": "Not found", "path": path])
            }

        // Fat-client automation edits: DELETE /automations/{id},
        // POST /automations/{id}/run, POST /automations/{id}/toggle.
        case (let m, let p) where p.hasPrefix("/automations/"):
            guard debugEnabled || isTrustedLocal else { sendResponse(fd: fd, status: 403, body: ["error": "Local only"]); return }
            let rest = String(p.dropFirst("/automations/".count))
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            let id = parts.first.flatMap { $0.removingPercentEncoding } ?? ""
            let action = parts.count > 1 ? parts[1] : ""
            let ok: Bool
            switch (m, action) {
            case ("DELETE", ""):     ok = DispatchQueue.main.sync { self.onDeleteAutomation?(id) ?? false }
            case ("POST", "run"):    ok = DispatchQueue.main.sync { self.onRunAutomation?(id) ?? false }
            case ("POST", "toggle"): ok = DispatchQueue.main.sync { self.onToggleAutomation?(id) ?? false }
            default:
                sendResponse(fd: fd, status: 404, body: ["error": "Not found", "path": path]); return
            }
            sendResponse(fd: fd, status: ok ? 200 : 400, body: ["ok": ok])

        case (let m, let p) where p.hasPrefix("/vms/"):
            handleVMRoute(fd: fd, method: m, path: p, bodyJSON: bodyJSON)

        case (let m, let p) where p.hasPrefix("/profiles/"):
            handleProfileRoute(fd: fd, method: m, path: p, bodyJSON: bodyJSON)

        case (let m, let p) where p == "/trace" || p.hasPrefix("/trace?") || p.hasPrefix("/trace/"):
            handleTraceRoute(fd: fd, method: m, path: p)

        // /sessions/{id} and /sessions/{id}/exec
        case (let m, let p) where p.hasPrefix("/sessions/"):
            handleSessionRoute(fd: fd, method: m, path: p, bodyJSON: bodyJSON)

        default:
            sendResponse(fd: fd, status: 404, body: ["error": "Not found", "path": path])
        }
    }

    /// Run the real prompt-injection detectors on `text` and return a verdict.
    /// `kind == "source"` → PromptGuard (tool_result injection). Otherwise the
    /// rogue-instruction detectors: the deterministic `RulesFileScanner`
    /// heuristics (always available) plus the fine-tuned ModernBERT model when
    /// installed. `modelInstalled` lets the caller distinguish "model said no"
    /// from "model not downloaded".
    private static func runDetection(text: String, kind: String) -> [String: Any] {
        // Box so the semaphore-bridged Task can write the async result without
        // a concurrent-capture warning on a bare local var.
        final class Box: @unchecked Sendable { var hit = false }

        if kind == "source" {
            let installed = PromptInjectionModels.isInstalled(.promptGuard)
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                box.hit = await PromptInjectionClassifier.shared
                    .detect(spans: [(id: "test", content: text)]) != nil
                sem.signal()
            }
            sem.wait()
            return ["detector": "source", "flagged": box.hit, "modelInstalled": installed]
        }

        // rules: deterministic heuristics + ModernBERT (if installed).
        let findings = RulesFileScanner.scanHiddenUnicode(text)
            + RulesFileScanner.scanInstructionContent(text)
        let heuristicHigh = findings.contains { $0.severity == .high }
        let installed = PromptInjectionModels.isInstalled(.claudeMdGuard)
        let box = Box()
        if installed {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                box.hit = await PromptInjectionClassifier.claudeMd
                    .detect(spans: [(id: "test", content: text)]) != nil
                sem.signal()
            }
            sem.wait()
        }
        return [
            "detector": "rules",
            "flagged": heuristicHigh || box.hit,
            "heuristicHigh": heuristicHigh,
            "signals": findings.map { $0.signal },
            "modelFlagged": box.hit,
            "modelInstalled": installed,
        ]
    }

    private func handleSessionRoute(fd: Int32, method: String, path: String, bodyJSON: [String: Any]) {
        let rest = String(path.dropFirst("/sessions/".count))
        if rest.hasSuffix("/worktree") {
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
                return
            }
            let id = String(rest.dropLast("/worktree".count))
            let action = bodyJSON["action"] as? String ?? ""
            let args = (bodyJSON["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            let ok = DispatchQueue.main.sync { self.onWorktreeCommand?(id, action, args) ?? false }
            sendResponse(fd: fd, status: ok ? 200 : 400,
                         body: ok ? ["ok": true] : ["ok": false, "error": "unknown session or bad action"])
            return
        }
        if rest.hasSuffix("/tab") {
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
                return
            }
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
                return
            }
            let id = String(rest.dropLast("/tab".count))
            let action = bodyJSON["action"] as? String ?? "new"
            let index = (bodyJSON["index"] as? Int) ?? Int(bodyJSON["index"] as? String ?? "") ?? 0
            let ok = DispatchQueue.main.sync { self.onTabCommand?(id, action, index) ?? false }
            sendResponse(fd: fd, status: ok ? 200 : 400,
                         body: ok ? ["ok": true] : ["ok": false, "error": "unknown session or bad action"])
            return
        }
        if rest.hasSuffix("/exec") {
            guard debugEnabled || isTrustedLocal else {
                sendResponse(fd: fd, status: 403, body: ["error": "Debug endpoints require BROMURE_DEBUG_CLAUDE"])
                return
            }
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
                return
            }
            let id = String(rest.dropLast("/exec".count))
            handleExec(fd: fd, profileID: id, bodyJSON: bodyJSON)
            return
        }

        // /sessions/{id}
        let id = rest
        switch method {
        case "GET":
            let sessions = DispatchQueue.main.sync { self.onListSessions?() ?? [] }
            if let s = sessions.first(where: { $0.profileID == id || $0.profileName == id }) {
                sendResponse(fd: fd, status: 200, body: s.toDict())
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "Session not found"])
            }
        case "DELETE":
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                Task { @MainActor in
                    ok = await self.onDestroySession?(id) ?? false
                    semaphore.signal()
                }
            }
            semaphore.wait()
            if ok {
                sendResponse(fd: fd, status: 200, body: ["status": "closed"])
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "Session not found"])
            }
        default:
            sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
        }
    }

    private func handleVMRoute(fd: Int32, method: String, path: String, bodyJSON: [String: Any]) {
        guard debugEnabled || isTrustedLocal else {
            sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
            return
        }
        // Strip any query string; params come from the JSON body.
        let noQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let rest = String(noQuery.dropFirst("/vms/".count))
        // The id/name is a single percent-encoded path segment (so names with
        // spaces survive the request line) — decode it before resolving.
        func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }

        if rest.hasSuffix("/exec") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            handleExec(fd: fd, profileID: decode(String(rest.dropLast("/exec".count))), bodyJSON: bodyJSON)
            return
        }
        if rest.hasSuffix("/file") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/file".count)))
            let op = (bodyJSON["op"] as? [String: Any]) ?? [:]
            let timeout = (bodyJSON["timeout"] as? Int) ?? 30
            if debugEnabled {
                // What actually reached the guest-op layer: an empty op / blank
                // path here (with the body log above quiet) means the op itself
                // was dropped, not the body truncated.
                let dataLen = (op["data"] as? String)?.count ?? 0
                NSLog("[ac-http] /file op=%@ path=%@ dataB64=%d",
                      (op["op"] as? String) ?? "<none>",
                      (op["path"] as? String) ?? "<none>", dataLen)
            }
            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = ["error": "not handled"]
            DispatchQueue.main.async {
                Task { @MainActor in
                    result = await self.onGuestFileOp?(id, op, timeout) ?? ["error": "not handled"]
                    semaphore.signal()
                }
            }
            semaphore.wait()
            sendResponse(fd: fd, status: result["error"] == nil ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/docker") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/docker".count)))
            let result = DispatchQueue.main.sync { self.onDockerCommand?(id, bodyJSON) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/attach") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/attach".count)))
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                Task { @MainActor in ok = await self.onAttachVM?(id) ?? false; semaphore.signal() }
            }
            semaphore.wait()
            sendResponse(fd: fd, status: ok ? 200 : 404,
                         body: ok ? ["status": "attached"] : ["error": "VM not found"])
            return
        }
        if rest.hasSuffix("/checkpoints") {
            guard method == "GET" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/checkpoints".count)))
            let list = DispatchQueue.main.sync { self.onListCheckpoints?(id) ?? [] }
            sendResponse(fd: fd, status: 200, body: ["checkpoints": list])
            return
        }
        if rest.hasSuffix("/revert") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/revert".count)))
            let cp = (bodyJSON["checkpoint"] as? String) ?? ""
            let target = (bodyJSON["target"] as? String) ?? "disk"
            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = ["error": "not handled"]
            DispatchQueue.main.async {
                Task { @MainActor in
                    result = await self.onRevertCheckpoint?(id, cp, target) ?? ["error": "not handled"]
                    semaphore.signal()
                }
            }
            semaphore.wait()
            sendResponse(fd: fd, status: result["error"] == nil ? 200 : 400, body: result)
            return
        }
        if rest.hasSuffix("/reboot") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/reboot".count)))
            let mode = (bodyJSON["mode"] as? String) ?? "soft"
            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any] = ["ok": false, "error": "not handled"]
            DispatchQueue.main.async {
                Task { @MainActor in
                    result = await self.onRebootVM?(id, mode) ?? ["ok": false, "error": "not handled"]
                    semaphore.signal()
                }
            }
            semaphore.wait()
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/fusion") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/fusion".count)))
            let engaged = (bodyJSON["engaged"] as? Bool) ?? false
            let result = DispatchQueue.main.sync { self.onSetFusion?(id, engaged) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/routing") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/routing".count)))
            let mode = (bodyJSON["mode"] as? String) ?? "cloud"
            let result = DispatchQueue.main.sync { self.onSetRouting?(id, mode) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/hybrid") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/hybrid".count)))
            let knob = (bodyJSON["knob"] as? String) ?? ""
            let value = (bodyJSON["value"] as? Double) ?? Double((bodyJSON["value"] as? Int) ?? 0)
            let result = DispatchQueue.main.sync { self.onSetHybrid?(id, knob, value) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        if rest.hasSuffix("/model") {
            guard method == "POST" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let id = decode(String(rest.dropLast("/model".count)))
            let modelID = (bodyJSON["modelID"] as? String) ?? ""
            let result = DispatchQueue.main.sync { self.onSetModel?(id, modelID) }
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
            return
        }
        // /vms/{id}
        let id = decode(rest)
        switch method {
        case "DELETE":
            let action = (bodyJSON["action"] as? String) ?? "shutdown"
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                Task { @MainActor in ok = await self.onStopVM?(id, action) ?? false; semaphore.signal() }
            }
            semaphore.wait()
            sendResponse(fd: fd, status: ok ? 200 : 404,
                         body: ok ? ["status": "stopped"] : ["error": "VM not found"])
        case "GET":
            let vms = DispatchQueue.main.sync { self.onListVMs?() ?? [] }
            if let vm = vms.first(where: {
                ($0["id"] as? String) == id || ($0["shortId"] as? String) == id
                    || ($0["name"] as? String) == id
            }) {
                sendResponse(fd: fd, status: 200, body: vm)
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "VM not found"])
            }
        default:
            sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
        }
    }

    private func handleTraceRoute(fd: Int32, method: String, path: String) {
        guard debugEnabled || isTrustedLocal else {
            sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
            return
        }
        // Split "/path?a=b&c=d" into the bare path + a decoded query map.
        let bare: String
        var query: [String: String] = [:]
        if let qIdx = path.firstIndex(of: "?") {
            bare = String(path[..<qIdx])
            for pair in path[path.index(after: qIdx)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        } else {
            bare = path
        }
        let profileKey = query["profile"]

        // Fat-client Trace Inspector back-channel: full records + decrypted bodies.
        switch bare {
        case "/trace/records":
            guard method == "GET" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            let recs = DispatchQueue.main.sync { self.onListTraceRecords?(profileKey) ?? [] }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let dicts: [[String: Any]] = recs.compactMap { rec in
                guard let data = try? encoder.encode(rec),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return obj
            }
            sendResponse(fd: fd, status: 200, body: ["records": dicts])
            return
        case "/trace/body":
            guard method == "GET" else {
                sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"]); return
            }
            guard let idStr = query["id"], let id = UUID(uuidString: idStr),
                  let kind = query["kind"].flatMap(TraceStore.BodyKind.init(rawValue:)) else {
                sendResponse(fd: fd, status: 400, body: ["error": "id and kind (request|response) required"]); return
            }
            let data = DispatchQueue.main.sync { self.onLoadTraceBody?(id, kind) }
            sendResponse(fd: fd, status: 200, body: ["body": data?.base64EncodedString() ?? ""])
            return
        default:
            break
        }

        switch method {
        case "GET":
            let recs = DispatchQueue.main.sync { self.onListTrace?(profileKey) ?? [] }
            sendResponse(fd: fd, status: 200, body: ["trace": recs])
        case "DELETE":
            let n = DispatchQueue.main.sync { self.onClearTrace?() ?? 0 }
            sendResponse(fd: fd, status: 200, body: ["cleared": n])
        default:
            sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
        }
    }

    private func handleProfileRoute(fd: Int32, method: String, path: String, bodyJSON: [String: Any]) {
        guard debugEnabled || isTrustedLocal else {
            sendResponse(fd: fd, status: 403, body: ["error": "Control endpoints require the local control socket"])
            return
        }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let noQuery = parts.first ?? path
        let query = parts.count > 1 ? parts[1] : ""
        let raw = String(noQuery.dropFirst("/profiles/".count))
        let id = raw.removingPercentEncoding ?? raw
        switch method {
        case "GET":
            // `?full=1` → the whole Profile Codable (secrets blanked) for the
            // `workspaces edit` / raw-JSON round-trip; otherwise the compact
            // describe summary.
            if query.contains("full=1") || query.contains("full=true") {
                if let d = DispatchQueue.main.sync(execute: { self.onExportProfile?(id) }) {
                    sendResponse(fd: fd, status: 200, body: d)
                } else {
                    sendResponse(fd: fd, status: 404, body: ["error": "Profile not found"])
                }
            } else if let d = DispatchQueue.main.sync(execute: { self.onDescribeProfile?(id) }) {
                sendResponse(fd: fd, status: 200, body: d)
            } else {
                sendResponse(fd: fd, status: 404, body: ["error": "Profile not found"])
            }
        case "PUT", "PATCH":
            // Full-document, secret-preserving update (the client sends a doc it
            // fetched via `?full=1`, edited).
            let result = DispatchQueue.main.sync(execute: { self.onUpdateProfile?(id, bodyJSON) })
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            // 404 for a missing workspace, 400 for a bad document, else 200.
            let status: Int = ok ? 200
                : ((result["error"] as? String)?.contains("not found") == true ? 404 : 400)
            sendResponse(fd: fd, status: status, body: result)
        case "DELETE":
            let result = DispatchQueue.main.sync(execute: { self.onDeleteProfile?(id) })
                ?? ["ok": false, "error": "unavailable"]
            let ok = (result["ok"] as? Bool) ?? false
            sendResponse(fd: fd, status: ok ? 200 : 409, body: result)
        default:
            sendResponse(fd: fd, status: 405, body: ["error": "Method not allowed"])
        }
    }

    private func handleExec(fd: Int32, profileID: String, bodyJSON: [String: Any]) {
        // Interactive (`exec -it`): hijack the client connection and stream a
        // pty session — no request/response framing at this layer.
        if bodyJSON["interactive"] as? Bool == true {
            handleInteractiveExec(clientFD: fd, profileID: profileID, bodyJSON: bodyJSON)
            return
        }
        let command = bodyJSON["command"] as? String ?? ""
        if command.isEmpty {
            sendResponse(fd: fd, status: 400, body: ["error": "Missing 'command' field"])
            return
        }
        let timeout = bodyJSON["timeout"] as? Int ?? 30

        // Wait up to 10s for a shell connection (matches the browser's behavior).
        var shellConn: ACShellProxyConnection?
        for _ in 0..<100 {
            shellConn = DispatchQueue.main.sync { self.onGetShellConnection?(profileID) }
            if shellConn != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard var conn = shellConn else {
            sendResponse(fd: fd, status: 502, body: [
                "error": "No shell connection for '\(profileID)' after 10s — the VM may not be running, the id/name didn't match, or its shell agent hasn't come up yet.",
            ])
            return
        }

        // A dequeued connection can be DEAD without the pool knowing — after an
        // in-place guest reboot the pool head still holds the previous boot's
        // sockets. A dead socket fails before the command ever runs (write
        // error / instant EOF), so it's safe to fall through to the next queued
        // connection; a mid-stream failure is NOT retried (the command may have
        // executed).
        for attempt in 0..<4 {
            switch Self.executeShellCommand(fd: conn.fd, command: command, timeout: timeout) {
            case .success(let result):
                sendResponse(fd: fd, status: 200, body: [
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "exitCode": result.exitCode,
                ])
                _ = conn.conn  // keep alive until the response is sent
                return
            case .deadConnection:
                guard attempt < 3,
                      let next = DispatchQueue.main.sync(execute: { self.onGetShellConnection?(profileID) })
                else {
                    sendResponse(fd: fd, status: 502, body: [
                        "error": "Shell command execution failed (stale guest connection — retry in a moment)",
                    ])
                    return
                }
                conn = next
            case .protocolFailure:
                sendResponse(fd: fd, status: 502, body: ["error": "Shell command execution failed"])
                return
            }
        }
    }

    /// Run `command` in `profileID`'s VM via the shell agent; return stdout, or
    /// nil on failure. Blocking — call off the main thread (it hops to main only
    /// to dequeue a shell connection). Used by `RemoteConsent` to drive a tmux
    /// consent popup over SSH.
    public func vmExec(profileID: String, command: String, timeoutSeconds: Int) -> String? {
        var shellConn: ACShellProxyConnection?
        for _ in 0..<100 {
            shellConn = DispatchQueue.main.sync { self.onGetShellConnection?(profileID) }
            if shellConn != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard var conn = shellConn else { return nil }
        // Same stale-pool retry as handleExec: a dead pooled socket (previous
        // guest boot) fails before the command runs, so the next one is safe.
        for attempt in 0..<4 {
            defer { _ = conn.conn }   // keep the connection alive until we're done
            switch Self.executeShellCommand(fd: conn.fd, command: command, timeout: timeoutSeconds) {
            case .success(let result): return result.stdout
            case .protocolFailure: return nil
            case .deadConnection:
                guard attempt < 3,
                      let next = DispatchQueue.main.sync(execute: { self.onGetShellConnection?(profileID) })
                else { return nil }
                conn = next
            }
        }
        return nil
    }

    // Active interactive (CLI/SSH) attaches → the gate the host uses to present a
    // consent prompt on the USER's side of the pump (never in the guest). SHARED
    // (static) across all AutomationServer instances (control-socket + TCP); one
    // gate per profile (the most recent attach wins).
    private static let attachLock = NSLock()
    nonisolated(unsafe) private static var consentGates: [String: PumpConsentGate] = [:]

    /// True while `profileID` has a live interactive (CLI/SSH) attach — i.e. a
    /// consent prompt can be shown on the user's terminal instead of an NSAlert.
    static func isInteractivelyAttached(_ profileID: String) -> Bool {
        attachLock.lock(); defer { attachLock.unlock() }
        return consentGates[profileID] != nil
    }

    /// Present a consent prompt on the attached user's terminal (host side of the
    /// pump) and return the chosen 0-based index — or nil (no live attach / the
    /// user dismissed / timed out), which every broker maps to deny.
    static func presentConsentViaPump(profileID: String, prompt: String,
                                      choices: [String], timeoutSeconds: TimeInterval) -> Int? {
        attachLock.lock(); let gate = consentGates[profileID]; attachLock.unlock()
        return gate?.ask(prompt: prompt, choices: choices, timeout: timeoutSeconds)
    }

    private static func registerGate(_ gate: PumpConsentGate, for profileID: String) {
        attachLock.lock(); consentGates[profileID] = gate; attachLock.unlock()
    }
    private static func unregisterGate(_ gate: PumpConsentGate, for profileID: String) {
        attachLock.lock()
        if consentGates[profileID] === gate { consentGates[profileID] = nil }
        attachLock.unlock()
        // Detached while a prompt was outstanding → wake the blocked broker now
        // (deny) instead of letting it wait out the full timeout. The gate is
        // discarded after this, so the signal can't affect a future prompt.
        gate.deliver(nil)
    }

    /// Hand-off between a broker (any thread) and the pump that owns the user's
    /// terminal: the broker sets a prompt and blocks on `ask`; the pump claims it
    /// via `takePending`, renders it, and `deliver`s the chosen index.
    final class PumpConsentGate {
        private let lock = NSLock()
        private var prompt: String?
        private var choices: [String] = []
        private var promptTimeout: TimeInterval = 120
        private var answerIdx: Int?
        private let answered = DispatchSemaphore(value: 0)

        func ask(prompt: String, choices: [String], timeout: TimeInterval) -> Int? {
            lock.lock()
            self.prompt = prompt; self.choices = choices
            self.promptTimeout = timeout; self.answerIdx = nil
            lock.unlock()
            // Wait a little past the in-terminal read so the pump delivers first.
            let r = answered.wait(timeout: .now() + timeout + 10)
            lock.lock(); defer { lock.unlock() }
            self.prompt = nil; self.choices = []
            return r == .timedOut ? nil : answerIdx
        }
        /// Pump side: claim a pending prompt to render (once).
        func takePending() -> (String, [String], TimeInterval)? {
            lock.lock(); defer { lock.unlock() }
            guard let p = prompt else { return nil }
            prompt = nil
            return (p, choices, promptTimeout)
        }
        /// Pump side: hand the chosen index (or nil) back to the waiting broker.
        func deliver(_ idx: Int?) {
            lock.lock(); answerIdx = idx; lock.unlock()
            answered.signal()
        }
    }

    /// Render a consent prompt on the user's terminal `clientFD` (host side; the
    /// guest never sees it) and read a single-digit choice. The interactive attach
    /// is a framed pty protocol ([type:u8][len:u32-BE][payload]; type 0=data,
    /// 1=resize, 2=exit, 3=stdin-EOF), so we MUST frame our output (type-0) and
    /// decode the client's framed keystrokes — raw bytes wouldn't render. Clears
    /// in place (no nested alt screen); the caller forces a `tmux refresh-client`
    /// repaint afterward. Returns the 0-based index, or nil (Enter/timeout/EOF →
    /// deny).
    private static func presentConsent(clientFD a: Int32, prompt: String,
                                       choices: [String], timeout: TimeInterval) -> Int? {
        var s = "\u{1b}[2J\u{1b}[H"                                 // clear, home
        s += "\u{1b}[1;33m🔒 Bromure — approval required\u{1b}[0m\r\n\r\n"
        s += prompt.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n"
        for (i, c) in choices.enumerated() { s += "  \u{1b}[1m\(i + 1)\u{1b}[0m) \(c)\r\n" }
        s += "\r\nChoice [1-\(choices.count)]  (Enter or timeout = deny): "
        writeFrame(a, 0, Array(s.utf8))

        let deadline = Date().addingTimeInterval(timeout)
        var inbuf = [UInt8](); inbuf.reserveCapacity(256)
        var buf = [UInt8](repeating: 0, count: 1024)
        var choice: Int? = nil
        readLoop: while true {
            let remMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            if remMs == 0 { break }
            var fds = [pollfd(fd: a, events: Int16(POLLIN), revents: 0)]
            let n = poll(&fds, 1, remMs)
            if n <= 0 { break }                                     // timeout / error → deny
            let r = Darwin.read(a, &buf, buf.count)
            if r <= 0 { break }                                     // client closed → deny
            inbuf.append(contentsOf: buf[0..<r])
            while inbuf.count >= 5 {
                let ftype = inbuf[0]
                let flen = (Int(inbuf[1]) << 24) | (Int(inbuf[2]) << 16)
                         | (Int(inbuf[3]) << 8) | Int(inbuf[4])
                if inbuf.count < 5 + flen { break }                 // partial frame; wait for more
                let payload = Array(inbuf[5 ..< 5 + flen])
                inbuf.removeFirst(5 + flen)
                if ftype == 3 { break readLoop }                    // stdin EOF → deny
                guard ftype == 0 else { continue }                  // ignore resize (1) etc.
                for ch in payload {
                    if ch == 0x0d || ch == 0x0a { break readLoop }  // Enter → deny
                    if ch >= 0x31, ch <= 0x39 {                     // '1'..'9'
                        let d = Int(ch - 0x30)
                        if d >= 1, d <= choices.count { choice = d - 1; break readLoop }
                    }
                }
            }
        }
        writeFrame(a, 0, Array("\u{1b}[2J\u{1b}[H".utf8))           // clear; caller repaints tmux next
        return choice
    }

    /// Write one pty-protocol frame ([type:u8][len:u32-BE][payload]) to `fd`.
    private static func writeFrame(_ fd: Int32, _ type: UInt8, _ payload: [UInt8]) {
        var out: [UInt8] = [type,
            UInt8((UInt32(payload.count) >> 24) & 0xff), UInt8((UInt32(payload.count) >> 16) & 0xff),
            UInt8((UInt32(payload.count) >> 8) & 0xff),  UInt8(UInt32(payload.count) & 0xff)]
        out.append(contentsOf: payload)
        _ = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, out.count) }
    }

    /// Interactive pty session: dequeue a guest shell connection, tell the
    /// guest to go interactive, then pump raw bytes between the CLI's socket and
    /// the guest vsock until either side closes. The pty framing is end-to-end
    /// (CLI <-> guest); this layer is a transparent byte pump.
    private func handleInteractiveExec(clientFD: Int32, profileID: String, bodyJSON: [String: Any]) {
        let command = bodyJSON["command"] as? String ?? ""
        let cols = bodyJSON["cols"] as? Int ?? 80
        let rows = bodyJSON["rows"] as? Int ?? 24

        var shellConn: ACShellProxyConnection?
        for _ in 0..<100 {
            shellConn = DispatchQueue.main.sync { self.onGetShellConnection?(profileID) }
            if shellConn != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let conn = shellConn else {
            sendResponse(fd: clientFD, status: 502, body: [
                "error": "No shell connection for '\(profileID)' after 10s — the VM may not be running or its shell agent hasn't come up yet.",
            ])
            return
        }
        let vsockFD = conn.fd

        // Tell the guest to start an interactive pty: [u32be len][JSON].
        // `view`/`window` (host terminal views) pass through verbatim — the
        // guest agent turns them into a grouped tmux-session attach.
        var req: [String: Any] = ["cmd": command, "interactive": true, "cols": cols, "rows": rows]
        if let view = bodyJSON["view"] as? String { req["view"] = view }
        if let window = bodyJSON["window"] as? Int { req["window"] = window }
        guard let reqData = try? JSONSerialization.data(withJSONObject: req) else {
            sendResponse(fd: clientFD, status: 500, body: ["error": "Failed to encode request"])
            return
        }
        var lenBE = UInt32(reqData.count).bigEndian
        let framed = Data(bytes: &lenBE, count: 4) + reqData
        _ = framed.withUnsafeBytes { Darwin.write(vsockFD, $0.baseAddress, framed.count) }

        // Switch the client to raw streaming, then become a transparent pump.
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        let hbytes = Array(header.utf8)
        _ = hbytes.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, hbytes.count) }

        // GUI-fronted attaches (the app's own native terminal, or a fat-client
        // mirror terminal) present MITM consent as a native NSAlert — locally, or
        // routed to the fat client — never in this terminal. They register NO
        // tmux consent gate, so `RemoteConsent.route` sees "not interactively
        // attached" and picks the NSAlert/fat-client path. A plain SSH/CLI attach
        // (no flag) registers a gate so a headless user can approve on their
        // terminal, where consent prompts go to a tmux popup instead of an
        // NSAlert nobody would see.
        let guiConsent = bodyJSON["guiConsent"] as? Bool ?? false
        let gateNote = guiConsent ? "no tmux gate (NSAlert/fat-client)" : "tmux consent gate"
        FileHandle.standardError.write(Data(
            "[consent] interactive attach pid=\(profileID.prefix(8)) guiConsent=\(guiConsent) → \(gateNote)\n".utf8))
        if guiConsent {
            Self.pump(clientFD, vsockFD)   // plain transparent pump, no consent gate
        } else {
            // Key by the canonical UUID (the CLI may pass a name/short id) so the
            // consent broker, which queries by UUID, actually matches.
            let attachKey = (DispatchQueue.main.sync { self.onResolveProfileID?(profileID) }) ?? profileID
            // Register a consent gate for the life of this attach: a gate firing
            // for this profile renders its prompt on THIS user's terminal
            // (clientFD), never in the guest, so a compromised guest can't forge
            // approval.
            let gate = PumpConsentGate()
            Self.registerGate(gate, for: attachKey)
            defer { Self.unregisterGate(gate, for: attachKey) }
            Self.pump(clientFD, vsockFD, gate: gate, afterConsent: { [weak self] in
                // Repaint the guest's tmux over where the prompt was — a tmux
                // command, not pane input, so we never inject keystrokes into
                // the agent.
                _ = self?.vmExec(profileID: attachKey,
                                 command: "tmux refresh-client 2>/dev/null || true", timeoutSeconds: 5)
            })
        }
        _ = conn.conn   // keep the vsock connection alive for the whole pump
        Darwin.close(clientFD)
    }

    /// Bidirectional raw byte pump between two fds until either closes.
    private static func pump(_ a: Int32, _ b: Int32, gate: PumpConsentGate? = nil,
                             afterConsent: (() -> Void)? = nil) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let bad = Int16(POLLHUP | POLLERR | POLLNVAL)
        while true {
            // Host-side consent: if a gate fired for this session, render its
            // prompt on the user's side (a) and read the answer here — the guest
            // (b) never sees it, so a compromised guest can't forge consent.
            if let g = gate, let (prompt, choices, t) = g.takePending() {
                g.deliver(presentConsent(clientFD: a, prompt: prompt, choices: choices, timeout: t))
                afterConsent?()   // repaint the guest's tmux over where the prompt was
            }
            var fds = [pollfd(fd: a, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: b, events: Int16(POLLIN), revents: 0)]
            let n = poll(&fds, 2, gate == nil ? -1 : 200)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { continue }
            if fds[0].revents & Int16(POLLIN) != 0 {
                let r = Darwin.read(a, &buf, buf.count)
                if r <= 0 { break }
                if !writeAll(b, buf, r) { break }
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let r = Darwin.read(b, &buf, buf.count)
                if r <= 0 { break }
                if !writeAll(a, buf, r) { break }
            }
            if (fds[0].revents & bad) != 0 && (fds[0].revents & Int16(POLLIN)) == 0 { break }
            if (fds[1].revents & bad) != 0 && (fds[1].revents & Int16(POLLIN)) == 0 { break }
        }
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8], _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let w = buf.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: off), count - off)
            }
            if w <= 0 { return false }
            off += w
        }
        return true
    }

    // MARK: - Shell-agent protocol

    /// Wire format: [u32be len][JSON {"cmd": "...", "timeout": N}] →
    ///              [u32be len][JSON {"stdout": "...", "stderr": "...", "exit_code": N}]
    /// How one exec attempt on a pooled connection ended. `deadConnection`
    /// means nothing was ever exchanged (write failed, or EOF before a single
    /// response byte) — the guest can't have run the command, so the caller may
    /// safely retry on another connection. `protocolFailure` is a mid-stream
    /// error — the command may have executed, so don't retry.
    enum ShellExecOutcome {
        case success(ACShellExecResult)
        case deadConnection
        case protocolFailure
    }

    /// Outcome of one framed JSON round-trip on a pooled shell-agent
    /// connection. Same retry semantics as ShellExecOutcome: `deadConnection`
    /// = nothing was exchanged, safe to retry on another connection.
    enum JSONExchangeOutcome {
        case success([String: Any])
        case deadConnection
        case protocolFailure
    }

    /// Internal (not private): the file-explorer pane's guest exec reuses this
    /// exact framed exchange via `ACAppDelegate.guestExec`.
    static func executeShellCommand(fd: Int32, command: String, timeout: Int) -> ShellExecOutcome {
        switch exchangeJSON(fd: fd, request: ["cmd": command, "timeout": timeout]) {
        case .deadConnection: return .deadConnection
        case .protocolFailure: return .protocolFailure
        case .success(let obj):
            return .success(ACShellExecResult(
                stdout: obj["stdout"] as? String ?? "",
                stderr: obj["stderr"] as? String ?? "",
                exitCode: obj["exit_code"] as? Int ?? -1
            ))
        }
    }

    /// One length-prefixed JSON request/response on the shell channel.
    /// Factored out of `executeShellCommand` so the file-service ops
    /// (`{"file": {...}}`, the file browser's data plane) share the wire
    /// code without pretending to be shell commands.
    static func exchangeJSON(fd: Int32, request: [String: Any]) -> JSONExchangeOutcome {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: request) else {
            return .protocolFailure
        }
        var lenBE = UInt32(bodyData.count).bigEndian
        let lenData = Data(bytes: &lenBE, count: 4)
        let payload = lenData + bodyData

        let bytesWritten = payload.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.write(fd, base, payload.count)
        }
        guard bytesWritten == payload.count else { return .deadConnection }

        // Read length prefix. EOF before the FIRST byte = the peer was already
        // gone (stale pool entry from a previous guest boot) → retryable.
        var lenBuf = [UInt8](repeating: 0, count: 4)
        var got = 0
        while got < 4 {
            let n = lenBuf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: got), 4 - got)
            }
            if n <= 0 { return got == 0 ? .deadConnection : .protocolFailure }
            got += n
        }
        let respLen = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16) | (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3])
        guard respLen < 50 * 1024 * 1024 else { return .protocolFailure }

        var bodyBuf = [UInt8](repeating: 0, count: Int(respLen))
        got = 0
        while got < Int(respLen) {
            let n = bodyBuf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: got), Int(respLen) - got)
            }
            if n <= 0 { return .protocolFailure }
            got += n
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bodyBuf)) as? [String: Any] else {
            return .protocolFailure
        }
        return .success(obj)
    }

    // MARK: - Response helpers

    private func sendResponse(fd: Int32, status: Int, body: [String: Any]) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let statusText = httpStatusText(status)
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        let headerData = Data(response.utf8)
        let payload = headerData + bodyData
        _ = payload.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.write(fd, base, payload.count)
        }
        Darwin.close(fd)
    }

    private func httpStatusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default:  return "OK"
        }
    }
}

// MARK: - DTOs

struct ACAutomationProfileInfo {
    let id: String
    let shortId: String
    let name: String
    let color: String
    let tool: String
    let authMode: String
    let mcpServerCount: Int
    /// Live lifecycle state: "off" | "suspended" | "booting" | "running".
    let state: String

    func toDict() -> [String: Any] {
        [
            "id": id,
            "shortId": shortId,
            "name": name,
            "color": color,
            "tool": tool,
            "authMode": authMode,
            "mcpServerCount": mcpServerCount,
            "state": state,
        ]
    }
}

struct ACAutomationSessionInfo {
    let profileID: String
    let profileName: String
    let windowID: Int
    let visible: Bool

    func toDict() -> [String: Any] {
        [
            "profileId": profileID,
            "profileName": profileName,
            "windowId": windowID,
            "visible": visible,
        ]
    }
}

struct ACShellProxyConnection {
    let fd: Int32
    /// Keep alive until response sent.
    let conn: Any
}

struct ACShellExecResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
}
