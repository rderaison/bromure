import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Beautified live session (the "looks like Claude Code / Codex desktop" mode)
//
// An optional per-pane view mode that replaces the raw ghostty terminal with a
// native chat-style transcript of the agent running in that tab — reusing the
// same `TranscriptItemView` renderer the plan/run/task windows use — plus a
// composer that types the user's prompt straight into the agent.
//
// The terminal keeps running behind this (both are views of the same tmux
// window), so flipping between the two modes is safe and lossless. Data flows
// through the existing poll-by-exec machinery: the transcript is the agent's
// on-disk JSONL tailed via `guestExec`, and the composer injects keystrokes via
// `CodingTaskEngine.typeCommand` (the same path the fat client and automation
// use). No new guest agent is required.

/// Supplies a beautified session with its live data + input sink. Two concrete
/// providers exist: the local pane (`LocalTranscriptProvider`, runs guest
/// commands over vsock) and the fat client (`RemoteTranscriptProvider`, runs
/// them on the mirrored remote workspace over the tunnel). Keeping the model
/// provider-driven is what lets the exact same view + composer serve both.
@MainActor
protocol BeautifiedTranscriptProvider: AnyObject {
    var accent: Color { get }
    /// The active tmux window index (send-keys target), or nil if not ready.
    func activeTabIndex() -> Int?
    /// Run a guest command in the workspace, returning stdout (nil on failure).
    func execGuest(_ command: String, timeout: Int) async -> String?
    /// Whether the agent is currently working. Cross-agent: bromure already
    /// computes this per tab — Claude via its per-window hooks, every other
    /// agent via MITM request activity — so it drives the "thinking" cue for
    /// all supported agents uniformly.
    func isWorking() -> Bool
    /// Run one native file op (`{op,path,data,…}`) in the workspace guest — the
    /// file-browser data plane. Payloads ride base64 inside JSON (no shell), so
    /// unlike `execGuest` they aren't bound by the kernel's 128 KB per-argv
    /// cap — which a single filled base64 chunk would blow past. nil on failure.
    /// Used to stage dropped files (local: vsock; fat client: the tunnel).
    func guestFileOp(_ op: [String: Any]) async -> [String: Any]?
}

extension BeautifiedTranscriptProvider {
    /// The active tab's transcript as raw JSONL bytes. Resolves the tab's cwd
    /// AND a session floor in one guest round-trip, then tails the newest store.
    ///
    /// The floor (`since`) is when the tab's FOREGROUND process started: a
    /// freshly-launched `claude` (or any agent) is a new process, so its start
    /// time excludes the PREVIOUS session's transcript file — otherwise running
    /// `claude` (not `--resume`) showed the prior conversation until the new one
    /// wrote its first turn. Cross-agent (pure process timing). Falls back to 0
    /// (newest overall) if the foreground process can't be determined.
    ///
    /// EXCEPTION — a RESUMED session (`--resume`/`--continue`/`resume`): the
    /// agent reattaches an existing transcript whose file predates this process,
    /// so the process-start floor would hide it until the next turn bumps its
    /// mtime. When the foreground command line looks like a resume, drop the
    /// floor to 0 so the reattached transcript shows immediately.
    func fetchTranscript() async -> Data? {
        guard let idx = activeTabIndex() else { return nil }
        let meta = await execGuest(
            "i=\(idx); "
            + "cwd=$(tmux display-message -p -t bromure:$i '#{pane_current_path}' 2>/dev/null); "
            + "tty=$(tmux display-message -p -t bromure:$i '#{pane_tty}' 2>/dev/null); "
            + "pid=$(ps -t \"${tty#/dev/}\" -o pid=,stat= 2>/dev/null | awk '$2 ~ /\\+/ {print $1; exit}'); "
            + "et=$(ps -o etimes= -p \"$pid\" 2>/dev/null | tr -d ' '); "
            + "if [ -n \"$et\" ]; then s=$(( $(date +%s) - et )); else s=0; fi; "
            // Resuming reattaches an older transcript → don't floor it out. Match
            // only the long flags: the args string also contains the (free-text)
            // prompt, so short flags / bare words like `-c` or `resume` there
            // would false-positive and resurrect a stale session on a FRESH run.
            + "a=$(ps -ww -o args= -p \"$pid\" 2>/dev/null); "
            + "case \"$a\" in "
            + "*--resume*|*--continue*|*--restore*) s=0;; "
            + "esac; "
            + "printf '%s\\n%s\\n' \"$cwd\" \"$s\"",
            timeout: 8)
        let lines = (meta ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return nil }
        let cwd = lines[0].trimmingCharacters(in: .whitespaces)
        let since = Int(lines[1].trimmingCharacters(in: .whitespaces)) ?? 0
        guard !cwd.isEmpty,
              // agent: nil → probe every store, newest match wins + sniff.
              let cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: since, agent: nil),
              let out = await execGuest(cmd, timeout: 15)
        else { return nil }
        return Data(out.utf8)
    }

    /// Type `text` into the running agent (base64 → tmux send-keys + Enter).
    func send(_ text: String) async {
        guard let idx = activeTabIndex() else { return }
        _ = await execGuest(CodingTaskEngine.typeCommand(tabIndex: idx, text: text), timeout: 15)
    }

    /// The active tab's visible terminal — for detecting states the transcript
    /// never records: an auth/subscription error the agent prints (no turn is
    /// written, so the transcript can't tell a stuck "Thinking…" from a dead
    /// session), or a blocking TUI prompt (folder-trust, `/login`) the beautified
    /// view hides. Cross-agent (pure tmux).
    func captureScreen() async -> String? {
        guard let idx = activeTabIndex() else { return nil }
        // `-J` joins wrapped lines, so a soft-wrapped `/login` OAuth URL comes
        // back whole (it's one logical line the terminal split to fit the pane).
        return await execGuest("tmux capture-pane -p -J -t bromure:\(idx) 2>/dev/null", timeout: 8)
    }

    /// Press a sequence of tmux key names into the active tab (e.g. Down, Enter
    /// to pick "Yes, I trust this folder", or a digit to choose a login method).
    /// Named keys only, with a beat so the TUI's debounce doesn't swallow them.
    func pressKeys(_ keys: [String]) async {
        guard let idx = activeTabIndex(), !keys.isEmpty else { return }
        let cmd = keys.map { "tmux send-keys -t bromure:\(idx) \($0)" }
            .joined(separator: "; sleep 0.4; ")
        _ = await execGuest(cmd, timeout: 15)
    }

    /// Type a literal string then Enter into the active tab — for a raw TUI
    /// field like `/login`'s "Paste code here >", not the chat composer.
    func typeText(_ text: String) async {
        guard let idx = activeTabIndex() else { return }
        let quoted = "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        _ = await execGuest(
            "tmux send-keys -t bromure:\(idx) -l \(quoted); sleep 0.3; "
            + "tmux send-keys -t bromure:\(idx) Enter", timeout: 15)
    }

    /// Write dropped/attached files into the guest at deterministic paths and
    /// return the guest paths written (for the message text + thumbnails). Does
    /// NOT type anything — the model composes and sends the message. Local and
    /// fat client share this; only `guestFileOp` differs (vsock vs. tunnel).
    ///
    /// Uses the file-op write plane, NOT `execGuest` base64: a shell
    /// `printf %s '<b64>'` passes the chunk as one argv, and the guest runs the
    /// command as a single argv string — so a chunk over the kernel's 128 KB
    /// per-argv-string cap fails with E2BIG and the file never lands (the drop's
    /// path was referenced but the bytes were missing). File ops carry base64
    /// inside JSON, so they clear the cap and upload each file in a few large
    /// requests instead of many small exec round-trips over the tunnel.
    func stage(_ files: [DroppedFile]) async -> [String] {
        var paths: [String] = []
        // The write op opens the path directly (no mkdir), so ensure the
        // staging dir exists first; bail if we can't even create it.
        guard await guestFileOp(["op": "mkdir", "path": GuestDrop.baseDir]) != nil
        else { return paths }
        for (n, f) in files.enumerated() {
            let path = GuestDrop.path(index: n, name: f.name)
            var ok = true
            for op in GuestDrop.writeOps(guestPath: path, data: f.data) {
                if await guestFileOp(op) == nil { ok = false; break }
            }
            if ok { paths.append(path) }
        }
        return paths
    }
}

/// A file dragged onto the beautified window (host bytes + name + whether it's
/// an image, so the drop can show a thumbnail).
struct DroppedFile {
    let name: String
    let data: Data
    let isImage: Bool
}

/// Builds the guest-side commands to stage a dropped file and the message that
/// references it to the agent.
enum GuestDrop {
    /// Fixed staging dir. Absolute (no `$HOME` resolution needed), so the guest
    /// paths are deterministic on the host — which lets the drop echo them and
    /// render thumbnails against the same paths the real transcript will show.
    static let baseDir = "/tmp/bromure-drops"
    /// Raw bytes per file-op write request — base64 of a chunk stays under the
    /// guest's ~10 MB request cap. (A file-op payload rides base64 inside JSON,
    /// so unlike a shell `printf` it isn't bound by the kernel's 128 KB
    /// per-argv-string cap, which a single filled chunk would blow past.)
    private static let writeChunk = 6 * 1024 * 1024

    /// A safe path component: everything outside `[A-Za-z0-9._-]` (plus unicode
    /// letters/digits) becomes `_`, so the name carries no shell metacharacters
    /// or path separators. `/` is already mapped to `_` (no traversal possible),
    /// and any `..` is collapsed as well so a leaf can never be a parent ref —
    /// a dropped name like `../../etc/passwd` becomes a single inert filename.
    static func safeName(_ name: String) -> String {
        var safe = String(name.map { c in
            (c.isLetter || c.isNumber || c == "." || c == "-" || c == "_") ? c : "_"
        })
        while safe.contains("..") { safe = safe.replacingOccurrences(of: "..", with: "_") }
        return (safe.isEmpty || safe == ".") ? "file" : String(safe.prefix(120))
    }

    /// The deterministic absolute guest path for the drop at `index`. Index
    /// prefix avoids collisions when two files sanitize alike. `safeName`
    /// guarantees the leaf has no `/` or `..`, so the result is always a direct
    /// child of `baseDir` — no path traversal.
    static func path(index: Int, name: String) -> String {
        let leaf = "\(index)_\(safeName(name))"
        precondition(!leaf.contains("/") && !leaf.contains(".."), "unsafe drop leaf")
        return "\(baseDir)/\(leaf)"
    }

    /// The file-op sequence writing `data` to `guestPath`: a truncating first
    /// write (`append:false`) then appends, chunked so each request's base64
    /// clears the guest's request cap. Empty data yields one truncating write
    /// (creates an empty file). The parent dir is created once by `stage`.
    static func writeOps(guestPath: String, data: Data) -> [[String: Any]] {
        var ops: [[String: Any]] = []
        var offset = 0
        var first = true
        repeat {
            let end = min(offset + writeChunk, data.count)
            let piece = data.subdata(in: offset..<end)
            ops.append(["op": "write", "path": guestPath,
                        "data": piece.base64EncodedString(), "append": !first])
            offset = end
            first = false
        } while offset < data.count
        return ops
    }

}

/// Reconciles the raw `isWorking()` signal with a user interrupt. A plain Esc
/// doesn't reliably fire Claude's `Stop` hook, so after a Stop the hook-derived
/// `isWorking()` can stay stuck `true` — which would make the "Thinking…" cue
/// spring back the moment the poll re-applied it. Once interrupted, the gate
/// reports NOT working (whatever the raw signal says) until the agent finally
/// reports idle on its own, or the user sends a new message.
struct WorkingGate {
    private(set) var interrupted = false

    /// User hit Stop/Esc — suppress "working" until reality catches up.
    mutating func interrupt() { interrupted = true }
    /// User sent a new message — a fresh turn supersedes the stop.
    mutating func userSent() { interrupted = false }

    /// The effective working state for a raw `isWorking()` reading. While
    /// interrupted it stays `false`; the first idle reading releases the latch
    /// (reality agreed with the stop) so later turns show normally.
    mutating func effective(_ raw: Bool) -> Bool {
        if interrupted {
            if raw { return false }
            interrupted = false
        }
        return raw
    }
}

/// Drives one beautified view: polls its provider for the live transcript and
/// relays composer input. `@MainActor` — it only touches provider calls (main-
/// actor) and SwiftUI state.
@MainActor
final class BeautifiedSessionModel: ObservableObject {
    @Published var items: [TranscriptItem] = []
    @Published var composerText = ""
    @Published var sending = false
    /// True until the first transcript fetch resolves — drives the placeholder.
    @Published var loading = true
    /// Bumped on every transcript mutation (poll replace + optimistic append),
    /// so the view scrolls to the tail even when the last item mutates in place
    /// (assistant streaming) without changing the item count.
    @Published var revision = 0
    /// The agent is actively working — drives the "thinking" cue. Set
    /// optimistically the instant a prompt is sent, then reconciled each poll
    /// from the per-tab agent status (hooks for Claude, MITM for the rest).
    @Published var working = false
    /// A detected agent failure the transcript never recorded — most importantly
    /// an invalid subscription / auth error, which the agent prints to its
    /// terminal but writes no turn for, leaving the view stuck on "Thinking…".
    /// When set it replaces the cue with a failure card and forces `working`
    /// false; cleared when the transcript makes progress or the user sends again.
    @Published var failure: SessionFailure?
    /// A blocking TUI prompt the agent is showing in its terminal that the
    /// beautified view otherwise hides — a folder-trust dialog or a `/login`
    /// flow. Surfaced so the user isn't left staring at a silent view while the
    /// agent waits for a keypress they can't see (the reported desync).
    @Published var prompt: TerminalPrompt?
    /// When the current working spell began — drives the elapsed time on the
    /// cue, so a long turn reads as intentional and a hung one shows its age.
    @Published var workingSince: Date?

    /// Dropped image bytes keyed by their (deterministic) guest path, so the
    /// view can render a thumbnail wherever that path appears in the transcript
    /// — persisting across polls (the real user turn carries the same path).
    @Published var imagesByPath: [String: Data] = [:]

    var accent: Color { provider.accent }

    private let provider: BeautifiedTranscriptProvider
    private var pollTask: Task<Void, Never>?
    /// Ids for optimistic (locally-added) items — descend from Int.max so they
    /// never collide with the parser's ascending ids.
    private var nextOptimisticID = Int.max
    /// The parsed transcript (source of truth).
    private var parsedItems: [TranscriptItem] = []
    /// Consecutive polls that parsed to EMPTY while we already had a transcript.
    /// A populated transcript that suddenly reads empty is almost always a
    /// transient fetch glitch — the session-floor probe momentarily resolving a
    /// short-lived foreground child of the agent (flooring out the store), or a
    /// guest/tunnel hiccup (more common on the fat client) — not the
    /// conversation being cleared. Tolerate a few before believing it.
    private var emptyParseStreak = 0
    private static let maxEmptyParseStreak = 4   // ~6s at the 1.5s cadence
    /// Throttle for the terminal-state scan (capture-pane). It runs on its own
    /// cadence, independent of the transcript poll and of `isWorking` — a trust
    /// dialog and a `/login` menu both appear when the agent is NOT "working" and
    /// often before any transcript exists, so a working-gated scan misses them.
    private var lastScanAt = Date.distantPast
    private static let scanInterval: TimeInterval = 2
    /// Suppresses a stuck "working" after the user interrupts — a plain Esc
    /// doesn't reliably fire Claude's `Stop` hook, so `isWorking()` can stay true
    /// and the cue would spring back. See `WorkingGate`.
    private var gate = WorkingGate()
    /// Locally-echoed turns awaiting confirmation from the real transcript. Kept
    /// appended (so nothing flickers off) until the parse contains the same text
    /// — or they age out, in case the agent never records the turn.
    private struct Pending { let item: TranscriptItem; let added: Date }
    private var pending: [Pending] = []

    init(provider: BeautifiedTranscriptProvider) {
        self.provider = provider
    }

    private func rebuild() {
        let combined = parsedItems + pending.map(\.item)
        guard combined != items else { return }
        items = combined
        revision &+= 1
    }

    /// Echo a locally-authored turn instantly (kept until the poll confirms it).
    private func appendOptimistic(_ kind: TranscriptItem.Kind) {
        pending.append(Pending(item: TranscriptItem(id: nextOptimisticID, kind: kind, timestamp: nil),
                               added: Date()))
        nextOptimisticID -= 1
        rebuild()
    }

    /// Drop pending echoes the real transcript now contains (matched by text),
    /// or that have aged out (the agent never recorded them).
    private func reconcilePending() {
        pending.removeAll { p in
            if Date().timeIntervalSince(p.added) > 45 { return true }
            guard case .userText(let t) = p.item.kind else { return true }
            return parsedItems.contains {
                if case .userText(let rt) = $0.kind { return rt == t }
                return false
            }
        }
    }

    /// Begin polling the live transcript (~1.5s cadence, like the plan window).
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Set `working`, tracking when a working spell begins (for the elapsed
    /// timer). A pending failure or blocking prompt always wins — the cue must
    /// never show over a failure/prompt card, so the view can't hang on
    /// "Thinking…" while the agent is actually dead or waiting on a keypress.
    private func setWorking(_ w: Bool) {
        // The gate suppresses a stuck `isWorking()` after an interrupt, releasing
        // once the agent truly reports idle.
        let effective = gate.effective(w) && failure == nil && prompt == nil
        if effective {
            if workingSince == nil { workingSince = Date() }
        } else {
            workingSince = nil
        }
        working = effective
    }

    private func poll() async {
        let isWorking = provider.isWorking()
        // Terminal-state scan FIRST and unconditionally: a trust/login prompt (or
        // an auth error) can be on screen before any transcript store exists, so
        // it must not sit behind the transcript fetch's early return.
        await scanTerminal()
        guard let data = await provider.fetchTranscript() else { setWorking(isWorking); loading = false; return }
        loading = false
        let parsed = AgentTranscript.parse(data)
        // Don't blank a populated transcript on a transient empty read (see
        // `emptyParseStreak`) — that's the "beautified view goes all white" bug.
        // Keep the last good items until either real content returns or the
        // empties persist long enough to be a genuinely cleared session.
        if parsed.isEmpty, !parsedItems.isEmpty {
            emptyParseStreak += 1
            if emptyParseStreak < Self.maxEmptyParseStreak {
                setWorking(isWorking)
                return
            }
        }
        emptyParseStreak = 0
        if parsed != parsedItems {
            parsedItems = parsed
            // Real transcript progress ⇒ any earlier terminal card is stale.
            if failure != nil || prompt != nil {
                withAnimation(.easeOut(duration: 0.2)) { failure = nil; prompt = nil }
            }
        }
        reconcilePending()
        rebuild()
        setWorking(isWorking)
    }

    /// Sniff the tab's terminal for a state the transcript can't carry — a
    /// blocking prompt (folder-trust, `/login`) or an auth/quota/error banner —
    /// and reflect it into `prompt`/`failure`. Authoritative: it also CLEARS a
    /// card once the banner/prompt leaves the screen (e.g. the user answered it
    /// in the terminal). Throttled so the pane isn't captured every poll.
    private func scanTerminal() async {
        let now = Date()
        guard now.timeIntervalSince(lastScanAt) > Self.scanInterval else { return }
        lastScanAt = now
        guard let screen = await provider.captureScreen() else { return }
        let state = TerminalScan.classify(screen)
        // Only touch published state when it actually changes, so a steady error
        // banner doesn't re-fire the animation every scan.
        let newPrompt: TerminalPrompt? = { if case .prompt(let p) = state { return p } else { return nil } }()
        let newFailure: SessionFailure? = { if case .failure(let f) = state { return f } else { return nil } }()
        guard newPrompt != prompt || newFailure != failure else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            prompt = newPrompt
            failure = newFailure
        }
    }

    /// Answer Claude's folder-trust dialog inline (Down → "Yes, I trust this
    /// folder", Enter to confirm), so the user needn't hunt for the hidden
    /// terminal. Optimistically clears the card and marks the session working.
    func trustFolder() {
        guard let p = prompt, p.canAnswerTrust else { return }
        withAnimation(.easeOut(duration: 0.2)) { prompt = nil }
        setWorking(true)
        Task { [weak self] in
            await self?.provider.pressKeys(["Down", "Enter"])
            await self?.rescanSoon()
        }
    }

    /// `/login` → choose a sign-in method (sends the option's digit). The next
    /// scan surfaces the OAuth URL stage.
    func chooseLoginMethod(_ index: Int) {
        Task { [weak self] in
            await self?.provider.pressKeys(["\(index)", "Enter"])
            await self?.rescanSoon()
        }
    }

    /// Open the `/login` OAuth URL in the host browser — the user approves there,
    /// then pastes the code back into the card (`submitLoginCode`).
    func openLoginURL() {
        guard let s = prompt?.authURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Paste the verification code back into the agent's "Paste code here >"
    /// field, completing sign-in without ever touching the terminal.
    func submitLoginCode(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        setWorking(true)
        Task { [weak self] in
            await self?.provider.typeText(c)
            await self?.rescanSoon()
        }
    }

    /// Interrupt the running agent — send Esc to its pane, the interrupt key
    /// every supported TUI honours ("esc to interrupt"). Optimistically drops the
    /// cue for instant feedback; the next poll reconciles from real status.
    func interrupt() {
        gate.interrupt()
        // Force the cue off now; the next poll feeds the real `isWorking()` to
        // the gate, which keeps it suppressed until the agent reports idle.
        withAnimation(.easeOut(duration: 0.15)) { working = false; workingSince = nil }
        Task { [weak self] in
            await self?.provider.pressKeys(["Escape"])
            await self?.rescanSoon()
        }
    }

    /// Force the throttled terminal scan to run on the next poll (so a card
    /// updates promptly after we send it a keystroke), then poll.
    private func rescanSoon() async {
        lastScanAt = .distantPast
        await poll()
    }

    /// Files dropped on the window, pending as composer attachments (thumbnail
    /// chips) until the user hits Send — TUI parity: the drop attaches, Send
    /// transmits your text plus the staged paths as ONE message.
    @Published var pendingAttachments: [DroppedFile] = []
    /// Per-send batch counter — prefixes staged names so consecutive sends
    /// can't overwrite each other's files in the fixed staging dir.
    private var batchCounter = 0

    /// Drop handler: queue the files as pending attachments. Nothing is sent
    /// until the user hits Send.
    func drop(_ files: [DroppedFile]) {
        pendingAttachments.append(contentsOf: files)
    }

    func removeAttachment(at index: Int) {
        guard pendingAttachments.indices.contains(index) else { return }
        pendingAttachments.remove(at: index)
    }

    /// Send the composer text + any pending attachments as one message: the
    /// attachments are staged in the guest and their paths appended to the text
    /// (just the paths — the agent reads them, like the TUI). Host file paths
    /// pasted/dropped into the TextField are translated the same way.
    func send() {
        let raw = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = pendingAttachments
        guard !raw.isEmpty || !atts.isEmpty, !sending else { return }
        composerText = ""
        pendingAttachments = []
        failure = nil
        prompt = nil
        gate.userSent()                   // a fresh send supersedes any prior stop
        setWorking(true)
        sending = true

        // Deterministic guest paths for this batch (computed before staging so
        // the optimistic echo + thumbnails are instant and match what lands).
        batchCounter += 1
        let batch = batchCounter
        let prefixed = atts.map {
            DroppedFile(name: "b\(batch)_\($0.name)", data: $0.data, isImage: $0.isImage)
        }
        let attPaths = prefixed.enumerated().map { GuestDrop.path(index: $0.offset, name: $0.element.name) }
        for (i, f) in prefixed.enumerated() where f.isImage { imagesByPath[attPaths[i]] = f.data }

        Task { [weak self] in
            guard let self else { return }
            var text = await self.translateHostFiles(in: raw)
            if !attPaths.isEmpty {
                text = text.isEmpty ? attPaths.joined(separator: " ")
                                    : text + " " + attPaths.joined(separator: " ")
            }
            self.appendOptimistic(.userText(text))
            if !prefixed.isEmpty { _ = await self.provider.stage(prefixed) }
            await self.provider.send(text)
            self.sending = false
            await self.poll()
        }
    }

    /// Rewrite host file paths in `text` to guest paths, uploading each file.
    /// Returns `text` unchanged (fast, no I/O) when it names no host files.
    private func translateHostFiles(in text: String) async -> String {
        var tokens = Set(text.split(whereSeparator: { " \n\t".contains($0) }).map(String.init))
        tokens.insert(text)   // whole-string case: composer holds just the path
        var hits: [(token: String, file: DroppedFile)] = []
        for tok in tokens {
            guard let url = Self.hostFileURL(tok),
                  let data = try? Data(contentsOf: url), data.count <= 25 * 1024 * 1024 else { continue }
            let isImg = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            hits.append((tok, DroppedFile(name: url.lastPathComponent, data: data, isImage: isImg)))
        }
        guard !hits.isEmpty else { return text }
        let staged = await provider.stage(hits.map(\.file))
        guard staged.count == hits.count else { return text }
        var out = text
        for (i, h) in hits.enumerated() {
            out = out.replacingOccurrences(of: h.token, with: staged[i])
            if h.file.isImage { imagesByPath[staged[i]] = h.file.data }
        }
        return out
    }

    /// A readable host FILE for `token` (absolute path, `~`, or `file://`), or nil.
    private static func hostFileURL(_ token: String) -> URL? {
        var path = token
        if path.hasPrefix("file://"), let u = URL(string: path) { path = u.path }
        else if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        guard path.hasPrefix("/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Local provider: runs the transcript + type commands in the workspace VM over
/// vsock (`guestExec`), resolving the active tab's guest cwd (the transcript
/// store is keyed off it) and caching it per tmux window.
@MainActor
final class LocalTranscriptProvider: BeautifiedTranscriptProvider {
    let accent: Color
    private weak var pane: SessionPane?

    init(pane: SessionPane) {
        self.pane = pane
        self.accent = Color(hex: pane.profile.color.hexInUI)
    }

    func activeTabIndex() -> Int? {
        guard let pane, pane.model.tabs.indices.contains(pane.model.activeIndex)
        else { return nil }
        return pane.model.tabs[pane.model.activeIndex].index
    }

    func execGuest(_ command: String, timeout: Int) async -> String? {
        guard let pane, let delegate = pane.acDelegate else { return nil }
        return try? await delegate.guestExec(profileID: pane.profile.id, command: command, timeout: timeout)
    }

    func guestFileOp(_ op: [String: Any]) async -> [String: Any]? {
        guard let pane, let delegate = pane.acDelegate else { return nil }
        return try? await delegate.guestFileOp(profileID: pane.profile.id, op: op, timeout: 30)
    }

    func isWorking() -> Bool { pane?.model.activeTab?.agentStatus == .working }
}

/// The beautified pane: a live, auto-scrolling transcript of the agent + a
/// Codex-desktop-style composer. Mounted into the pane's container by
/// `SessionPane.updateNativeTerminalMount()` when the view mode is `.beautified`.
struct BeautifiedSessionView: View {
    @ObservedObject var model: BeautifiedSessionModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider().opacity(0.5)
            if !model.pendingAttachments.isEmpty {
                PendingAttachmentChips(files: model.pendingAttachments,
                                       onRemove: { model.removeAttachment(at: $0) })
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            ChatComposer(
                placeholder: NSLocalizedString("Message the agent…  (or drop files)", comment: "beautified composer"),
                text: $model.composerText,
                busy: model.sending,
                accent: model.accent,
                canSendEmpty: !model.pendingAttachments.isEmpty,
                working: model.working,
                onStop: { model.interrupt() },
                onSend: { model.send() })
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        // A chat surface, not a terminal: opaque so it never picks up the
        // window's terminal-translucency (which reads as a gray scrim here).
        .background(Color.platformTextBackground)
        // Drop images or text-based files anywhere in the window → staged in
        // the guest and handed to the agent (the same thing the TUI does).
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 30))
                        Text(NSLocalizedString("Drop to attach", comment: "drop hint"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.items.isEmpty && !model.working && model.failure == nil && model.prompt == nil {
            VStack(spacing: 10) {
                if model.loading {
                    ProgressView()
                    Text(NSLocalizedString("Loading transcript…", comment: "beautified"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(NSLocalizedString("No agent activity yet — send a message to begin.",
                                           comment: "beautified empty"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.items) { item in
                            itemRow(item)
                        }
                        if let prompt = model.prompt {
                            PromptCard(prompt: prompt,
                                       onTrust: { model.trustFolder() },
                                       onMethod: { model.chooseLoginMethod($0) },
                                       onOpenURL: { model.openLoginURL() },
                                       onSubmitCode: { model.submitLoginCode($0) })
                                .id("beautified-prompt")
                                .transition(.opacity)
                        } else if let failure = model.failure {
                            FailureCard(failure: failure)
                                .id("beautified-failure")
                                .transition(.opacity)
                        } else if model.working {
                            liveCue.id("beautified-thinking")
                        }
                        Color.clear.frame(height: 1).id(Self.tailID)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onChange(of: model.revision) { _, _ in scrollToTail(proxy) }
                .onChange(of: model.working) { _, _ in scrollToTail(proxy) }
                .onChange(of: model.failure) { _, _ in scrollToTail(proxy) }
                .onChange(of: model.prompt) { _, _ in scrollToTail(proxy) }
                .onAppear { proxy.scrollTo(Self.tailID, anchor: .bottom) }
            }
        }
    }

    /// The live-activity cue shown while the agent works: a blinking caret when
    /// the tail is streaming assistant prose (it reads as "still writing"), and
    /// the cycling "Thinking…" verb otherwise — so the two never show at once.
    @ViewBuilder
    private var liveCue: some View {
        if let last = model.items.last, case .assistantText = last.kind {
            StreamingCaret()
        } else {
            ThinkingRow(since: model.workingSince)
        }
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.tailID, anchor: .bottom)
        }
    }

    /// One transcript item plus, for a user turn that references dropped
    /// images, their thumbnails below it (persists after the poll, since the
    /// real user turn carries the same guest paths the drop echoed).
    @ViewBuilder
    private func itemRow(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TranscriptItemView(item: item)
            if case .userText(let text) = item.kind {
                let imgs = model.imagesByPath.compactMap { text.contains($0.key) ? $0.value : nil }
                if !imgs.isEmpty { AttachmentThumbnails(images: imgs) }
            }
        }
        .id(item.id)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var files: [DroppedFile] = []
            for p in providers {
                if let f = await Self.loadDropped(p) { files.append(f) }
            }
            if !files.isEmpty { model.drop(files) }
        }
        return true
    }

    /// Load one dragged item as bytes. Uses `loadObject(ofClass: URL.self)` —
    /// the same call the file browser's working drop uses — for Finder file
    /// drags (any type), and falls back to a raw image representation for images
    /// dragged from a browser/Preview (no backing file URL).
    private static func loadDropped(_ p: NSItemProvider) async -> DroppedFile? {
        let maxBytes = 25 * 1024 * 1024
        if p.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = p.loadObject(ofClass: URL.self) { u, _ in cont.resume(returning: u) }
            }
            guard let url, url.isFileURL,
                  let data = try? Data(contentsOf: url), data.count <= maxBytes else { return nil }
            let isImg = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            return DroppedFile(name: url.lastPathComponent, data: data, isImage: isImg)
        }
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data? = await withCheckedContinuation { cont in
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in
                    cont.resume(returning: d)
                }
            }
            guard let data, data.count <= maxBytes else { return nil }
            return DroppedFile(name: "pasted-image.png", data: data, isImage: true)
        }
        return nil
    }

    private static let tailID = "beautified-tail"
}

/// Pending-attachment chips above the composer: image thumbnails / file chips,
/// each removable. What Send transmits alongside the text.
private struct PendingAttachmentChips: View {
    let files: [DroppedFile]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files.indices, id: \.self) { i in
                    chip(files[i], index: i)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func chip(_ f: DroppedFile, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if f.isImage, let ns = NSImage(data: f.data) {
                    Image(nsImage: ns)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 84, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.text").font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text(f.name).font(.system(size: 9.5)).lineLimit(1)
                            .truncationMode(.middle).foregroundStyle(.secondary)
                            .frame(maxWidth: 76)
                    }
                    .frame(width: 84, height: 64)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15)))
            Button { onRemove(index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help(NSLocalizedString("Remove attachment", comment: "chip"))
        }
    }
}

/// Horizontal strip of dropped-image thumbnails shown under the user turn.
private struct AttachmentThumbnails: View {
    let images: [Data]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images.indices, id: \.self) { i in
                    if let ns = NSImage(data: images[i]) {
                        Image(nsImage: ns)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 128, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15)))
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// A blinking caret shown at the tail of streaming assistant prose — the "still
/// writing" cue, the beautified-view counterpart to a terminal cursor. Shown in
/// place of `ThinkingRow` while the last turn is assistant text being extended.
private struct StreamingCaret: View {
    @State private var lit = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 8, height: 16)
            .opacity(lit ? 0.9 : 0.12)
            .padding(.vertical, 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    lit = false
                }
            }
            .accessibilityHidden(true)
    }
}

/// The "agent is working" cue — a spinner with a gently cycling gerund, plus a
/// live elapsed readout once a turn runs long (so a genuinely-long turn reads as
/// intentional, and a hung one visibly ages). The beautified-view equivalent of
/// Claude Code's "Crafting… (12s)".
private struct ThinkingRow: View {
    /// When the working spell began, for the elapsed readout; nil hides it.
    var since: Date?

    private static let verbs = ["Thinking", "Working", "Crafting", "Pondering",
                                "Reasoning", "Cooking", "Churning", "Noodling",
                                "Brewing", "Simmering", "Percolating", "Ruminating",
                                "Mulling", "Synthesizing", "Conjuring", "Tinkering",
                                "Wrangling", "Untangling", "Deliberating", "Contemplating",
                                "Scheming", "Calculating", "Processing", "Weaving",
                                "Distilling", "Formulating", "Marinating", "Puzzling"]
    /// Seconds each verb shows before the next.
    private static let period: TimeInterval = 7.2

    var body: some View {
        // Tick every second (for the elapsed readout); the verb still advances
        // once per `period` via the slot math, so the two can't drift.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let slot = Int(context.date.timeIntervalSinceReferenceDate / Self.period)
            let verb = Self.verbs[((slot % Self.verbs.count) + Self.verbs.count) % Self.verbs.count]
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verb + "…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if let since {
                    let s = Int(context.date.timeIntervalSince(since))
                    if s >= 4 {
                        Text(Self.elapsed(s))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    private static func elapsed(_ s: Int) -> String {
        s < 60 ? "· \(s)s" : "· \(s / 60)m \(s % 60)s"
    }
}

/// A failure the agent surfaced to its terminal but never wrote to the
/// transcript — most importantly an invalid subscription / auth error, which
/// otherwise leaves the beautified view stuck on "Thinking…". Detected by
/// sniffing the tail of the tab's terminal for high-signal error banners.
struct SessionFailure: Equatable {
    enum Kind: Equatable { case auth, quota, generic }
    let kind: Kind
    /// A short human line lifted verbatim from the terminal (what the agent
    /// actually said), shown under the headline.
    let detail: String

    var headline: String {
        switch kind {
        case .auth:    return NSLocalizedString("The agent couldn't authenticate", comment: "failure")
        case .quota:   return NSLocalizedString("The agent hit a usage limit", comment: "failure")
        case .generic: return NSLocalizedString("The agent stopped with an error", comment: "failure")
        }
    }

    // High-signal banners, calibrated against every supported agent's real
    // wording (Claude prints "401 API key is invalid" — note the word order, the
    // reason the first cut missed it; Codex "Incorrect API key provided" /
    // "401 Unauthorized"; xAI/Grok, Kimi and omp echo their provider's message).
    // Deliberately phrase-specific — bare "error"/"401" are NOT triggers — and a
    // false positive self-heals the instant real transcript content returns.
    private static let authNeedles = [
        // invalid / missing key — both word orders, across CLIs
        "api key is invalid", "invalid api key", "invalid x-api-key", "incorrect api key",
        "api key not valid", "no api key", "didn't provide an api key", "missing api key",
        "invalid_api_key", "x-api-key header is invalid", "invalid access token",
        // authentication / authorization
        "authentication_error", "authentication error", "authentication failed",
        "invalid authentication", "401 unauthorized", "not authenticated",
        "invalid bearer token", "could not refresh token", "permission_error",
        // login / session / subscription
        "please run /login", "run `/login`", "please log in", "not logged in",
        "login expired", "session expired", "token has expired", "token expired",
        "oauth token", "sign in again", "re-authenticate",
        "subscription has expired", "subscription is invalid", "subscription expired",
    ]
    private static let quotaNeedles = [
        "credit balance is too low", "usage limit reached", "reached your usage limit",
        "you've reached your usage", "rate limit", "insufficient_quota",
        "quota exceeded", "exceeded your current quota", "overloaded_error",
        "session limit reached", "out of credits", "too many requests",
    ]

    static func detect(inScreen screen: String) -> SessionFailure? {
        detect(tail: terminalTail(screen))
    }

    /// Scan a pre-split terminal tail (shared with `TerminalScan`, which splits
    /// once). Bottom-up: the lowest matching line is the current state.
    static func detect(tail: [String]) -> SessionFailure? {
        func match(_ needles: [String]) -> String? {
            for raw in tail.reversed() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                let low = line.lowercased()
                if needles.contains(where: { low.contains($0) }) { return clean(line) }
            }
            return nil
        }
        if let d = match(quotaNeedles) { return SessionFailure(kind: .quota, detail: d) }
        if let d = match(authNeedles)  { return SessionFailure(kind: .auth,  detail: d) }
        return nil
    }

    /// Strip a TUI box/bullet gutter and clamp length so the line reads cleanly.
    private static func clean(_ line: String) -> String {
        let gutter = Set("│┃|>•*✗✘⎿⏺●─╮╯ ")
        let stripped = String(line.drop(while: { gutter.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        let s = stripped.isEmpty ? line : stripped
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }
}

/// The last N lines of a terminal snapshot — "now". Split once and shared by
/// both detectors (an old banner scrolled above this isn't the current state).
func terminalTail(_ screen: String, _ n: Int = 45) -> [String] {
    Array(screen.split(whereSeparator: \.isNewline).map(String.init).suffix(n))
}

/// One selectable method in the `/login` menu ("1. Claude account with…").
struct LoginOption: Equatable, Identifiable {
    let index: Int
    let label: String
    var id: Int { index }
}

/// A blocking TUI prompt the agent is showing that the beautified view hides —
/// a folder-trust dialog or a `/login` flow. The whole `/login` interaction is
/// reconstructed as native UI (method buttons → an "Open sign-in page" button →
/// a paste-the-code field), so the user never has to find the hidden terminal.
/// Claude's trust dialog is likewise answerable inline (its arrow list puts
/// "Yes, I trust this folder" one Down from the default "No, exit").
struct TerminalPrompt: Equatable {
    enum Kind: Equatable { case trust, login }
    let kind: Kind
    /// Trust: the folder path. (Login carries its state in the fields below.)
    var detail: String = ""
    /// Trust dialog we recognize well enough to answer with Down,Enter.
    var canAnswerTrust: Bool = false
    /// Login — the method menu (non-empty at the "Select login method" stage).
    var loginMethods: [LoginOption] = []
    /// Login — the OAuth sign-in URL, once the agent prints it.
    var authURL: String? = nil
    /// Login — the agent is waiting for the verification code ("Paste code here").
    var awaitingCode: Bool = false

    var headline: String {
        switch kind {
        case .trust: return NSLocalizedString("The agent is waiting for you to trust this folder", comment: "prompt")
        case .login: return NSLocalizedString("Sign in to Claude", comment: "prompt")
        }
    }

    private static let trustNeedles = [
        "trust the files in this", "do you trust", "trust this folder",
        "trust this directory", "trust this workspace", "is this a project you created",
        "yes, i trust this folder", "trust the authors of", "quick safety check",
    ]

    static func detect(inScreen screen: String) -> TerminalPrompt? { detect(tail: terminalTail(screen)) }

    static func detect(tail: [String]) -> TerminalPrompt? {
        let trimmed = tail.map { $0.trimmingCharacters(in: .whitespaces) }
        let low = trimmed.joined(separator: "\n").lowercased()

        // `/login` flow: the method menu, then the OAuth URL + code prompt.
        let looksLikeLogin = low.contains("select login method")
            || low.contains("browser didn't open")
            || low.contains("paste code here")
            || trimmed.contains { $0.contains("/oauth/authorize") }
        if looksLikeLogin {
            return TerminalPrompt(
                kind: .login,
                loginMethods: trimmed.compactMap(loginOption),
                authURL: trimmed.compactMap(authorizeURL).first,
                awaitingCode: low.contains("paste code here"))
        }

        // Folder-trust dialog.
        if trustNeedles.contains(where: { low.contains($0) }) {
            let folder = trimmed.first(where: { $0.hasPrefix("/") && !$0.contains(" ") })
                ?? NSLocalizedString("this folder", comment: "prompt")
            return TerminalPrompt(kind: .trust, detail: folder,
                                  canAnswerTrust: low.contains("yes, i trust this folder"))
        }
        return nil
    }

    /// "❯ 1. Claude account with subscription · Pro, Max…" → (1, "Claude account
    /// with subscription"). The part after " · " is a tagline we drop.
    private static func loginOption(_ line: String) -> LoginOption? {
        let s = line.drop(while: { $0 == "❯" || $0 == " " })
        guard let dot = s.firstIndex(of: "."),
              let n = Int(s[s.startIndex..<dot]), (1...9).contains(n) else { return nil }
        var label = s[s.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        if let sep = label.range(of: " · ") { label = String(label[..<sep.lowerBound]) }
        guard !label.isEmpty else { return nil }
        return LoginOption(index: n, label: label)
    }

    /// The OAuth authorize URL on a (tmux `-J`-joined) line — not the changelog
    /// link or the percent-encoded redirect_uri buried inside it.
    private static func authorizeURL(_ line: String) -> String? {
        guard let r = line.range(of: "https://") else { return nil }
        let url = String(line[r.lowerBound...])
            .split(whereSeparator: { $0 == " " }).first.map(String.init) ?? ""
        return url.contains("/oauth/authorize") ? url : nil
    }
}

/// The one terminal state the beautified view surfaces. A blocking prompt wins
/// over an error banner — it's what the agent is waiting on right now.
enum TerminalState: Equatable {
    case prompt(TerminalPrompt)
    case failure(SessionFailure)
}

/// Classifies a terminal snapshot, splitting the tail once for both detectors.
enum TerminalScan {
    static func classify(_ screen: String) -> TerminalState? {
        let tail = terminalTail(screen)
        if let p = TerminalPrompt.detect(tail: tail) { return .prompt(p) }
        if let f = SessionFailure.detect(tail: tail) { return .failure(f) }
        return nil
    }
}

/// The failure card shown in place of the cue — red-accented so a dead session
/// is unmistakable, carrying the terminal's own error line and a nudge back to
/// the terminal, where the fix (re-login, top up) actually happens.
private struct FailureCard: View {
    let failure: SessionFailure
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(failure.headline)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(failure.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(NSLocalizedString("Switch to the terminal to resolve it, then send again.",
                                       comment: "failure hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.red.opacity(0.3)))
    }
}

/// The prompt card shown when the agent is blocked on a hidden TUI dialog —
/// amber (a wait, not a failure). It reconstructs the interaction natively so
/// the user never touches the terminal: Claude's folder-trust dialog gets a
/// one-click "Trust & continue"; `/login` becomes method buttons → an "Open
/// sign-in page" button → a paste-the-code field.
private struct PromptCard: View {
    let prompt: TerminalPrompt
    var onTrust: () -> Void = {}
    var onMethod: (Int) -> Void = { _ in }
    var onOpenURL: () -> Void = {}
    var onSubmitCode: (String) -> Void = { _ in }

    @State private var code = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: prompt.kind == .login ? "person.badge.key.fill" : "hand.raised.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt.headline).font(.system(size: 12.5, weight: .semibold))
                switch prompt.kind {
                case .trust: trustBody
                case .login: loginBody
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.3)))
    }

    @ViewBuilder private var trustBody: some View {
        Text(prompt.detail)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        if prompt.canAnswerTrust {
            Button(action: onTrust) {
                Label(NSLocalizedString("Trust this folder & continue", comment: "prompt"),
                      systemImage: "checkmark.shield.fill")
            }
            .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
        } else {
            Text(NSLocalizedString(
                "Switch to the terminal view (the transcript toggle in the toolbar) to respond.",
                comment: "prompt hint"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var loginBody: some View {
        if !prompt.loginMethods.isEmpty {
            // Stage 1 — pick a sign-in method.
            Text(NSLocalizedString("How would you like to sign in?", comment: "login"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(prompt.loginMethods) { m in
                Button { onMethod(m.index) } label: {
                    HStack(spacing: 7) {
                        Text("\(m.index)").font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.orange).frame(width: 14)
                        Text(m.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else if prompt.authURL != nil {
            // Stage 2 — approve in the browser, paste the code back.
            Text(NSLocalizedString("Open the sign-in page, approve access, then paste the code back here.",
                                   comment: "login")).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(action: onOpenURL) {
                Label(NSLocalizedString("Open sign-in page", comment: "login"),
                      systemImage: "arrow.up.right.square.fill")
            }
            .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
            if prompt.awaitingCode {
                HStack(spacing: 6) {
                    TextField(NSLocalizedString("Paste code", comment: "login"), text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 280)
                        .onSubmit { submit() }
                    Button(NSLocalizedString("Submit", comment: "login")) { submit() }
                        .controlSize(.small)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 1)
            }
        } else {
            Text(NSLocalizedString("Starting sign-in…", comment: "login"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func submit() {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        onSubmitCode(c)
        code = ""
    }
}
