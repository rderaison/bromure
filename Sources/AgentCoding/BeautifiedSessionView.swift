import AppKit
import CryptoKit
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
            // The foreground process — but never the tab's SHELL: an agent
            // launched by the managed .bashrc shares bash's foreground group,
            // so bash reads as "+" too (and first, by pid). Its start time is
            // the tab's, not the agent's, and its args carry no resume flag —
            // a `--continue` relaunched in a fresh tab was floored out. Take
            // the first "+" process that isn't a shell; a shell only if
            // nothing else is in the foreground. Still the FIRST such process
            // (pid order), so a short-lived tool child of the agent doesn't
            // win either.
            + "pid=$(ps -t \"${tty#/dev/}\" -o pid=,stat=,args= 2>/dev/null | awk '"
            + "$2 ~ /\\+/ { if (first == \"\") first = $1; "
            + "if (!found && $3 !~ /(^|\\/)-?(bash|sh|zsh|dash|fish|login)$/) { print $1; found = 1 } } "
            + "END { if (!found) print first }'); "
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
              let cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: since, agent: nil,
                                                               pinnedWindow: idx),
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
    /// Inside the home image, so a drop outlives a reboot of the machine and a
    /// turn that references it can still be read back later.
    static let baseDir = "/home/ubuntu/.bromure/drops"
    /// Where drops landed before they moved into the home: still recognized
    /// in old turns (the files themselves are gone with the reboot).
    static let legacyBaseDir = "/tmp/bromure-drops"
    /// What a dropped file's name is prefixed with per send, so two sends of
    /// "photo.png" never share a path — the thumbnail of an old turn must not
    /// turn into the newest drop's picture.
    static func stamp(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: now) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp",
    ]
    /// The drop paths in a turn's text that name images, in order.
    static func imagePaths(in text: String) -> [String] {
        var out: [String] = []
        for tok in text.split(whereSeparator: { $0.isWhitespace }) {
            let path = String(tok)
            guard path.hasPrefix(baseDir + "/") || path.hasPrefix(legacyBaseDir + "/"),
                  imageExtensions.contains((path as NSString).pathExtension.lowercased()),
                  !out.contains(path) else { continue }
            out.append(path)
        }
        return out
    }
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

/// The pictures this Mac uploaded, kept by their guest path, so a turn
/// that references one shows its thumbnail after a remount or a relaunch.
/// The record of record: the machine's copy is never read back (the agent
/// may have changed it), and a turn sent from elsewhere shows none. Paths
/// carry a per-send stamp, so a path names one picture for good.
enum DropImageStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BromureAC/drop-images", isDirectory: true)
    }()

    private static func file(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(digest)
    }

    static func load(_ path: String) -> Data? { try? Data(contentsOf: file(for: path)) }

    static func store(_ data: Data, for path: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file(for: path), options: .atomic)
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
    /// Filled by a send, else from this Mac's record of what it uploaded
    /// (`ensureDropImages`); never read back from the machine, whose copy
    /// the agent may have changed.
    @Published var imagesByPath: [String: Data] = [:]

    /// The delegations this session is part of — the panel above the
    /// composer. nil where the window keeps no such records (a bare tab).
    var delegationStore: DelegationStore?
    var sessionStore: AgentSessionStore?
    /// The session this chat is, as of now (a tab binds to its record a
    /// beat after launch).
    var currentSession: (() -> AgentSession?)?
    /// Put another session on stage (the other end of a delegation).
    var openSession: ((UUID) -> Void)?
    /// The user answers a delegate's question on the agent's behalf:
    /// (delegation, ask, text). nil = read-only (a mirror).
    var answerDelegation: ((UUID, UUID, String) -> Void)?
    /// A workspace's name, for the panel (a delegate elsewhere).
    var workspaceName: ((UUID) -> String)?
    /// The sessions the composer's "@" palette can complete to — the
    /// nicknamed ones as they are, the rest with the name they'd get.
    var peerMentions: (() -> [PeerMention])?
    /// Give a session the nickname the palette proposed, as it's picked.
    var assignNickname: ((UUID, String) -> Void)?
    /// Requests this session made to sessions on other hosts (their records
    /// live there), with the host's name, for the panel.
    var remoteDelegations: (() -> [(Delegation, String)])?

    var accent: Color { provider.accent }

    /// The agent's slash commands for the "/" palette: built-ins at once,
    /// the user's own (custom commands, skills) once read from the guest.
    @Published var slashCommands: [SlashCommand] = []
    @Published var agentDisplayName: String = ""
    /// Every transcript read is handed here too (the session's local copy,
    /// readable once the machine sleeps).
    var transcriptSink: ((Data) -> Void)?

    /// The agent kind behind this tab ("claude", "codex", …), from the slash
    /// command load — decides which account a sign-in card offers.
    @Published var agentKind: String?
    /// A sign-in the host runs for this tab (a throwaway machine does the
    /// OAuth; the credential stays on the host): the pane wires it, the card
    /// shows its events. nil when this window can't offer it.
    var hostSignIn: ((SubscriptionProvider, @escaping (HostSignInEvent) -> Void) -> Void)?
    /// After a successful host sign-in: push the stand-in key into the
    /// workspace and start the agent again on it.
    var relaunchAfterSignIn: (() -> Void)?
    /// Agents with no account to sign into (Oh My Pi): where a model
    /// provider is added.
    var openProviderSettings: (() -> Void)?
    /// The tab shows (or stopped showing) a sign-in screen — the sidebar
    /// reflects it.
    var loginPromptChanged: ((Bool) -> Void)?
    /// What the host sign-in is doing right now, for the card. nil = idle.
    @Published var hostSignInStatus: String?
    /// Why the last host sign-in didn't land, shown in the card under the
    /// button until the next attempt.
    @Published var hostSignInError: String?

    /// "Claude", "ChatGPT", "Grok", "Kimi" — the account, not the tool.
    var signInAccountName: String {
        signInProvider?.displayName ?? (agentDisplayName.isEmpty ? "Claude" : agentDisplayName)
    }

    var signInProvider: SubscriptionProvider? {
        agentKind.flatMap { SubscriptionProvider(rawValue: $0) }
    }

    /// The card's "Sign in…": run the account sign-in on the host and, once
    /// the credential is stored, restart the agent on the stand-in key. The
    /// login card stays up (pinned against the scan) while this runs.
    func startHostSignIn() {
        guard let provider = signInProvider, let hostSignIn, hostSignInStatus == nil else { return }
        if prompt?.kind != .login {
            withAnimation(.easeOut(duration: 0.2)) { prompt = TerminalPrompt(kind: .login); failure = nil }
        }
        hostSignInStatus = NSLocalizedString("Starting the sign-in…", comment: "sign-in")
        hostSignInError = nil
        hostSignIn(provider) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .status(let text):
                    self.hostSignInStatus = text
                case .finished(let ok, let message):
                    if ok {
                        self.hostSignInStatus = String(format: NSLocalizedString(
                            "Signed in. Starting %@ again…", comment: "sign-in"), self.agentDisplayName)
                        self.relaunchAfterSignIn?()
                    } else {
                        self.hostSignInStatus = nil
                        self.hostSignInError = message ?? NSLocalizedString(
                            "The sign-in didn't complete. You can try again.", comment: "sign-in")
                    }
                }
            }
        }
    }

    func loadSlashCommands(agent: String?, cwd: String?) {
        guard let agent else { return }
        agentKind = agent
        agentDisplayName = Profile.Tool(rawValue: agent)?.displayName ?? agent
        let builtIn = SlashCommandCatalog.builtIn(for: agent)
        slashCommands = builtIn
        guard let cmd = SlashCommandCatalog.discoveryCommand(
            agent: agent, cwd: ScheduledAutomationEngine.guestPath(cwd ?? "~")) else { return }
        Task { [weak self] in
            guard let self, let out = await self.provider.execGuest(cmd, timeout: 10) else { return }
            let extra = SlashCommandCatalog.parseDiscovery(out)
            guard !extra.isEmpty else { return }
            var seen = Set(builtIn.map(\.name))
            var merged = builtIn
            for c in extra where !seen.contains(c.name) { merged.append(c); seen.insert(c.name) }
            self.slashCommands = merged
        }
    }

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
    private struct Pending { let item: TranscriptItem; let added: Date; var ttl: TimeInterval = 45 }
    private var pending: [Pending] = []
    /// A session started with an opening message: the message is echoed
    /// before the agent has written anything, and the thinking cue is held
    /// up until the agent's first words land (or a generous timeout) — so a
    /// fresh session never opens on a blank "send a message to begin".
    private var seededUntil: Date?

    func seedOpening(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pending.append(Pending(item: TranscriptItem(id: nextOptimisticID, kind: .userText(t), timestamp: nil),
                               added: Date(), ttl: 180))
        nextOptimisticID -= 1
        rebuild()
        seededUntil = Date().addingTimeInterval(120)
        loading = false
        setWorking(true)
    }

    /// The seeded "working" holds until the agent has answered (an assistant
    /// turn in the real transcript) or the seed times out.
    private func seedHolds() -> Bool {
        guard let until = seededUntil else { return false }
        let answered = parsedItems.contains {
            if case .assistantText = $0.kind { return true }
            if case .toolUse = $0.kind { return true }
            return false
        }
        if answered || Date() > until { seededUntil = nil; return false }
        return true
    }

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
            if Date().timeIntervalSince(p.added) > p.ttl { return true }
            guard case .userText(let t) = p.item.kind else { return true }
            return parsedItems.contains {
                if case .userText(let rt) = $0.kind { return rt == t }
                return false
            }
        }
    }

    /// Begin polling the live transcript: brisk while the agent is working
    /// (its turn streams into the file as it goes, and a lagging chat is
    /// what the user notices), relaxed once it's idle.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let busy = self?.working ?? false
                try? await Task.sleep(nanoseconds: busy ? 400_000_000 : 1_200_000_000)
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
        let isWorking = provider.isWorking() || seedHolds()
        // Terminal-state scan FIRST and unconditionally: a trust/login prompt (or
        // an auth error) can be on screen before any transcript store exists, so
        // it must not sit behind the transcript fetch's early return.
        await scanTerminal()
        guard let data = await provider.fetchTranscript() else { setWorking(isWorking); loading = false; return }
        loading = false
        if !data.isEmpty { transcriptSink?(data) }   // the session's local copy
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
            ensureDropImages()
            // Real transcript progress ⇒ any earlier terminal card is stale.
            if failure != nil || prompt != nil {
                let wasLogin = prompt?.kind == .login
                withAnimation(.easeOut(duration: 0.2)) { failure = nil; prompt = nil }
                if wasLogin { loginPromptChanged?(false) }
                hostSignInStatus = nil
            }
        }
        reconcilePending()
        rebuild()
        setWorking(provider.isWorking() || seedHolds())
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
        // A host sign-in in flight owns the card: the screen still shows the
        // login menu (or the error that led here) until the agent restarts.
        guard hostSignInStatus == nil else { return }
        let state = TerminalScan.classify(screen, agent: agentKind)
        // Only touch published state when it actually changes, so a steady error
        // banner doesn't re-fire the animation every scan.
        let newPrompt: TerminalPrompt? = { if case .prompt(let p) = state { return p } else { return nil } }()
        let newFailure: SessionFailure? = { if case .failure(let f) = state { return f } else { return nil } }()
        guard newPrompt != prompt || newFailure != failure else { return }
        let wasLogin = prompt?.kind == .login
        withAnimation(.easeOut(duration: 0.2)) {
            prompt = newPrompt
            failure = newFailure
        }
        let isLogin = newPrompt?.kind == .login
        if isLogin != wasLogin { loginPromptChanged?(isLogin) }
    }

    /// Answer Claude's folder-trust dialog inline (Down → "Yes, I trust this
    /// folder", Enter to confirm), so the user needn't hunt for the hidden
    /// terminal. Optimistically clears the card and marks the session working.
    func trustFolder() {
        guard let p = prompt, p.canAnswerTrust else { return }
        withAnimation(.easeOut(duration: 0.2)) { prompt = nil }
        setWorking(true)
        let keys = p.trustKeys
        Task { [weak self] in
            await self?.provider.pressKeys(keys)
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

    /// The images user turns reference by their drop path that this view
    /// doesn't hold yet, from this Mac's record of what it uploaded. A turn
    /// sent from another client shows no thumbnail: the machine's copy is
    /// never read back, since the agent may have changed it.
    private func ensureDropImages() {
        for item in parsedItems {
            guard case .userText(let text) = item.kind else { continue }
            for path in GuestDrop.imagePaths(in: text) where imagesByPath[path] == nil {
                if let kept = DropImageStore.load(path) { imagesByPath[path] = kept }
            }
        }
    }

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
        // A slash command: the TUI answers on screen, not in the transcript.
        let isCommand = raw.hasPrefix("/") && atts.isEmpty && !raw.contains("\n")
        dismissCommandOutput()
        composerText = ""
        pendingAttachments = []
        failure = nil
        prompt = nil
        gate.userSent()                   // a fresh send supersedes any prior stop
        setWorking(true)
        sending = true

        // Deterministic guest paths for this batch (computed before staging so
        // the optimistic echo + thumbnails are instant and match what lands),
        // stamped so no later send reuses them.
        let stamp = GuestDrop.stamp()
        let prefixed = atts.map {
            DroppedFile(name: "\(stamp)_\($0.name)", data: $0.data, isImage: $0.isImage)
        }
        let attPaths = prefixed.enumerated().map { GuestDrop.path(index: $0.offset, name: $0.element.name) }
        for (i, f) in prefixed.enumerated() where f.isImage {
            imagesByPath[attPaths[i]] = f.data
            DropImageStore.store(f.data, for: attPaths[i])
        }

        Task { [weak self] in
            guard let self else { return }
            var text = await self.translateHostFiles(in: raw)
            if !attPaths.isEmpty {
                text = text.isEmpty ? attPaths.joined(separator: " ")
                                    : text + " " + attPaths.joined(separator: " ")
            }
            // A slash command is shown by its card, not as a turn: the
            // transcript never carries it as plain text (Claude Code writes
            // a tagged record the parser drops), so an echo would sit there
            // until it aged out.
            if !isCommand { self.appendOptimistic(.userText(text)) }
            if !prefixed.isEmpty { _ = await self.provider.stage(prefixed) }
            let before = isCommand ? await self.provider.captureScreen() : nil
            // Sent exactly as typed: the TUIs run the completion their popup
            // highlights, which is the exact match when the name is right —
            // hence the palette offers only names the agent really has (a
            // trailing space would turn it into a plain message for some).
            await self.provider.send(text)
            self.sending = false
            if isCommand { self.watchCommand(raw, before: before) }
            await self.poll()
        }
    }

    // MARK: Slash commands → what the terminal printed

    /// What the TUI printed in answer to a slash command sent from the
    /// composer. Local commands (/help, /cost, /status, /model…) never reach
    /// the transcript, so the chat reads the screen instead — whatever is new
    /// since the command went out, minus the input box and status chrome.
    struct CommandOutput: Equatable {
        let command: String
        var lines: [String]
        /// The TUI opened a menu (a picker, a list to arrow through).
        var menu: Bool
        /// The card IS the terminal right now: the tab's own surface, inline,
        /// so the menu is answered here with the arrow keys and Return.
        var live: Bool
        /// The watch is over; what's here is what the command printed.
        var settled: Bool
    }
    @Published var commandOutput: CommandOutput?
    private var commandWatch: Task<Void, Never>?
    private var liveWatch: Task<Void, Never>?
    private var commandBaseline: Set<String> = []
    /// The tab's native terminal surface, for the inline card (nil when the
    /// pane has none — a fat-client mirror, say).
    var inlineTerminal: (() -> NSView?)?
    /// The tmux session behind the inline surface (a "view-…" grouped
    /// session of its own), so tmux's mouse mode can go on for that view
    /// alone while the terminal is inline — the wheel and clicks then act
    /// in the TUI on show — and off again when it folds.
    var inlineTerminalSession: (() -> String?)?

    private func setInlineMouse(_ on: Bool) {
        guard let name = inlineTerminalSession?() else { return }
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        Task { [weak self] in
            _ = await self?.provider.execGuest(
                "tmux set-option -t \(quoted) mouse \(on ? "on" : "off") 2>/dev/null; true", timeout: 10)
        }
    }

    /// The TUI's menu is still up as its card goes away or folds: close it
    /// there too (Esc, which every TUI honours), so the chat and the agent
    /// agree on where the conversation stands.
    private func closeTUIMenuIfOpen(_ out: CommandOutput?) {
        guard let out, out.live || out.menu else { return }
        Task { [weak self] in await self?.provider.pressKeys(["Escape"]) }
    }

    func dismissCommandOutput() {
        commandWatch?.cancel(); commandWatch = nil
        liveWatch?.cancel(); liveWatch = nil
        closeTUIMenuIfOpen(commandOutput)
        if commandOutput?.live == true { setInlineMouse(false) }
        if commandOutput != nil {
            withAnimation(.easeOut(duration: 0.15)) { commandOutput = nil }
        }
    }

    /// Show the terminal inline for the current command (or fold it back).
    func toggleLiveCommand() {
        guard var out = commandOutput else { return }
        out.live.toggle()
        commandWatch?.cancel(); commandWatch = nil
        withAnimation(.easeOut(duration: 0.15)) { commandOutput = out }
        setInlineMouse(out.live)
        if out.live {
            watchLive(out.command)
        } else {
            liveWatch?.cancel(); liveWatch = nil
            // Folded by hand with the menu still up: the agent would sit in it.
            closeTUIMenuIfOpen(out)
        }
    }

    private func watchCommand(_ command: String, before: String?) {
        commandWatch?.cancel()
        liveWatch?.cancel()
        commandBaseline = Set((before ?? "").split(whereSeparator: \.isNewline).map { Self.normalizedLine($0) })
        commandOutput = CommandOutput(command: command, lines: [], menu: false, live: false, settled: false)
        commandWatch = Task { [weak self] in
            // Captures at ~0.7, 1.6, 3, 5, 8 s: fast commands show at once,
            // slow ones (a network call behind /status) still land.
            let gaps: [UInt64] = [700, 900, 1400, 2000, 3000]
            for (i, gap) in gaps.enumerated() {
                try? await Task.sleep(nanoseconds: gap * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                guard var out = self.commandOutput, out.command == command, !out.live else { return }
                let last = i == gaps.count - 1
                if let screen = await self.provider.captureScreen() {
                    out.menu = Self.looksLikeMenu(screen)
                    out.lines = Self.commandLines(screen, excluding: self.commandBaseline, command: command)
                    // A menu is answered in the terminal — so bring the
                    // terminal here, the moment it shows.
                    if out.menu, self.inlineTerminal != nil {
                        out.live = true
                        withAnimation(.easeOut(duration: 0.15)) { self.commandOutput = out }
                        self.setInlineMouse(true)
                        self.watchLive(command)
                        return
                    }
                }
                out.settled = last
                if out != self.commandOutput {
                    withAnimation(.easeOut(duration: 0.15)) { self.commandOutput = out }
                }
            }
        }
    }

    /// While the terminal is inline: once its menu has gone (a pick made,
    /// Esc pressed), fold the card back to what the screen says now.
    ///
    /// "Gone" is judged on the menu's OWN lines: what the picker drew when it
    /// opened is its signature, and the menu is over when that signature has
    /// (mostly) left the screen and no picker footer remains — whatever the
    /// idle prompt looks like afterwards (Claude Code's starts with the same
    /// "❯" a highlighted row does).
    private func watchLive(_ command: String) {
        liveWatch?.cancel()
        liveWatch = Task { [weak self] in
            var signature: Set<String>? = nil
            var calm = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, var out = self.commandOutput, out.command == command, out.live else { return }
                guard let screen = await self.provider.captureScreen() else { continue }
                let current = Set(screen.split(whereSeparator: \.isNewline).map { Self.normalizedLine($0) })
                if signature == nil {
                    // First look with the menu up: remember what it drew.
                    let drawn = Set(Self.commandLines(screen, excluding: self.commandBaseline, command: command)
                        .map { $0.trimmingCharacters(in: .whitespaces) })
                    if Self.looksLikeMenu(screen), !drawn.isEmpty { signature = drawn }
                    continue
                }
                let remaining = signature!.filter { current.contains($0) }.count
                let mostlyGone = remaining <= max(1, signature!.count * 3 / 10)
                if Self.menuHints(screen) || !mostlyGone { calm = 0; continue }
                calm += 1
                guard calm >= 2 else { continue }
                out.live = false
                out.menu = false
                out.settled = true
                self.setInlineMouse(false)
                out.lines = Self.commandLines(screen, excluding: self.commandBaseline, command: command)
                withAnimation(.easeOut(duration: 0.15)) { self.commandOutput = out }
                return
            }
        }
    }

    nonisolated static func normalizedLine(_ s: Substring) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    /// The screen's lines that weren't there before the command, minus box
    /// borders, prompt rows and status bars. Capped so a long help screen
    /// stays a card.
    nonisolated static func commandLines(_ screen: String, excluding baseline: Set<String>,
                                         command: String) -> [String] {
        var out: [String] = []
        for raw in screen.split(whereSeparator: \.isNewline) {
            let line = normalizedLine(raw)
            if line.isEmpty || baseline.contains(line) { continue }
            if isChrome(line) || line == command || line.hasSuffix(" " + command) { continue }
            out.append(String(raw).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        if out.count > 60 { out = Array(out.prefix(60)) + ["…"] }
        return out
    }

    /// Box borders, prompt rows, status bars.
    nonisolated static func isChrome(_ line: String) -> Bool {
        let box: Set<Character> = ["─", "│", "╭", "╮", "╯", "╰", "┃", "━", "┌", "┐", "└", "┘",
                                   "├", "┤", "═", "║", "╌", "┄", " "]
        if line.allSatisfy({ box.contains($0) }) { return true }
        for p in [">", "❯", "›", "π ", "⏵", "$ "] where line.hasPrefix(p) { return true }
        return false
    }

    /// The footer a picker prints while it's open ("Enter to confirm · Esc
    /// to exit", "↑/↓ providers · Esc close"). Never the idle prompt's own
    /// hints ("? for shortcuts", "esc to interrupt").
    nonisolated static func menuHints(_ screen: String) -> Bool {
        let tail = screen.split(whereSeparator: \.isNewline).suffix(30).joined(separator: "\n").lowercased()
        return tail.contains("↑/↓") || tail.contains("↑↓") || tail.contains("enter to select")
            || tail.contains("enter to confirm") || tail.contains("esc to cancel") || tail.contains("esc to close")
            || tail.contains("esc to exit") || tail.contains("esc close")
            || (tail.contains("arrow") && tail.contains("select"))
    }

    /// A menu is open: its footer hints, or a highlighted row ("❯ …") that
    /// sits inside a list — not Claude Code's input prompt, which starts
    /// with the same glyph but has nothing but chrome and "? for shortcuts"
    /// under it.
    nonisolated static func looksLikeMenu(_ screen: String) -> Bool {
        if menuHints(screen) { return true }
        let lines = Array(screen.split(whereSeparator: \.isNewline).suffix(40)).map { String($0) }
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("❯ ") else { continue }
            let below = lines[(i + 1)..<min(lines.count, i + 4)]
            let listy = below.contains { r in
                let t = r.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !isChrome(t) && !t.lowercased().contains("for shortcuts")
                    && !t.lowercased().contains("esc to interrupt")
            }
            if listy { return true }
        }
        return false
    }

    /// Rewrite host file paths in `text` to guest paths, uploading each file.
    /// Returns `text` unchanged (fast, no I/O) when it names no host files.
    private func translateHostFiles(in text: String) async -> String {
        var tokens = Set(text.split(whereSeparator: { " \n\t".contains($0) }).map(String.init))
        tokens.insert(text)   // whole-string case: composer holds just the path
        var hits: [(token: String, file: DroppedFile)] = []
        let stamp = GuestDrop.stamp()
        for tok in tokens {
            guard let url = Self.hostFileURL(tok),
                  let data = try? Data(contentsOf: url), data.count <= 25 * 1024 * 1024 else { continue }
            let isImg = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            hits.append((tok, DroppedFile(name: "\(stamp)_\(url.lastPathComponent)", data: data, isImage: isImg)))
        }
        guard !hits.isEmpty else { return text }
        let staged = await provider.stage(hits.map(\.file))
        guard staged.count == hits.count else { return text }
        var out = text
        for (i, h) in hits.enumerated() {
            out = out.replacingOccurrences(of: h.token, with: staged[i])
            if h.file.isImage {
                imagesByPath[staged[i]] = h.file.data
                DropImageStore.store(h.file.data, for: staged[i])
            }
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
    /// Keyboard highlight in the "/" palette.
    @State private var paletteIndex = 0

    /// What's typed after a leading "/" — the palette shows for it until a
    /// space (the command is chosen) or a newline.
    private var paletteQuery: String? {
        let t = model.composerText
        guard t.hasPrefix("/"), !t.contains(" "), !t.contains("\n") else { return nil }
        return String(t.dropFirst())
    }
    /// "@…" being typed as the last word: the sessions with a nickname
    /// that match, for the composer to complete ("Ask @seclio to…"). Never
    /// inside a slash command; gone once the word is closed with a space.
    private var mentionQuery: String? {
        let t = model.composerText
        guard !t.hasPrefix("/"), !t.isEmpty, model.peerMentions != nil else { return nil }
        let word = t[Self.lastWordStart(of: t)...]
        guard word.hasPrefix("@") else { return nil }
        return String(word.dropFirst())
    }
    private static func lastWordStart(of t: String) -> String.Index {
        t.lastIndex(where: { $0 == " " || $0.isNewline }).map { t.index(after: $0) } ?? t.startIndex
    }
    /// Every session but this one: by its nickname, or by the name it
    /// would get (tagged so), matched on the name or the title. Named
    /// sessions first.
    private var mentionMatches: [SlashCommand] {
        guard let q = mentionQuery?.lowercased(), let peers = model.peerMentions?() else { return [] }
        func rank(_ p: PeerMention) -> (Int, Int, String) {
            // A name that starts with what's typed beats a title that merely
            // contains it; a session already named beats one that would be.
            (q.isEmpty || p.nick.lowercased().hasPrefix(q) ? 0 : 1, p.assigned ? 0 : 1, p.nick.lowercased())
        }
        return peers
            .filter { q.isEmpty || $0.nick.lowercased().hasPrefix(q) || $0.title.lowercased().contains(q) }
            .sorted { rank($0) < rank($1) }
            .map { p in
                var c = SlashCommand(name: p.nick,
                                     description: p.title + (p.workspace.isEmpty ? "" : " · " + p.workspace),
                                     source: .builtIn)
                if !p.assigned { c.tag = NSLocalizedString("new name", comment: "mention palette tag") }
                return c
            }
    }
    private var mentionMode: Bool { paletteQuery == nil && mentionQuery != nil }
    private var paletteCommands: [SlashCommand] {
        if mentionMode { return mentionMatches }
        guard let q = paletteQuery, !model.slashCommands.isEmpty else { return [] }
        return SlashCommandCatalog.matches(q, in: model.slashCommands)
    }
    private var paletteVisible: Bool { !paletteCommands.isEmpty }
    private var paletteCurrent: SlashCommand? {
        let cmds = paletteCommands
        return cmds.indices.contains(paletteIndex) ? cmds[paletteIndex] : cmds.first
    }

    /// Put the command into the composer. One that takes text gets a trailing
    /// space (the palette closes, the user types on); a bare one stays exact
    /// so ↩ sends it. A mention replaces the "@…" being typed, plus a space
    /// to go on with the sentence.
    private func complete(_ c: SlashCommand) {
        if mentionMode {
            // A session without a nickname gets the proposed one now, so
            // the "@name" being typed is one an agent can resolve.
            if let peer = model.peerMentions?().first(where: { $0.nick == c.name }), !peer.assigned {
                model.assignNickname?(peer.sessionID, peer.nick)
            }
            let t = model.composerText
            model.composerText = String(t[..<Self.lastWordStart(of: t)]) + "@" + c.name + " "
            return
        }
        model.composerText = "/" + c.name + (c.takesArgument ? " " : "")
    }

    /// The palette's keys, offered by the composer before it acts on them.
    /// Arrows move the highlight, Tab completes, ↩ completes a partial
    /// command (an exact match falls through and the composer sends it),
    /// Escape clears. False = not the palette's key, the composer's own.
    private func handlePaletteKey(_ key: ComposerKey) -> Bool {
        switch key {
        case .up:
            guard paletteVisible else { return false }
            paletteIndex = max(0, paletteIndex - 1); return true
        case .down:
            guard paletteVisible else { return false }
            paletteIndex = min(paletteCommands.count - 1, paletteIndex + 1); return true
        case .tab:
            guard paletteVisible, let c = paletteCurrent else { return false }
            complete(c); return true
        case .enter:
            guard paletteVisible, let c = paletteCurrent else { return false }
            if mentionMode { complete(c); return true }
            guard c.name != paletteQuery else { return false }
            complete(c); return true
        case .escape:
            guard paletteVisible else { return false }
            if mentionMode {
                // Drop just the "@…" being typed; the sentence stays.
                let t = model.composerText
                model.composerText = String(t[..<Self.lastWordStart(of: t)])
            } else {
                model.composerText = ""
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            // omp keeps its TODO pinned at the bottom at all times; the inline
            // card otherwise scrolls up out of view (the transcript auto-sticks
            // to the tail). Pin the current todo here, above the composer.
            if let todo = pinnedTodo { todoPinPanel(todo) }
            // What this session delegated (and to whom it answers), kept
            // in sight the same way.
            if let store = model.delegationStore, let me = model.currentSession?() {
                DelegationPanel(store: store, sessions: model.sessionStore, session: me,
                                accent: model.accent,
                                workspaceName: model.workspaceName,
                                remote: model.remoteDelegations?() ?? [],
                                open: { model.openSession?($0) },
                                answer: model.answerDelegation)
            }
            if paletteVisible {
                SlashCommandPalette(
                    commands: paletteCommands,
                    agentName: mentionMode
                        ? NSLocalizedString("sessions you can ask", comment: "mention palette")
                        : model.agentDisplayName,
                    highlighted: paletteIndex,
                    onPick: { c in
                        let mention = mentionMode
                        complete(c)
                        if !mention && !c.takesArgument { model.send() }
                    },
                    onHover: { paletteIndex = $0 },
                    prefix: mentionMode ? "@" : "/",
                    title: mentionMode ? NSLocalizedString("Sessions", comment: "mention palette") : nil)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider().opacity(0.5)
            if !model.pendingAttachments.isEmpty {
                PendingAttachmentChips(files: model.pendingAttachments,
                                       onRemove: { model.removeAttachment(at: $0) })
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            ChatComposer(
                placeholder: model.agentDisplayName.isEmpty
                    ? NSLocalizedString("Message the agent…  (or drop files)", comment: "beautified composer")
                    : String(format: NSLocalizedString("Message %@…  (or drop files)", comment: "beautified composer"),
                             model.agentDisplayName),
                text: $model.composerText,
                autofocus: true,
                busy: model.sending,
                accent: model.accent,
                canSendEmpty: !model.pendingAttachments.isEmpty,
                working: model.working,
                onStop: { model.interrupt() },
                onKey: { handlePaletteKey($0) },
                onSend: { model.send() })
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .animation(.easeOut(duration: 0.15), value: paletteVisible)
        .onChange(of: paletteQuery) { _, _ in paletteIndex = 0 }
        // A chat surface, not a terminal: opaque so it never picks up the
        // window's terminal-translucency (which reads as a gray scrim here).
        // The canvas tone — the composer card is the white thing on it.
        .background(Color.platformWindowBackground)
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
                    Text(model.agentDisplayName.isEmpty
                         ? NSLocalizedString("Say what you need — the agent is listening.",
                                             comment: "beautified empty")
                         : String(format: NSLocalizedString("%@ is ready. Say what you need.",
                                                            comment: "beautified empty"),
                                  model.agentDisplayName))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.items) { item in
                            // The consolidated todo is shown pinned above the
                            // composer, not inline (where it scrolls away).
                            if !Self.isTodo(item) { itemRow(item) }
                        }
                        if let out = model.commandOutput {
                            CommandCard(output: out,
                                        terminal: out.live ? model.inlineTerminal?() : nil,
                                        canGoLive: model.inlineTerminal != nil,
                                        onToggleLive: { model.toggleLiveCommand() },
                                        onDismiss: { model.dismissCommandOutput() })
                                .id("beautified-command")
                                .transition(.opacity)
                        }
                        if let prompt = model.prompt {
                            PromptCard(prompt: prompt,
                                       providerName: model.signInAccountName,
                                       hostSignInAvailable: model.hostSignIn != nil && model.signInProvider != nil,
                                       signInStatus: model.hostSignInStatus,
                                       signInError: model.hostSignInError,
                                       onHostSignIn: { model.startHostSignIn() },
                                       onOpenProviderSettings: model.signInProvider == nil ? model.openProviderSettings : nil,
                                       onTrust: { model.trustFolder() },
                                       onMethod: { model.chooseLoginMethod($0) },
                                       onOpenURL: { model.openLoginURL() },
                                       onSubmitCode: { model.submitLoginCode($0) })
                                .id("beautified-prompt")
                                .transition(.opacity)
                        } else if let failure = model.failure {
                            FailureCard(failure: failure,
                                        providerName: model.signInAccountName,
                                        onSignIn: model.hostSignIn != nil && model.signInProvider != nil
                                            ? { model.startHostSignIn() } : nil)
                                .id("beautified-failure")
                                .transition(.opacity)
                        } else if model.working, model.commandOutput == nil {
                            liveCue.id("beautified-thinking")
                        }
                        Color.clear.frame(height: 1).id(Self.tailID)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onChange(of: model.commandOutput) { _, _ in scrollToTail(proxy) }
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

    /// True for the consolidated `.todo` item (omp's plan), which is pinned at
    /// the bottom rather than shown inline (where it scrolls out of view).
    static func isTodo(_ item: TranscriptItem) -> Bool {
        if case .todo = item.kind { return true } else { return false }
    }

    /// The todo to pin (the latest consolidated one, if any).
    private var pinnedTodo: TranscriptItem? {
        model.items.last(where: Self.isTodo)
    }

    /// The pinned TODO panel — omp keeps its plan visible at all times; this is
    /// the beautified-view equivalent, above the composer and capped so a long
    /// plan scrolls in place instead of eating the transcript.
    @ViewBuilder
    private func todoPinPanel(_ item: TranscriptItem) -> some View {
        if case .todo(let title, let rows) = item.kind {
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                ScrollView {
                    TodoListView(title: title, rows: rows)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 190)
            }
            .background(Color.platformTextBackground)
        }
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.tailID, anchor: .bottom)
        }
    }

    /// One transcript item. A user turn that references pictures this Mac
    /// uploaded shows them inside its bubble in place of their paths
    /// (persists after the poll, since the real user turn carries the same
    /// guest paths the drop echoed).
    @ViewBuilder
    private func itemRow(_ item: TranscriptItem) -> some View {
        if case .userText(let text) = item.kind {
            let paths = GuestDrop.imagePaths(in: text).filter { model.imagesByPath[$0] != nil }
            TranscriptItemView(item: item,
                               attachments: paths.compactMap { model.imagesByPath[$0] },
                               hiddenPaths: paths)
                .id(item.id)
        } else {
            TranscriptItemView(item: item)
                .id(item.id)
        }
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
    /// Trust dialog we recognize well enough to answer inline.
    var canAnswerTrust: Bool = false
    /// The keystrokes that accept it: Claude's picker needs Down then Enter
    /// ("Yes, I trust this folder" is the second option); Codex defaults to
    /// "Yes, continue", so Enter alone.
    var trustKeys: [String] = ["Down", "Enter"]
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

    static func detect(inScreen screen: String, agent: String? = nil) -> TerminalPrompt? {
        detect(tail: terminalTail(screen), agent: agent)
    }

    /// `agent`: the tab's agent kind, for the wording only it uses (Oh My Pi
    /// has no account — a missing provider key is its "sign-in").
    static func detect(tail: [String], agent: String? = nil) -> TerminalPrompt? {
        let trimmed = tail.map { $0.trimmingCharacters(in: .whitespaces) }
        let low = trimmed.joined(separator: "\n").lowercased()

        // Sign-in screens: Claude's `/login` flow (the method menu, then the
        // OAuth URL + code prompt), Codex's first-run picker, and the
        // logged-out banners Grok / Kimi print.
        let looksLikeLogin = low.contains("select login method")
            || low.contains("browser didn't open")
            || low.contains("paste code here")
            || trimmed.contains { $0.contains("/oauth/authorize") }
            || low.contains("sign in with chatgpt")
            || low.contains("sign in with your chatgpt")
            || low.contains("grok login") || low.contains("kimi login")
            || low.contains("not logged in") || low.contains("please log in")
            || low.contains("login required")
            // Grok's first run: its own device-code screen.
            || low.contains("approve in your browser")
            // Oh My Pi's first-run wizard ("Setup step 1 of 5 · Set up your
            // providers"), or a run with no provider key at all.
            || (agent == "omp" && (low.contains("set up your providers") || low.contains("select provider to login")
                                   || low.contains("no api key") || low.contains("api key is not set")
                                   || low.contains("missing api key") || low.contains("anthropic_api_key")))
        if looksLikeLogin {
            return TerminalPrompt(
                kind: .login,
                loginMethods: trimmed.compactMap(loginOption),
                authURL: trimmed.compactMap(authorizeURL).first,
                awaitingCode: low.contains("paste code here"))
        }

        // Folder-trust dialog (Claude's picker, Codex's "Do you trust the
        // contents of this directory?").
        if trustNeedles.contains(where: { low.contains($0) }) {
            // The folder: a line that is just a path (Claude), else the first
            // absolute path mentioned ("You are in /home/…" — Codex).
            let folder = trimmed.first(where: { $0.hasPrefix("/") && !$0.contains(" ") })
                ?? trimmed.joined(separator: " ").split(separator: " ")
                    .first(where: { $0.hasPrefix("/home/") || $0.hasPrefix("/root/") })
                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;)")) }
                ?? NSLocalizedString("this folder", comment: "prompt")
            let claudePicker = low.contains("yes, i trust this folder")
            let codexPicker = low.contains("yes, continue")
            // Kimi's picker defaults to "Trust this folder" (Enter picks it).
            let kimiPicker = low.contains("don't trust") && low.contains("trust this folder")
            return TerminalPrompt(kind: .trust, detail: folder,
                                  canAnswerTrust: claudePicker || codexPicker || kimiPicker,
                                  trustKeys: claudePicker ? ["Down", "Enter"] : ["Enter"])
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
    static func classify(_ screen: String, agent: String? = nil) -> TerminalState? {
        let tail = terminalTail(screen)
        if let p = TerminalPrompt.detect(tail: tail, agent: agent) { return .prompt(p) }
        if let f = SessionFailure.detect(tail: tail) { return .failure(f) }
        return nil
    }
}

/// What the terminal printed after a slash command: a monospace card under
/// the command, refreshed for a few seconds, with the way to the real
/// terminal when the command opened a menu there.
private struct CommandCard: View {
    let output: BeautifiedSessionModel.CommandOutput
    /// The tab's terminal surface to show inline while `output.live`.
    let terminal: NSView?
    let canGoLive: Bool
    let onToggleLive: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(output.command)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if !output.settled, !output.live { ProgressView().controlSize(.mini) }
                if output.live {
                    Text(NSLocalizedString("↑↓ move · ⏎ pick · esc close", comment: "command card"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if canGoLive {
                    Button(action: onToggleLive) {
                        Label(output.live
                              ? NSLocalizedString("Fold", comment: "command card")
                              : NSLocalizedString("Interact", comment: "command card"),
                              systemImage: output.live ? "rectangle.compress.vertical" : "keyboard")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .controlSize(.small)
                    .help(output.live
                          ? NSLocalizedString("Back to the printed output", comment: "command card")
                          : NSLocalizedString("Show the terminal here and type into it", comment: "command card"))
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Dismiss", comment: ""))
            }
            if output.live, let terminal {
                // The real thing: the tab's own surface, sized to a comfortable
                // picker. Keys go straight to the agent.
                InlineTerminalView(terminal: terminal)
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10)))
            } else if output.lines.isEmpty {
                Text(output.settled
                     ? NSLocalizedString("Nothing new appeared in the terminal.", comment: "command card")
                     : NSLocalizedString("Waiting for the terminal…", comment: "command card"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(output.lines.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
                if output.menu, !canGoLive {
                    Text(NSLocalizedString("This command opened a menu in the terminal — make your pick there (⌥⌘U).", comment: "command card"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Hosts the tab's native terminal surface inside the chat for the length
/// of an interactive command. The surface is the same one the Linux view
/// mounts — one tmux client, re-parented — and goes back to being unmounted
/// when the card folds.
private struct InlineTerminalView: NSViewRepresentable {
    let terminal: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // The keys are the point: focus it as soon as it's on screen.
        DispatchQueue.main.async { container.window?.makeFirstResponder(terminal) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        let win = container.window
        for sub in container.subviews { sub.removeFromSuperview() }
        win?.makeFirstResponder(nil)
    }
}

/// The failure card shown in place of the cue — red-accented so a dead session
/// is unmistakable, carrying the terminal's own error line and a nudge back to
/// the terminal, where the fix (re-login, top up) actually happens.
/// What a host-run sign-in reports to the card that started it.
enum HostSignInEvent: Equatable {
    case status(String)
    case finished(success: Bool, message: String?)
}

private struct FailureCard: View {
    let failure: SessionFailure
    /// Auth failures: the host sign-in, when this window can offer it.
    var providerName: String = ""
    var onSignIn: (() -> Void)? = nil
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
                if failure.kind == .auth, let onSignIn {
                    Button(action: onSignIn) {
                        Label(String(format: NSLocalizedString("Sign in to %@…", comment: "login"), providerName),
                              systemImage: "person.badge.key.fill")
                    }
                    .controlSize(.small).buttonStyle(.borderedProminent).tint(.red)
                    .padding(.top, 3)
                } else {
                    Text(NSLocalizedString("Switch to the terminal to resolve it, then send again.",
                                           comment: "failure hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
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
    /// "Claude", "ChatGPT"… — the account the sign-in is for.
    var providerName: String = "Claude"
    /// The host can sign in for this tab (see BeautifiedSessionModel.hostSignIn).
    var hostSignInAvailable = false
    var signInStatus: String? = nil
    var signInError: String? = nil
    var onHostSignIn: () -> Void = {}
    /// No account to sign into (Oh My Pi): the machine's provider settings.
    var onOpenProviderSettings: (() -> Void)? = nil
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
                Text(headline).font(.system(size: 12.5, weight: .semibold))
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
                "Open Linux (⌥⌘U) to answer in the terminal.",
                comment: "prompt hint"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var headline: String {
        guard prompt.kind == .login else { return prompt.headline }
        if onOpenProviderSettings != nil {
            return String(format: NSLocalizedString("%@ needs a model provider", comment: "prompt"), providerName)
        }
        return String(format: NSLocalizedString("Sign in to %@", comment: "prompt"), providerName)
    }

    @ViewBuilder private var loginBody: some View {
        if let onOpenProviderSettings {
            // No account to sign into: the machine needs an API key or a
            // local model for this agent.
            Text(String(format: NSLocalizedString(
                "%@ has no model provider on this machine yet. Add an API key or a local model in the machine's settings, then start the session again.",
                comment: "login"), providerName))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenProviderSettings) {
                Label(NSLocalizedString("Machine settings…", comment: "login"), systemImage: "gearshape")
            }
            .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
        } else if hostSignInAvailable {
            // The host signs in: a throwaway machine does the OAuth, the
            // credential is stored on this Mac, the agent gets a stand-in key.
            Text(String(format: NSLocalizedString(
                "Bromure signs you in on this Mac and keeps your %@ account out of the machine — the agent only ever sees a stand-in key.",
                comment: "login"), providerName))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let signInStatus {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(signInStatus).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else {
                Button(action: onHostSignIn) {
                    Label(String(format: NSLocalizedString("Sign in to %@…", comment: "login"), providerName),
                          systemImage: "person.badge.key.fill")
                }
                .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
                if let signInError {
                    Text(signInError)
                        .font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if !prompt.loginMethods.isEmpty {
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

// MARK: - Delegations panel

/// Above the composer: what this session delegated — each delegate's
/// state, its last word, a question waiting for an answer — or, when this
/// session is itself a delegate, whom it answers to. Folds to a line;
/// nothing at all when the session is on neither end.
struct DelegationPanel: View {
    let store: DelegationStore
    let sessions: AgentSessionStore?
    let session: AgentSession
    let accent: Color
    /// A workspace's name — a delegate or peer elsewhere says where it is.
    let workspaceName: ((UUID) -> String)?
    /// Requests of this session's whose records live on other hosts, with
    /// the host's name.
    var remote: [(Delegation, String)] = []
    let open: (UUID) -> Void
    /// nil = read-only (a fat client's mirror).
    let answer: ((UUID, UUID, String) -> Void)?
    @AppStorage("sessions.delegationsExpanded") private var expanded = true
    @State private var drafts: [UUID: String] = [:]

    private var remoteHosts: [UUID: String] {
        Dictionary(remote.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let mine = (store.delegations(parent: session.id) + remote.map(\.0)).sorted { $0.createdAt < $1.createdAt }
        let asChild = store.openAsChild(session.id)
        if mine.isEmpty && asChild.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                ForEach(asChild) { delegateStrip($0) }
                if !mine.isEmpty { delegatorList(mine) }
            }
            .background(Color.platformTextBackground)
        }
    }

    // MARK: Delegate: whom I answer to

    /// "@nick" or “title” for the other end of a delegation.
    private func who(_ sessionID: UUID, label: String?) -> String {
        if let label, !label.isEmpty { return label }
        if let t = title(of: sessionID) { return "“\(t)”" }
        return NSLocalizedString("another session", comment: "delegation panel")
    }

    private func delegateStrip(_ d: Delegation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: d.isRequest ? "bubble.left.and.text.bubble.right" : "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(d.isRequest
                 ? String(format: NSLocalizedString("Request from %@", comment: "delegation panel"),
                          who(d.parentSessionID, label: d.parentLabel))
                 : String(format: NSLocalizedString("Delegated by %@", comment: "delegation panel"),
                          who(d.parentSessionID, label: d.parentLabel)))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            if d.isRequest {
                Text(DelegationNotice.oneLine(d.brief, max: 120))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            statusPill(d)
            Spacer(minLength: 0)
            // The requester is on this host, or on another Mac (a fat client's
            // own session): only the former can be put on stage.
            if d.parentRemote == nil {
                Button(d.isRequest
                       ? NSLocalizedString("Show requester", comment: "delegation panel")
                       : NSLocalizedString("Show delegator", comment: "delegation panel")) { open(d.parentSessionID) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .help(d.brief)
    }

    // MARK: Delegator: my delegates

    private func delegatorList(_ list: [Delegation]) -> some View {
        let waiting = list.filter { $0.status == .waitingForParent }.count
        let delivered = list.filter { $0.status == .delivered }.count
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("Delegations", comment: "delegation panel"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(list.count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if waiting > 0 {
                        Text(waiting == 1
                             ? NSLocalizedString("1 question", comment: "delegation panel")
                             : String(format: NSLocalizedString("%d questions", comment: "delegation panel"), waiting))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    if delivered > 0 {
                        Text(delivered == 1
                             ? NSLocalizedString("1 delivery", comment: "delegation panel")
                             : String(format: NSLocalizedString("%d deliveries", comment: "delegation panel"), delivered))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            if expanded {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(list) { row($0) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func row(_ d: Delegation) -> some View {
        let child = sessions?.session(d.childSessionID)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                AgentAvatar(tool: child?.tool ?? session.tool, size: 20, status: dot(d))
                Button { open(d.childSessionID) } label: {
                    Text(d.isRequest ? (d.childLabel ?? d.title) : d.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(d.isRequest
                      ? NSLocalizedString("Open the peer's session", comment: "delegation panel")
                      : NSLocalizedString("Open the delegate's session", comment: "delegation panel"))
                if d.isRequest {
                    Text(NSLocalizedString("request", comment: "delegation panel tag"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                statusPill(d)
                if let host = remoteHosts[d.id] {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(NSLocalizedString("The peer is on this Mac, reached through its mirror", comment: "delegation panel"))
                } else if let pid = child?.profileID, pid != session.profileID,
                          let ws = workspaceName?(pid), !ws.isEmpty {
                    Text(ws)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let b = child?.worktreeBranch, !b.isEmpty {
                    Text(b)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if d.status == .waitingForParent, let ask = d.pendingAsk {
                askBox(d, ask)
            } else if let why = d.failure {
                Text(why)
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else if let last = d.lastMessage {
                Text(lastLine(last))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .opacity(d.status.isOpen ? 1 : 0.6)
        .help(d.brief)
    }

    private func askBox(_ d: Delegation, _ ask: DelegationMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ask.text)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if answer != nil {
                HStack(spacing: 6) {
                    TextField(NSLocalizedString("Answer for the agent…", comment: "delegation panel"),
                              text: Binding(get: { drafts[ask.id] ?? "" }, set: { drafts[ask.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                        .onSubmit { send(d, ask) }
                    Button(NSLocalizedString("Send", comment: "delegation panel")) { send(d, ask) }
                        .controlSize(.small)
                        .disabled((drafts[ask.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(NSLocalizedString("Your agent can answer it too — this sends yours in its place.",
                                       comment: "delegation panel"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)))
    }

    private func send(_ d: Delegation, _ ask: DelegationMessage) {
        let t = (drafts[ask.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        answer?(d.id, ask.id, t)
        drafts[ask.id] = nil
    }

    // MARK: Bits

    private func title(of sessionID: UUID) -> String? { sessions?.session(sessionID)?.title }

    private func dot(_ d: Delegation) -> AgentStatus? {
        switch d.status {
        case .starting, .working: return .working
        case .waitingForParent, .delivered: return .needsInput
        case .done: return .done
        case .cancelled, .failed: return nil
        }
    }

    private func statusPill(_ d: Delegation) -> some View {
        let (label, tint): (String, Color) = {
            switch d.status {
            case .starting: return (NSLocalizedString("Starting", comment: "delegation status"), .secondary)
            case .working: return (NSLocalizedString("Working", comment: "delegation status"), .blue)
            case .waitingForParent: return (NSLocalizedString("Asked a question", comment: "delegation status"), .orange)
            case .delivered: return (NSLocalizedString("Delivered", comment: "delegation status"), .green)
            case .done:
                return (d.verdict == "rejected"
                        ? NSLocalizedString("Rejected", comment: "delegation status")
                        : NSLocalizedString("Accepted", comment: "delegation status"), .secondary)
            case .cancelled: return (NSLocalizedString("Cancelled", comment: "delegation status"), .secondary)
            case .failed: return (NSLocalizedString("Failed", comment: "delegation status"), .red)
            }
        }()
        return Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func lastLine(_ m: DelegationMessage) -> String {
        let who: String
        switch m.from {
        case .child: who = NSLocalizedString("Delegate", comment: "delegation panel")
        case .parent: who = NSLocalizedString("Your agent", comment: "delegation panel")
        case .user: who = NSLocalizedString("You", comment: "delegation panel")
        case .host: who = "Bromure"
        }
        let verb: String
        switch m.kind {
        case .ask: verb = NSLocalizedString("asked", comment: "delegation panel")
        case .answer: verb = NSLocalizedString("answered", comment: "delegation panel")
        case .report: verb = NSLocalizedString("reported", comment: "delegation panel")
        case .deliver: verb = NSLocalizedString("delivered", comment: "delegation panel")
        case .steer: verb = NSLocalizedString("steered", comment: "delegation panel")
        case .cancel: verb = NSLocalizedString("cancelled", comment: "delegation panel")
        case .note, .brief: verb = NSLocalizedString("noted", comment: "delegation panel")
        }
        return "\(who) \(verb): " + DelegationNotice.oneLine(m.text, max: 200)
    }
}
