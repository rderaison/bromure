import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto   // swift-crypto: the same SHA256 API off Apple platforms
#endif

// A live session chat's model types, apart from the views
// (BeautifiedSessionView.swift): transcript reads, files dropped into the
// guest, queued messages, composer drafts. The session engine and the Linux
// daemon use them without SwiftUI.

/// Where the host's copy of a transcript file ends: the file path and the
/// offset the next read continues from.
typealias TranscriptCursor = (path: String, offset: Int)

enum TranscriptFetchMode { case tail, earlier }

/// How one transcript read ended (`readTranscript`).
enum TranscriptRead {
    case fetched(TranscriptFetch)
    /// The machine answered: there is no transcript for the tab (yet), or
    /// the tab is gone.
    case none
    /// The machine couldn't be asked, or didn't answer in time.
    case failed
}

/// When an empty chat stops waiting and says what went wrong (`loadIssue`).
/// A populated chat never does: a failed poll there keeps what's on show.
struct TranscriptLoadTracker {
    enum Issue: Equatable {
        /// Reads keep failing (timing out over the link, the machine not
        /// answering).
        case failed
        /// The agent has been working a while and no transcript turns up.
        case notFound
    }
    private(set) var failStreak = 0
    private(set) var missingSince: Date?
    /// Consecutive failed reads before an empty chat says so — each one
    /// already waited out its timeout.
    nonisolated static let failuresBeforeError = 2
    /// How long a working agent may go without a transcript before the
    /// chat says it can't find one (a fresh agent writes its first record
    /// within seconds of the prompt).
    nonisolated static let missingGrace: TimeInterval = 20

    mutating func record(_ read: TranscriptRead, at now: Date, showing: Bool, working: Bool) -> Issue? {
        switch read {
        case .fetched:
            failStreak = 0
            missingSince = nil
            return nil
        case .failed:
            failStreak += 1
            missingSince = nil
            return !showing && failStreak >= Self.failuresBeforeError ? .failed : nil
        case .none:
            failStreak = 0
            guard !showing, working else { missingSince = nil; return nil }
            let since = missingSince ?? now
            missingSince = since
            return now.timeIntervalSince(since) >= Self.missingGrace ? .notFound : nil
        }
    }
}

/// One answer from `CodingTaskEngine.transcriptChunkCommand`.
struct TranscriptFetch {
    let path: String
    /// A pending AskUserQuestion dump (Claude), or empty. Transient: parsed
    /// with the history, never stored in it.
    let pq: Data
    let size: Int
    /// File offsets of `chunk`. `end` is the file offset to continue from —
    /// file bytes, which can exceed `chunk.count` when the transfer dropped
    /// invalid ones.
    let start: Int
    let end: Int
    let chunk: Data
    /// When the tab's agent process started (epoch seconds; 0 unknown):
    /// a turn the transcript left open before then was interrupted.
    var agentStarted: Int = 0

    /// Header = 5 newline-terminated lines (path, pq, size, start, end),
    /// then the bytes. nil for empty output (no transcript file).
    static func parse(_ data: Data) -> TranscriptFetch? {
        var cuts: [Data.Index] = []
        var i = data.startIndex
        while cuts.count < 5, i < data.endIndex, let nl = data[i...].firstIndex(of: 0x0A) {
            cuts.append(nl)
            i = data.index(after: nl)
        }
        guard cuts.count == 5 else { return nil }
        func field(_ k: Int) -> Data {
            let s = k == 0 ? data.startIndex : data.index(after: cuts[k - 1])
            return data[s..<cuts[k]]
        }
        func int(_ k: Int) -> Int? {
            Int(String(decoding: field(k), as: UTF8.self).trimmingCharacters(in: .whitespaces))
        }
        let path = String(decoding: field(0), as: UTF8.self)
        guard !path.isEmpty, let size = int(2), let start = int(3), let end = int(4) else { return nil }
        return TranscriptFetch(path: path, pq: Data(field(1)), size: size, start: start, end: end,
                               chunk: Data(data[data.index(after: cuts[4])...]))
    }
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
    /// A drop path as staged (`baseDir/<leaf>`), whatever home the turn
    /// shows it under: a native Mac's agent reads `/Users/<you>/.bromure/
    /// drops/<leaf>` (Bromure Sidecar maps the Linux home to the real one).
    static func canonical(_ path: String) -> String {
        guard !path.hasPrefix(baseDir + "/"), let r = path.range(of: "/.bromure/drops/"),
              path.hasPrefix("/") else { return path }
        return baseDir + "/" + path[r.upperBound...]
    }

    /// The drop paths in a turn's text that name images, in order.
    static func imagePaths(in text: String) -> [String] {
        var out: [String] = []
        for tok in text.split(whereSeparator: { $0.isWhitespace }) {
            let path = String(tok)
            guard path.hasPrefix(baseDir + "/") || path.hasPrefix(legacyBaseDir + "/")
                    || (path.hasPrefix("/") && path.contains("/.bromure/drops/")),
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

/// A message sent while the agent was busy (see `queued`).
struct QueuedMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    var text: String
    var queuedAt = Date()
    /// Bromure holds it: the agent's queue can't be edited, so it's typed in
    /// when the turn ends. Otherwise it sits in the agent's own queue.
    var held: Bool
    /// The agent's own queue can give it back (Edit); a held one always can.
    var editable: Bool
    /// User turns in the transcript when it was queued.
    var baseline: Int
    /// Where the transcript file ended when it was queued: its delivery is
    /// looked for in what was written after.
    var path: String?
    var offset: Int = 0
    /// Where a held one is typed: the chat's window as it was when queued
    /// (its stable id and markers) — never whatever tab has its index by
    /// the time the agent is free.
    var target: PaneTarget?
    /// Why it couldn't be typed (shown on its row); nil while it waits.
    var failure: String?
    /// Being typed right now.
    var sending = false
    /// Held because the agent is asking the user something (a picker, an
    /// approval dialog): typing would answer it. Delivered once it closes.
    /// Optional so a queue saved before it existed still decodes.
    var awaitingAnswer: Bool? = nil
    var waitingOnDialog: Bool { awaitingAnswer == true }
    /// The session it was written in, when known: its paused view lists
    /// it, and the chat the session comes back in (maybe another tab)
    /// takes it over.
    var sessionID: UUID? = nil
    /// A held one Bromure typed in: the agent has it (maybe in its own
    /// queue — Kimi's "ctrl-s to steer"), the transcript doesn't yet. Shown
    /// until it lands as a turn. Optional so an older saved queue decodes.
    var delivered: Bool? = nil
    var isDelivered: Bool { delivered == true }
    /// Times Bromure typed it in without the agent ever taking it (typed as
    /// a dialog closed, into a screen still redrawing): put back on hold
    /// once, then shown as not delivered — never silently dropped.
    var redeliveries: Int? = nil
}

/// What each agent does with a message submitted while it's busy, measured
/// on each TUI (claude 2.1, codex 0.153, kimi 0.41, grok 1.0, omp 18.1):
/// - claude: queues it and takes it in at the next tool boundary (steer);
///   ↑ on an empty input pulls ALL queued messages back into the box.
/// - omp: steers it in almost at once; Alt+↑ restores all queued ones.
/// - codex: steers it in after the next tool call (seconds); an Enter-steer
///   can't be recalled.
/// - kimi, grok: queue it as a follow-up for after the turn, recallable only
///   one at a time (kimi) or through a selection mode (grok) — the same
///   timing as holding it here, which is fully editable, so they're held.
enum AgentQueueSupport {
    enum Mode: Equatable {
        /// Into the agent's own queue at once. `recall`: the key (tmux name)
        /// that pulls its whole queue back into the input box; nil = it can't.
        case native(recall: String?)
        /// Held by Bromure, typed in when the agent is idle.
        case held
    }

    static func mode(for agent: String?) -> Mode {
        switch agent {
        case "claude": return .native(recall: "Up")
        case "omp":    return .native(recall: "M-Up")
        case "codex":  return .native(recall: nil)
        default:       return .held
        }
    }

    /// Whether Esc puts the agent's queue back into its input box, unsent
    /// (omp's `restoreQueuedMessagesToEditor`).
    static func escapeRestoresQueue(_ agent: String?) -> Bool { agent == "omp" }
}

/// What's typed (and attached) in a chat's composer but not sent, kept
/// apart from the chat's model: a session switch builds a fresh model, and
/// the draft used to go with the old one.
@MainActor
enum ComposerDrafts {
    struct Draft { var text = ""; var attachments: [DroppedFile] = [] }
    private static var drafts: [String: Draft] = [:]
    static subscript(key: String) -> Draft {
        get { drafts[key] ?? Draft() }
        set {
            if newValue.text.isEmpty && newValue.attachments.isEmpty { drafts[key] = nil }
            else { drafts[key] = newValue }
        }
    }
}
