// The Security Timeline's data for one mirrored host — the port of
// `SecurityTimeline` (its fat-client half) and the RemoteHostController sync
// that feeds it (FatClientController.swift, "securityTimelineHead").
//
// A host that syncs by deltas sends a cheap head with every /state snapshot
// ({epoch, last, oldest, totals}); the client asks
// `/security-timeline?after=<last>&epoch=<epoch>` for the rows it hasn't got
// and shows the host's own totals. An older host mirrors its last rows in
// /state.securityTimeline; the window fetches its full history for the range
// (`/security-timeline?hours=`) and the mirror merges into it.

import type { RemoteHost } from '../../core/remote/host';

export type Decision = 'allowed' | 'blocked' | 'info';

export interface FirewallRef {
  host?: string; ip?: string; port?: number; proto?: string; rule?: string;
  denied: boolean; byPolicy: boolean; aliases: string[]; exe?: string;
}
export interface PackageRef { ecosystem: string; name: string }

/** One row (SecurityTimeline.Event). Times are epoch milliseconds. */
export interface SecEvent {
  /** Unique per decoded row (React key). */
  id: string;
  /** The row's stable id across coalescing / restarts (wire `rid`). */
  rowID?: string;
  seq?: number;
  time: number;
  engine: string;
  condition: string;
  decision: string;
  kind: Decision;
  profileID: string;
  workspace?: string;
  count?: number;
  eventType?: string;
  detail?: Record<string, any>;
  coalesceKey?: string;
  denials?: number;
  firewall?: FirewallRef;
  package?: PackageRef;
}
export const stableID = (e: SecEvent) => e.rowID ?? e.id;

/** How many identical routine events a coalesced row stands for (>1). */
export function repeats(e: SecEvent): number | undefined {
  return e.coalesceKey != null && e.count != null && e.count > 1 ? e.count : undefined;
}
/** Occurrences the row counts for in a total. */
export const occurrences = (e: SecEvent) => e.denials ?? Math.max(1, repeats(e) ?? 1);

/** The words that find every instance of this event (`searchKey`). */
export function searchKey(e: SecEvent): string {
  let c = e.condition.replace(/ \(pid \d+\)/, '');
  c = c.replace(/ — ×\d+.*$|\s×\d+$/, '');
  if (e.engine === 'Guest sandbox') {
    const i = c.indexOf(' — ');
    if (i >= 0) return c.slice(i + 3);
  }
  return c;
}

export const RANGE_CHOICES = [1, 24, 168, 720, 0];
export function rangeTitle(h: number) {
  switch (h) {
    case 1: return 'Last hour';
    case 24: return 'Last 24 hours';
    case 168: return 'Last 7 days';
    case 720: return 'Last 30 days';
    default: return 'All history';
  }
}
/** Preferences › Tracing default (unset = 24); the web client can't read the
 *  host's UserDefaults, so it's the default. */
export const DEFAULT_RANGE_HOURS = 24;

export function historyHours(range: number, overview: number) {
  return range === 0 || overview === 0 ? 0 : Math.max(range, overview);
}

// ── Totals ───────────────────────────────────────────────────────────────

export interface Totals { blocked: number; allowed: number; credential: number; supplyChain: number; pii: number; sandbox: number; sandboxSeen: boolean }
export const emptyTotals = (): Totals => ({ blocked: 0, allowed: 0, credential: 0, supplyChain: 0, pii: 0, sandbox: 0, sandboxSeen: false });

export function addToTotals(t: Totals, e: SecEvent) {
  if (e.kind === 'blocked') t.blocked += occurrences(e);
  else if (e.kind === 'allowed') t.allowed += occurrences(e);
  if (e.engine === 'Credential brokering') t.credential += e.count ?? 1;
  else if (e.engine === 'Supply chain') t.supplyChain += 1;
  else if (e.engine === 'PII protection') t.pii += e.count ?? 1;
  else if (e.engine === 'Guest sandbox') {
    t.sandboxSeen = true;
    if (e.kind === 'blocked') t.sandbox += occurrences(e);
  }
}
export function totalsOf(events: SecEvent[]): Totals {
  const t = emptyTotals();
  for (const e of events) addToTotals(t, e);
  return t;
}
function totalsByRangeWire(w: any): Record<number, Totals> | null {
  if (!w || typeof w !== 'object') return null;
  const out: Record<number, Totals> = {};
  for (const [k, v] of Object.entries<any>(w)) {
    const h = parseInt(k, 10);
    if (Number.isNaN(h) || !v || typeof v !== 'object') continue;
    out[h] = {
      blocked: v.blocked ?? 0, allowed: v.allowed ?? 0, credential: v.credential ?? 0,
      supplyChain: v.supplyChain ?? 0, pii: v.pii ?? 0, sandbox: v.sandbox ?? 0, sandboxSeen: !!v.sandboxSeen,
    };
  }
  return out;
}

// ── Wire decoding ────────────────────────────────────────────────────────

/** `SecretFingerprint.redactLegacy`: an older row's "sk-a…kUyU" preview
 *  becomes its kind and "(redacted)" — never any secret characters. */
const KINDS: [string, string][] = [
  ['brm_', 'stand-in'], ['bromure-', 'stand-in'],
  ['sk-ant-oat', 'Claude subscription token'], ['sk-ant-', 'Anthropic key'],
  ['sk-proj-', 'OpenAI key'], ['sk-svcacct-', 'OpenAI key'], ['sk-or-', 'OpenRouter key'],
  ['xai-', 'xAI key'], ['gsk_', 'Groq key'], ['AIza', 'Google API key'],
  ['ghp_', 'GitHub token'], ['gho_', 'GitHub token'], ['ghu_', 'GitHub token'],
  ['ghs_', 'GitHub token'], ['github_pat_', 'GitHub token'], ['glpat-', 'GitLab token'],
  ['xoxb-', 'Slack token'], ['xoxp-', 'Slack token'], ['xapp-', 'Slack token'],
  ['AKIA', 'AWS access key'], ['ASIA', 'AWS session key'],
  ['dop_v1_', 'DigitalOcean token'], ['npm_', 'npm token'], ['pypi-', 'PyPI token'],
  ['hf_', 'Hugging Face token'], ['eyJ', 'JWT'], ['sk-', 'API key'],
];
const HEADS: Record<string, string> = {
  'sk-a': 'Anthropic key', 'sk-p': 'OpenAI key', 'sk-o': 'OpenRouter key', 'xai-': 'xAI key', 'brm_': 'stand-in',
  'ghp_': 'GitHub token', 'gith': 'GitHub token', 'glpa': 'GitLab token', 'AKIA': 'AWS access key',
  'ASIA': 'AWS session key', 'xoxb': 'Slack token', 'AIza': 'Google API key',
};
const LEGACY_PREVIEW = /(?<![A-Za-z0-9_\-])([A-Za-z0-9_\-]{2,8})…([A-Za-z0-9_\-]{3,8})(?![A-Za-z0-9_\-])/g;
function legacyKind(head: string) {
  const k = HEADS[head.slice(0, 4)];
  if (k) return k;
  for (const [p, name] of KINDS) if (p.startsWith(head) || head.startsWith(p)) return name;
  return 'credential';
}
export function redactLegacy(s: string): string {
  if (!s.includes('…')) return s;
  return s.replace(LEGACY_PREVIEW, (_m, head: string) => `${legacyKind(head)} (redacted)`);
}

let uid = 0;
function decodeRow(r: any): SecEvent | null {
  if (!r || typeof r.engine !== 'string' || typeof r.condition !== 'string' || typeof r.decision !== 'string') return null;
  const fw = r.fw && typeof r.fw === 'object' ? {
    host: r.fw.host, ip: r.fw.ip, port: r.fw.port, proto: r.fw.proto, rule: r.fw.rule,
    denied: !!r.fw.denied, byPolicy: !!r.fw.byPolicy, aliases: Array.isArray(r.fw.aliases) ? r.fw.aliases : [], exe: r.fw.exe,
  } : undefined;
  let pk: PackageRef | undefined;
  if (typeof r.pk === 'string') {
    const i = r.pk.indexOf(':');
    if (i > 0 && i < r.pk.length - 1) pk = { ecosystem: r.pk.slice(0, i), name: r.pk.slice(i + 1) };
  }
  return {
    id: 'e' + (++uid),
    rowID: typeof r.rid === 'string' ? r.rid : undefined,
    seq: typeof r.sq === 'number' ? r.sq : undefined,
    time: typeof r.t === 'number' ? r.t * 1000 : Date.now(),
    engine: r.engine,
    condition: redactLegacy(r.condition),
    decision: redactLegacy(r.decision),
    kind: r.kind === 'blocked' ? 'blocked' : r.kind === 'allowed' ? 'allowed' : 'info',
    profileID: typeof r.profileID === 'string' ? r.profileID : crypto.randomUUID().toUpperCase(),
    workspace: typeof r.workspace === 'string' ? r.workspace : undefined,
    count: typeof r.count === 'number' ? r.count : undefined,
    eventType: typeof r.type === 'string' ? r.type : undefined,
    detail: r.detail && typeof r.detail === 'object' ? r.detail : undefined,
    coalesceKey: typeof r.ck === 'string' ? r.ck : undefined,
    denials: typeof r.dn === 'number' ? r.dn : undefined,
    firewall: fw, package: pk,
  };
}
const decodeRows = (rows: any[]) => rows.map(decodeRow).filter((e): e is SecEvent => !!e);

// ── Merge (older hosts: mirror over fetched history) ─────────────────────

const CAP = 5000;
const COALESCE_WINDOW_MS = 10 * 60 * 1000;

type Retention = { kind: 'sequence'; first: number } | { kind: 'time'; oldest: number | null } | { kind: 'unknown' };

function notCarriedAgain(candidates: SecEvent[], mirror: SecEvent[], mirrored: Set<string>): SecEvent[] {
  const repeatTimes = new Map<string, number[]>();
  for (const e of mirror) if (e.coalesceKey) {
    const k = `${e.profileID}|${e.coalesceKey}`;
    (repeatTimes.get(k) ?? repeatTimes.set(k, []).get(k)!).push(e.time);
  }
  return candidates.filter(e => {
    if (e.rowID) return !mirrored.has(e.rowID);
    const times = e.coalesceKey ? repeatTimes.get(`${e.profileID}|${e.coalesceKey}`) : undefined;
    if (!times) return true;
    return !times.some(t => t >= e.time && t - e.time <= COALESCE_WINDOW_MS);
  });
}

export function merged(history: SecEvent[], mirror: SecEvent[], retention: Retention): SecEvent[] {
  if (!history.length) return mirror;
  if (!mirror.length) return [];
  const mirrored = new Set(mirror.map(e => e.rowID).filter((x): x is string => !!x));
  const byTime = (a: SecEvent, b: SecEvent) => a.time - b.time;
  switch (retention.kind) {
    case 'time': {
      const oldest = Math.min(...mirror.map(e => e.time));
      const cands = history.filter(e => e.time < oldest && (retention.oldest == null || e.time >= retention.oldest));
      return [...notCarriedAgain(cands, mirror, mirrored), ...mirror].sort(byTime).slice(-CAP);
    }
    case 'sequence': {
      const seqs = mirror.map(e => e.seq).filter((x): x is number => x != null);
      const mirrorFirst = seqs.length ? Math.min(...seqs) : undefined;
      const kept = history.filter(e => {
        if (e.rowID && mirrored.has(e.rowID)) return false;
        if (e.seq == null || mirrorFirst == null) return true;
        return e.seq >= retention.first && e.seq < mirrorFirst;
      });
      return [...kept, ...mirror].sort((a, b) => ((a.seq ?? -1) - (b.seq ?? -1)) || (a.time - b.time)).slice(-CAP);
    }
    case 'unknown':
      return [...notCarriedAgain(history, mirror, mirrored), ...mirror].sort(byTime).slice(-CAP);
  }
}

// ── The per-host store ───────────────────────────────────────────────────

interface SyncMark { epoch: string; last?: number; oldest?: number }
const markOf = (d: any): SyncMark | null => d && typeof d.epoch === 'string'
  ? { epoch: d.epoch, last: typeof d.last === 'number' ? d.last : undefined, oldest: typeof d.oldest === 'number' ? d.oldest : undefined }
  : null;
const sameMark = (a?: SyncMark | null, b?: SyncMark | null) =>
  (!a && !b) || (!!a && !!b && a.epoch === b.epoch && a.last === b.last && a.oldest === b.oldest);

export class SecurityStore {
  /** The host's events, oldest first (its bucket). */
  events: SecEvent[] = [];
  /** The host's own totals by range, from its last head. */
  remoteTotals: Record<number, Totals> | null = null;
  /** Bumped on every change (useSyncExternalStore snapshot). */
  version = 0;

  private listeners = new Set<() => void>();
  private synced: SyncMark | null = null;
  private deltaHost = false;
  private inFlight = 0;
  private failures = 0;
  private retryAt: number | null = null;
  // Older hosts (mirror + fetched history)
  private fetched: SecEvent[] | null = null;
  private fetchedEpoch: string | null = null;
  private historyRequested = false;
  private historyOwed = false;
  private historyHours = 24;
  private historyGeneration = 0;
  private historyApplied = 0;
  private lastMirror: { rows: unknown; oldest: unknown; oldestSeq: unknown; epoch: unknown; hv: number } | null = null;
  private historyVersion = 0;
  private unsub: (() => void) | null = null;

  constructor(readonly host: RemoteHost) {}

  subscribe = (l: () => void) => {
    this.listeners.add(l);
    if (!this.unsub) {
      this.unsub = this.host.onState(() => this.applySnapshot());
      this.applySnapshot();
    }
    return () => { this.listeners.delete(l); };
  };
  private emit() { this.version++; for (const l of [...this.listeners]) l(); }

  /** Start following the host's /state even with no window open (counts
   *  stay current, the window opens instantly). */
  follow() { if (!this.unsub) { this.unsub = this.host.onState(() => this.applySnapshot()); this.applySnapshot(); } }

  private applySnapshot() {
    const s: any = this.host.state;
    if (!s) return;
    const head = s.securityTimelineHead;
    const mark = markOf(head);
    if (mark) {
      this.deltaHost = true;
      const totals = totalsByRangeWire(head.totals);
      if (totals && JSON.stringify(totals) !== JSON.stringify(this.remoteTotals)) { this.remoteTotals = totals; this.emit(); }
      if (!sameMark(this.synced, mark) && this.inFlight === 0 && (this.retryAt == null || Date.now() >= this.retryAt)) {
        this.fetchDelta();
      }
    } else if (Array.isArray(s.securityTimeline)) {
      if (this.deltaHost) {
        this.deltaHost = false;
        this.forgetDeltaSync();
        this.historyOwed = this.historyRequested;
      }
      const epoch = typeof s.securityTimelineEpoch === 'string' ? s.securityTimelineEpoch : null;
      this.applyMirror(s.securityTimeline,
        typeof s.securityTimelineOldest === 'number' ? s.securityTimelineOldest * 1000 : null,
        typeof s.securityTimelineOldestSeq === 'number' ? s.securityTimelineOldestSeq : null, epoch);
      const stale = !!epoch && this.fetched != null && this.fetchedEpoch !== epoch;
      const requested = this.historyRequested || this.historyGeneration > 0;
      const outstanding = this.historyOwed || this.historyGeneration > this.historyApplied;
      if (requested && this.inFlight === 0 && (this.retryAt == null || Date.now() >= this.retryAt) && (stale || outstanding)) {
        this.fetchHistory(this.historyHours);
      }
    }
  }

  private forgetDeltaSync() {
    this.remoteTotals = null;
    this.synced = null;
    this.lastMirror = null;
  }

  private failed() {
    this.failures++;
    this.retryAt = Date.now() + Math.min(120, 10 * Math.pow(2, Math.max(0, this.failures - 1))) * 1000;
  }

  private async fetchDelta() {
    const base = this.synced;
    let path = `/security-timeline?after=${base?.last ?? ''}`;
    if (base?.epoch) path += `&epoch=${encodeURIComponent(base.epoch)}`;
    this.inFlight++;
    let body: any = null;
    try {
      const r = await this.host.request<any>('GET', path, undefined, { timeoutMs: 30000 });
      body = r && r.rows != null ? r : null;
    } catch { body = null; }
    this.inFlight = Math.max(0, this.inFlight - 1);
    if (!body) { this.failed(); return; }
    this.failures = 0; this.retryAt = null;
    if (!this.deltaHost) return;
    this.applyDelta(body, base);
    // The head may have moved on while this was under way.
    this.applySnapshot();
  }

  private applyDelta(body: any, base: SyncMark | null): boolean {
    if (!sameMark(this.synced, base)) return false;
    const mark = markOf(body);
    if (!mark || !Array.isArray(body.rows)) return false;
    const delta = body.delta === true && this.synced?.epoch === mark.epoch;
    const fresh = decodeRows(body.rows);
    const before = this.events;
    let bucket = delta ? [...before] : [];
    if (delta && fresh.length) {
      const ids = new Set(fresh.map(stableID));
      bucket = bucket.filter(e => !ids.has(stableID(e)));
    }
    bucket.push(...fresh);
    if (mark.oldest != null) { const first = mark.oldest; bucket = bucket.filter(e => (e.seq ?? Infinity) >= first); }
    else bucket = [];
    if (bucket.length > CAP) bucket = bucket.slice(bucket.length - CAP);
    this.synced = mark;
    if (delta && !fresh.length && bucket.length === before.length) return true;
    this.events = bucket;
    this.emit();
    return true;
  }

  private applyMirror(rows: any[], oldest: number | null, oldestSeq: number | null, epoch: string | null) {
    const last = this.lastMirror;
    // The push stream replaces a section only when it changed: the same
    // array again is the same mirror.
    if (last && last.rows === rows && last.oldest === oldest && last.oldestSeq === oldestSeq && last.epoch === epoch && last.hv === this.historyVersion) return;
    const mirror = decodeRows(rows);
    if (!mirror.length) {
      if (this.fetched) this.historyVersion++;
      this.fetched = null; this.fetchedEpoch = null;
    }
    let retention: Retention;
    if (oldestSeq != null && epoch) retention = this.fetchedEpoch === epoch ? { kind: 'sequence', first: oldestSeq } : { kind: 'unknown' };
    else retention = { kind: 'time', oldest };
    if (this.fetched) {
      if (retention.kind === 'sequence') { const f = retention.first; this.fetched = this.fetched.filter(e => e.seq == null || e.seq >= f); }
      else if (retention.kind === 'time' && retention.oldest != null) { const o = retention.oldest; this.fetched = this.fetched.filter(e => e.time >= o); }
    }
    this.events = merged(this.fetched ?? [], mirror, retention);
    this.lastMirror = { rows, oldest, oldestSeq, epoch, hv: this.historyVersion };
    this.emit();
  }

  /** The window's range changed / it opened: an older host's full history
   *  for that many hours (0 = all). A delta host already sends everything. */
  fetchHistory(hours: number) {
    this.historyRequested = true;
    if (this.deltaHost) { this.historyHours = Math.max(0, hours); return; }
    this.historyOwed = false;
    const generation = ++this.historyGeneration;
    const range = Math.max(0, hours);
    this.historyHours = range;
    this.inFlight++;
    this.host.request<any>('GET', `/security-timeline?hours=${range}`, undefined, { timeoutMs: 30000 })
      .then(r => r, () => null)
      .then(r => {
        this.inFlight = Math.max(0, this.inFlight - 1);
        const rows = r && Array.isArray(r.rows) ? r.rows : null;
        if (!rows) { this.failed(); return; }
        this.failures = 0; this.retryAt = null;
        if (this.deltaHost) return;
        // `acceptsHistory`: the range asked for last, newer than the last applied.
        if (range !== this.historyHours || generation <= this.historyApplied) return;
        this.historyApplied = generation;
        this.fetched = decodeRows(rows);
        this.fetchedEpoch = typeof r.epoch === 'string' ? r.epoch : null;
        this.historyVersion++;
        this.events = this.fetched;
        this.emit();
      });
  }

  /** Clear the window (`SecurityTimeline.clear`): the host's log stays; the
   *  next head refills the bucket, as on the Mac. */
  clear() {
    this.events = [];
    this.fetched = null;
    this.lastMirror = null;
    this.synced = null;
    this.remoteTotals = null;
    this.emit();
  }
}

const stores = new WeakMap<RemoteHost, SecurityStore>();
export function securityStore(host: RemoteHost): SecurityStore {
  let s = stores.get(host);
  if (!s) { s = new SecurityStore(host); stores.set(host, s); }
  return s;
}
