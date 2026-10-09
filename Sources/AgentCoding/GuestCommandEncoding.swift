import Foundation

/// Host → guest outbox command lines (`cmd-*.txt`, consumed by agentd's
/// `_dispatch_command`). The guest splits the argument part on whitespace
/// (`set -- $arg`), so every field must be exactly one non-empty token:
/// base64 has no spaces, but `base64("")` is the EMPTY string, which the
/// split drops — and every later field then shifts one slot left (a cleared
/// parent branch became the display name, the display the tool, …).
///
/// `arg(_:)` therefore encodes an empty value as the placeholder "-", which
/// is not base64 (agentd's `_b64d` maps it back to ""). Every positional
/// base64 field goes through it; raw keyword fields ("background",
/// "continue") are appended as-is.
enum GuestCommand {
    /// The placeholder holding an empty field's slot.
    static let emptyPlaceholder = "-"

    /// One positional field: base64 of `s`, or "-" when `s` is empty.
    static func arg(_ s: String) -> String {
        s.isEmpty ? emptyPlaceholder : Data(s.utf8).base64EncodedString()
    }

    /// The guest's decoding of one field (mirror of agentd's `_b64d`):
    /// "-" and undecodable tokens are "".
    static func decode(_ token: String) -> String {
        if token == emptyPlaceholder || token.isEmpty { return "" }
        guard let d = Data(base64Encoded: token) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The guest's field split (mirror of agentd's `_fields`): whitespace
    /// tokens, padded with "" to `n`.
    static func fields(_ line: String, _ n: Int) -> [String] {
        var f = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        while f.count < n { f.append("") }
        return f
    }

    /// Builds the outbox line for an automation/worktree verb (the action
    /// names `automationWorktreeCommand` takes). nil = unknown action or too
    /// few arguments.
    static func line(action: String, args: [String]) -> String? {
        let name: String
        var encoded: [String]
        switch action {
        case "create":
            guard args.count >= 4 else { return nil }   // cwd, slug, display, tool[, prompt[, background[, base[, flags]]]]
            name = "worktree-create"
            // Optional 6th, raw: "background" — the tab opens behind the
            // current one (a delegate's; the user is looking at its delegator).
            // Optional 7th: the branch to start from. Optional 8th: the
            // host's launch flags (the agent's role/autonomy flags — the same
            // a session in a plain folder gets).
            let base = args.count >= 7 ? args[6] : ""
            let flags = args.count >= 8 ? args[7] : ""
            encoded = args.prefix(4).map(arg) + [arg(args.count >= 5 ? args[4] : "")]
                + [args.count >= 6 && args[5] == "background" ? "background" : emptyPlaceholder]
                + (!base.isEmpty || !flags.isEmpty ? [arg(base)] : [])
                + (!flags.isEmpty ? [arg(flags)] : [])
        case "run":
            // Automation fire: same layout as "create", but the guest falls
            // back to a plain agent tab when cwd isn't a git repo. Optional
            // 6th arg: run mode ("task" wires the board MCP tools in,
            // "review" the findings tools). Optional 7th: the commit (or
            // origin/<branch>) the worktree starts from — a mode-less run
            // with a base holds the 6th slot with the placeholder.
            guard args.count >= 4 else { return nil }   // cwd, slug, display, tool[, prompt[, mode[, base]]]
            name = "automation-run"
            let mode = args.count >= 6 ? args[5] : ""
            let base = args.count >= 7 ? args[6] : ""
            encoded = args.prefix(4).map(arg) + [arg(args.count >= 5 ? args[4] : "")]
                + (!mode.isEmpty || !base.isEmpty ? [arg(mode)] : [])
                + (!base.isEmpty ? [arg(base)] : [])
        case "finish":
            guard args.count >= 1 else { return nil }   // worktree branch
            name = "automation-finish"; encoded = [arg(args[0])]
        case "task-resume":
            // Coding board review round: reopen the agent on an existing
            // worktree with a follow-up prompt.
            guard args.count >= 6 else { return nil }   // root, branch, parent, display, tool, prompt
            name = "task-resume"
            encoded = args.prefix(6).map(arg)
            // Optional 7th, raw: "continue" — the agent picks its own
            // conversation back up (the tool's resume flag) instead of
            // starting a new one (landing an approved task).
            if args.count >= 7, args[6] == "continue" { encoded.append("continue") }
        case "agent-tab":
            // Home-screen session: an interactive agent tab in a folder (no
            // worktree; the host's flags carry resume + autonomy).
            // cwd, display, tool, prompt[, flags[, background]].
            guard args.count >= 4 else { return nil }
            name = "agent-tab"
            let background = args.count >= 6 && args[5] == "background"
            let flags = args.count >= 5 ? args[4] : ""
            encoded = args.prefix(4).map(arg)
                + ((!flags.isEmpty || background) ? [arg(flags)] : [])
                + (background ? ["background"] : [])
        case "merge":
            // src, target, mainRoot, display, tool[, mode ("merge"/"squash")
            // [, autonomy ("ask"/"auto" — board merges commit without asking)]]
            guard args.count >= 5 else { return nil }
            name = "worktree-merge"; encoded = args.prefix(7).map(arg)
        case "pr":
            guard args.count >= 5 else { return nil }   // src, target, mainRoot, display, tool
            name = "worktree-pr"; encoded = args.prefix(5).map(arg)
        case "remove":
            guard args.count >= 2 else { return nil }   // mainRoot, branch
            name = "worktree-remove"; encoded = args.prefix(2).map(arg)
        case "resolve":
            guard args.count >= 2 else { return nil }   // dir, tool
            name = "worktree-resolve"; encoded = args.prefix(2).map(arg)
        case "terminal":
            guard args.count >= 2 else { return nil }   // mainRoot, branch
            name = "worktree-terminal"; encoded = args.prefix(2).map(arg)
        case "unregister":
            // Keep the checkout, stop reopening it at boot (an archived
            // branch session the user chose to keep).
            guard args.count >= 2 else { return nil }   // mainRoot, branch
            name = "worktree-unregister"; encoded = args.prefix(2).map(arg)
        default:
            return nil
        }
        return ([name] + encoded).joined(separator: " ")
    }
}
