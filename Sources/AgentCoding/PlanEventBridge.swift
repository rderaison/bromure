import Foundation
import Virtualization

// MARK: - Plan-stream events (guest → host)

/// One decoded event from the plan-stream protocol (v1, NDJSON over vsock
/// port 5832). The guest planning driver pushes these as the agent works;
/// unlike the task-board MCP this is event-push, not request/response.
enum PlanEvent: Equatable {
    /// First line after every (re)connect — names the worktree branch this
    /// connection belongs to and which agent tool is driving.
    case hello(branch: String, tool: String)
    case state(String)
    /// A COMPLETED message (no deltas in v1), attributed to a role.
    case text(role: String, text: String)
    case thinking(String)
    case tool(name: String, summary: String)
    case toolResult(name: String, ok: Bool, summary: String)
    /// The agent asking the user — the questions payload has exactly the
    /// AskUserQuestion shape, so it reuses the transcript's question model
    /// (and therefore its rendering) instead of a parallel type.
    case question(qid: String, questions: [TranscriptQuestion])
    /// The question was resolved elsewhere (or cancelled) — drop the card.
    case questionResolved(qid: String)
    /// TERMINAL: session over.
    case result(ok: Bool, error: String?)
    /// TERMINAL: the driver or agent died.
    case fatal(String)

    /// Decode one NDJSON line. Tolerant by protocol contract: unknown
    /// events and malformed lines return nil (the host must survive a
    /// newer guest), and missing fields take safe defaults rather than
    /// failing the whole line.
    static func parse(line: Data) -> PlanEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let ev = obj["ev"] as? String else { return nil }
        switch ev {
        case "hello":
            return .hello(branch: obj["branch"] as? String ?? "",
                          tool: obj["tool"] as? String ?? "")
        case "state":
            return .state(obj["state"] as? String ?? "")
        case "text":
            return .text(role: obj["role"] as? String ?? "assistant",
                         text: obj["text"] as? String ?? "")
        case "thinking":
            return .thinking(obj["text"] as? String ?? "")
        case "tool":
            return .tool(name: obj["name"] as? String ?? "",
                         summary: obj["summary"] as? String ?? "")
        case "tool_result":
            return .toolResult(name: obj["name"] as? String ?? "",
                               ok: obj["ok"] as? Bool ?? true,
                               summary: obj["summary"] as? String ?? "")
        case "question":
            // The event object itself carries the "questions" array, which
            // is exactly what TranscriptQuestion.parse expects.
            return .question(qid: obj["qid"] as? String ?? "",
                             questions: TranscriptQuestion.parse(obj))
        case "question_resolved":
            return .questionResolved(qid: obj["qid"] as? String ?? "")
        case "result":
            // ok's default follows the error field: a result that lost its
            // ok flag but carries an error string is still a failure.
            let error = obj["error"] as? String
            return .result(ok: obj["ok"] as? Bool ?? (error == nil), error: error)
        case "fatal":
            return .fatal(obj["error"] as? String ?? "")
        default:
            return nil
        }
    }
}

// MARK: - Plan-stream commands (host → guest)

/// A command the host sends back on the plan stream. Encoded as
/// protocol-shape NDJSON — one JSON object per line.
enum PlanCommand {
    /// A new user turn.
    case user(String)
    /// Answers a "question" event. `labels` are the chosen option labels;
    /// `other` carries free-form text when the user typed their own answer.
    case answer(qid: String, answers: [(question: String, labels: [String], other: String?)])
    case interrupt
    /// Tear the session down; the driver replies with result then exits.
    case end

    /// One wire-ready NDJSON line, trailing newline included.
    func jsonLine() -> Data {
        let obj: [String: Any]
        switch self {
        case .user(let text):
            obj = ["cmd": "user", "text": text]
        case .answer(let qid, let answers):
            obj = ["cmd": "answer", "qid": qid,
                   "answers": answers.map { a -> [String: Any] in
                       ["question": a.question,
                        "labels": a.labels,
                        // Explicit null, not an absent key — the wire shape
                        // in the frozen protocol shows "other":null.
                        "other": (a.other as Any?) ?? NSNull()]
                   }]
        case .interrupt:
            obj = ["cmd": "interrupt"]
        case .end:
            obj = ["cmd": "end"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        data.append(0x0A)
        return data
    }
}

// MARK: - Vsock bridge

/// Host-side vsock listener for the plan stream (port 5832) —
/// TaskMCPVsockBridge's structure, but event-push instead of RPC: the guest
/// driver dials in, announces its worktree branch with a hello event, then
/// streams NDJSON events; commands travel back on the same socket.
@MainActor
final class PlanEventBridge: NSObject {
    /// Must match the guest driver and SessionDisk.planStreamVsockPort —
    /// defined locally so this file doesn't depend on that constant's
    /// landing order.
    static let vsockPort: UInt32 = 5832

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: PlanEventListenerDelegate?
    /// Every live connection (bound or not), keyed by identity.
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// branch → the connection whose hello claimed it. A fresh hello for
    /// the same branch replaces the old connection — the driver reconnects
    /// after a socket drop and replays nothing, so the newest socket wins.
    private var bound: [String: Connection] = [:]

    /// Invoked on the main actor for every decoded event on a bound
    /// connection; the binding hello itself is forwarded too. Events that
    /// arrive before a hello have no branch to attribute them to and are
    /// dropped, as are events after a terminal result/fatal.
    var onEvent: ((_ branch: String, _ event: PlanEvent) -> Void)?

    /// A BOUND connection's socket closed without a terminal event — the
    /// driver died or the VM went away mid-session. The driver reconnects
    /// with a fresh hello within seconds when it's alive, so the consumer
    /// should apply a grace period before declaring the session dead
    /// (check `isBound` again after it).
    var onConnectionLost: ((_ branch: String) -> Void)?

    /// A live connection currently claims this branch.
    func isBound(branch: String) -> Bool { bound[branch] != nil }

    init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        super.init()
        let delegate = PlanEventListenerDelegate { [weak self] conn in self?.adopt(conn) }
        listenerDelegate = delegate
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
    }

    /// Write a command to the connection bound to `branch`; false when no
    /// live session claims that branch (the protocol only allows commands
    /// between hello and result/fatal).
    func send(branch: String, _ cmd: PlanCommand) -> Bool {
        guard let c = bound[branch] else { return false }
        return c.write(cmd.jsonLine())
    }

    func stop() {
        socketDevice?.removeSocketListener(forPort: Self.vsockPort)
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        bound.removeAll()
    }

    private func adopt(_ conn: VZVirtioSocketConnection) {
        let c = Connection(conn: conn,
                           onEvent: { [weak self] c, event in self?.handle(c, event) },
                           onClose: { [weak self] c in self?.closed(c) })
        connections[ObjectIdentifier(c)] = c
        c.start()
    }

    private func handle(_ c: Connection, _ event: PlanEvent) {
        if case .hello(let branch, _) = event {
            // A hello with no branch has nothing to bind to — tolerate it
            // by dropping, per the protocol's ignore-what-you-don't-know
            // rule, rather than poisoning the table with an empty key.
            guard !branch.isEmpty else { return }
            if let old = bound[branch], old !== c { old.cancel() }
            bound[branch] = c
            c.branch = branch
            onEvent?(branch, event)
            return
        }
        guard let branch = c.branch else { return }   // pre-hello chatter
        onEvent?(branch, event)
        // Terminal events end the session even before the socket closes:
        // unbinding here makes send() refuse further commands and drops any
        // trailing events, exactly as the protocol requires.
        switch event {
        case .result, .fatal: unbind(c)
        default: break
        }
    }

    private func unbind(_ c: Connection) {
        // Identity check: a stale connection closing must not evict the
        // fresh connection that replaced it for the same branch.
        if let branch = c.branch, bound[branch] === c {
            bound.removeValue(forKey: branch)
        }
        c.branch = nil
    }

    private func closed(_ c: Connection) {
        // A bound connection dying WITHOUT a terminal event is the "driver
        // crashed / VM died" signal — terminal events already unbound it in
        // handle(), and a stale replaced connection fails the identity check.
        let lostBranch: String? = {
            guard let b = c.branch, bound[b] === c else { return nil }
            return b
        }()
        unbind(c)
        connections.removeValue(forKey: ObjectIdentifier(c))
        if let b = lostBranch { onConnectionLost?(b) }
    }

    private final class Connection {
        private let conn: VZVirtioSocketConnection
        private let fd: Int32
        private let onEvent: (Connection, PlanEvent) -> Void
        private let onClose: (Connection) -> Void
        private var readSource: DispatchSourceRead?
        private var pending = Data()
        /// The worktree branch this connection's hello claimed; nil until
        /// the hello arrives, and cleared again on a terminal event or when
        /// a reconnect replaces this connection.
        var branch: String?

        init(conn: VZVirtioSocketConnection,
             onEvent: @escaping (Connection, PlanEvent) -> Void,
             onClose: @escaping (Connection) -> Void) {
            self.conn = conn
            self.fd = conn.fileDescriptor
            self.onEvent = onEvent
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
                let lineData = Data(pending[pending.startIndex..<nl])
                pending = Data(pending[(nl + 1)...])
                guard !lineData.isEmpty,
                      let event = PlanEvent.parse(line: lineData) else { continue }
                onEvent(self, event)
            }
        }

        /// Write one already-framed NDJSON line; true when fully written.
        func write(_ data: Data) -> Bool {
            guard fd >= 0 else { return false }
            var ok = true
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { ok = false; return }
                var off = 0, rem = raw.count
                while rem > 0 {
                    let w = Darwin.write(fd, base.advanced(by: off), rem)
                    if w <= 0 { ok = false; break }
                    off += w; rem -= w
                }
            }
            return ok
        }
    }
}

private final class PlanEventListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
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
