// BeautifiedSessionModel + RemoteTranscriptProvider (BeautifiedSessionView.swift,
// FatClientController.swift): the live chat for a session's tmux window,
// read over guest exec — the floor probe, then the transcript chunk tailed
// from where the last read ended — parsed client-side for every agent; the
// composer types into the agent through the server's POST /vms/<id>/type.
//
// `copy` mode is a resting / fixture session: its conversation comes from
// the server's copy (GET /agent-sessions/<id>/transcript) — or, in dev with
// `?fixtures=<base>`, from the demo fixture's JSONL over HTTP.

import type { RemoteHost } from '../../../core/remote/host';
import { seg } from '../../../core/remote/host';
import type { AgentSession, RemoteState } from '../../../core/remote/types';
import type { TranscriptItem, TranscriptQuestion } from '../transcript/types';
import { questionResolved } from '../transcript/types';
import { parseTranscript as parseRaw, unwrapPasted, rewriteSharePaths } from '../transcript/parse';

/** AgentTranscript.parse + GuestSharePaths.rewrite (tool headers read the home as ~). */
function parseTranscript(text: string, agent?: string) { return { items: rewriteSharePaths(parseRaw(text, agent).items, {}) }; }
import {
  floorProbeCommand, parseFloorProbe, transcriptChunkCommand, parseTranscriptFetch, isForeignConversation,
  transcriptPinForConversation, kimiUnpinnedPin, paneTargetChat, paneTargetJSON, typeOutcome, keysCommand,
  answerKeysCommand, resolvePaneTarget, FAT_CLIENT_HISTORY_BYTES_HINT, type TranscriptPin, type PaneTarget, type TypeOutcome,
} from '../transcript/guestCommands';
import { builtInCommands, discoveryCommand, parseDiscovery, type SlashCommand } from './slash';
import { toolDisplayName } from '../sessionState';
import { writeGuestFile } from '../../../core/remote/chunkedWrite';

export interface HeldMessage {
  id: string; text: string; failure?: string; awaitingAnswer?: boolean; sending?: boolean;
}

export interface ChatSnapshot {
  items: TranscriptItem[];
  working: boolean;
  workingSince?: number;
  loading: boolean;
  loadIssue: 'failed' | 'notFound' | null;
  canLoadEarlier: boolean;
  loadingEarlier: boolean;
  fileSize: number;
  heldBytes: number;
  sending: boolean;
  held: HeldMessage[];
  slash: SlashCommand[];
  agent: string;
  agentName: string;
  /** dropped-image data URLs by guest path (thumbnails in your turns). */
  images: Record<string, string>;
  live: boolean;
}

const NOT_TYPED = 'Not sent — typing it into the session failed. Edit it or send it again.';
const NOT_DELIVERED = "Not delivered — it's in the agent's input box but its Return didn't take. Press Return in the terminal, or clear the box and send it again.";
const NOT_TAKEN = "Not delivered — the agent didn't take it. Edit it or send it again.";
function refusalText(r: string) {
  switch (r) {
    case 'gone': return "Not sent — the session's tab is gone.";
    case 'identity': return 'Not sent — that tab is now another session’s.';
    case 'shell': return 'Not sent — the agent isn’t running in its tab.';
    default: return 'Not sent.';
  }
}

export const DROP_DIR = '/home/ubuntu/.bromure/drops';
export function dropStamp() {
  const d = new Date(), p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}-`
    + crypto.randomUUID().slice(0, 8).toLowerCase();   // a drop's own names: its failed copy's cleanup can't hit another's
}
export function dropSafeName(name: string) {
  let s = [...name].map(c => /[\p{L}\p{N}._-]/u.test(c) ? c : '_').join('');
  while (s.includes('..')) s = s.replace('..', '_');
  return !s || s === '.' ? 'file' : s.slice(0, 120);
}
const IMAGE_EXT = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'heif', 'tiff', 'tif', 'bmp']);
export function dropImagePaths(text: string): string[] {
  const out: string[] = [];
  for (const tok of text.split(/\s+/)) {
    if (!(tok.startsWith(DROP_DIR + '/') || tok.startsWith('/tmp/bromure-drops/') || (tok.startsWith('/') && tok.includes('/.bromure/drops/')))) continue;
    if (!IMAGE_EXT.has((tok.split('.').pop() ?? '').toLowerCase()) || out.includes(tok)) continue;
    out.push(tok);
  }
  return out;
}

function b64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
function utf8FromB64(b: string): string {
  const bin = atob(b);
  const u = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
  return new TextDecoder().decode(u);
}

/** The server's copy of a session's conversation (or the dev fixture). */
export async function fetchSessionTranscript(host: RemoteHost, s: AgentSession): Promise<string | null> {
  try {
    const r = await host.request<any>('GET', `/agent-sessions/${seg(s.id)}/transcript`, undefined, { timeoutMs: 60_000, allowError: true });
    if (typeof r?.transcript === 'string' && r.transcript) return utf8FromB64(r.transcript);
  } catch {}
  return fetchFixture(s);
}

/** Dev only: `?fixtures=<base-url>` serves scripts/manual-demo's fixture dir. */
async function fetchFixture(s: AgentSession): Promise<string | null> {
  const base = new URLSearchParams(location.search).get('fixtures');
  if (!base) return null;
  try {
    const spec = await (await fetch(base.replace(/\/$/, '') + '/spec.json')).json();
    const e = (spec.sessions ?? []).find((x: any) => x.title === s.title);
    if (!e?.transcript) return null;
    return await (await fetch(base.replace(/\/$/, '') + '/' + e.transcript)).text();
  } catch { return null; }
}

/** Transcript echo matching (EchoKey). */
function echoKey(s: string) { return unwrapPasted(s).replace(/\r\n?/g, '\n').trim(); }

export class ChatModel {
  private listeners = new Set<() => void>();
  private snap: ChatSnapshot;
  private parsed: TranscriptItem[] = [];
  private pending: { item: TranscriptItem; added: number }[] = [];
  private buffer: { path: string; data: string; base: number; end: number } | null = null;
  private pq = '';
  private stopped = true;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private interrupted = false;
  private seq = 0;

  constructor(private host: RemoteHost, private sessionID: string, readonly mode: 'live' | 'copy',
              private getSession: () => AgentSession | undefined) {
    const s = getSession();
    const agent = s?.tool ?? 'claude';
    this.snap = {
      items: [], working: false, loading: true, loadIssue: null, canLoadEarlier: false, loadingEarlier: false,
      fileSize: 0, heldBytes: 0, sending: false, held: [], slash: builtInCommands(agent), agent,
      agentName: toolDisplayName(agent), images: {}, live: mode === 'live',
    };
  }

  // ── store ──
  subscribe = (l: () => void) => { this.listeners.add(l); return () => this.listeners.delete(l); };
  get = () => this.snap;
  private set(p: Partial<ChatSnapshot>) {
    let changed = false;
    for (const k in p) if ((this.snap as any)[k] !== (p as any)[k]) { changed = true; break; }
    if (!changed) return;
    this.snap = { ...this.snap, ...p };
    for (const l of [...this.listeners]) l();
  }
  private rebuild() { this.set({ items: [...this.parsed, ...this.pending.map(p => p.item)] }); }

  // ── session / tab ──
  private get session() { return this.getSession(); }
  private get workspaceID() { return this.session?.profileID ?? ''; }
  private get window(): number | null { return this.session?.windowIndex ?? null; }
  private tab() {
    const st = this.host.state;
    const vm = st?.vms?.find(v => v.id === this.workspaceID);
    const w = this.window;
    return w == null ? undefined : vm?.tabs?.find(t => t.index === w);
  }
  private target(): PaneTarget | null {
    const w = this.window, s = this.session;
    if (w == null || !s) return null;
    const tab = this.tab();
    return paneTargetChat({ window: w, windowID: s.windowID, display: (s.launchDisplay as string) ?? (tab?.display as string),
                            worktree: tab?.worktreeBranch as string });
  }
  private pin(): TranscriptPin {
    const s = this.session;
    if (!s) return {};
    const st = this.host.state as RemoteState | null;
    const others = (st?.agentSessions ?? []).filter(o => o.id !== s.id && o.profileID === s.profileID && !o.deletedAt);
    const id = s.agentTranscriptID as string | undefined;
    if (s.tool === 'kimi' && id) { const p = transcriptPinForConversation('kimi', id); if (p.kimiSession) return p; }
    if (s.tool === 'grok' || s.tool === 'codex' || s.tool === 'omp') {
      const p = transcriptPinForConversation(s.tool, id);
      if (Object.keys(p).length) return p;
      p.foreignConversations = others.filter(o => o.tool === s.tool && o.agentTranscriptID).map(o => String(o.agentTranscriptID).toLowerCase());
      return p;
    }
    return { kimiExclude: others.filter(o => o.tool === 'kimi' && o.agentTranscriptID).map(o => String(o.agentTranscriptID)) };
  }
  private exec(cmd: string, timeout: number) { return this.host.guestExec(this.workspaceID, cmd, timeout); }

  private rawWorking(): boolean {
    if (this.mode === 'copy') return this.session?.demoBucket === 1;
    const tab = this.tab();
    return tab?.agentStatus === 'working' && this.session?.awaitingAnswer !== true;
  }
  private setWorking(raw: boolean) {
    // WorkingGate: an interrupt keeps the cue off until the agent says idle.
    if (this.interrupted) { if (!raw) this.interrupted = false; raw = false; }
    this.set({ working: raw, workingSince: raw ? (this.snap.workingSince ?? Date.now()) : undefined });
  }

  // ── lifecycle ──
  start() {
    if (!this.stopped) return;
    this.stopped = false;
    this.loadSlash();
    if (this.mode === 'copy') { this.loadCopy(); return; }
    const loop = async () => {
      if (this.stopped) return;
      try { await this.poll(); } catch (e) { console.warn('chat poll', e); }
      if (this.stopped) return;
      this.timer = setTimeout(loop, this.snap.working ? 400 : 1200);
    };
    loop();
  }
  stop() { this.stopped = true; if (this.timer) clearTimeout(this.timer); }

  private async loadCopy() {
    const s = this.session;
    if (!s) return;
    const text = await fetchSessionTranscript(this.host, s);
    if (this.stopped) return;
    if (text) this.applyParsed(parseTranscript(text, s.tool).items);
    this.set({ loading: false });
    this.setWorking(this.rawWorking());
  }

  private loadSlash() {
    const s = this.session;
    if (!s) return;
    const builtIn = builtInCommands(s.tool);
    this.set({ slash: builtIn, agent: s.tool, agentName: toolDisplayName(s.tool) });
    if (this.mode !== 'live') return;
    const cmd = discoveryCommand(s.tool, guestPathOf(s.cwd ?? '~'));
    if (!cmd) return;
    this.exec(cmd, 10).then(out => {
      const extra = parseDiscovery(out);
      if (!extra.length) return;
      const seen = new Set(builtIn.map(c => c.name));
      this.set({ slash: [...builtIn, ...extra.filter(c => !seen.has(c.name) && (seen.add(c.name), true))] });
    }).catch(() => {});
  }

  private failStreak = 0;
  private missingSince: number | null = null;

  private async read(earlier: boolean): Promise<'fetched' | 'none' | 'failed'> {
    const w = this.window;
    if (w == null || !this.tab()) return 'none';
    let meta: string;
    try { meta = await this.exec(floorProbeCommand(w), 8); } catch { return 'failed'; }
    const probe = parseFloorProbe(meta);
    if (!probe) return 'none';
    const agent = this.session?.tool ?? null;
    let pin = this.pin();
    if (agent === 'kimi' && !pin.kimiSession) pin = kimiUnpinnedPin(probe.kimiSession, probe.resumed, probe.since, pin.kimiExclude ?? []);
    const known = this.buffer;
    const cmd = transcriptChunkCommand({
      guestCwd: probe.cwd, since: probe.since, agent, pinnedWindow: w, pin,
      knownPath: known?.path ?? null, knownOffset: earlier ? (known?.base ?? -1) : (known?.end ?? -1),
      bytes: FAT_CLIENT_HISTORY_BYTES_HINT, earlier, pqFallback: true,
    });
    if (!cmd) return 'none';
    let out: string;
    try { out = await this.exec(cmd, 30); } catch { return 'failed'; }
    const f = parseTranscriptFetch(out);
    if (!f || isForeignConversation(f.path, agent, pin)) return 'none';
    this.set({ fileSize: f.size });
    if (earlier) {
      if (known && known.path === f.path && f.end === known.base) {
        this.buffer = { ...known, data: f.chunk + known.data, base: f.start };
      }
    } else {
      if (f.pq !== this.pq) { this.pq = f.pq; this.dirty = true; }
      if (known && known.path === f.path && f.start === known.end) {
        if (f.chunk) { this.buffer = { ...known, data: known.data + f.chunk, end: f.end }; this.dirty = true; }
      } else {
        this.buffer = { path: f.path, data: f.chunk, base: f.start, end: f.end };
        this.dirty = true;
      }
    }
    this.set({ canLoadEarlier: (this.buffer?.base ?? 0) > 0, heldBytes: this.buffer ? new Blob([this.buffer.data]).size : 0 });
    return 'fetched';
  }

  private dirty = false;
  private emptyStreak = 0;

  private async poll() {
    const working = this.rawWorking();
    const r = await this.read(false);
    if (this.stopped) return;
    const showing = this.parsed.length > 0;
    let issue: ChatSnapshot['loadIssue'] = null;
    if (r === 'fetched') { this.failStreak = 0; this.missingSince = null; }
    else if (r === 'failed') { this.failStreak++; this.missingSince = null; if (!showing && this.failStreak >= 2) issue = 'failed'; }
    else {
      this.failStreak = 0;
      if (!showing && working) {
        this.missingSince ??= Date.now();
        if (Date.now() - this.missingSince >= 20_000) issue = 'notFound';
      } else this.missingSince = null;
    }
    this.set({ loadIssue: issue });
    if (r !== 'fetched') {
      if (this.snap.loading && (r === 'none' || issue)) this.set({ loading: false });
      this.setWorking(working);
      return;
    }
    this.set({ loading: false });
    if (this.dirty) {
      this.dirty = false;
      let input = this.buffer?.data ?? '';
      if (this.pq) input += '\n' + this.pq + '\n';
      const parsed = parseTranscript(input, this.session?.tool).items;
      if (!parsed.length && this.parsed.length && ++this.emptyStreak < 4) { this.dirty = true; this.setWorking(working); return; }
      this.emptyStreak = 0;
      this.applyParsed(parsed);
    }
    this.reconcilePending();
    this.rebuild();
    this.setWorking(working);
  }

  private applyParsed(items: TranscriptItem[]) {
    this.parsed = items;
    this.rebuild();
  }

  private reconcilePending() {
    if (!this.pending.length) return;
    const recorded = this.parsed.filter(i => i.kind.t === 'userText').map(i => echoKey((i.kind as any).text));
    const now = Date.now();
    this.pending = this.pending.filter(p => {
      if (now - p.added > 120_000) return false;
      return !recorded.includes(echoKey((p.item.kind as any).text));
    });
  }

  retry() { this.failStreak = 0; this.missingSince = null; this.set({ loadIssue: null, loading: this.parsed.length === 0 }); }

  async loadEarlier() {
    if (this.snap.loadingEarlier || !this.buffer || this.buffer.base <= 0) return;
    this.set({ loadingEarlier: true });
    try {
      await this.read(true);
      let input = this.buffer?.data ?? '';
      if (this.pq) input += '\n' + this.pq + '\n';
      this.applyParsed(parseTranscript(input, this.session?.tool).items);
      this.reconcilePending();
      this.rebuild();
    } finally { this.set({ loadingEarlier: false }); }
  }

  // ── input ──

  /** Type `text` into the agent through the server (PaneTypeGuard there). */
  private async typeText(text: string): Promise<TypeOutcome> {
    const t = this.target();
    if (!t) return { refused: 'gone' };
    try {
      const r = await this.host.request<any>('POST', `/vms/${seg(this.workspaceID)}/type`,
        { target: JSON.parse(paneTargetJSON(t)), text }, { timeoutMs: 75_000, allowError: true });
      if (r?.typeRoute !== true) return 'failed';     // an older server: step-by-step typing isn't ported
      return typeOutcome(typeof r.output === 'string' ? r.output : null);
    } catch { return 'unreachable'; }
  }

  private hold(text: string, failure?: string, awaitingAnswer?: boolean) {
    this.set({ held: [...this.snap.held, { id: crypto.randomUUID(), text, failure, awaitingAnswer }] });
  }
  dropHeld(id: string) { this.set({ held: this.snap.held.filter(h => h.id !== id) }); }

  async stage(files: File[]): Promise<string[]> {
    if (!files.length) return [];
    const paths: string[] = [];
    // Every write (and a failed copy's cleanup) goes to the workspace the
    // drop was staged for, even if the session's state changes meanwhile.
    const ws = this.workspaceID;
    if (!ws) return paths;
    try { await this.host.guestFileOp(ws, { op: 'mkdir', path: DROP_DIR }); } catch { return paths; }
    const stamp = dropStamp();
    for (let n = 0; n < files.length; n++) {
      const f = files[n];
      const path = `${DROP_DIR}/${n}_${dropSafeName(stamp + '_' + f.name)}`;
      let ok = true;
      try {
        await writeGuestFile(f.stream(), path, 6 * 1024 * 1024,
          (op, t) => this.host.guestFileOp(ws, op, t), b64);
      } catch { ok = false; }
      if (ok) {
        paths.push(path);
        if (f.type.startsWith('image/')) {
          const url = URL.createObjectURL(f);
          this.set({ images: { ...this.snap.images, [path]: url } });
        }
      }
    }
    return paths;
  }

  /** BeautifiedSessionModel.send: the composer's text (+ staged files) as one message. */
  async send(raw: string, files: File[]): Promise<boolean> {
    const text0 = raw.trim();
    if ((!text0 && !files.length) || this.snap.sending) return false;
    if (this.mode !== 'live') return false;
    const isCommand = text0.startsWith('/') && !files.length && !text0.includes('\n');
    this.interrupted = false;
    this.set({ sending: true });
    if (!isCommand) this.setWorking(true);
    const id = 'echo:' + ++this.seq;
    let text = text0;
    if (!isCommand && text) {
      this.pending.push({ item: { id, kind: { t: 'userText', text } }, added: Date.now() });
      this.rebuild();
    }
    const paths = await this.stage(files);
    if (paths.length) {
      text = text ? text + ' ' + paths.join(' ') : paths.join(' ');
      const p = this.pending.find(x => x.item.id === id);
      if (p) p.item = { ...p.item, kind: { t: 'userText', text } };
      else if (!isCommand) this.pending.push({ item: { id, kind: { t: 'userText', text } }, added: Date.now() });
      this.rebuild();
    }
    const outcome = await this.typeText(text);
    this.set({ sending: false });
    if (outcome === 'typed') { this.poll().catch(() => {}); return true; }
    this.pending = this.pending.filter(p => p.item.id !== id);
    this.rebuild();
    this.setWorking(false);
    if (outcome === 'held') this.hold(text, undefined, true);
    else if (typeof outcome === 'object') this.hold(text, refusalText(outcome.refused));
    else if (outcome === 'unconfirmed') this.hold(text, NOT_DELIVERED);
    else if (outcome === 'dropped') this.hold(text, NOT_TAKEN);
    else this.hold(text, NOT_TYPED);
    return false;
  }

  /** Stop: Esc (or Ctrl-C where the agent's busy line says so) into the pane. */
  async interrupt() {
    this.interrupted = true;
    this.set({ working: false, workingSince: undefined });
    const t = this.target();
    if (!t) return;
    let key = this.session?.tool === 'grok' ? 'C-c' : 'Escape';
    try {
      const screen = await this.exec(resolvePaneTarget(t) + '[ -n "$_bt" ] && tmux capture-pane -p -t "$_bt" 2>/dev/null | tail -n 30', 4);
      for (const raw of screen.split('\n').slice(-14).reverse()) {
        const l = raw.trim().toLowerCase();
        if (l.includes('ctrl+c to interrupt') || l.includes('ctrl-c to interrupt')) { key = 'C-c'; break; }
        if (l.includes('esc to interrupt')) { key = 'Escape'; break; }
        if (l.endsWith('[stop]')) { key = 'C-c'; break; }
      }
    } catch {}
    const cmd = keysCommand(t, [key]);
    if (cmd) this.exec(cmd, 15).catch(() => {});
  }

  /** The round the agent waits on (unresolved questions at the end). */
  pendingQuestions(items: TranscriptItem[]): TranscriptItem[] {
    if (this.mode !== 'live' && this.session?.demoBucket !== 0) return [];
    const out: TranscriptItem[] = [];
    for (let i = items.length - 1; i >= 0; i--) {
      const k = items[i].kind;
      if (k.t === 'question') { if (questionResolved(k.q)) break; out.unshift(items[i]); }
      else if (k.t === 'todo') continue;
      else break;
    }
    return out;
  }

  async answerQuestions(keys: string[]): Promise<boolean> {
    const w = this.window, t = this.target();
    if (w == null || !t || !keys.length || this.mode !== 'live') return false;
    try { await this.exec(`tmux capture-pane -p -t bromure:${w} 2>/dev/null | grep -qE 'Enter to (select|confirm)'`, 8); }
    catch { return false; }
    this.setWorking(true);
    try { await this.exec(answerKeysCommand(t, keys), 60); } catch { return false; }
    this.poll().catch(() => {});
    return true;
  }
}

export function guestPathOf(p: string): string {
  const home = '/home/ubuntu', t = (p ?? '').trim();
  if (!t || t === '~') return home;
  if (t.startsWith('~/')) return home + t.slice(1);
  return t.startsWith('/') ? t : home + '/' + t;
}

export type { TranscriptQuestion };
