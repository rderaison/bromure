// Coding tasks + automations: the wire shapes (CodingTask, ScheduledAutomation,
// AutomationRunRecord as AutomationServer encodes them) and the pure logic the
// Swift keeps beside its views — the board's buckets, the describer's words,
// the dates. Everything tolerates missing fields (older servers).

import type { RemoteState, AgentSession, Workspace } from '../../core/remote/types';

// ── Tasks ──────────────────────────────────────────────────────────────────

export type Stage = 'backlog' | 'planning' | 'inProgress' | 'testing' | 'done';
export interface Assignment { kind: 'worktree' | 'session' | 'room' | 'switchboard'; id: string; label: string }
export interface TaskComment { id: string; text: string; file?: string; line?: number; createdAt?: string; sentAt?: string; undelivered?: boolean }
export interface Landing { mode: 'merge' | 'squash' | 'pr'; target: string; phase: 'checking' | 'fastMerging' | 'agentLanding' | 'needsYou' | 'landed'; detail?: string; agentLine?: string; handingOver?: boolean; startedAt?: string }

export interface CodingTask {
  id: string; title: string; details: string; stage: Stage;
  profileID: string; repoPath: string; tool: string;
  branch?: string; branchSlug?: string; worktreeDir?: string; parentBranch?: string; rootRepo?: string;
  comments: TaskComment[];
  createdAt: string; createdAtExact?: number; updatedAt?: string; startedAt?: string; testingAt?: string; completedAt?: string;
  startingAt?: string; queuedAt?: string;
  merged?: boolean; prOpened?: boolean; pullRequestURL?: string; completion?: any;
  parentTaskID?: string; dependsOn?: string[]; queueRank?: number;
  lastError?: string; restartNeeded?: boolean;
  assignment?: Assignment; delegationID?: string; pendingQuestion?: string; pendingAskID?: string; assigneeNote?: string; deliverySummary?: string;
  validation?: any; validationRequestedAt?: string; validatedAt?: string;
  landing?: Landing; codeChanges?: number; locatingSince?: string; sessionID?: string; finish?: any;
  [k: string]: unknown;
}

export const toolName = (t?: string) => ({ claude: 'Claude Code', codex: 'Codex', grok: 'Grok Build', kimi: 'Kimi Code', omp: 'Oh My Pi', hermes: 'Hermes Agent' } as Record<string, string>)[t ?? ''] ?? (t || 'Claude Code');
export const authName = (a?: string) => ({ token: 'API token', subscription: 'Subscription (interactive login)', bedrock: 'Bedrock (AWS)', local: 'Local model' } as Record<string, string>)[a ?? ''] ?? (a || 'API token');
export const reliableDone = (t?: string) => ['claude', 'kimi', 'codex', 'grok'].includes(t ?? 'claude');

const ms = (d?: string) => (d ? Date.parse(d) : NaN);
export const tasksOf = (s?: RemoteState | null): CodingTask[] => (s?.tasks?.tasks ?? []) as CodingTask[];

export function createdTime(t: CodingTask) {
  const whole = ms(t.createdAt) / 1000;
  return t.createdAtExact != null && Math.abs(t.createdAtExact - whole) < 1 ? t.createdAtExact : whole;
}
export const backlogRank = (t: CodingTask) => t.queueRank ?? createdTime(t);
export function backlogOrder(a: CodingTask, b: CodingTask) {
  const ra = backlogRank(a), rb = backlogRank(b);
  if (ra !== rb) return ra - rb;
  const ca = createdTime(a), cb = createdTime(b);
  if (ca !== cb) return ca - cb;
  return a.id < b.id ? -1 : 1;
}
export function backlogTasks(all: CodingTask[]) {
  return all.filter(t => t.stage === 'backlog' && !(t.validatedAt && all.some(o => o.parentTaskID === t.id))).sort(backlogOrder);
}
export const inStage = (all: CodingTask[], s: Stage) => all.filter(t => t.stage === s);

export function validationInFlight(t: CodingTask) {
  const req = ms(t.validationRequestedAt);
  if (isNaN(req)) return false;
  const done = ms(t.validatedAt);
  if (!isNaN(done) && done >= req) return false;
  return Date.now() - req < 3600_000;
}
export function isStarting(t: CodingTask) {
  const at = ms(t.startingAt);
  return !isNaN(at) && (t.stage === 'backlog' || t.stage === 'planning') && Date.now() - at < 900_000;
}
export function awaitsRelocation(t: CodingTask) {
  return !!t.delegationID && t.stage === 'testing' && !t.worktreeDir && t.landing?.phase !== 'landed';
}
export function isLocating(t: CodingTask) {
  const at = ms(t.locatingSince);
  return awaitsRelocation(t) && !isNaN(at) && Date.now() - at < 600_000;
}
export function isNoCode(t: CodingTask) {
  if (!t.branch && !t.branchSlug) return true;
  if (t.delegationID && t.stage === 'testing' && !t.worktreeDir) return !isLocating(t);
  return t.codeChanges === 0;
}
export const LOCATING_TEXT = 'Looking for the worktree…';
export function workerName(t: CodingTask) {
  if (t.assignment && t.assignment.kind !== 'worktree') return t.assignment.label;
  return toolName(t.tool);
}
const safeBranch = (b?: string) => !!b && /^[A-Za-z0-9._/-]+$/.test(b) && !b.startsWith('-');
export const landingTarget = (t: CodingTask) => t.landing?.target ?? (safeBranch(t.parentBranch) ? t.parentBranch : undefined);
export const unmetDependencies = (t: CodingTask, all: CodingTask[]) =>
  (t.dependsOn ?? []).filter(id => { const d = all.find(x => x.id === id); return d ? d.stage !== 'done' : false; });
export const unsentComments = (t: CodingTask) => (t.comments ?? []).filter(c => !c.sentAt).length;

export type Completion = { kind: 'merged'; target: string; verified: boolean; by?: string } | { kind: 'prOpened'; url?: string } | { kind: 'markedDone'; byUser: boolean } | { kind: 'closed' };
export function effectiveCompletion(t: CodingTask): Completion | null {
  const c = t.completion;
  if (c && typeof c === 'object') {
    if (c.merged) return { kind: 'merged', target: c.merged.target ?? '', verified: !!c.merged.verified, by: c.merged.by ?? undefined };
    if (c.prOpened) return { kind: 'prOpened', url: c.prOpened.url ?? undefined };
    if (c.markedDone) return { kind: 'markedDone', byUser: !!c.markedDone.byUser };
    if ('closedWithoutMerge' in c) return { kind: 'closed' };
  }
  if (t.stage !== 'done') return null;
  if (t.merged) return { kind: 'merged', target: t.parentBranch ?? '', verified: true };
  if (t.prOpened) return { kind: 'prOpened', url: t.pullRequestURL };
  return { kind: 'closed' };
}
export function doneText(t: CodingTask) {
  const c = effectiveCompletion(t);
  switch (c?.kind) {
    case 'merged': {
      const into = c.target ? `Merged into ${c.target}` : 'Merged';
      if (c.verified) return into;
      if (c.by === 'user') return into + ' · marked by you';
      return into + ` · reported by ${c.by ?? 'the agent'}, not verified`;
    }
    case 'prOpened': {
      const n = c.url?.split('/').pop();
      return n && /^\d+$/.test(n) ? `PR #${n} opened` : 'Pull request opened';
    }
    case 'markedDone': return c.byUser ? 'Marked done by you' : 'All its phases are done';
    default: return 'Closed without merging';
  }
}
export function landingLine(t: CodingTask): string | null {
  if (t.stage !== 'testing') return null;
  const l = t.landing;
  if (!l) return isNoCode(t) ? null : 'Ready to land';
  switch (l.phase) {
    case 'needsYou': return `Needs you — ${l.detail ?? ''}`;
    case 'checking': case 'fastMerging': case 'landed': return `Landing — merging into ${l.target}…`;
    default:
      if (l.handingOver) return `Handing over to ${workerName(t)}…`;
      return l.mode === 'pr' ? `Landing — ${workerName(t)} is opening a pull request into ${l.target}…`
                             : `Landing — ${workerName(t)} is merging into ${l.target}…`;
  }
}
export function queuePosition(t: CodingTask, all: CodingTask[]) {
  if (t.stage !== 'backlog' || !t.assignment) return null;
  const a = t.assignment;
  const same = (o?: Assignment) => !!o && o.kind === a.kind && (a.kind === 'worktree' || a.kind === 'switchboard' || o.id === a.id);
  const q = all.filter(x => x.stage === 'backlog' && same(x.assignment)).sort(backlogOrder);
  const i = q.findIndex(x => x.id === t.id);
  return i < 0 ? null : i + 1;
}
export const assignmentIcon = (a?: Assignment) =>
  !a ? 'person.crop.circle' : a.kind === 'switchboard' ? 'switch.2' : a.kind === 'room' ? 'square.grid.2x2' : a.kind === 'worktree' ? 'arrow.triangle.branch' : 'person.crop.circle';
export const NEW_AGENT: Assignment = { kind: 'worktree', id: '00000000-0000-4000-8000-00000000A6E7', label: 'New agent' };
export const SWITCHBOARD: Assignment = { kind: 'switchboard', id: '00000000-0000-4000-8000-0000005B0A2D', label: '@switchboard' };

/** A brief's markdown as one line of plain prose (card excerpts). */
export function plainExcerpt(md: string) {
  const out: string[] = []; let fence = false;
  for (const raw of (md ?? '').split(/\r?\n/)) {
    let line = raw.trim();
    if (line.startsWith('```')) { fence = !fence; continue; }
    if (fence || !line) continue;
    while (line && '#>-*+'.includes(line[0])) line = line.slice(1).trim();
    line = line.replace(/^\d+\.\s*/, '').replace(/\*\*|__|`/g, '');
    if (line) out.push(line);
    if (out.join(' ').length > 400) break;
  }
  return out.join(' ');
}

// ── Live state of a running task (TaskLiveState) ───────────────────────────

export type Bucket = 'needsYou' | 'working' | 'idle' | 'asleep' | 'ended';
export const bucketTitle: Record<Bucket, string> = { needsYou: 'Needs you', working: 'Working', idle: 'Ready', asleep: 'Paused', ended: 'Paused' };
export const bucketTint: Record<Bucket, string> = { needsYou: 'var(--red)', working: 'var(--orange)', idle: 'var(--green)', asleep: 'var(--label-secondary)', ended: 'var(--label-secondary)' };

/** The manual's demo fixture (sessions carry a scripted bucket): the native
 *  DemoMode shows every in-progress card running. */
export const isDemo = (s?: RemoteState | null) => !!s?.agentSessions?.some(x => (x as any).demoBucket);

function branchMatches(branch: string | undefined, slug: string) {
  if (!branch?.startsWith('wt/')) return false;
  const part = branch.slice(3);
  return part === slug || (part.startsWith(slug + '-') && /^\d+$/.test(part.slice(slug.length + 1)));
}
export { branchMatches };

function sessionBucket(s: AgentSession, st: RemoteState): Bucket {
  const demo = (s as any).demoBucket as string | undefined;
  if (demo && ['needsYou', 'working', 'idle', 'asleep', 'ended'].includes(demo)) return demo as Bucket;
  if (s.archivedAt || s.endedAt) return 'ended';
  if (s.pausedAt) return 'asleep';
  if (s.awaitingAnswer) return 'needsYou';
  const vm = st.vms?.find(v => v.id === s.profileID);
  const tab = vm?.tabs?.find(t => t.index === s.windowIndex);
  const a = (tab as any)?.agentStatus;
  if (!vm || vm.state !== 'running' || !tab) return 'asleep';
  return a === 'needsInput' ? 'needsYou' : a === 'working' ? 'working' : 'idle';
}

export function taskSession(t: CodingTask, st: RemoteState): AgentSession | undefined {
  const ss = st.agentSessions ?? [];
  if (t.sessionID) {
    const s = ss.find(x => x.id === t.sessionID && !x.archivedAt && x.windowIndex != null && x.profileID === t.profileID);
    if (s) return s;
  }
  const slugs = [t.branchSlug, t.branch?.slice(3)].filter(Boolean) as string[];
  if (!slugs.length) return undefined;
  return ss.find(x => x.profileID === t.profileID && !x.archivedAt && slugs.some(sl => branchMatches((x as any).worktreeBranch, sl)));
}
export function taskBucket(t: CodingTask, st: RemoteState): Bucket | null {
  if (isDemo(st) && t.stage === 'inProgress') return 'working';
  const s = taskSession(t, st);
  if (s) return sessionBucket(s, st);
  const slugs = [t.branchSlug, t.branch?.slice(3)].filter(Boolean) as string[];
  const tab = st.vms?.find(v => v.id === t.profileID)?.tabs?.find(tb => slugs.some(sl => branchMatches((tb as any).worktreeBranch, sl)));
  if (!tab) return null;
  const a = (tab as any).agentStatus;
  return a === 'needsInput' ? 'needsYou' : a === 'working' ? 'working' : 'idle';
}
export function couldntStart(t: CodingTask, st: RemoteState) {
  if (t.stage !== 'inProgress' || isDemo(st)) return false;
  const s = taskSession(t, st);
  if (s) return !(s as any).isLaunching && !!(s as any).lastError;
  return taskBucket(t, st) == null && !!t.lastError;
}
export const needsAttention = (t: CodingTask, st: RemoteState) => taskBucket(t, st) === 'needsYou' || couldntStart(t, st);

// ── Automations ────────────────────────────────────────────────────────────

export type Trigger = 'schedule' | 'githubPullRequest' | 'githubIssue' | 'githubCommit' | 'linearIssue' | 'afterAutomation';
export interface Filters { labels: string[]; titleContains: string; excludeDrafts: boolean; ignoreBots: boolean; baseBranch: string; commitBranch: string; commitSubfolder: string; linearProjectID: string; linearProjectName: string; linearMinPriority: number }
export interface Automation {
  id: string; name: string; profileID: string; enabled: boolean;
  trigger: Trigger; githubRepo: string; assignmentFilter: 'unassigned' | 'assignedToMe'; linearTeam: string; ignoreBacklog: boolean; filters: Filters;
  frequency: 'interval' | 'daily' | 'weekdays' | 'weekly'; weekday: number; hour: number; minute: number; intervalMinutes: number; missedRunPolicy: 'skip' | 'runOnWake';
  tool: string; prompt: string; repoPath: string; closeWhenDone: boolean; startWorkspaceIfNeeded: boolean; cloneWorkspaceFirst: boolean;
  chainedAutomationID?: string; watchID?: string; cloneURL?: string; maxParallelRuns: number; createdAt: string;
  [k: string]: unknown;
}
export interface Run {
  id: string; automationID: string; firedAt: string; completedAt?: string; acknowledgedAt?: string;
  outcome: 'launched' | 'skipped' | 'failed' | 'blocked'; detail: string; branchSlug?: string; runProfileID?: string; itemKey?: string; tool?: string; isBacklogSeed?: boolean;
  [k: string]: unknown;
}
export const automationsOf = (s?: RemoteState | null): Automation[] => (s?.automations?.automations ?? []) as Automation[];
export const runsOf = (s?: RemoteState | null): Run[] => (s?.automations?.runs ?? []) as Run[];

export function uuid() {
  return (crypto as any).randomUUID ? (crypto as any).randomUUID().toUpperCase()
    : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }).toUpperCase();
}
export const isoNow = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');

export function newAutomation(profile?: Workspace): Automation {
  return {
    id: uuid(), name: '', profileID: profile?.id ?? '', enabled: true, trigger: 'schedule', githubRepo: '', assignmentFilter: 'unassigned',
    linearTeam: '', ignoreBacklog: true,
    filters: { labels: [], titleContains: '', excludeDrafts: true, ignoreBots: false, baseBranch: '', commitBranch: '', commitSubfolder: '', linearProjectID: '', linearProjectName: '', linearMinPriority: 0 },
    frequency: 'weekdays', weekday: 2, hour: 9, minute: 0, intervalMinutes: 60, missedRunPolicy: 'skip',
    tool: profile?.tool ?? 'claude', prompt: '', repoPath: '~', closeWhenDone: true, startWorkspaceIfNeeded: true, cloneWorkspaceFirst: false,
    maxParallelRuns: 1, createdAt: isoNow(),
  };
}

export interface BoardColumns { inProgress: Run[]; needsAttention: Run[]; done: Run[] }
/** AutomationBoard.classify — `isLive`: does a launched run still have a tab? */
export function classify(runs: Run[], isLive: (r: Run) => boolean): BoardColumns {
  const out: BoardColumns = { inProgress: [], needsAttention: [], done: [] };
  for (const r of runs) {
    if (r.isBacklogSeed) continue;
    if (r.outcome === 'launched' && !r.completedAt && isLive(r)) out.inProgress.push(r);
    else if (r.outcome === 'failed' || r.outcome === 'blocked') (r.acknowledgedAt ? out.done : out.needsAttention).push(r);
    else out.done.push(r);
  }
  const by = (a: Run, b: Run) => ms(b.firedAt) - ms(a.firedAt);
  out.inProgress.sort(by); out.needsAttention.sort(by);
  out.done.sort((a, b) => ms(b.completedAt ?? b.firedAt) - ms(a.completedAt ?? a.firedAt));
  return out;
}
export function liveRunTab(r: Run, autos: Automation[], st: RemoteState) {
  if (r.outcome !== 'launched' || !r.branchSlug) return undefined;
  const pid = r.runProfileID ?? autos.find(a => a.id === r.automationID)?.profileID;
  return st.vms?.find(v => v.id === pid)?.tabs?.find(t => branchMatches((t as any).worktreeBranch, r.branchSlug!));
}
export const outcomeGlyph = (o: Run['outcome']) => ({ launched: 'checkmark.circle', skipped: 'forward.end', failed: 'xmark.circle', blocked: 'shield.slash' })[o] ?? 'circle';
export const outcomeTint = (o: Run['outcome']) => o === 'launched' ? 'var(--green)' : o === 'skipped' ? 'var(--label-secondary)' : 'var(--red)';

export type Kind = 'scheduled' | 'event' | 'security';
export const kindOf = (a: Automation): Kind => a.watchID ? 'security' : a.trigger === 'schedule' ? 'scheduled' : 'event';
export const kindTint = (k: Kind) => k === 'scheduled' ? 'var(--blue)' : k === 'event' ? 'var(--purple)' : 'var(--green)';
export const kindIcon = (k: Kind) => k === 'scheduled' ? 'calendar.badge.clock' : k === 'event' ? 'arrow.triangle.pull' : 'doc.text.magnifyingglass';
export const kindTitle = (k: Kind) => k === 'scheduled' ? 'Scheduled' : k === 'event' ? 'GitHub & Linear events' : 'Code review';
export const kindTagline = (k: Kind) => k === 'scheduled' ? 'Run an agent on a prompt, on a schedule.'
  : k === 'event' ? 'React when something happens on GitHub or Linear.' : 'Keep a GitHub repository continuously reviewed for vulnerabilities and bugs.';
export const kindSteps = (k: Kind): [string, string][] => k === 'scheduled' ? [
  ['clock', 'At the time you pick — every weekday at 9:00, hourly, weekly…'],
  ['terminal', 'An agent starts in one of your workspaces with your prompt, on a fresh branch'],
  ['tray.full', 'You find its result on the Runs tab: transcript and branch'],
] : k === 'event' ? [
  ['bell', 'When a pull request, issue or commit lands on GitHub, a Linear issue appears, or another automation finishes'],
  ['terminal', 'An agent picks up that item with your prompt — screened for prompt injection first'],
  ['tray.full', 'Each item runs once, on its own branch, listed on the Runs tab'],
] : [
  ['magnifyingglass', 'An agent reviews the whole repository weekly, and every new commit and pull request'],
  ['list.bullet.rectangle', 'Findings are collected and deduplicated across scans, by severity'],
  ['wrench.and.screwdriver', 'One click starts a fix on its own branch — you review before anything merges'],
];

// ── Time zones & dates ─────────────────────────────────────────────────────

const viewerTZ = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
function tzOffset(tz: string, d: Date) {
  try {
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric' })
      .formatToParts(d).map(x => [x.type, x.value]));
    return (Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute) - Math.floor(d.getTime() / 60000) * 60000) / 60000;
  } catch { return -d.getTimezoneOffset(); }
}
export const tzDiffers = (tz?: string, d = new Date()) => !!tz && tzOffset(tz, d) !== tzOffset(viewerTZ(), d);
export function zoneName(tz: string, d = new Date()) {
  try { return new Intl.DateTimeFormat('en-US', { timeZone: tz, timeZoneName: 'short' }).formatToParts(d).find(p => p.type === 'timeZoneName')?.value ?? tz; } catch { return tz; }
}
const clockFmt = (tz?: string) => new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', timeZone: tz });
export const clock = (d: Date, tz?: string) => clockFmt(tz).format(d).replace(' ', ' ').replace(' ', ' ');
const dayFmt = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
/** `.formatted(date: .abbreviated, time: .shortened)` → "Nov 25, 2026 at 6:31 AM". */
export const dateTime = (d: string | Date) => { const x = new Date(d); return `${dayFmt.format(x)} at ${clock(x)}`; };
const longDay = new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric', year: 'numeric' });
export const dateTimeLong = (d: string | Date) => { const x = new Date(d); return `${longDay.format(x)} at ${clock(x)}`; };

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [['year', 31536000], ['month', 2592000], ['week', 604800], ['day', 86400], ['hour', 3600], ['minute', 60], ['second', 1]];
function relParts(d: string | Date) {
  const s = (new Date(d).getTime() - Date.now()) / 1000;
  for (const [u, n] of UNITS) if (Math.abs(s) >= n || u === 'second') return { v: Math.trunc(s / n), u };
  return { v: 0, u: 'second' as Intl.RelativeTimeFormatUnit };
}
const rtfNamed = new Intl.RelativeTimeFormat('en-US', { numeric: 'auto' });
const rtfShort = new Intl.RelativeTimeFormat('en-US', { numeric: 'always', style: 'short' });
/** `.relative(presentation: .named)` → "56 minutes ago", "yesterday". */
export const relNamed = (d: string | Date) => { const { v, u } = relParts(d); return rtfNamed.format(v, u); };
/** `.relative(presentation: .numeric, unitsStyle: .abbreviated)` → "5 min. ago". */
export const relShort = (d: string | Date) => { const { v, u } = relParts(d); return rtfShort.format(v, u); };

/** AutomationDescriber.moment: "Tomorrow at 2:30 AM" (relative date formatting). */
export function moment(d: string | Date, scheduleTZ?: string) {
  const x = new Date(d), now = new Date();
  const day = (a: Date) => new Date(a.getFullYear(), a.getMonth(), a.getDate()).getTime();
  const diff = Math.round((day(x) - day(now)) / 86400000);
  const date = diff === 0 ? 'Today' : diff === 1 ? 'Tomorrow' : diff === -1 ? 'Yesterday' : dayFmt.format(x);
  const s = `${date} at ${clock(x)}`;
  return tzDiffers(scheduleTZ, x) ? s + ' ' + zoneName(viewerTZ(), x) : s;
}
const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const SHORT_WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
export { WEEKDAYS };

/** The row's one-line trigger summary ("Daily 2:30", "PR · owner/repo"). */
export function scheduleSummary(a: Automation, tz?: string) {
  switch (a.trigger) {
    case 'githubPullRequest': case 'githubIssue': return `${a.trigger === 'githubIssue' ? 'Issue' : 'PR'} · ${a.githubRepo || '?'}`;
    case 'githubCommit': return 'Commit · ' + (a.githubRepo || '?') + (a.filters?.commitSubfolder ? '/' + a.filters.commitSubfolder : '');
    case 'linearIssue': return ['Linear', ...(a.linearTeam ? [a.linearTeam.toUpperCase()] : []), a.assignmentFilter === 'assignedToMe' ? 'Mine' : 'Unassigned'].join(' · ');
    case 'afterAutomation': return 'Chained';
  }
  const zone = tzDiffers(tz) ? ' ' + zoneName(tz!) : '';
  const time = `${a.hour}:${String(a.minute).padStart(2, '0')}${zone}`;
  switch (a.frequency) {
    case 'interval': { const m = Math.max(5, a.intervalMinutes); return m % 60 === 0 ? `Every ${m / 60}h` : `Every ${m}m`; }
    case 'daily': return `Daily ${time}`;
    case 'weekdays': return `Weekdays ${time}`;
    default: return `${SHORT_WEEKDAYS[Math.min(Math.max(a.weekday, 1), 7) - 1]} ${time}`;
  }
}

function hostTime(a: Automation, tz?: string) {
  // The wall time on the host's clock, today.
  const now = new Date();
  const off = tz ? tzOffset(tz, now) : -now.getTimezoneOffset();
  const p = tz ? Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: tz, year: 'numeric', month: 'numeric', day: 'numeric' }).formatToParts(now).map(x => [x.type, x.value])) : null;
  const y = p ? +p.year : now.getFullYear(), mo = p ? +p.month - 1 : now.getMonth(), da = p ? +p.day : now.getDate();
  const date = new Date(Date.UTC(y, mo, da, a.hour, a.minute) - off * 60000);
  const there = clock(date, tz);
  if (!tzDiffers(tz, date)) return there;
  return `${there} ${zoneName(tz!, date)} (${clock(date)} ${zoneName(viewerTZ(), date)} here)`;
}
/** AutomationDescriber.when: "Every weekday at 9:00 AM", "When a pull request is opened on acme/api". */
export function describeWhen(a: Automation, upstreamName?: string, tz?: string) {
  const repo = a.githubRepo || 'a repository';
  switch (a.trigger) {
    case 'schedule':
      switch (a.frequency) {
        case 'interval': { const m = Math.max(5, a.intervalMinutes); return m % 60 === 0 ? (m === 60 ? 'Every hour' : `Every ${m / 60} hours`) : `Every ${m} minutes`; }
        case 'daily': return `Every day at ${hostTime(a, tz)}`;
        case 'weekdays': return `Every weekday at ${hostTime(a, tz)}`;
        default: return `Every ${WEEKDAYS[Math.min(Math.max(a.weekday, 1), 7) - 1]} at ${hostTime(a, tz)}`;
      }
    case 'githubPullRequest': return `When a pull request is opened on ${repo}` + (a.filters?.baseBranch ? ` against ${a.filters.baseBranch}` : '');
    case 'githubIssue': return a.assignmentFilter === 'assignedToMe' ? `When an issue on ${repo} is assigned to you` : `When an unassigned issue is opened on ${repo}`;
    case 'githubCommit': return `When a commit lands on ${a.filters?.commitBranch || 'the default branch'} of ${repo}` + (a.filters?.commitSubfolder ? ` touching ${a.filters.commitSubfolder}` : '');
    case 'linearIssue': return (a.assignmentFilter === 'assignedToMe' ? 'When a Linear issue is assigned to you' : 'When an unassigned Linear issue is created') + (a.linearTeam ? ` (${a.linearTeam.toUpperCase()})` : '');
    case 'afterAutomation': return `When “${upstreamName ?? 'another automation'}” finishes`;
  }
}
export function describeWhat(a: Automation, workspace: string) {
  const p = (a.repoPath ?? '').trim();
  let s = `${toolName(a.tool)} works on your prompt in a new branch of ${!p || p === '~' ? 'the home folder' : p}, in ${workspace}`;
  if (a.cloneWorkspaceFirst && reliableDone(a.tool)) s += ' (a disposable copy)';
  return s;
}
export const describeAfter = (a: Automation) => a.closeWhenDone && reliableDone(a.tool)
  ? 'The session closes; its transcript and branch stay for you to review' : 'The session stays open for you to check';

/** AutomationSchedule.nextFire, on the host's clock (preview in the editor). */
export function nextFire(a: Automation, tz?: string, after = new Date()): Date | null {
  if (a.trigger !== 'schedule' || !a.enabled) return null;
  if (a.frequency === 'interval') return new Date(after.getTime() + Math.max(5, a.intervalMinutes) * 60000);
  for (let i = 0; i < 9; i++) {
    const probe = new Date(after.getTime() + i * 86400000);
    const off = tz ? tzOffset(tz, probe) : -probe.getTimezoneOffset();
    const p = tz ? Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: tz, year: 'numeric', month: 'numeric', day: 'numeric', weekday: 'short' }).formatToParts(probe).map(x => [x.type, x.value]))
      : { year: String(probe.getFullYear()), month: String(probe.getMonth() + 1), day: String(probe.getDate()), weekday: SHORT_WEEKDAYS[probe.getDay()] };
    const wd = SHORT_WEEKDAYS.indexOf(p.weekday) + 1;
    const d = new Date(Date.UTC(+p.year, +p.month - 1, +p.day, a.hour, a.minute) - off * 60000);
    if (d <= after) continue;
    if (a.frequency === 'weekdays' && (wd === 1 || wd === 7)) continue;
    if (a.frequency === 'weekly' && wd !== a.weekday) continue;
    return d;
  }
  return null;
}

export const isValidRepoSlug = (s: string) => /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(s.trim());

export function chainCycles(id: string, all: Automation[]) {
  const seen = new Set<string>(); let cur: string | undefined = id;
  while (cur) {
    if (seen.has(cur)) return true;
    seen.add(cur);
    cur = all.find(a => a.id === cur)?.chainedAutomationID;
    if (cur === id) return true;
  }
  return false;
}

export const workspaceOf = (st: RemoteState | null | undefined, id?: string) => st?.workspaces?.find(w => w.id === id);
export const accentOf = (st: RemoteState | null | undefined, id?: string) => workspaceOf(st, id)?.accentHex ?? '#888888';

/** Who a task can be queued for (the task editor's and "Who picks this up?"'s list). */
export interface Choices {
  sessions: { id: string; label: string; workspace: string; busy: boolean; profileID?: string }[];
  rooms: { id: string; name: string }[];
}

export function assigneeChoices(st: RemoteState): Choices {
  const byName = (a: string, b: string) => a.replace(/^@/, '').localeCompare(b.replace(/^@/, ''), undefined, { numeric: true, sensitivity: 'base' });
  const sessions = (st.agentSessions ?? [])
    // Every session: a list cut to the first 40 left the others unassignable.
    .filter(s => !s.archivedAt && !(s as any).deletedAt && (s as any).role !== 'switchboard')
    .map(s => ({ id: s.id, label: s.nickname ? '@' + s.nickname : s.title, workspace: workspaceOf(st, s.profileID)?.name ?? '', busy: false, profileID: s.profileID }))
    .sort((a, b) => byName(a.label, b.label) || a.workspace.localeCompare(b.workspace));
  const rooms = (st.agentRooms ?? []).filter(r => !(r as any).archivedAt).map(r => ({ id: r.id, name: r.name })).sort((a, b) => byName(a.name, b.name));
  return { sessions, rooms };
}
