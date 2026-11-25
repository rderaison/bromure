// One attached terminal on a workspace's tmux window (or a scratch tmux
// session): the web port of iOS AttachSession.swift + the macOS
// TerminalSessionController's reattach / size-authority logic.
//
//  - Opens the framed-PTY interactive exec stream (POST /vms/<id>/exec).
//  - A bare drop (EOF, link loss, VM reboot) reconnects with capped,
//    jittered backoff while someone is looking (visible); a run that lasted
//    10 s resets the backoff.
//  - A CLEAN exit (PTY exit frame: ctrl-D / `exit`, the window gone) parks
//    the session — re-dialing would resurrect the window the user just
//    closed. `revive()` re-arms it if the window comes back in the roster.
//  - Attaches size-passive (tmux `ignore-size`) under a stable view name, and
//    grants itself size authority only while this page is focused with
//    recent input (TerminalSessionController.assertSizeAuthority) — so a
//    background browser tab never resizes the shared window out from under
//    the person actually working in it.

import { PTY, ptyFrame, seg, type RemoteHost } from '../../core/remote/host';
import { concat, utf8 } from '../../core/ssh/wire';

export type AttachPhase = 'connecting' | 'connected' | 'reconnecting' | 'exited' | 'closed';

export interface AttachTarget {
  vmID: string;
  /** tmux window of the shared `bromure` session; ignored for scratch. */
  windowIndex: number;
  /** A scratch terminal: its own guest tmux session (the chat's /term). */
  scratch?: { session: string; cwd: string };
}

export interface AttachEvents {
  data(bytes: Uint8Array): void;
  phase(p: AttachPhase): void;
  /** The guest shell exited cleanly (PTY exit frame). */
  cleanExit?(code: number | null): void;
  /** The link came back after a drop (the roster is likely stale). */
  relinked?(): void;
}

type Channel = Awaited<ReturnType<RemoteHost['openStream']>>;

/** Stable per page load: window i's view session is `view-v<token>w<i>`. */
const viewToken = Array.from(crypto.getRandomValues(new Uint8Array(4)), b => b.toString(16).padStart(2, '0')).join('');
export function viewName(windowIndex: number) { return `v${viewToken}w${windowIndex}`; }

/** CLICommands.scratchCommand: attach to (or create) the scratch tmux session in `cwd`. */
export function scratchCommand(session: string, cwd: string): string {
  const q = (s: string) => "'" + s.replace(/'/g, "'\\''") + "'";
  const name = session.replace(/[^A-Za-z0-9-]/g, '').slice(0, 48);
  const dir = cwd === '~' ? '$HOME' : cwd.startsWith('~/') ? '$HOME/' + q(cwd.slice(2)) : q(cwd);
  return `d=${dir}; [ -d "$d" ] || d="$HOME"; `
    + `exec tmux new-session -A -s ${q(name)} -c "$d" \\; set-option status off \\; `
    + `set-option mouse off \\; set-option -s set-clipboard on`;
}

/** TerminalSessionController.scratchSession */
export function scratchSessionName(key: string) {
  return 'scratch-' + key.toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 40);
}

export class AttachSession {
  phase: AttachPhase = 'connecting';
  everConnected = false;
  private ch: Channel | null = null;
  private stopped = false;
  private pumping = false;
  private delay = 1000;
  private lastConnectAt = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private cols = 80;
  private rows = 24;
  private gen = 0;

  constructor(private host: RemoteHost, readonly target: AttachTarget, private ev: AttachEvents) {
    document.addEventListener('visibilitychange', this.onVisibility);
    window.addEventListener('online', this.kick);
  }

  get isScratch() { return !!this.target.scratch; }

  start(cols: number, rows: number) {
    this.cols = cols; this.rows = rows;
    if (this.pumping || this.stopped) return;
    this.pump();
  }

  private setPhase(p: AttachPhase) { this.phase = p; this.ev.phase(p); }

  private onVisibility = () => { if (!document.hidden) this.kick(); };

  /** Reconnect now (back from the background, the network changed). */
  kick = () => {
    if (this.stopped || this.phase === 'exited') return;
    this.delay = 1000;
    if (!this.pumping) this.pump();
  };

  private pump() {
    if (this.stopped) return;
    this.pumping = true;
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    const go = () => { this.timer = null; this.lastConnectAt = performance.now(); this.open(); };
    // A re-dial after a failure waits out the backoff (±25% jitter so
    // terminals knocked off by one blip don't re-dial in lockstep); the first
    // attach, and one after a long healthy run, go at once.
    if (this.delay > 1000) {
      this.timer = setTimeout(go, this.delay * (0.75 + Math.random() * 0.5));
    } else go();
  }

  private async open() {
    const gen = ++this.gen;
    if (this.phase !== 'connected') this.setPhase(this.everConnected ? 'reconnecting' : 'connecting');
    const t = this.target;
    const body: Record<string, unknown> = { interactive: true, cols: this.cols, rows: this.rows, guiConsent: true };
    if (t.scratch) body.command = scratchCommand(t.scratch.session, t.scratch.cwd);
    else Object.assign(body, { command: '', view: viewName(t.windowIndex), window: t.windowIndex, sizePassive: true });
    let ch: Channel;
    try {
      ch = await this.host.openStream('POST', `/vms/${seg(t.vmID)}/exec`, body);
    } catch {
      if (gen === this.gen) this.ended(false);
      return;
    }
    if (this.stopped || gen !== this.gen) { ch.close(); return; }
    this.ch = ch;
    const wasReconnect = this.everConnected;
    let buf: Uint8Array = new Uint8Array(0);
    let clean = false;
    let exitCode: number | null = null;
    ch.onData = d => {
      buf = buf.length ? concat(buf, d) : d;
      let at = 0;
      while (buf.length - at >= 5) {
        const type = buf[at];
        const len = ((buf[at + 1] << 24) | (buf[at + 2] << 16) | (buf[at + 3] << 8) | buf[at + 4]) >>> 0;
        if (len > 16 * 1024 * 1024) { ch.close(); return; }   // no PTY frame is this big: a broken stream
        if (buf.length - at < 5 + len) break;
        const payload = buf.subarray(at + 5, at + 5 + len);
        if (type === PTY.data && len) {
          if (this.phase !== 'connected') this.connected(wasReconnect);
          this.ev.data(payload.slice());
        } else if (type === PTY.exit) {
          clean = true;
          exitCode = len >= 4 ? ((payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3]) : null;
        }
        at += 5 + len;
      }
      if (at) buf = buf.slice(at);
      if (clean) ch.close();
    };
    ch.onClose = () => {
      if (this.ch === ch) this.ch = null;
      if (gen === this.gen) this.ended(clean, exitCode);
    };
    ch.resume();
    // The stream is up: push our geometry so tmux repaints at our size, and
    // say connected even before the first byte (an idle shell sends none).
    this.resize(this.cols, this.rows, true);
    setTimeout(() => { if (this.ch === ch && this.phase !== 'connected') this.connected(wasReconnect); }, 400);
  }

  private connected(wasReconnect: boolean) {
    this.everConnected = true;
    this.setPhase('connected');
    if (wasReconnect) this.ev.relinked?.();
    if (!this.isScratch) authority.add(this);
  }

  private ended(clean: boolean, code: number | null = null) {
    authority.remove(this);
    if (this.everConnected) this.ev.relinked?.();
    // A run that lasted a while resets the backoff.
    if (performance.now() - this.lastConnectAt > 10000) this.delay = 1000;
    else this.delay = Math.min(this.delay * 2, 30000);
    if (this.stopped) { this.pumping = false; return; }
    if (clean) {
      this.pumping = false;
      this.setPhase('exited');
      this.ev.cleanExit?.(code);
      return;
    }
    this.setPhase(this.everConnected ? 'reconnecting' : 'connecting');
    // Only re-dial while someone is looking; visibilitychange kicks it.
    if (document.hidden) { this.pumping = false; return; }
    this.pump();
  }

  /** Re-arm a cleanly-exited session whose window is back in the roster. */
  revive() {
    if (this.phase !== 'exited' || this.stopped) return;
    this.delay = 1000;
    this.pump();
  }

  input(data: string | Uint8Array) {
    this.ch?.write(ptyFrame(PTY.data, typeof data === 'string' ? utf8(data) : data));
  }

  resize(cols: number, rows: number, force = false) {
    if (!force && cols === this.cols && rows === this.rows) return;
    this.cols = cols; this.rows = rows;
    const p = new Uint8Array([(cols >> 8) & 0xff, cols & 0xff, (rows >> 8) & 0xff, rows & 0xff]);
    this.ch?.write(ptyFrame(PTY.resize, p));
  }

  get size() { return { cols: this.cols, rows: this.rows }; }

  close() {
    this.stopped = true;
    this.gen++;
    if (this.timer) clearTimeout(this.timer);
    document.removeEventListener('visibilitychange', this.onVisibility);
    window.removeEventListener('online', this.kick);
    authority.remove(this);
    this.ch?.close();
    this.ch = null;
    this.setPhase('closed');
  }

  /** Expose the host for the authority pass. */
  get remote() { return this.host; }
}

// ── size authority (TerminalSessionController "Size authority") ───────────

const FLOOR_COLS = 100, FLOOR_ROWS = 30;

function sizeFloorCommand(window: number) {
  const t = `'bromure:${window}'`;
  return `if ! tmux list-clients -F '#{window_index} #{client_flags}' 2>/dev/null`
    + ` | grep -v ignore-size | grep -q '^${window} '; then`
    + ` set -- $(tmux display-message -p -t ${t} '#{window_width} #{window_height}' 2>/dev/null)`
    + `; if [ -n "$1" ] && { [ "$1" -lt ${FLOOR_COLS} ] || [ "$2" -lt ${FLOOR_ROWS} ]; }; then`
    + ` tmux resize-window -t ${t} -x $(( $1 < ${FLOOR_COLS} ? ${FLOOR_COLS} : $1 )) -y $(( $2 < ${FLOOR_ROWS} ? ${FLOOR_ROWS} : $2 ))`
    + `; fi; fi`;
}

const authority = new (class {
  private live = new Set<AttachSession>();
  private last = new Map<AttachSession, boolean>();
  private lastPush = 0;
  private lastInput = performance.now();
  private tick: ReturnType<typeof setInterval> | null = null;
  private scheduled = false;
  private installed = false;

  private install() {
    if (this.installed) return;
    this.installed = true;
    const touch = () => { this.lastInput = performance.now(); };
    for (const e of ['keydown', 'mousedown', 'wheel', 'touchstart'])
      window.addEventListener(e, touch, { capture: true, passive: true });
    for (const e of ['focus', 'blur']) window.addEventListener(e, () => this.schedule());
    document.addEventListener('visibilitychange', () => this.schedule());
  }

  add(s: AttachSession) {
    this.install();
    this.live.add(s);
    if (!this.tick) this.tick = setInterval(() => this.assert(true), 20000);
    // A fresh client comes up passive: grant at once, and again shortly after
    // (the attach settles a beat later).
    this.assert(true);
    setTimeout(() => this.assert(true), 1500);
  }
  remove(s: AttachSession) {
    this.live.delete(s); this.last.delete(s);
    if (!this.live.size && this.tick) { clearInterval(this.tick); this.tick = null; }
  }
  private schedule() {
    if (this.scheduled) return;
    this.scheduled = true;
    setTimeout(() => { this.scheduled = false; this.assert(); }, 400);
  }
  private activelyUsed() {
    return !document.hidden && document.hasFocus() && performance.now() - this.lastInput < 180000;
  }
  private assert(force = false) {
    if (!this.live.size) return;
    const active = this.activelyUsed();
    let changed = false;
    for (const s of this.live) if (this.last.get(s) !== active) changed = true;
    if (!force && !changed && performance.now() - this.lastPush < 15000) return;
    this.lastPush = performance.now();
    const byVM = new Map<string, { host: RemoteHost; parts: string[] }>();
    for (const s of this.live) {
      this.last.set(s, active);
      const idx = s.target.windowIndex;
      const session = `view-${viewName(idx)}`;
      const e = byVM.get(s.target.vmID) ?? { host: s.remote, parts: [] };
      byVM.set(s.target.vmID, e);
      if (active) {
        e.parts.push(`tmux set-option -wu -t 'bromure:${idx}' window-size 2>/dev/null`
          + `; set -- $(tmux list-clients -t '${session}' -F '#{client_tty} #{client_width} #{client_height}' 2>/dev/null | head -1)`
          + `; [ -n "$1" ] && tmux refresh-client -t "$1" -f '!ignore-size' && tmux refresh-client -t "$1" -C "\${2}x\${3}"`);
      } else {
        e.parts.push(`set -- $(tmux list-clients -t '${session}' -F '#{client_tty}' 2>/dev/null | head -1)`
          + `; [ -n "$1" ] && tmux refresh-client -t "$1" -f ignore-size`);
        e.parts.push(sizeFloorCommand(idx));
      }
    }
    for (const [vmID, e] of byVM) {
      e.host.guestExec(vmID, e.parts.join('; ') + '; true', 10).catch(() => {});
    }
  }
})();
