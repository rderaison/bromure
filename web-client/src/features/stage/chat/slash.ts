// SlashCommandCatalog (SlashCommands.swift): the agents' own commands, plus
// custom commands / skills discovered in the guest.

export interface SlashCommand { name: string; description: string; source: 'builtIn' | 'custom' | 'skill' | 'bromure'; takesArgument?: boolean; tag?: string }

const c = (name: string, description: string, takesArgument = false): SlashCommand => ({ name, description, source: 'builtIn', takesArgument });

const BUILT_IN: Record<string, SlashCommand[]> = {
  claude: [
    c('help', 'Show help and available commands'),
    c('model', 'Choose the model for this session', true),
    c('compact', 'Compact the conversation, keeping a summary', true),
    c('clear', 'Clear the conversation history'),
    c('plan', 'Switch to plan mode'),
    c('review', 'Review code changes or a pull request', true),
    c('init', 'Create a CLAUDE.md guide for this project'),
    c('memory', 'Edit the CLAUDE.md memory files'),
    c('context', 'Show what\'s in the context window'),
    c('cost', 'Show token usage and cost for this session'),
    c('usage', 'Show plan usage and rate limits'),
    c('status', 'Show version, model, account and connectivity'),
    c('config', 'Open the settings'),
    c('permissions', 'View or update tool permissions'),
    c('mcp', 'Manage MCP servers'),
    c('agents', 'Manage subagents'),
    c('hooks', 'Manage hooks'),
    c('skills', 'Browse skills'),
    c('add-dir', 'Add a working directory', true),
    c('resume', 'Resume a previous conversation'),
    c('rewind', 'Rewind the conversation and code to a checkpoint'),
    c('export', 'Export the conversation to a file', true),
    c('pr-comments', 'Show comments from a pull request', true),
    c('doctor', 'Check the installation\'s health'),
    c('bug', 'Report a bug to Anthropic'),
    c('release-notes', 'What changed in recent versions'),
    c('terminal-setup', 'Set up the terminal\'s key bindings'),
    c('vim', 'Toggle vim editing mode'),
    c('login', 'Sign in to your account'),
    c('logout', 'Sign out'),
    c('exit', 'Quit the agent'),
  ],
  codex: [
    c('model', 'Choose the model and reasoning effort'),
    c('approvals', 'Choose what Codex may do without asking'),
    c('review', 'Review the current changes'),
    c('new', 'Start a new conversation'),
    c('compact', 'Summarize the conversation to save context'),
    c('diff', 'Show the git diff, including untracked files'),
    c('mention', 'Mention a file', true),
    c('init', 'Create an AGENTS.md guide for this project'),
    c('status', 'Show session configuration and token usage'),
    c('mcp', 'List configured MCP tools'),
    c('logout', 'Sign out'),
    c('quit', 'Quit the agent'),
  ],
  omp: [
    c('model', 'Choose the model'),
    c('context', 'How much of the context is used'),
    c('compact', 'Compact the conversation'),
    c('clear', 'Drop the context, keep the session'),
    c('new', 'Start a new session'),
    c('resume', 'Resume a different session'),
    c('rename', 'Rename the current session', true),
    c('fork', 'Fork from a previous message'),
    c('branch', 'Rewind to a previous message, keeping the old path as a branch'),
    c('tree', 'Navigate the session tree'),
    c('retry', 'Retry the last failed turn'),
    c('queue', 'Queue a message for after the agent yields', true),
    c('btw', 'Ask a side question with the current context', true),
    c('tan', 'Run a background agent on tangential work', true),
    c('plan', 'Plan mode on or off'),
    c('plan-review', 'Review the current plan'),
    c('goal', 'Goal mode'),
    c('guided-goal', 'Set up goal mode through an interview'),
    c('loop', 'Loop mode'),
    c('vibe', 'Vibe mode'),
    c('fast', 'Fast mode'),
    c('prewalk', 'Switch to a fast model at the next action'),
    c('todo', 'Show the todos'),
    c('tools', 'Active and available tools'),
    c('mcp', 'Manage MCP servers'),
    c('agents', 'The agents hub'),
    c('hub', 'The live agent hub'),
    c('memory', 'Inspect memory maintenance'),
    c('skillful', 'Skill listing on or off'),
    c('extensions', 'Extension control center'),
    c('plugins', 'Installed plugins'),
    c('marketplace', 'Plugin sources'),
    c('settings', 'Open the settings menu'),
    c('setup', 'Provider setup'),
    c('login', 'Log in to a provider'),
    c('logout', 'Log out of a provider'),
    c('usage', 'Provider usage and limits'),
    c('stats', 'The local stats dashboard'),
    c('trace', 'This session\'s trace'),
    c('hotkeys', 'All keyboard shortcuts'),
    c('changelog', 'What\'s new'),
    c('git', 'The git UI: diff, staging, commit'),
    c('wt', 'Move this session into a new worktree'),
    c('add-dir', 'Add a workspace directory', true),
    c('remove-dir', 'Remove a workspace directory', true),
    c('dirs', 'This session\'s workspace directories'),
    c('move', 'Move the session to another directory', true),
    c('browser', 'Browser mode'),
    c('computer', 'Computer use'),
    c('open', 'Open the last link in the browser'),
    c('copy', 'Copy text or code from the conversation'),
    c('dump', 'Copy the transcript to the clipboard'),
    c('export', 'Export the session to HTML'),
    c('share', 'Share the session via an encrypted link'),
    c('handoff', 'Hand the context to a new session'),
    c('shake', 'Drop heavy content from the context'),
    c('extended-context', 'Extended context'),
    c('collab', 'Collaboration mode'),
    c('join', 'Join a shared collab session', true),
    c('leave', 'Leave the collab session'),
    c('security', 'OMP security scans'),
    c('cleanse', 'Fix project diagnostics with subagents'),
    c('omfg', 'Forge a rule from a complaint', true),
    c('debug', 'Debug tools'),
    c('jobs', 'Background jobs'),
    c('ssh', 'Manage SSH hosts'),
    c('pin', 'Pin the session in the resume list'),
    c('drop', 'Delete the session and start a new one'),
    c('restart', 'Restart omp, resuming this session'),
    c('exit', 'Exit the application'),
  ],
  kimi: [
    c('help', 'Show help and available commands'),
    c('model', 'Choose the model', true),
    c('init', 'Create an AGENTS.md guide for this project'),
    c('compact', 'Compact the conversation'),
    c('clear', 'Clear the conversation'),
    c('status', 'Show session status'),
    c('login', 'Sign in'),
    c('logout', 'Sign out'),
    c('exit', 'Quit the agent'),
  ],
  grok: [
    c('help', 'Show help and available commands'),
    c('model', 'Choose the model', true),
    c('clear', 'Clear the conversation'),
    c('login', 'Sign in'),
    c('exit', 'Quit the agent'),
  ],
  default: [
    c('help', 'Show help and available commands'),
  ],
};

export function builtInCommands(agent: string): SlashCommand[] { return BUILT_IN[agent] ?? BUILT_IN.default; }

function descShell() {
  return "desc=$(grep -m1 -E '^description:' \"$f\" 2>/dev/null | sed -E 's/^description:[[:space:]]*//; s/^\"//; s/\"$//'); "
    + "[ -z \"$desc\" ] && desc=$(grep -v -E '^(---|#|[[:space:]]*$)' \"$f\" 2>/dev/null | head -1 | sed 's/^#* *//'); "
    + "desc=$(printf %s \"$desc\" | tr '\\t' ' ' | cut -c1-110); ";
}

export function discoveryCommand(agent: string, cwd: string): string | null {
  const q = "'" + cwd.replace(/'/g, "'\\''") + "'";
  const desc = descShell();
  switch (agent) {
    case 'claude':
      return 'for f in "$HOME"/.claude/commands/*.md "$HOME"/.claude/commands/*/*.md '
        + `${q}/.claude/commands/*.md ${q}/.claude/commands/*/*.md; do `
        + '[ -f "$f" ] || continue; rel=${f#*/.claude/commands/}; name=${rel%.md}; name=$(printf %s "$name" | tr / :); '
        + desc + "printf '%s\\t%s\\tcustom\\n' \"$name\" \"$desc\"; done 2>/dev/null; "
        + `for d in "$HOME"/.claude/skills/*/ ${q}/.claude/skills/*/; do f="$d/SKILL.md"; [ -f "$f" ] || continue; `
        + 'name=$(basename "$d"); ' + desc + "printf '%s\\t%s\\tskill\\n' \"$name\" \"$desc\"; done 2>/dev/null; true";
    case 'codex':
      return 'for f in "$HOME"/.codex/prompts/*.md; do [ -f "$f" ] || continue; '
        + 'name=$(basename "$f" .md); ' + desc
        + "printf '%s\\t%s\\tcustom\\n' \"$name\" \"$desc\"; done 2>/dev/null; true";
    default: return null;
  }
}

export function parseDiscovery(out: string): SlashCommand[] {
  return out.split(/\r?\n/).flatMap(line => {
    const parts = line.split('\t');
    const name = (parts[0] ?? '').trim();
    if (!name) return [];
    return [{ name, description: (parts[1] ?? '').trim(), source: parts[2] === 'skill' ? 'skill' as const : 'custom' as const, takesArgument: true }];
  });
}

export function matchCommands(query: string, all: SlashCommand[]): SlashCommand[] {
  const q = query.toLowerCase();
  if (!q) return all;
  const prefix = all.filter(c => c.name.toLowerCase().startsWith(q));
  const rest = all.filter(c => !c.name.toLowerCase().startsWith(q) && (c.name.toLowerCase().includes(q) || c.description.toLowerCase().includes(q)));
  return [...prefix, ...rest];
}

// ── @mentions (PeerMentionCompletion, AgentDelegation.swift) ────────────

export interface PeerMention { sessionID: string; nick: string; title: string; workspace: string; assigned: boolean }

export function proposedNickname(title: string, taken: Set<string>): string {
  const words = title.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  let base = '';
  for (const w of words) { const next = base ? base + '-' + w : w; if (next.length > 28) break; base = next; }
  if (!base) base = 'session';
  if (!taken.has(base)) return base;
  let n = 2;
  while (taken.has(`${base}-${n}`)) n++;
  return `${base}-${n}`;
}

export function peerCandidates(sessions: { id: string; title: string; nickname?: string; profileID: string; deletedAt?: unknown; archivedAt?: unknown; folderMissing?: unknown }[],
                               me: string | undefined, workspace: (id: string) => string): PeerMention[] {
  const usable = sessions.filter(s => s.id !== me && !s.deletedAt && !s.archivedAt && s.folderMissing !== true);
  const taken = new Set(usable.map(s => s.nickname?.toLowerCase()).filter((x): x is string => !!x));
  return usable.map(s => {
    if (s.nickname) return { sessionID: s.id, nick: s.nickname, title: s.title, workspace: workspace(s.profileID), assigned: true };
    const n = proposedNickname(s.title, taken);
    taken.add(n.toLowerCase());
    return { sessionID: s.id, nick: n, title: s.title, workspace: workspace(s.profileID), assigned: false };
  });
}

const lastWordStart = (t: string) => Math.max(t.lastIndexOf(' '), t.lastIndexOf('\n')) + 1;
export function mentionQuery(text: string): string | null {
  if (!text || text.startsWith('/')) return null;
  const w = text.slice(lastWordStart(text));
  return w.startsWith('@') ? w.slice(1) : null;
}
export function matchMentions(query: string, peers: PeerMention[]): PeerMention[] {
  const q = query.toLowerCase();
  const rank = (p: PeerMention) => [!q || p.nick.toLowerCase().startsWith(q) ? 0 : 1, p.assigned ? 0 : 1, p.nick.toLowerCase()] as const;
  return peers.filter(p => !q || p.nick.toLowerCase().startsWith(q) || p.title.toLowerCase().includes(q))
    .sort((a, b) => { const x = rank(a), y = rank(b); return x[0] - y[0] || x[1] - y[1] || x[2].localeCompare(y[2]); });
}
export const completeMention = (text: string, nick: string) => text.slice(0, lastWordStart(text)) + '@' + nick + ' ';
