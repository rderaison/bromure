import SwiftUI

// MARK: - Slash commands
//
// Every agent has slash commands ("/model", "/compact", …) plus whatever the
// user added themselves (Claude's custom commands and skills, Codex's saved
// prompts). The chat's composer surfaces them: type "/" and a palette floats
// up above the box — filter as you type, ↑↓ to move, ⇥ to complete, ↩ to
// send. The catalog below is the built-in set per agent; discovery reads the
// custom ones from the workspace.

struct SlashCommand: Identifiable, Hashable {
    enum Source: String { case builtIn, custom, skill }
    let name: String            // without the leading "/"
    let description: String
    let source: Source
    /// The command expects text after it ("/model opus") — completion
    /// leaves a space so the user keeps typing.
    var takesArgument = false
    /// A tag of the row's own, shown instead of the source's ("new name"
    /// on a session the @ palette would nickname on the spot).
    var tag: String? = nil
    var id: String { source.rawValue + ":" + name }
}

extension PeerMentionCompletion {
    /// Matching sessions as rows of the "@" palette (a session the pick would
    /// nickname on the spot is tagged "new name").
    static func paletteRows(_ query: String, in peers: [PeerMention]) -> [SlashCommand] {
        matches(query, in: peers).map { p in
            var c = SlashCommand(name: p.nick,
                                 description: p.title + (p.workspace.isEmpty ? "" : " · " + p.workspace),
                                 source: .builtIn)
            if !p.assigned { c.tag = NSLocalizedString("new name", comment: "mention palette tag") }
            return c
        }
    }
}

enum SlashCommandCatalog {
    /// The built-in commands of an agent, in the order its own /help lists
    /// them (roughly: everyday first).
    static func builtIn(for agent: String) -> [SlashCommand] {
        func c(_ n: String, _ d: String, arg: Bool = false) -> SlashCommand {
            SlashCommand(name: n, description: d, source: .builtIn, takesArgument: arg)
        }
        switch agent {
        case "claude":
            return [
                c("help", "Show help and available commands"),
                c("model", "Choose the model for this session", arg: true),
                c("compact", "Compact the conversation, keeping a summary", arg: true),
                c("clear", "Clear the conversation history"),
                c("plan", "Switch to plan mode"),
                c("review", "Review code changes or a pull request", arg: true),
                c("init", "Create a CLAUDE.md guide for this project"),
                c("memory", "Edit the CLAUDE.md memory files"),
                c("context", "Show what's in the context window"),
                c("cost", "Show token usage and cost for this session"),
                c("usage", "Show plan usage and rate limits"),
                c("status", "Show version, model, account and connectivity"),
                c("config", "Open the settings"),
                c("permissions", "View or update tool permissions"),
                c("mcp", "Manage MCP servers"),
                c("agents", "Manage subagents"),
                c("hooks", "Manage hooks"),
                c("skills", "Browse skills"),
                c("add-dir", "Add a working directory", arg: true),
                c("resume", "Resume a previous conversation"),
                c("rewind", "Rewind the conversation and code to a checkpoint"),
                c("export", "Export the conversation to a file", arg: true),
                c("pr-comments", "Show comments from a pull request", arg: true),
                c("doctor", "Check the installation's health"),
                c("bug", "Report a bug to Anthropic"),
                c("release-notes", "What changed in recent versions"),
                c("terminal-setup", "Set up the terminal's key bindings"),
                c("vim", "Toggle vim editing mode"),
                c("login", "Sign in to your account"),
                c("logout", "Sign out"),
                c("exit", "Quit the agent"),
            ]
        case "codex":
            return [
                c("model", "Choose the model and reasoning effort"),
                c("approvals", "Choose what Codex may do without asking"),
                c("review", "Review the current changes"),
                c("new", "Start a new conversation"),
                c("compact", "Summarize the conversation to save context"),
                c("diff", "Show the git diff, including untracked files"),
                c("mention", "Mention a file", arg: true),
                c("init", "Create an AGENTS.md guide for this project"),
                c("status", "Show session configuration and token usage"),
                c("mcp", "List configured MCP tools"),
                c("logout", "Sign out"),
                c("quit", "Quit the agent"),
            ]
        case "omp":
            // Oh My Pi 18 — the names its "/" popup offers (Return runs the
            // highlighted fuzzy match, so only real names belong here).
            return [
                c("model", "Choose the model"),
                c("context", "How much of the context is used"),
                c("compact", "Compact the conversation"),
                c("clear", "Drop the context, keep the session"),
                c("new", "Start a new session"),
                c("resume", "Resume a different session"),
                c("rename", "Rename the current session", arg: true),
                c("fork", "Fork from a previous message"),
                c("branch", "Rewind to a previous message, keeping the old path as a branch"),
                c("tree", "Navigate the session tree"),
                c("retry", "Retry the last failed turn"),
                c("queue", "Queue a message for after the agent yields", arg: true),
                c("btw", "Ask a side question with the current context", arg: true),
                c("tan", "Run a background agent on tangential work", arg: true),
                c("plan", "Plan mode on or off"),
                c("plan-review", "Review the current plan"),
                c("goal", "Goal mode"),
                c("guided-goal", "Set up goal mode through an interview"),
                c("loop", "Loop mode"),
                c("vibe", "Vibe mode"),
                c("fast", "Fast mode"),
                c("prewalk", "Switch to a fast model at the next action"),
                c("todo", "Show the todos"),
                c("tools", "Active and available tools"),
                c("mcp", "Manage MCP servers"),
                c("agents", "The agents hub"),
                c("hub", "The live agent hub"),
                c("memory", "Inspect memory maintenance"),
                c("skillful", "Skill listing on or off"),
                c("extensions", "Extension control center"),
                c("plugins", "Installed plugins"),
                c("marketplace", "Plugin sources"),
                c("settings", "Open the settings menu"),
                c("setup", "Provider setup"),
                c("login", "Log in to a provider"),
                c("logout", "Log out of a provider"),
                c("usage", "Provider usage and limits"),
                c("stats", "The local stats dashboard"),
                c("trace", "This session's trace"),
                c("hotkeys", "All keyboard shortcuts"),
                c("changelog", "What's new"),
                c("git", "The git UI: diff, staging, commit"),
                c("wt", "Move this session into a new worktree"),
                c("add-dir", "Add a workspace directory", arg: true),
                c("remove-dir", "Remove a workspace directory", arg: true),
                c("dirs", "This session's workspace directories"),
                c("move", "Move the session to another directory", arg: true),
                c("browser", "Browser mode"),
                c("computer", "Computer use"),
                c("open", "Open the last link in the browser"),
                c("copy", "Copy text or code from the conversation"),
                c("dump", "Copy the transcript to the clipboard"),
                c("export", "Export the session to HTML"),
                c("share", "Share the session via an encrypted link"),
                c("handoff", "Hand the context to a new session"),
                c("shake", "Drop heavy content from the context"),
                c("extended-context", "Extended context"),
                c("collab", "Collaboration mode"),
                c("join", "Join a shared collab session", arg: true),
                c("leave", "Leave the collab session"),
                c("security", "OMP security scans"),
                c("cleanse", "Fix project diagnostics with subagents"),
                c("omfg", "Forge a rule from a complaint", arg: true),
                c("debug", "Debug tools"),
                c("jobs", "Background jobs"),
                c("ssh", "Manage SSH hosts"),
                c("pin", "Pin the session in the resume list"),
                c("drop", "Delete the session and start a new one"),
                c("restart", "Restart omp, resuming this session"),
                c("exit", "Exit the application"),
            ]
        case "kimi":
            return [
                c("help", "Show help and available commands"),
                c("model", "Choose the model", arg: true),
                c("init", "Create an AGENTS.md guide for this project"),
                c("compact", "Compact the conversation"),
                c("clear", "Clear the conversation"),
                c("status", "Show session status"),
                c("login", "Sign in"),
                c("logout", "Sign out"),
                c("exit", "Quit the agent"),
            ]
        case "grok":
            return [
                c("help", "Show help and available commands"),
                c("model", "Choose the model", arg: true),
                c("clear", "Clear the conversation"),
                c("login", "Sign in"),
                c("exit", "Quit the agent"),
            ]
        default:
            return [c("help", "Show help and available commands")]
        }
    }

    /// The guest shell command that lists the user's own commands for an
    /// agent — one line per command: `name<TAB>description<TAB>source`. nil
    /// when the agent has no such thing we know of.
    static func discoveryCommand(agent: String, cwd: String) -> String? {
        let q = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // description: from the frontmatter when there is one, else the first
        // line of prose (never the "---" fence or a heading marker).
        let desc = "desc=$(grep -m1 -E '^description:' \"$f\" 2>/dev/null | sed -E 's/^description:[[:space:]]*//; s/^\"//; s/\"$//'); "
            + "[ -z \"$desc\" ] && desc=$(grep -v -E '^(---|#|[[:space:]]*$)' \"$f\" 2>/dev/null | head -1 | sed 's/^#* *//'); "
            + "desc=$(printf %s \"$desc\" | tr '\\t' ' ' | cut -c1-110); "
        switch agent {
        case "claude":
            return "for f in \"$HOME\"/.claude/commands/*.md \"$HOME\"/.claude/commands/*/*.md "
                + "\(q)/.claude/commands/*.md \(q)/.claude/commands/*/*.md; do "
                + "[ -f \"$f\" ] || continue; rel=${f#*/.claude/commands/}; name=${rel%.md}; name=$(printf %s \"$name\" | tr / :); "
                + desc + "printf '%s\\t%s\\tcustom\\n' \"$name\" \"$desc\"; done 2>/dev/null; "
                + "for d in \"$HOME\"/.claude/skills/*/ \(q)/.claude/skills/*/; do f=\"$d/SKILL.md\"; [ -f \"$f\" ] || continue; "
                + "name=$(basename \"$d\"); " + desc + "printf '%s\\t%s\\tskill\\n' \"$name\" \"$desc\"; done 2>/dev/null; true"
        case "codex":
            return "for f in \"$HOME\"/.codex/prompts/*.md; do [ -f \"$f\" ] || continue; "
                + "name=$(basename \"$f\" .md); " + desc
                + "printf '%s\\t%s\\tcustom\\n' \"$name\" \"$desc\"; done 2>/dev/null; true"
        default:
            return nil
        }
    }

    static func parseDiscovery(_ out: String) -> [SlashCommand] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 1 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let description = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let source: SlashCommand.Source = parts.count > 2 && parts[2] == "skill" ? .skill : .custom
            return SlashCommand(name: name, description: description, source: source, takesArgument: true)
        }
    }

    /// Filter + rank for a typed prefix: name prefix matches first (in
    /// catalog order), then anything that mentions the text.
    static func matches(_ query: String, in all: [SlashCommand]) -> [SlashCommand] {
        let q = query.lowercased()
        if q.isEmpty { return all }
        let prefix = all.filter { $0.name.lowercased().hasPrefix(q) }
        let rest = all.filter {
            !$0.name.lowercased().hasPrefix(q)
                && ($0.name.lowercased().contains(q) || $0.description.lowercased().contains(q))
        }
        return prefix + rest
    }
}

// MARK: - Palette

/// The floating list above the composer. Rows are the matches for what's
/// typed; one is highlighted (keyboard) and any can be clicked.
struct SlashCommandPalette: View {
    let commands: [SlashCommand]
    let agentName: String
    let highlighted: Int
    let onPick: (SlashCommand) -> Void
    let onHover: (Int) -> Void
    /// What each entry starts with: "/" for commands, "@" for sessions.
    var prefix = "/"
    /// The header, when it isn't "Commands".
    var title: String? = nil

    private static let rowHeight: CGFloat = 36
    private static let visibleRows = 7

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title ?? NSLocalizedString("Commands", comment: "slash palette"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("·").foregroundStyle(.tertiary)
                Text(agentName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(commands.count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { i, c in
                            row(c, selected: i == highlighted)
                                .id(c.id)
                                .onTapGesture { onPick(c) }
                                .onHover { if $0 { onHover(i) } }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: Self.rowHeight * CGFloat(min(Self.visibleRows, max(1, commands.count))) + 12)
                .onChange(of: highlighted) { _, i in
                    if commands.indices.contains(i) {
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(commands[i].id, anchor: .center) }
                    }
                }
            }

            Divider().opacity(0.5)
            HStack(spacing: 12) {
                hint("↑↓", NSLocalizedString("move", comment: "slash palette"))
                hint("⇥", NSLocalizedString("complete", comment: "slash palette"))
                hint("↩", NSLocalizedString("send", comment: "slash palette"))
                hint("esc", NSLocalizedString("close", comment: "slash palette"))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
    }

    private func row(_ c: SlashCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(prefix + c.name)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .lineLimit(1)
                .fixedSize()
            Text(c.description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let tag = c.tag {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            } else if c.source != .builtIn {
                Text(c.source == .skill
                     ? NSLocalizedString("skill", comment: "slash palette tag")
                     : NSLocalizedString("yours", comment: "slash palette tag"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            Text(what).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
}
