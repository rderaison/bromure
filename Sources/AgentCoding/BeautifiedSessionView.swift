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
    func fetchTranscript() async -> Data? {
        guard let idx = activeTabIndex() else { return nil }
        let meta = await execGuest(
            "i=\(idx); "
            + "cwd=$(tmux display-message -p -t bromure:$i '#{pane_current_path}' 2>/dev/null); "
            + "tty=$(tmux display-message -p -t bromure:$i '#{pane_tty}' 2>/dev/null); "
            + "pid=$(ps -t \"${tty#/dev/}\" -o pid=,stat= 2>/dev/null | awk '$2 ~ /\\+/ {print $1; exit}'); "
            + "et=$(ps -o etimes= -p \"$pid\" 2>/dev/null | tr -d ' '); "
            + "if [ -n \"$et\" ]; then s=$(( $(date +%s) - et )); else s=0; fi; "
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

    /// Write dropped/attached files into the guest at deterministic paths and
    /// return the guest paths written (for the message text + thumbnails). Does
    /// NOT type anything — the model composes and sends the message. Local and
    /// fat client share this; only `execGuest` differs (vsock vs. tunnel).
    func stage(_ files: [DroppedFile]) async -> [String] {
        var paths: [String] = []
        for (n, f) in files.enumerated() {
            let path = GuestDrop.path(index: n, name: f.name)
            var ok = true
            for cmd in GuestDrop.writeCommands(guestPath: path, data: f.data) {
                if await execGuest(cmd, timeout: 30) == nil { ok = false; break }
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
    /// Base64 chunk size — keeps each `printf` well under ARG_MAX; a multiple of
    /// 4 so every chunk decodes to whole bytes independently (the append works).
    private static let chunkBytes = 192 * 1024

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

    /// Chunked base64 writes to `guestPath`: mkdir + first (truncate) chunk,
    /// then appends. base64 is `[A-Za-z0-9+/=]` so the chunk is single-quoted;
    /// the path is fixed/sanitized so double-quoting is safe.
    static func writeCommands(guestPath: String, data: Data) -> [String] {
        let b64 = data.base64EncodedString()
        var cmds: [String] = []
        var idx = b64.startIndex
        var first = true
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunkBytes, limitedBy: b64.endIndex) ?? b64.endIndex
            let chunk = String(b64[idx..<end])
            idx = end
            let redir = first ? ">" : ">>"
            let prefix = first ? "mkdir -p \(baseDir) && " : ""
            cmds.append("\(prefix)printf %s '\(chunk)' | base64 -d \(redir) \"\(guestPath)\"")
            first = false
        }
        if cmds.isEmpty { cmds = ["mkdir -p \(baseDir) && : > \"\(guestPath)\""] }
        return cmds
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

    private func poll() async {
        working = provider.isWorking()
        guard let data = await provider.fetchTranscript() else { loading = false; return }
        loading = false
        parsedItems = AgentTranscript.parse(data)
        reconcilePending()
        rebuild()
        working = provider.isWorking()
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
        working = true
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
        if model.items.isEmpty && !model.working {
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
                        if model.working {
                            ThinkingRow().id("beautified-thinking")
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
                .onAppear { proxy.scrollTo(Self.tailID, anchor: .bottom) }
            }
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

/// The "agent is working" cue — a spinner with a gently cycling gerund, the
/// beautified-view equivalent of Claude Code's "Crafting…/Thinking…".
private struct ThinkingRow: View {
    private static let verbs = ["Thinking", "Working", "Crafting", "Pondering",
                                "Reasoning", "Cooking", "Churning", "Noodling"]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.4)) { context in
            let slot = Int(context.date.timeIntervalSinceReferenceDate / 2.4)
            let verb = Self.verbs[((slot % Self.verbs.count) + Self.verbs.count) % Self.verbs.count]
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verb + "…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}
