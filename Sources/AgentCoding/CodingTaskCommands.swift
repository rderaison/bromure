import Foundation

/// The guest commands the session engine and the coding-task engine both
/// build: typing a relaunch line, reading a transcript chunk, cloning a repo,
/// branch names safe to hand git. On CodingTaskEngine wherever it is (the
/// macOS engine, the fat client's statics, the Linux daemon's).
extension CodingTaskEngine {
    /// Type a COMMAND LINE into a tab whose agent exited (a relaunch in
    /// place): only while a shell — not an agent, which would take it as a
    /// message — holds the pane, and only in the intended window.
    nonisolated static func shellLineCommand(target: PaneTarget, line: String) -> String {
        var t = target
        t.foreground = .shell
        return PaneTypeGuard.typeCommand(target: t, text: line)
    }
    /// The shell that resolves `$f` — the transcript file a tab's agent is
    /// writing (its own pinned path first, else the newest store in the
    /// folder, floored by `since`). Shared by the one-shot tail and the
    /// beautified view's incremental reader.
    nonisolated static func transcriptLocatePrefix(
        path: String, since: Int, agent: String?, pinnedWindow: Int?,
        pin: TranscriptPin = TranscriptPin()) -> String {
        var cmd = "f=\"\"; pe=\"\"; "
        // Kimi records no per-window path, so the session's own id (pinned
        // by the engine once this launch's journal appeared) names its file.
        if agent == "kimi", let id = pin.kimiSession, AgentSessionLocator.isKimiSessionID(id) {
            cmd += AgentSessionLocator.kimiPinnedFragment(id: id, into: "f")
        } else if agent == "grok", let id = pin.grokSession, AgentSessionLocator.isConversationUUID(id) {
            // The session's own conversation, or nothing yet (`pe`): never
            // the folder's newest, which may be another session's.
            cmd += AgentSessionLocator.grokPinnedFragment(id: id, into: "f") + "[ -z \"$f\" ] && pe=1; "
        } else if agent == "codex", let id = pin.codexSession, AgentSessionLocator.isConversationUUID(id) {
            cmd += AgentSessionLocator.codexPinnedFragment(id: id, into: "f") + "[ -z \"$f\" ] && pe=1; "
        } else if agent == "omp", let id = pin.ompSession, AgentSessionLocator.isConversationUUID(id) {
            cmd += AgentSessionLocator.ompPinnedFragment(id: id, into: "f") + "[ -z \"$f\" ] && pe=1; "
        } else if let w = pinnedWindow {
            // The transcript the tab's agent itself named (its hook records the
            // path per window — see agent-status.sh) wins over "the newest file
            // in the folder": two agents in one folder (a delegate beside its
            // delegator) would otherwise take turns owning each other's view.
            // Still floored: a file older than this process is another's.
            cmd += AgentSessionLocator.pinnedPick(window: w, since: since)
        }
        cmd += "if [ -z \"$f\" ] && [ -z \"$pe\" ]; then "
            + AgentSessionLocator.locateBlock(path: path, since: since, agent: agent,
                                              kimiCreatedSince: pin.kimiCreatedSince,
                                              kimiExclude: pin.kimiExclude)
            + "fi; "
        return cmd
    }
    /// The beautified view's transcript reader: one round-trip that resolves
    /// the file and returns only what the host doesn't hold yet, so the view
    /// can keep the WHOLE conversation instead of re-reading a small tail on
    /// every poll. Output (empty when no transcript exists):
    ///
    ///     <file path>\n<pending-question line or empty>\n<file size>\n<start>\n<end>\n<bytes…>
    ///
    /// `tail` mode: when `$f` is `knownPath`, bytes from file offset
    /// `knownOffset` to the last complete line; otherwise (first read, another
    /// file, a truncated one) the last `bytes` of the file, aligned to a line.
    /// `earlier` mode: the `bytes` before `knownOffset` (the history's start),
    /// line-aligned, for "load earlier conversation". `start`/`end` are file
    /// offsets of the returned bytes; whole JSONL lines only, so the chunk is
    /// valid UTF-8 (the shell agent decodes stdout strictly) and the host can
    /// simply concatenate chunks.
    nonisolated static func transcriptChunkCommand(
        guestCwd: String, since: Int, agent: String? = nil, pinnedWindow: Int? = nil,
        pin: TranscriptPin = TranscriptPin(),
        knownPath: String?, knownOffset: Int, bytes: Int, earlier: Bool) -> String? {
        guard let path = AgentSessionLocator.sanitized(guestCwd: guestCwd)
        else { return nil }
        var cmd = transcriptLocatePrefix(path: path, since: since, agent: agent,
                                         pinnedWindow: pinnedWindow, pin: pin)
        cmd += "if [ -n \"$f\" ]; then printf '%s\\n' \"$f\"; "
        if agent == nil || agent == "claude" {
            // Same pending-AskUserQuestion dump as `planTranscriptCommand`,
            // on its own header line (it isn't part of the file, so it must
            // not land in the accumulated history).
            let enc2 = path.replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: "/", with: "-")
            let pq = "\"$HOME/.bromure/pq-\(enc2).json\""
            cmd += "if [ -n \"$(find \(pq) -newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null)\" ]; "
                + "then tr -d '\\n' < \(pq); fi; "
        }
        cmd += "echo; "
        let py = transcriptReaderPython
        cmd += "python3 - \"$f\" \(shellQuote(knownPath ?? "")) \(knownOffset) \(bytes) "
            + (earlier ? "earlier" : "tail")
            + " <<'BROMURE_PY' | iconv -f UTF-8 -t UTF-8 -c\n" + py + "\nBROMURE_PY\nfi"
        return cmd
    }
    /// Waits (up to 30 s) for the guest's loopback proxy, when the command's
    /// environment names one (HTTPS_PROXY=http://127.0.0.1:<port>, from
    /// proxy.env). A workspace answers exec as soon as agentd is up, a few
    /// seconds before agentd's proxy bridge listens: a clone fired on the
    /// first answer (an automation on a freshly booted workspace) failed to
    /// connect. No proxy named (OpenShell), or a port that never opens: no
    /// wait, or the clone runs anyway and reports git's own error.
    nonisolated static let proxyReadyFragment =
        "_bp=\"${HTTPS_PROXY:-${https_proxy:-}}\"; "
            + "case \"$_bp\" in http://127.0.0.1:[0-9]*) "
            + "_bp=\"${_bp#http://127.0.0.1:}\"; _bp=\"${_bp%%/*}\"; _bi=0; "
            + "until (: </dev/tcp/127.0.0.1/\"$_bp\") 2>/dev/null || [ \"$_bi\" -ge 60 ]; "
            + "do _bi=$((_bi+1)); sleep 0.5; done;; esac; "

    /// The guest command that clones `quotedURL` into `quotedPath` for a task
    /// with a clone URL — only when the folder holds no repository yet: an
    /// existing repo is left untouched (restarts never re-clone over work),
    /// a non-empty non-repo folder is refused rather than clobbered. Never
    /// prompts: a missing credential fails fast instead of hanging the
    /// start; an unknown SSH host is pinned on first contact.
    nonisolated static func cloneRepoCommand(quotedPath: String, quotedURL: String) -> String {
        "if git -C \(quotedPath) rev-parse --show-toplevel >/dev/null 2>&1; then :; "
            + "elif [ -e \(quotedPath) ] && [ -n \"$(ls -A \(quotedPath) 2>/dev/null)\" ]; then "
            + "echo 'the folder exists and is not a git repository' >&2; exit 3; "
            + "else " + proxyReadyFragment + "mkdir -p \"$(dirname \(quotedPath))\" && "
            + "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes' "
            + "git clone --quiet \(quotedURL) \(quotedPath) 2>&1 | tail -5 >&2; "
            + "test \"${PIPESTATUS[0]}\" -eq 0; fi"
    }
    /// A branch name safe to hand git — Bromure's commands and an agent's
    /// brief alike: what `git check-ref-format --branch` accepts, and never
    /// an option. Quoting stops the shell, not git: a parent branch named
    /// `--upload-pack=./pwn.sh` (HEAD can point at one, and the worktree's
    /// parent is read from HEAD) ran that program from `git pull --rebase`.
    nonisolated static func isSafeBranchName(_ s: String) -> Bool {
        BranchMergeCommands.isSafeBranchName(s)
    }
    /// The first of these names that isn't a plain branch name, if any.
    nonisolated static func unsafeBranch(_ names: String?...) -> String? {
        names.compactMap { $0 }.first { !isSafeBranchName($0) }
    }
    nonisolated static func unsafeBranchWhy(_ name: String) -> String {
        String(format: NSLocalizedString(
            "“%@” isn't a plain branch name — git would read it as an option. Rename the branch, then retry.",
            comment: "task landing: an option-shaped branch name"), name)
    }

    /// The reader `transcriptChunkCommand` runs in the guest (argv: file,
    /// known path, offset, window bytes, "tail"|"earlier"); prints
    /// `size\nstart\nend\n` then the file's bytes [start, end) — whole
    /// lines only, `start` always at a line's beginning.
    ///
    /// Bounded both ways, so one exec never ships (or reads) far more than
    /// its window — what keeps a call over a slow tunnel inside its timeout:
    /// - a first read aligns BACK to the start of the line the window opens
    ///   in only within another window's worth; a longer line (a multi-MB
    ///   tool result or screenshot) is skipped forward past instead — unless
    ///   it is the last whole line, which must still show;
    /// - a tail read more than `tailJumpFactor` windows behind the file
    ///   (the chat was away while the agent wrote tens of MB) starts over
    ///   from a fresh window at the end; "load earlier" fetches the gap;
    /// - the line scans walk 64 KB blocks (the old first read loaded the
    ///   whole file before the window to find one newline: 86 MB for a
    ///   long Claude session).
    /// "Earlier" always makes progress: a line longer than the window comes
    /// back whole rather than as nothing (which stalled "load earlier").
    nonisolated static let tailJumpFactor = 4
    nonisolated static let transcriptReaderPython = #"""
    import sys, os
    f, known, off, want, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    try:
        size = os.path.getsize(f)
    except OSError:
        sys.exit(0)
    want = max(want, 1)
    BLK = 1 << 16
    def line_start(fh, pos, limit):
        # Start of the line holding byte `pos`; None when it begins more
        # than `limit` bytes back (limit None: no bound).
        p = pos
        floor = 0 if limit is None else max(0, pos - limit)
        while p > floor:
            q = max(floor, p - BLK)
            fh.seek(q)
            b = fh.read(p - q)
            j = b.rfind(b'\n')
            if j >= 0:
                return q + j + 1
            p = q
        return 0 if floor == 0 else None
    def next_line(fh, pos, end):
        # Offset just past the first newline in [pos, end); None if none.
        p = pos
        while p < end:
            fh.seek(p)
            b = fh.read(min(BLK, end - p))
            if not b:
                break
            j = b.find(b'\n')
            if j >= 0:
                return p + j + 1
            p += len(b)
        return None
    def whole_end(fh, start, end):
        # Offset just past the last newline in [start, end); start if none.
        p = end
        while p > start:
            q = max(start, p - BLK)
            fh.seek(q)
            b = fh.read(p - q)
            j = b.rfind(b'\n')
            if j >= 0:
                return q + j + 1
            p = q
        return start
    with open(f, 'rb') as fh:
        if mode == 'earlier':
            end = min(max(off, 0), size)
            s0 = max(0, end - want)
            start = 0
            if s0 > 0:
                nx = next_line(fh, s0, end)
                start = nx if nx is not None and nx < end else line_start(fh, max(end - 1, 0), None)
        else:
            fresh = (f != known) or off < 0 or off > size or (size - off) > want * TAILJUMP
            if fresh:
                s0 = max(0, size - want)
                start = 0
                if s0 > 0:
                    ls = line_start(fh, s0, want)
                    if ls is not None:
                        start = ls
                    else:
                        we = whole_end(fh, s0, size)
                        nx = next_line(fh, s0, we)
                        start = nx if nx is not None and nx < we else line_start(fh, s0, None)
            else:
                start = off
            end = whole_end(fh, start, size)
        sys.stdout.write('%d\n%d\n%d\n' % (size, start, end))
        sys.stdout.flush()
        fh.seek(start)
        left = end - start
        while left > 0:
            b = fh.read(min(1 << 20, left))
            if not b:
                break
            sys.stdout.buffer.write(b)
            left -= len(b)
    """#.replacingOccurrences(of: "TAILJUMP", with: String(tailJumpFactor))

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The verify command's word for a checkout whose status can't be read.
    nonisolated static let treeUnknownWord = "TREEUNKNOWN"

    /// The guest command that tails a plan session's live agent transcript.
    /// The agent runs IN the task's configured directory, so the session
    /// store entry is derived from that path the way each tool encodes it;
    /// `since` (epoch seconds) skips transcripts of earlier sessions in the
    /// same directory. Output is capped so a long session stays cheap to
    /// poll. `agent` is a canonical `BromureIcons` agent kind — nil (or a
    /// tool without a known store) searches every store and takes the
    /// newest match, so a tab whose label hasn't resolved yet still reads.
    /// Nil return when the path has characters we won't quote.
    nonisolated static func planTranscriptCommand(guestCwd: String, since: Int,
                                                  agent: String? = nil,
                                                  pinnedWindow: Int? = nil,
                                                  pin: TranscriptPin) -> String? {
        guard let path = AgentSessionLocator.sanitized(guestCwd: guestCwd)
        else { return nil }
        var cmd = transcriptLocatePrefix(path: path, since: since, agent: agent,
                                         pinnedWindow: pinnedWindow, pin: pin)
        // iconv -c drops the orphan bytes a byte-cap cut can leave mid
        // UTF-8 sequence — a strict decode downstream used to collapse the
        // whole response.
        cmd += "if [ -n \"$f\" ]; then tail -c 300000 \"$f\" | iconv -f UTF-8 -t UTF-8 -c; fi; "
        if agent == nil || agent == "claude" {
            // The pq file is a PreToolUse hook's dump of a PENDING
            // AskUserQuestion (see the guest agent's _seed_question_hooks):
            // Claude Code doesn't write the assistant turn to the transcript
            // until the question is answered, so this is the only way the
            // window can show the question while it's actually being asked.
            // tr strips newlines so a pretty-printed dump still parses as one
            // transcript line. The pq name stays LOGICAL-path-encoded — the
            // hook derives it from $(pwd), which keeps the symlink.
            let enc2 = path.replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: "/", with: "-")
            let pq = "\"$HOME/.bromure/pq-\(enc2).json\""
            cmd += "if [ -n \"$(find \(pq) -newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null)\" ]; "
                + "then echo; tr -d '\\n' < \(pq); echo; fi"
        }
        return cmd
    }
}

// Typing into an agent's tab when it's free, through any machine's exec.
extension CodingTaskEngine {
    /// The same, through any machine's exec (an attached Mac's, say).
    static func typeWhenFree(exec: @escaping (String) async throws -> String, tabIndex: Int, text: String,
                             patience: TimeInterval = 600) async -> Bool {
        await typeWhenFreeResult(exec: exec, target: .index(tabIndex), text: text, patience: patience) == .typed
    }

    enum TypeResult: Equatable {
        case typed
        /// A menu or dialog stayed open.
        case menuOpen
        /// Someone else's text sat in the agent's input box.
        case draftInBox
        /// The guard refused: the window isn't the intended one any more, or
        /// no agent holds it. Nothing was typed; never retried.
        case refused(PaneRefusal)
    }



    /// The pane's bottom rows with their escapes, for `AgentInputBox`.
    nonisolated static func inputProbeCommand(tabIndex: Int) -> String {
        inputProbeCommand(target: .index(tabIndex))
    }

    nonisolated static func inputProbeCommand(target: PaneTarget) -> String {
        PaneTypeGuard.resolve(target)
            + "[ -n \"$_bt\" ] && tmux capture-pane -p -e -t \"$_bt\" 2>/dev/null | tail -n 30"
    }

    nonisolated static func cursorProbeCommand(target: PaneTarget) -> String {
        PaneTypeGuard.resolve(target)
            + "[ -n \"$_bt\" ] && { \(AgentInputBox.cursorProbeCommand(target: "\"$_bt\"")); }"
    }

    /// `typeWhenFree` with why it gave up. Never types onto text already
    /// in the agent's input box: our own message from an earlier try that
    /// held off before Enter just gets its Enter; anything else (a user's
    /// draft, a stray command) holds the text until the box is clear —
    /// concatenating the two would send neither as meant. A guard refusal
    /// (wrong window, a shell in the foreground) ends it at once.
    static func typeWhenFreeResult(exec: @escaping (String) async throws -> String, target: PaneTarget,
                                   text: String, patience: TimeInterval = 600) async -> TypeResult {
        let deadline = Date().addingTimeInterval(patience)
        var last: TypeResult = .menuOpen
        let label = "\(target.ref)"
        // Our text went in last round but its Enter never took: what the box
        // shows now is ours, however the agent drew it (omp's paste chip).
        var typedUnconfirmed = false
        var unconfirmedRounds = 0
        while true {
            let screen = (try? await exec(inputProbeCommand(target: target))) ?? ""
            var command: String? = nil   // nil: the guarded type (staged when long)
            var held = false
            var box = AgentInputBox.content(screen)
            if box == .unknown {
                // No ruled box: the terminal cursor's line (Kimi's prompt).
                let probe = (try? await exec(cursorProbeCommand(target: target))) ?? ""
                box = AgentInputBox.cursorContent(probe)
            }
            if case .text(let draft) = box {
                if typedUnconfirmed || AgentInputBox.isOwn(draft, of: text) {
                    BACDebug.log("type", "\(label): our text is already in the box — Enter only")
                    command = guardedEnterCommand(target: target)
                } else {
                    BACDebug.log("type", "held text for \(label): the input box has text in it")
                    held = true
                    last = .draftInBox
                }
            }
            if !held {
                var agentTarget = target
                agentTarget.foreground = .agent
                let run: String?
                if let command {
                    run = try? await exec(command)
                } else {
                    run = await PaneTypeGuard.runType(target: agentTarget, text: text) { try? await exec($0) }
                }
                guard let out = run else {
                    // The guest couldn't be asked: nothing is known typed.
                    last = .refused(.gone)
                    guard Date() < deadline else { return last }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                if let r = PaneTypeGuard.refusal(in: out) {
                    BACDebug.log("type", "REFUSED to type into \(label): \(r.rawValue)")
                    return .refused(r)
                }
                if PaneTypeGuard.typed(in: out) { return .typed }
                if PaneTypeGuard.unconfirmed(in: out) {
                    BACDebug.log("type", "\(label): the Enter didn't take — confirming again")
                    typedUnconfirmed = true
                    unconfirmedRounds += 1
                    last = .draftInBox
                    // Never Enter after Enter for long: twice more, then the
                    // caller says it wasn't delivered.
                    guard Date() < deadline, unconfirmedRounds < 3 else { return last }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                if out.contains(typeHeldMarker) {
                    BACDebug.log("type", "held text for \(label): a menu or dialog is open")
                    last = .menuOpen
                } else {
                    // Ran, but didn't go through (tmux refused it): try
                    // again — what did land is found in the box next time.
                    BACDebug.log("type", "typing into \(label) FAILED — retrying")
                    last = .refused(.gone)
                }
            }
            guard Date() < deadline else { return last }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Enter for text already in the box — unless a menu came up, or the
    /// window stopped being the intended agent's.
    nonisolated static func guardedEnterCommand(tabIndex: Int) -> String {
        guardedEnterCommand(target: .index(tabIndex))
    }

    nonisolated static func guardedEnterCommand(target: PaneTarget) -> String {
        PaneTypeGuard.prelude(target) + menuFunction + PaneTypeGuard.confirmFunctions
            + "if _bg; then if _bm; then echo \(typeHeldMarker); else \(PaneTypeGuard.confirmedEnter); fi; fi"
    }

    /// The user-facing reason a guarded send typed nothing.
    nonisolated static func refusalReason(_ r: PaneRefusal, worker: String) -> String {
        switch r {
        case .shell:
            return String(format: NSLocalizedString(
                "%@ isn't running in the task's session any more (only a shell is left), so nothing was typed — Restart Session to bring it back.",
                comment: "task send refused"), worker)
        case .identity, .gone, .agent:
            return String(format: NSLocalizedString(
                "The task's session tab is gone or now belongs to something else, so nothing was typed into it — Restart Session to bring %@ back.",
                comment: "task send refused"), worker)
        }
    }
}
