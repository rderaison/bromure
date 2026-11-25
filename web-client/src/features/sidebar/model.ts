// The session list's logic, ported line for line from the Swift:
//   SessionBucket / SessionHome / SwitchboardGate / RoomTally (AgentSessions.swift),
//   the fat client's mirror of workspaces + VM rosters (FatClientController
//   applyWorkspaces / apply → SessionListModel.profileRows / entries, TabsModel.applyRoster),
//   CodingTasksSection / AutomationsSection status lines.
// Pure functions over the mirrored /state — no React here, so the stage, the
// room grid and the palette can import the same bucketing.

import type { RemoteState, AgentSession, AgentRoom, Workspace, VMInfo } from '../../core/remote/types';

// ── mirrored model (SessionListModel) ─────────────────────────────────────

export type RunState = 'running' | 'booting' | 'suspended' | 'off';
export type AgentStatus = 'working' | 'done' | 'needsInput';

export interface ProfileRow { id: string; name: string; accentHex: string; state: RunState; compromised: boolean; notes: string; native: boolean }
export interface MirrorTab { index: number; label: string; agentStatus: AgentStatus; active: boolean; cwd?: string; worktreeBranch?: string; parentBranch?: string; containerID?: string; isGitRepo?: boolean; rootRepo?: string; repoRoot?: string }
export interface VMEntry { id: string; name: string; accentHex: string; tabs: MirrorTab[]; rosterLive: boolean; ip?: string; unresponsive: boolean; vm: VMInfo }

export interface ListModel {
  rows: ProfileRow[];
  entries: VMEntry[];
  /** Agent-host (native) workspace ids. */
  machineIDs: Set<string>;
  switchboardAvailable: boolean;
  now: number;
}

function runState(s: unknown): RunState {
  switch (s) { case 'running': return 'running'; case 'booting': return 'booting'; case 'suspended': return 'suspended'; default: return 'off'; }
}

function agentStatus(s: unknown): AgentStatus {
  return s === 'working' ? 'working' : s === 'needsInput' ? 'needsInput' : 'done';
}

export function buildListModel(st: RemoteState | null | undefined, now = Date.now()): ListModel {
  const workspaces: Workspace[] = st?.workspaces ?? [];
  const isAgentHost = (st as any)?.hostKind === 'agent-host';
  const machineIDs = new Set(workspaces.filter(w => (w as any).hostKind === 'agent-host').map(w => w.id));
  const rows: ProfileRow[] = workspaces.map(w => ({
    id: w.id, name: w.name ?? '?', accentHex: w.accentHex ?? '#888888', state: runState(w.state),
    compromised: !!w.compromised, notes: (w.comments as string) ?? '', native: machineIDs.has(w.id),
  }));
  const entries: VMEntry[] = [];
  for (const vm of st?.vms ?? []) {
    if (typeof vm.kubeClusterID === 'string' && vm.kubeClusterID) continue;   // k8s node VMs aren't workspaces
    const tabs: MirrorTab[] = (vm.tabs ?? []).map((t: any, i: number) => ({
      index: typeof t.index === 'number' ? t.index : i,
      label: typeof t.title === 'string' ? t.title : 'shell',
      agentStatus: agentStatus(t.agentStatus), active: t.active === true,
      cwd: t.cwd, worktreeBranch: t.worktreeBranch, parentBranch: t.parentBranch, containerID: t.containerID,
      rootRepo: t.rootRepo, repoRoot: t.repoRoot,
      isGitRepo: t.isGitRepo ?? !!t.repoRoot,
    }));
    const ws = workspaces.find(w => w.id === vm.id);
    entries.push({
      id: vm.id, name: vm.name ?? ws?.name ?? '?', accentHex: (vm.accentHex as string) ?? ws?.accentHex ?? '#3B82F6',
      tabs, rosterLive: tabs.length > 0, ip: vm.ip || undefined, unresponsive: vm.guestUnresponsive === true, vm,
    });
  }
  return { rows, entries, machineIDs, switchboardAvailable: !isAgentHost, now };
}

// ── session predicates (AgentSession extension) ──────────────────────────

const t = (d: unknown) => (typeof d === 'string' && d ? Date.parse(d) : NaN);
const has = (d: unknown) => typeof d === 'string' && d.length > 0;

export const isSwitchboard = (s: AgentSession) => s.role === 'switchboard';
export const isLaunching = (s: AgentSession) => has(s.launchingSince);
export const hasEnded = (s: AgentSession) => has(s.endedAt) && s.windowIndex == null;
export const isArchived = (s: AgentSession) => has(s.archivedAt);
export const isDeleted = (s: AgentSession) => has(s.deletedAt);
export const isUnread = (s: AgentSession) => ((s.replies as number) ?? 0) > ((s.readReplies as number) ?? 0);
export const origin = (s: AgentSession): string | undefined => (s.parentSessionID as string) ?? (s.worktreeOf as string) ?? undefined;
export const isBranch = (s: AgentSession) => has(s.worktreeBranch);
const lastError = (s: AgentSession) => (s.lastError as string) ?? '';

export function guestPath(path: string): string {
  const home = '/home/ubuntu';
  const p = (path ?? '').trim();
  if (!p || p === '~') return home;
  if (p.startsWith('~/')) return home + p.slice(1);
  if (p.startsWith('/')) return p;
  return home + '/' + p;
}
export const hasFolder = (s: AgentSession) => guestPath(s.cwd ?? '~') !== guestPath('~');

export function branchNeedsWord(s: AgentSession) { return isBranch(s) && (s.branchMerge as any)?.phase !== 'merged'; }

export function branchSummary(s: AgentSession): string | null {
  const i = s.branchInfo as any;
  if (!i) return null;
  if (!(i.ahead > 0) && !(i.changed > 0)) return 'no changes yet';
  const parts: string[] = [];
  if (i.ahead > 0) parts.push(i.ahead === 1 ? '1 commit' : `${i.ahead} commits`);
  if (i.changed > 0) parts.push(i.changed === 1 ? '1 uncommitted file' : `${i.changed} uncommitted files`);
  if (i.behind > 0) parts.push(`${i.behind} behind`);
  return parts.join(' · ');
}

export function mergeLine(s: AgentSession): string | null {
  const m = s.branchMerge as any;
  if (!m) return null;
  switch (m.phase) {
    case 'requested': return `Asks to merge into ${m.target}`;
    case 'merging': return `Merging into ${m.target}…`;
    case 'conflicts': return `Merging into ${m.target} — the agent is finishing it`;
    case 'merged': return `Merged into ${m.target}`;
    default: return 'Merge stalled';
  }
}

export function mergeTint(s: AgentSession): string | null {
  switch ((s.branchMerge as any)?.phase) {
    case 'requested': case 'conflicts': return 'var(--orange)';
    case 'merging': return 'var(--accent)';
    case 'merged': return 'var(--green)';
    case 'failed': return 'var(--red)';
    case undefined: return null;
    default: return 'var(--red)';
  }
}

// ── SessionHome ───────────────────────────────────────────────────────────

export type Bucket = 'needsYou' | 'working' | 'idle' | 'asleep' | 'ended';
export const BUCKETS: Bucket[] = ['needsYou', 'working', 'idle', 'asleep', 'ended'];
const DEMO_BUCKETS: Bucket[] = BUCKETS;

export const bucketTitle: Record<Bucket, string> = { needsYou: 'Needs you', working: 'Working', idle: 'Ready', asleep: 'Paused', ended: 'Paused' };
export const bucketTint: Record<Bucket, string> = {
  needsYou: 'var(--red)', working: 'var(--orange)', idle: 'var(--green)', asleep: 'var(--label-secondary)', ended: 'var(--label-secondary)',
};

export function goneReason(s: AgentSession, m: ListModel): string | null {
  if (m.rows.length > 0 && !m.rows.some(r => r.id === s.profileID)) return 'Machine removed';
  if (s.folderMissing === true) {
    if ((s.branchMerge as any)?.phase === 'merged') return mergeLine(s);
    return 'Folder removed';
  }
  return null;
}
export const isGone = (s: AgentSession, m: ListModel) => goneReason(s, m) != null;

export function sessionEntry(profileID: string, m: ListModel) { return m.entries.find(e => e.id === profileID); }
export function rosterLive(profileID: string, m: ListModel) { return sessionEntry(profileID, m)?.rosterLive ?? false; }

export function liveTab(s: AgentSession, m: ListModel): MirrorTab | undefined {
  if (s.windowIndex == null) return undefined;
  const e = sessionEntry(s.profileID, m);
  if (!e || !e.rosterLive) return undefined;
  return e.tabs.find(tb => tb.index === s.windowIndex);
}
export function liveTabPosition(s: AgentSession, m: ListModel): number | undefined {
  if (s.windowIndex == null) return undefined;
  const e = sessionEntry(s.profileID, m);
  if (!e || !e.rosterLive) return undefined;
  const i = e.tabs.findIndex(tb => tb.index === s.windowIndex);
  return i >= 0 ? i : undefined;
}

const KNOWN_AGENTS = ['claude', 'codex', 'grok', 'kimi', 'omp', 'hermes', 'aider', 'goose', 'amp', 'opencode', 'gemini', 'cursor'];
const AGENT_ALIASES: Record<string, string> = { 'kimi-code': 'kimi', 'kimi-co': 'kimi' };

/** BromureIcons.agentKind(forLabel:) */
export function agentKind(label: string): string | null {
  const lower = label.toLowerCase().trim();
  if (lower.endsWith(')')) {
    const open = lower.lastIndexOf('(');
    if (open >= 0) {
      const marker = lower.slice(open + 1, -1);
      if (KNOWN_AGENTS.includes(marker)) return marker;
      if (AGENT_ALIASES[marker]) return AGENT_ALIASES[marker];
    }
  }
  const firstWord = lower.split(' ').filter(Boolean)[0] ?? lower;
  const base = firstWord.split('/').pop() ?? firstWord;
  const stem = base.split('.')[0] ?? base;
  if (KNOWN_AGENTS.includes(stem)) return stem;
  if (AGENT_ALIASES[stem]) return AGENT_ALIASES[stem];
  const words = new Set(lower.split(/[^\p{L}\p{N}]+/u).filter(Boolean));
  return KNOWN_AGENTS.find(a => words.has(a)) ?? null;
}

export function agentRunning(s: AgentSession, tab: MirrorTab): boolean {
  if (typeof s.agentAlive === 'boolean') return s.agentAlive;
  return agentKind(tab.label) != null;
}

export const isAgentLive = (s: AgentSession, m: ListModel) => { const tb = liveTab(s, m); return !!tb && agentRunning(s, tb); };

export function agentExited(s: AgentSession, m: ListModel): boolean {
  const tab = liveTab(s, m);
  if (!tab || agentRunning(s, tab)) return false;
  if (s.agentAlive !== false) return false;
  const started = Math.max(t(s.createdAt) || 0, t(s.resumedAt) || 0);
  const seen = t(s.agentSeenAt);
  if (!isNaN(seen) && seen >= started) return true;
  return (m.now - started) / 1000 > 300;
}

const STARTING_GRACE = 60;
export function isStartingUp(s: AgentSession, now: number): boolean {
  if (s.agentAlive != null) return false;
  const r = t(s.resumedAt);
  if (isNaN(r)) return false;
  return (now - r) / 1000 < STARTING_GRACE;
}

export function workspaceState(s: AgentSession, m: ListModel): RunState {
  return m.rows.find(r => r.id === s.profileID)?.state ?? 'off';
}

export function bucket(s: AgentSession, m: ListModel): Bucket {
  const demo = s.demoBucket;
  if (typeof demo === 'number' && DEMO_BUCKETS[demo]) return DEMO_BUCKETS[demo];
  if (isGone(s, m)) return 'ended';
  if (isLaunching(s)) return 'working';
  if (s.needsSignIn === true && !hasEnded(s) && liveTab(s, m)) return 'needsYou';
  if (hasEnded(s)) return lastError(s) && !isArchived(s) ? 'needsYou' : 'ended';
  const ws = workspaceState(s, m);
  if (ws !== 'running' && ws !== 'booting') return 'asleep';
  if (sessionEntry(s.profileID, m)?.unresponsive) return 'asleep';
  if (!rosterLive(s.profileID, m)) return 'asleep';
  const failedStart = !!lastError(s);
  const tab = liveTab(s, m);
  if (!tab) return failedStart ? 'needsYou' : 'ended';
  if (!agentRunning(s, tab)) {
    if (failedStart) return 'needsYou';
    return agentExited(s, m) ? 'ended' : 'working';
  }
  if (isStartingUp(s, m.now)) return 'working';
  if (s.providerError != null) return 'needsYou';
  switch (tab.agentStatus) {
    case 'needsInput': return 'needsYou';
    case 'working': return s.awaitingAnswer === true ? 'needsYou' : 'working';
    case 'done':
      if (s.transcriptWorking === true) return 'working';
      return s.awaitingAnswer === true ? 'needsYou' : 'idle';
  }
}

export function showsUnread(s: AgentSession, m: ListModel): boolean {
  if (!isUnread(s) || isArchived(s)) return false;
  const b = bucket(s, m);
  return b === 'idle' || b === 'needsYou' || b === 'asleep';
}

export function dotFor(b: Bucket): AgentStatus | null {
  return b === 'needsYou' ? 'needsInput' : b === 'working' ? 'working' : b === 'idle' ? 'done' : null;
}
export const dot = (s: AgentSession, m: ListModel) => dotFor(bucket(s, m));

export function lastActivity(s: AgentSession): number {
  return Math.max(t(s.createdAt) || 0, ...[s.activeAt, s.endedAt, s.resumedAt].map(t).filter(x => !isNaN(x)));
}

export function elapsedCompact(since: number, now: number): string {
  const sec = Math.max(0, Math.floor((now - since) / 1000));
  if (sec < 60) return 'now';
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  return `${Math.floor(sec / 86400)}d`;
}

export function rowWhen(s: AgentSession, m: ListModel): string | null {
  if (isLaunching(s)) return null;
  return elapsedCompact(bucket(s, m) === 'working' ? m.now : lastActivity(s), m.now);
}

export function statusLine(s: AgentSession, m: ListModel): string {
  if (isLaunching(s)) {
    switch (workspaceState(s, m)) {
      case 'off': case 'suspended': return 'Waking up…';
      case 'booting': return 'Almost there…';
      case 'running': return 'Starting…';
    }
  }
  const why = goneReason(s, m);
  if (why) return why;
  if (lastError(s)) return "Couldn't start";
  switch (bucket(s, m)) {
    case 'needsYou':
      if (s.needsSignIn === true) return 'Sign in needed';
      if (s.providerError == null && s.awaitingAnswer === true) return 'Asking you something';
      switch (s.providerError) {
        case 'generic': return 'Provider unreachable';
        case 'blocked': return 'Blocked by Bromure';
        case 'quota': return 'Usage limit reached';
        case 'auth': return 'Sign in needed';
        default: return 'Needs you';
      }
    case 'working': {
      const tab = liveTab(s, m);
      if (tab && (!agentRunning(s, tab) || isStartingUp(s, m.now))) return 'Starting…';
      return 'Working…';
    }
    case 'idle': return 'Ready';
    case 'asleep': {
      const ws = workspaceState(s, m);
      const attached = !!sessionEntry(s.profileID, m);
      if (ws === 'booting' || (ws === 'running' && attached)) return 'Waking up…';
      return 'Paused';
    }
    case 'ended': return isArchived(s) ? 'Archived' : 'Paused';
  }
}

export function folderEchoesTitle(folder: string, title: string): boolean {
  const squash = (x: string) => x.toLowerCase().replace(/[^\p{L}]/gu, '');
  const f = squash(folder), tt = squash(title);
  if (!f || !tt) return false;
  return f.startsWith(tt.slice(0, 12)) || tt.startsWith(f);
}

export function distinctTitle(s: AgentSession, among: AgentSession[], m: ListModel): string {
  const twins = among.filter(o => o.id !== s.id && o.title === s.title && !isDeleted(o));
  if (!twins.length) return s.title;
  if (s.nickname) return s.title + ' · @' + s.nickname;
  const folder = (s.cwd ?? '').split('/').filter(Boolean).pop() ?? '';
  if (folder && folder !== '~' && folder !== 'ubuntu' && !folderEchoesTitle(folder, s.title)) return s.title + ' · ' + folder;
  const ws = m.rows.find(r => r.id === s.profileID)?.name;
  if (ws && !twins.every(o => o.profileID === s.profileID)) return s.title + ' · ' + ws;
  const d = new Date(t(s.createdAt) || 0);
  return s.title + ' · ' + d.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function grouped(list: AgentSession[], m: ListModel): Map<Bucket, AgentSession[]> {
  const out = new Map<Bucket, AgentSession[]>();
  for (const s of list) { const b = bucket(s, m); out.set(b, [...(out.get(b) ?? []), s]); }
  return out;
}

/** Every session in sidebar order (archived/deleted/switchboards out; gone last). */
export function orderedAll(sessions: AgentSession[], m: ListModel): AgentSession[] {
  const live = sessions.filter(s => !isArchived(s) && !isDeleted(s) && !isSwitchboard(s));
  const groups = grouped(live.filter(s => !isGone(s, m)), m);
  const gone = live.filter(s => isGone(s, m)).sort((a, b) => lastActivity(b) - lastActivity(a));
  return [...BUCKETS.flatMap(b => groups.get(b) ?? []), ...gone];
}

export function archivedSessions(sessions: AgentSession[]): AgentSession[] {
  return sessions.filter(s => isArchived(s) && !isDeleted(s) && !isSwitchboard(s))
    .sort((a, b) => (t(b.archivedAt) || 0) - (t(a.archivedAt) || 0));
}

/** SessionSectionsView.nested — each delegate right under its delegator. */
export function nested(list: AgentSession[]): { session: AgentSession; depth: number }[] {
  const ids = new Set(list.map(s => s.id));
  const out: { session: AgentSession; depth: number }[] = [];
  const seen = new Set<string>();
  const walk = (s: AgentSession, depth: number) => {
    if (seen.has(s.id)) return;
    seen.add(s.id); out.push({ session: s, depth });
    for (const c of list) if (origin(c) === s.id) walk(c, depth + 1);
  };
  for (const s of list) { const o = origin(s); if (!o || !ids.has(o)) walk(s, 0); }
  for (const s of list) if (!seen.has(s.id)) walk(s, 0);
  return out;
}

export const roomArchived = (r: AgentRoom) => has(r.archivedAt);

/** SessionHome.sidebarOrder — what ⌘1–9 number. */
export function sidebarOrder(sessions: AgentSession[], rooms: AgentRoom[], m: ListModel): AgentSession[] {
  const list = orderedAll(sessions, m);
  const live = rooms.filter(r => !roomArchived(r));
  const roomIDs = new Set(live.map(r => r.id));
  const out: AgentSession[] = [];
  for (const r of live) out.push(...nested(list.filter(s => s.roomID === r.id)).map(x => x.session));
  const loose = list.filter(s => !s.roomID || !roomIDs.has(s.roomID));
  for (const b of BUCKETS) if (b !== 'ended') out.push(...nested(loose.filter(s => bucket(s, m) === b)).map(x => x.session));
  return out;
}

/** The session the window opens on (SessionHome.initialSession). */
export function initialSession(sessions: AgentSession[], m: ListModel): AgentSession | undefined {
  const groups = grouped(sessions.filter(s => !isArchived(s) && !isDeleted(s) && !isSwitchboard(s)), m);
  for (const b of BUCKETS) { const g = groups.get(b); if (g?.length) return g[0]; }
  return undefined;
}

// ── SwitchboardGate / RoomTally ──────────────────────────────────────────

export const globalSwitchboard = (sessions: AgentSession[]) => sessions.find(s => isSwitchboard(s) && !isDeleted(s) && !s.roomID);

export function switchboardVisible(sessions: AgentSession[], m: ListModel): boolean {
  if (!m.switchboardAvailable) return false;
  if (globalSwitchboard(sessions)) return true;
  return sessions.some(s => !isSwitchboard(s) && !isArchived(s) && !isDeleted(s));
}

export const SWITCHBOARD_IDLE = 'Keeps track of your sessions';
export function switchboardSummary(sessions: AgentSession[], m: ListModel): string {
  const counts: Partial<Record<Bucket, number>> = {};
  for (const s of sessions) if (!isSwitchboard(s) && !isArchived(s) && !isDeleted(s)) { const b = bucket(s, m); counts[b] = (counts[b] ?? 0) + 1; }
  const parts: string[] = [];
  if (counts.needsYou) parts.push(`${counts.needsYou} need you`);
  if (counts.working) parts.push(`${counts.working} working`);
  if (counts.idle) parts.push(`${counts.idle} ready`);
  return parts.length ? parts.join(' · ') : SWITCHBOARD_IDLE;
}

export function roomMembers(r: AgentRoom, sessions: AgentSession[]) {
  return sessions.filter(s => s.roomID === r.id && !isSwitchboard(s) && !isDeleted(s) && (roomArchived(r) || !isArchived(s)));
}
export function roomSummary(r: AgentRoom, sessions: AgentSession[], m: ListModel): string {
  const list = roomMembers(r, sessions);
  if (!list.length) return 'Empty — drag sessions here';
  const active = switchboardSummary(list, m);
  if (active !== SWITCHBOARD_IDLE) return active;
  return list.length === 1 ? '1 session' : `${list.length} sessions`;
}
export function roomDot(r: AgentRoom, sessions: AgentSession[], m: ListModel): AgentStatus | null {
  const bs = roomMembers(r, sessions).map(s => bucket(s, m));
  if (bs.includes('needsYou')) return 'needsInput';
  if (bs.includes('working')) return 'working';
  if (bs.includes('idle')) return 'done';
  return null;
}

export const ROOM_PALETTE = ['#6366F1', '#10B981', '#F59E0B', '#EC4899', '#06B6D4', '#8B5CF6', '#EF4444', '#84CC16'];
export const ROOM_COLOR_NAMES: Record<string, string> = {
  '#6366F1': 'Indigo', '#10B981': 'Green', '#F59E0B': 'Amber', '#EC4899': 'Pink', '#06B6D4': 'Cyan', '#8B5CF6': 'Violet', '#EF4444': 'Red', '#84CC16': 'Lime',
};

export function normalizeNickname(raw: string): string | null {
  let s = raw.trim();
  while (s.startsWith('@')) s = s.slice(1);
  const allowed = [...s].filter(c => /[\p{L}\p{N}._-]/u.test(c)).join('');
  return allowed ? [...allowed].slice(0, 32).join('') : null;
}

export type NickVerdict = { kind: 'ok' } | { kind: 'refused'; why: string } | { kind: 'reclaim'; question: string };
export function checkNickname(id: string, raw: string, sessions: AgentSession[]): NickVerdict {
  const nick = normalizeNickname(raw);
  if (!nick) return { kind: 'ok' };
  const other = sessions.find(o => o.id !== id && !isDeleted(o) && (o.nickname ?? '').toLowerCase() === nick.toLowerCase());
  if (!other) return { kind: 'ok' };
  if (!isArchived(other)) return { kind: 'refused', why: `@${nick} is already “${other.title}”.` };
  const when = new Date(t(other.lastSeenAt) || t(other.createdAt) || 0).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  return { kind: 'reclaim', question: `@${nick} was used by archived session “${other.title}”, last on ${when}. Reuse it for this session?` };
}

// ── Coding Tasks / Automations sections ──────────────────────────────────

export function tasksSummary(st: RemoteState | null | undefined, sessions: AgentSession[], m: ListModel) {
  const tasks: any[] = st?.tasks?.tasks ?? [];
  const inStage = (stage: string) => tasks.filter(x => x.stage === stage);
  const backlog = tasks.filter(x => x.stage === 'backlog' && !(x.validatedAt && tasks.some(o => o.parentTaskID === x.id)));
  const planning = inStage('planning').length, running = inStage('inProgress').length, review = inStage('testing').length;
  const parts: string[] = [];
  if (planning > 0) parts.push(`${planning} planned`);
  if (running > 0) parts.push(`${running} in progress`);
  if (review > 0) parts.push(`${review} to review`);
  if (!parts.length) parts.push(backlog.length > 0 ? `${backlog.length} in backlog` : 'No open tasks');
  const attention = inStage('inProgress').filter(task => taskBucket(task, sessions, m) === 'needsYou').length;
  return { line: parts.join(' · '), openCount: backlog.length + planning + running + review, reviewCount: review, attention };
}

/** AutomationBoard.branchMatches */
export function branchMatches(branch: string | undefined | null, slug: string): boolean {
  if (!branch || !branch.startsWith('wt/')) return false;
  const part = branch.slice(3);
  return part === slug || (part.startsWith(slug + '-') && /^-?\d+$/.test(part.slice(slug.length + 1)));
}

function taskBucket(task: any, sessions: AgentSession[], m: ListModel): Bucket | null {
  if (task.sessionID) {
    const s = sessions.find(x => x.id === task.sessionID);
    if (s && !isDeleted(s) && !isArchived(s) && s.windowIndex != null && s.profileID === task.profileID) return bucket(s, m);
  }
  const slugs = [task.branchSlug, typeof task.branch === 'string' ? task.branch.slice(3) : undefined].filter(Boolean) as string[];
  if (!slugs.length) return null;
  const tabs = m.entries.find(e => e.id === task.profileID)?.tabs ?? [];
  const tab = tabs.find(tb => slugs.some(sl => branchMatches(tb.worktreeBranch, sl)));
  if (!tab) return null;
  return tab.agentStatus === 'needsInput' ? 'needsYou' : tab.agentStatus === 'working' ? 'working' : 'idle';
}

export function automationsSummary(st: RemoteState | null | undefined, m: ListModel) {
  const a = st?.automations;
  const autos: any[] = a?.automations ?? [];
  const runs: any[] = a?.runs ?? [];
  const liveRuns: AgentStatus[] = [];
  for (const run of runs) {
    if (run.outcome !== 'launched' || run.completedAt || !run.branchSlug) continue;
    const pid = run.runProfileID ?? autos.find(x => x.id === run.automationID)?.profileID;
    const entry = m.entries.find(e => e.id === pid);
    if (!entry) continue;
    const tab = entry.tabs.find(tb => branchMatches(tb.worktreeBranch, run.branchSlug));
    if (tab) liveRuns.push(tab.agentStatus);
  }
  const parked = runs.filter(r => (r.outcome === 'failed' || r.outcome === 'blocked') && !r.acknowledgedAt).length;
  const attention = parked + liveRuns.filter(x => x === 'needsInput').length;
  const parts: string[] = [];
  if (liveRuns.length > 0) parts.push(`${liveRuns.length} running`);
  const fires = autos.filter(x => x.enabled).map(x => t(a?.nextFires?.[x.id])).filter(x => !isNaN(x));
  if (fires.length) {
    const next = new Date(Math.min(...fires));
    const day = next.toLocaleDateString('en-US', { weekday: 'short' });
    const hm = `${String(next.getHours()).padStart(2, '0')}:${String(next.getMinutes()).padStart(2, '0')}`;
    let zone = '';
    const hostZone = a?.timeZone;
    const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (hostZone && hostZone !== localZone && tzOffset(hostZone, next) !== tzOffset(localZone, next)) {
      zone = ' ' + (new Intl.DateTimeFormat('en-US', { timeZoneName: 'short' }).formatToParts(next).find(p => p.type === 'timeZoneName')?.value ?? '');
    }
    parts.push(`next ${day} ${hm}${zone}`);
  }
  const line = parts.length ? parts.join(' · ') : autos.length === 0 ? 'No automations yet' : 'Open Automations';
  const openFindings = (a?.findings ?? []).filter((f: any) => f.status === 'new').length;
  return { line, count: autos.length, attention, openFindings };
}

function tzOffset(zone: string, at: Date): number {
  try {
    const p = new Intl.DateTimeFormat('en-US', { timeZone: zone, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).formatToParts(at);
    const g = (k: string) => +(p.find(x => x.type === k)?.value ?? 0);
    return Date.UTC(g('year'), g('month') - 1, g('day'), g('hour') % 24, g('minute')) - at.getTime();
  } catch { return 0; }
}
