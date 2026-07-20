import Foundation
@preconcurrency import Virtualization

// The coding-board MCP exposed to in-VM task agents: read the task card,
// record the agreed plan on it, split follow-up work into subtask cards, and
// hand the task to review — typed tools instead of prose conventions.
// Transport is the browser MCP's exact pattern: the guest launches a stdio
// shim (bromure-task-mcp.py) that pipes line-delimited JSON-RPC over vsock
// (port 5831) to this host-side handler. The shim's first line after every
// (re)connect is "bromure-hello <branch>", which binds the connection to the
// task whose worktree branch that is.

@MainActor
final class TaskBoardMCPServer {
    private let profileID: Profile.ID
    private let store: () -> CodingTaskStore?
    private let engine: () -> CodingTaskEngine?

    init(profileID: Profile.ID,
         store: @escaping () -> CodingTaskStore?,
         engine: @escaping () -> CodingTaskEngine?) {
        self.profileID = profileID
        self.store = store
        self.engine = engine
    }

    // MARK: - JSON-RPC line handling

    /// Handle one request line for a connection bound to `branch`; returns
    /// the response line, or nil for notifications.
    func handle(line: String, branch: String?) async -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return respond(id: id, result: [
                "protocolVersion": "2025-03-26",
                "serverInfo": ["name": "bromure-board", "version": "1.0.0"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": Self.serverInstructions,
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return respond(id: id, result: [:])
        case "tools/list":
            return respond(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return respond(id: id, result: callTool(name: name, args: args, branch: branch))
        default:
            guard id != nil else { return nil }
            return respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    static let serverInstructions = """
    Tools for the Bromure coding board. This session IS a board task: \
    board_get_task returns your card (brief, review comments, plan); \
    board_set_plan records the agreed plan on the card; \
    board_create_subtasks files follow-up work as new backlog cards; \
    board_ready_for_review hands this task to the Testing/Review column — \
    call it as your last action once everything is committed.
    """

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "board_get_task",
            "description": "The coding-board card this session is working on: title, brief, stage, plan, and review comments.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "board_set_plan",
            "description": "Record the agreed implementation plan (markdown) on this task's card. Overwrites the previous plan.",
            "inputSchema": [
                "type": "object",
                "properties": ["plan": ["type": "string", "description": "The plan, markdown."]],
                "required": ["plan"],
            ],
        ],
        [
            "name": "board_create_subtasks",
            "description": "File follow-up work as ordered cards in the board's Plan column, linked to this task (same workspace and repository). Use for work that is out of scope for this session. Each may declare dependsOn: 1-based indices of earlier entries that must be DONE before it can start.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "subtasks": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"],
                                "details": ["type": "string", "description": "Markdown brief."],
                                "dependsOn": ["type": "array", "items": ["type": "integer"],
                                              "description": "1-based indices of earlier entries this one waits for."],
                            ],
                            "required": ["title"],
                        ],
                    ],
                ],
                "required": ["subtasks"],
            ],
        ],
        [
            "name": "board_ready_for_review",
            "description": "Hand this task to the Testing/Review column. Call ONLY after all work is committed to the branch.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
    ]

    /// The task this connection is working on: the branch's live task in
    /// this workspace (in progress or already in review for late calls).
    private func resolveTask(branch: String?) -> CodingTask? {
        guard let branch, branch.hasPrefix("wt/"), let store = store() else { return nil }
        let slugPart = String(branch.dropFirst(3))
        return store.tasks.first { t in
            guard t.profileID == profileID,
                  t.stage != .done,   // backlog included: planner sessions bind their parent
                  let slug = t.branchSlug else { return false }
            return slugPart == slug || (slugPart.hasPrefix(slug + "-")
                && Int(slugPart.dropFirst(slug.count + 1)) != nil)
        }
    }

    private func callTool(name: String, args: [String: Any],
                          branch: String?) -> [String: Any] {
        guard let store = store() else { return errorResult("board unavailable") }
        guard let task = resolveTask(branch: branch) else {
            return errorResult(
                "This session isn't bound to a board task (branch: \(branch ?? "none")).")
        }
        switch name {
        case "board_get_task":
            var doc: [String: Any] = [
                "title": task.title,
                "details": task.details,
                "stage": task.stage.rawValue,
                "branch": task.branch ?? branch ?? "",
            ]
            if let plan = task.plan { doc["plan"] = plan }
            if !task.comments.isEmpty {
                doc["reviewComments"] = task.comments.map { c -> [String: Any] in
                    var out: [String: Any] = ["text": c.text, "sent": c.sentAt != nil]
                    if let f = c.file { out["file"] = f }
                    return out
                }
            }
            return textResult(jsonString(doc))
        case "board_set_plan":
            guard let plan = args["plan"] as? String,
                  !plan.trimmingCharacters(in: .whitespaces).isEmpty else {
                return errorResult("plan (markdown) is required")
            }
            store.mutate(task.id) {
                $0.plan = plan
                // A planner session delivering output ends the card's
                // in-flight spinner.
                if $0.stage == .backlog { $0.validatedAt = Date() }
            }
            BACDebug.log("tasks", "“\(task.title)”: plan recorded via MCP")
            return textResult("Plan recorded on the card.")
        case "board_create_subtasks":
            guard let raw = args["subtasks"] as? [[String: Any]], !raw.isEmpty else {
                return errorResult("subtasks (non-empty array) is required")
            }
            guard raw.count <= 20 else { return errorResult("at most 20 subtasks per call") }
            var titles: [String] = []
            var ids: [UUID] = []
            let base = Date()
            for item in raw {
                guard let title = item["title"] as? String,
                      !title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let sub = CodingTask(
                    title: title,
                    details: item["details"] as? String ?? "",
                    profileID: task.profileID,
                    repoPath: task.repoPath,
                    tool: task.tool,
                    stage: .planning,
                    createdAt: base.addingTimeInterval(Double(ids.count) * 1.0),
                    parentTaskID: task.id)
                store.upsert(sub)
                titles.append(title)
                ids.append(sub.id)
            }
            // Second pass: dependsOn as 1-based indices into THIS call's array.
            for (i, item) in raw.enumerated() where i < ids.count {
                let deps = ((item["dependsOn"] as? [Int]) ?? []).compactMap { idx -> UUID? in
                    guard idx >= 1, idx <= ids.count, idx != i + 1 else { return nil }
                    return ids[idx - 1]
                }
                if !deps.isEmpty { store.mutate(ids[i]) { $0.dependsOn = deps } }
            }
            guard !titles.isEmpty else { return errorResult("no valid subtasks") }
            store.mutate(task.id) {
                if $0.stage == .backlog { $0.validatedAt = Date() }
            }
            BACDebug.log("tasks", "“\(task.title)”: \(titles.count) subtask(s) filed via MCP")
            return textResult("Filed \(titles.count) card(s) in the Plan column: "
                + titles.joined(separator: " · "))
        case "board_ready_for_review":
            guard task.stage == .inProgress || task.stage == .planning else {
                return textResult("Already in \(task.stage.rawValue).")
            }
            engine()?.handToReview(profileID: profileID, worktreeBranch: branch)
            let now = store.task(task.id)?.stage
            guard now == .testing else {
                return errorResult("could not move the task to review — is the branch still checked out?")
            }
            BACDebug.log("tasks", "“\(task.title)”: handed to review via MCP")
            return textResult("Task moved to Testing/Review. The user reviews the diff from here.")
        default:
            return errorResult("Unknown tool: \(name)")
        }
    }

    // MARK: - JSON helpers (BrowserMCPServer conventions)

    private func textResult(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }

    private func errorResult(_ msg: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true]
    }

    private func jsonString(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(
                withJSONObject: v, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "\(v)" }
        return s
    }

    private func respond(id: Any?, result: [String: Any]) -> String? {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func respondError(id: Any?, code: Int, message: String) -> String? {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id { msg["id"] = id } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}

// MARK: - Vsock bridge

/// Host-side vsock listener for the task-board MCP (port 5831) — the
/// browser bridge's pattern minus the fat-client splicing. Each connection
/// remembers the branch its shim announced with "bromure-hello <branch>".
@MainActor
final class TaskMCPVsockBridge: NSObject {
    static let vsockPort = SessionDisk.taskBoardMCPVsockPort

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: TaskMCPListenerDelegate?
    private let server: TaskBoardMCPServer
    private var connections: [ObjectIdentifier: Connection] = [:]

    init(socketDevice: VZVirtioSocketDevice, server: TaskBoardMCPServer) {
        self.socketDevice = socketDevice
        self.server = server
        super.init()
        let delegate = TaskMCPListenerDelegate { [weak self] conn in self?.adopt(conn) }
        listenerDelegate = delegate
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
    }

    func stop() {
        socketDevice?.removeSocketListener(forPort: Self.vsockPort)
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
    }

    private func adopt(_ conn: VZVirtioSocketConnection) {
        let c = Connection(conn: conn, server: server) { [weak self] c in
            self?.connections.removeValue(forKey: ObjectIdentifier(c))
        }
        connections[ObjectIdentifier(c)] = c
        c.start()
    }

    private final class Connection {
        private let conn: VZVirtioSocketConnection
        private let fd: Int32
        private let server: TaskBoardMCPServer
        private let onClose: (Connection) -> Void
        private var readSource: DispatchSourceRead?
        private var pending = Data()
        /// The worktree branch the shim announced — binds tool calls to a task.
        private var branch: String?

        init(conn: VZVirtioSocketConnection, server: TaskBoardMCPServer,
             onClose: @escaping (Connection) -> Void) {
            self.conn = conn
            self.fd = conn.fileDescriptor
            self.server = server
            self.onClose = onClose
        }

        func start() {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            readSource = src
            src.setEventHandler { [weak self] in self?.readAvailable() }
            src.setCancelHandler { [weak self] in
                guard let self else { return }
                self.conn.close()
                self.onClose(self)
            }
            src.activate()
        }

        func cancel() { readSource?.cancel(); readSource = nil }

        private func readAvailable() {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { cancel(); return }
            pending.append(contentsOf: buf[0..<n])
            if pending.count > 4 * 1024 * 1024 { cancel(); return }   // pathological
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                guard !lineData.isEmpty,
                      let line = String(data: Data(lineData), encoding: .utf8) else { continue }
                if line.hasPrefix("bromure-hello ") {
                    branch = String(line.dropFirst("bromure-hello ".count))
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                let bound = branch
                MainActor.assumeIsolated {
                    Task { [weak self] in
                        guard let self else { return }
                        if let resp = await self.server.handle(line: line, branch: bound) {
                            self.writeLine(resp)
                        }
                    }
                }
            }
        }

        private func writeLine(_ s: String) {
            guard fd >= 0 else { return }
            var data = Data(s.utf8); data.append(0x0A)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var off = 0, rem = raw.count
                while rem > 0 {
                    let w = Darwin.write(fd, base.advanced(by: off), rem)
                    if w <= 0 { break }
                    off += w; rem -= w
                }
            }
        }
    }
}

private final class TaskMCPListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void
    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }
    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        DispatchQueue.main.async { self.onConnection(connection) }
        return true
    }
}
