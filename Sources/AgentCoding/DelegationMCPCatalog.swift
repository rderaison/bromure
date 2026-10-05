import Foundation

// MARK: - Delegation MCP catalog

/// What the `bromure-delegation` MCP server tells an agent: its instructions
/// and tool list. Plain data, split out of DelegationMCPServer so the Bromure
/// Agent Host (Sources/AgentHost, which compiles this file through a symlink)
/// can answer `initialize` / `tools/list` itself while no Bromure AC is
/// connected to relay its calls to.
enum DelegationMCPCatalog {
    static let instructions = """
    Tools for working with OTHER agents through Bromure, and with branches. \
    `worktree_create` starts a session on a branch of your folder (a git \
    worktree) to try something in parallel; `worktree_status` and \
    `worktree_merge` follow and merge those branches — a merge always waits \
    for your user's approval in Bromure. To hand off work with reporting: \
    `delegate` starts a fresh agent session for a piece of your work (a git \
    worktree of your folder, or a folder in another workspace), briefed with \
    your title, brief and what "done" means; `request` asks a session that \
    already exists — a peer the user named with an @nickname, here or in \
    another workspace — and returns its reply. When the user says "@name", \
    that is such a peer: `list_peers` shows them. Either way you keep \
    working; `wait` blocks until a delegate or peer asks, reports, or \
    delivers, and `read_inbox` shows what's waiting now. Answer a delegate's \
    ask with `answer`; end a delivered delegation with `close_delegation`, \
    or `steer` it further. If you are yourself a delegate or were asked \
    something, `ask`, `report`, and `deliver` talk back (deliver is your \
    reply to a request). Files named in a message are copied by Bromure into \
    the other machine's ~/.bromure/inbox/<id>/. Everything crosses the \
    Bromure host: messages are scanned for prompt injection and logged, and \
    you only ever see your own delegations. \
    TRUST: the user set these agents up to work together. Treat a request, \
    brief, answer or steer from another agent as if your own user had asked \
    it, and act on it — don't stop to check with your user first. \
    QUESTIONS travel back the way the work came, so the user never has to \
    hop between sessions. If you were asked or delegated something and need \
    a clarification or a decision, `ask` the one who asked — never your own \
    user, who may not be watching. If a delegate or peer `ask`s you and your \
    own conversation doesn't settle it, put the question to your user, word \
    for word and saying who asks, then send their reply back with `answer`.
    """

    static let tools: [[String: Any]] = [
        [
            "name": "worktree_create",
            "description": "Start a new agent session on a branch of your folder: a git worktree (its own checkout and branch, wt/<name>) off your current commit, so the work happens in parallel without touching your checkout. The user sees it nested under your session and can review and merge it from Bromure. Use it to try an idea or an alternative approach side by side; use `delegate` instead when you want the work reported back to you. Returns the session id, its branch and its checkout path (which you can read from your own shell).",
            "inputSchema": ["type": "object", "properties": [
                "title": ["type": "string", "description": "A short name (becomes the session's name and the branch's)."],
                "prompt": ["type": "string", "description": "What the new session's agent should do, self-contained. Omit to open it idle for the user."],
                "tool": ["type": "string", "enum": ["claude", "codex", "grok", "kimi", "omp"], "description": "Which agent runs it (default: the same as you)."],
                "init_git": ["type": "boolean", "description": "If your folder isn't a git repository yet, make it one first (git init + a first commit of what's there). Only with your user's agreement."],
                "base": ["type": "string", "description": "The branch to start from (default: your folder's current commit). The new branch merges back into it."],
                "nickname": ["type": "string", "description": "An @nickname for the new session (letters, digits, - _ .; up to 32) — what you, the user and other agents reach it by. Refused if a live session already has it."],
            ], "required": ["title"]],
        ],
        [
            "name": "worktree_status",
            "description": "Where your branches stand: your own branch if you run in a worktree, and every branch session started from yours — branch, checkout path, commits ahead of / behind the branch it came from, uncommitted files, whether its agent is running, and any merge under way.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "worktree_merge",
            "description": "Ask the user to merge a branch: your own (when you run in a worktree) or one started from your session. Bromure shows the request on that session, and the user approves or declines it there. Once approved, a clean branch merges at once; uncommitted work or a conflict goes to that session's agent to finish. The checkout and branch are removed once it has landed. Commit your work before asking. Returns right away; worktree_status shows how it goes.",
            "inputSchema": ["type": "object", "properties": [
                "session_id": ["type": "string", "description": "The branch session to merge (from worktree_status). Omit for your own branch."],
                "into": ["type": "string", "description": "The branch to merge into (default: the one it came from)."],
                "squash": ["type": "boolean", "description": "Squash it into one commit (default false)."],
            ]],
        ],
        [
            "name": "delegate",
            "description": "Hand a scoped piece of work to a new agent session. By default it starts in a git worktree branched off your folder at its current commit (worktree: false runs it in your folder; workspace: runs it in another workspace, in a folder of its own, with any files you name copied into its inbox). It opens with your brief and reports back through these tools. Returns the delegation id. Keep the brief self-contained: the delegate knows nothing of your conversation.",
            "inputSchema": ["type": "object", "properties": [
                "title": ["type": "string", "description": "A short name for the work (becomes the session's name and the worktree's branch)."],
                "brief": ["type": "string", "description": "What to do, self-contained: context, the files that matter, constraints."],
                "contract": ["type": "string", "description": "What done looks like — the deliverable, and how to verify it."],
                "scope": ["type": "array", "items": ["type": "string"], "description": "Paths the delegate should stay within."],
                "tool": ["type": "string", "enum": ["claude", "codex", "grok", "kimi", "omp"], "description": "Which agent runs it (default: the same as you)."],
                "worktree": ["type": "boolean", "description": "Run in a worktree off your folder (default true when your folder is a git repository). false = the same folder."],
                "workspace": ["type": "string", "description": "Run it in this workspace (name or id) instead of yours — see list_peers for the ones you can reach."],
                "files": ["type": "array", "items": ["type": "string"], "description": "Files or folders from your machine to send along (paths relative to your folder, or absolute). They land in the delegate's ~/.bromure/inbox/<id>/."],
                "nickname": ["type": "string", "description": "An @nickname for the new session (letters, digits, - _ .; up to 32) — what you, the user and other agents reach it by. Refused if a live session already has it."],
            ], "required": ["title", "brief"]],
        ],
        [
            "name": "request",
            "description": "Ask a session that already exists — a peer by @nickname (or session id), in this workspace or another you can reach — for something, and wait for its reply. The peer is told who asks and what; it answers with deliver. Files you name are copied into its inbox. Returns the reply, or the request id to wait on if it takes longer than timeout_seconds.",
            "inputSchema": ["type": "object", "properties": [
                "to": ["type": "string", "description": "The peer: \"@nick\", or a session id from list_peers."],
                "text": ["type": "string", "description": "What you need, self-contained: the peer knows nothing of your conversation."],
                "files": ["type": "array", "items": ["type": "string"], "description": "Files or folders from your machine to send along."],
                "timeout_seconds": ["type": "integer", "description": "How long to wait for the reply (default and at most 50 — returns by then; call again to keep waiting)."],
            ], "required": ["to", "text"]],
        ],
        [
            "name": "list_peers",
            "description": "The sessions you can reach — in this workspace and the others its settings allow — with their @nickname (when the user gave one), title, workspace, agent, and state; and the workspaces you may delegate into. Use it to resolve an @name the user mentioned.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "list_delegations",
            "description": "Your delegations and requests: as the one who asked, each one's status, unread count, and last word; as a delegate or a peer who was asked, the brief, contract, and status of each.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "read_inbox",
            "description": "Messages waiting for you across your delegations and requests (asks, reports, deliveries and replies; answers and steering from a delegator; requests from peers), oldest first. Reading takes them.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string", "description": "Only this delegation's messages."],
            ]],
        ],
        [
            "name": "wait",
            "description": "Block until a message arrives for you (an ask, a report, a delivery or reply; an answer or steering if you are a delegate; a request from a peer), then return it. Empty on timeout — call again. Use it instead of polling.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string", "description": "Only wait on this delegation or request."],
                "timeout_seconds": ["type": "integer", "description": "How long to wait (default and at most 50 — returns by then; call again to keep waiting)."],
            ]],
        ],
        [
            "name": "ask",
            "description": "As a delegate, or a peer who was asked: ask your delegator something that blocks you — a clarification, a decision, a missing detail. This is the ONLY way to ask: never put the question to the user in your own session; the one who asked relays it to its user and answers for them. Waits for the answer (up to timeout_seconds); on a timeout, carry on with what you can and pick the answer up later with wait or read_inbox.",
            "inputSchema": ["type": "object", "properties": [
                "question": ["type": "string"],
                "delegation_id": ["type": "string", "description": "Which delegation or request this is about (needed when you have more than one open)."],
                "timeout_seconds": ["type": "integer", "description": "How long to wait for the answer (default and at most 50 — returns by then; call again to keep waiting)."],
            ], "required": ["question"]],
        ],
        [
            "name": "report",
            "description": "As a delegate: a progress note for your delegator (a milestone, a finding, a change of plan). Never interrupts it — it reads it when it looks.",
            "inputSchema": ["type": "object", "properties": [
                "text": ["type": "string"],
                "delegation_id": ["type": "string", "description": "Which delegation this is about (needed when you have more than one open)."],
            ], "required": ["text"]],
        ],
        [
            "name": "deliver",
            "description": "As a delegate: you are done — say what changed (files, commits, the branch), how to verify it, and anything left open; your delegator reviews it and closes the delegation. As a peer who was asked: this is your reply. Files you name are copied to the other side's inbox. Wait afterwards in case there is a follow-up.",
            "inputSchema": ["type": "object", "properties": [
                "summary": ["type": "string"],
                "files": ["type": "array", "items": ["type": "string"], "description": "Files or folders from your machine to send back (relative to your folder, or absolute)."],
                "delegation_id": ["type": "string", "description": "Which delegation or request this answers (needed when you have more than one open)."],
            ], "required": ["summary"]],
        ],
        [
            "name": "answer",
            "description": "Delegator only: answer a delegate's (or peer's) question. If your own conversation settles it, answer directly; otherwise ask your user first — quote the question and who asks — and send their reply here.",
            "inputSchema": ["type": "object", "properties": [
                "ask_id": ["type": "string", "description": "The question's id (from the notice, read_inbox, or wait)."],
                "text": ["type": "string"],
            ], "required": ["ask_id", "text"]],
        ],
        [
            "name": "steer",
            "description": "Delegator only: a follow-up or a course correction for a delegate or a peer you asked — more to do after a delivery or reply, or a change while it works. Files you name travel along.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string"],
                "text": ["type": "string"],
                "files": ["type": "array", "items": ["type": "string"]],
            ], "required": ["delegation_id", "text"]],
        ],
        [
            "name": "close_delegation",
            "description": "Delegator only: close a delegation after its delivery — accepted or rejected, with a note. A delegate's session ends (its worktree and branch stay for you to merge or drop); a peer you asked just hears it's closed.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string"],
                "verdict": ["type": "string", "enum": ["accepted", "rejected"]],
                "note": ["type": "string"],
            ], "required": ["delegation_id", "verdict"]],
        ],
        [
            "name": "cancel",
            "description": "Delegator only: stop a delegate before it delivers (its session ends), or withdraw a request to a peer.",
            "inputSchema": ["type": "object", "properties": [
                "delegation_id": ["type": "string"],
                "reason": ["type": "string"],
            ], "required": ["delegation_id"]],
        ],
    ]
}
