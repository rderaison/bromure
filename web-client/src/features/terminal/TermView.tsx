// The terminal surface: xterm.js (WebGL renderer, DOM fallback) wired to an
// AttachSession — the web counterpart of TerminalSurfaceView (libghostty) +
// the iOS RemoteTerminalView. Keys follow the generated ghostty config:
// ⌘C copies (never on select), ⌘V pastes (bracketed), ⌘= / ⌘- / ⌘0 zoom the
// font. On Linux/Windows the copy/paste chords are Ctrl+Shift+C / V (plain
// Ctrl+C stays ^C), zoom is Ctrl+= / Ctrl+- / Ctrl+0. Links open on a
// ⌘/Ctrl-click, as ghostty's.

import React, { useEffect, useRef, useState } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { WebLinksAddon } from '@xterm/addon-web-links';
import { Unicode11Addon } from '@xterm/addon-unicode11';
import { WebglAddon } from '@xterm/addon-webgl';
import '@xterm/xterm/css/xterm.css';
import type { RemoteHost } from '../../core/remote/host';
import { isMac, openExternal } from '../../platform';
import { AttachSession, type AttachPhase, type AttachTarget } from './attach';
import { PADDING, fontStack, xtermTheme, type TermStyle } from './termStyle';
import { Spinner } from '../../ui/kit';

export interface TermViewProps {
  host: RemoteHost;
  target: AttachTarget;
  style: TermStyle;
  autoFocus?: boolean;
  /** The guest shell ended cleanly (ctrl-D / exit). */
  onCleanExit?: () => void;
  /** The link dropped or came back (re-poll the roster). */
  onRelinked?: () => void;
  onPhase?: (p: AttachPhase) => void;
  /** Bumped by the owner to re-arm a cleanly exited session. */
  reviveTick?: number;
  className?: string;
}

/** Live terminals by element, for the dev harness / tests. */
export const liveTerminals = new Map<HTMLElement, { term: Terminal; session: AttachSession }>();

export function TermView({ host, target, style, autoFocus, onCleanExit, onRelinked, onPhase, reviveTick, className }: TermViewProps) {
  const hostRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<Terminal | null>(null);
  const sessionRef = useRef<AttachSession | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const cbs = useRef({ onCleanExit, onRelinked, onPhase });
  cbs.current = { onCleanExit, onRelinked, onPhase };
  const [phase, setPhase] = useState<AttachPhase>('connecting');
  const [everConnected, setEverConnected] = useState(false);
  const baseSize = useRef(style.fontSize);
  const key = `${target.vmID}|${target.windowIndex}|${target.scratch?.session ?? ''}`;

  useEffect(() => {
    const el = hostRef.current!;
    const term = new Terminal({
      fontFamily: fontStack(style.fontFamily),
      fontSize: style.fontSize,
      lineHeight: 1,
      letterSpacing: 0,
      theme: xtermTheme(style),
      cursorStyle: 'bar',
      cursorInactiveStyle: 'outline',
      cursorBlink: false,
      scrollback: 10000,
      allowProposedApi: true,
      macOptionIsMeta: false,
      rightClickSelectsWord: isMac,
      drawBoldTextInBrightColors: false,
      minimumContrastRatio: 1,
      fontWeightBold: 'bold',
    });
    termRef.current = term;
    const fit = new FitAddon();
    fitRef.current = fit;
    term.loadAddon(fit);
    term.loadAddon(new Unicode11Addon());
    term.unicode.activeVersion = '11';
    term.loadAddon(new WebLinksAddon((e, uri) => {
      if (isMac ? e.metaKey : e.ctrlKey) openExternal(uri);
    }));
    term.open(el);
    try {
      const gl = new WebglAddon();
      gl.onContextLoss(() => gl.dispose());   // the DOM renderer takes over
      term.loadAddon(gl);
    } catch { /* no WebGL2: the DOM renderer */ }

    const zoom = (d: number | 0) => {
      const size = d === 0 ? baseSize.current : Math.max(6, Math.min(72, (term.options.fontSize ?? 14) + d));
      term.options.fontSize = size;
      try { fit.fit(); } catch {}
    };
    term.attachCustomKeyEventHandler(e => {
      if (e.type !== 'keydown') return true;
      const mod = isMac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
      if (!mod || e.altKey) return true;
      const k = e.key.toLowerCase();
      if (k === '=' || k === '+') { e.preventDefault(); zoom(1); return false; }
      if (k === '-') { e.preventDefault(); zoom(-1); return false; }
      if (k === '0') { e.preventDefault(); zoom(0); return false; }
      if (isMac) {
        // ⌘C / ⌘V: the browser's copy / paste events reach xterm's own
        // handlers (selection copy, bracketed paste) — let them through.
        if (k === 'c' || k === 'v' || k === 'a') { if (k === 'a') { e.preventDefault(); term.selectAll(); } return false; }
        return false;   // other ⌘ chords belong to the app, not the shell
      }
      if (e.shiftKey && k === 'c') {
        e.preventDefault();
        const sel = term.getSelection();
        if (sel) navigator.clipboard?.writeText(sel).catch(() => {});
        return false;
      }
      if (e.shiftKey && k === 'v') {
        e.preventDefault();
        navigator.clipboard?.readText().then(t => t && term.paste(t)).catch(() => {});
        return false;
      }
      return true;
    });

    const session = new AttachSession(host, target, {
      data: b => term.write(b),
      phase: p => {
        setPhase(p);
        if (p === 'connected') setEverConnected(true);
        cbs.current.onPhase?.(p);
      },
      cleanExit: () => cbs.current.onCleanExit?.(),
      relinked: () => cbs.current.onRelinked?.(),
    });
    sessionRef.current = session;
    liveTerminals.set(el, { term, session });
    term.onData(d => session.input(d));
    term.onBinary(d => session.input(Uint8Array.from(d, c => c.charCodeAt(0) & 0xff)));
    term.onResize(({ cols, rows }) => session.resize(cols, rows));

    let started = false;
    const ro = new ResizeObserver(() => {
      if (!el.clientWidth || !el.clientHeight) return;
      try { fit.fit(); } catch { return; }
      if (!started) { started = true; session.start(term.cols, term.rows); }
    });
    ro.observe(el);
    if (autoFocus) setTimeout(() => term.focus(), 0);

    return () => {
      ro.disconnect();
      liveTerminals.delete(el);
      session.close();
      term.dispose();
      termRef.current = null; sessionRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [host, key]);

  // Appearance changes restyle the live surface (applyProfile).
  useEffect(() => {
    const term = termRef.current;
    if (!term) return;
    baseSize.current = style.fontSize;
    term.options.theme = xtermTheme(style);
    term.options.fontFamily = fontStack(style.fontFamily);
    if (term.options.fontSize !== style.fontSize) term.options.fontSize = style.fontSize;
    try { fitRef.current?.fit(); } catch {}
  }, [style.fontFamily, style.fontSize, style.background, style.foreground]);

  useEffect(() => { if (reviveTick) sessionRef.current?.revive(); }, [reviveTick]);

  const veil = phase === 'connecting' || phase === 'reconnecting';
  return (
    <div className={'term-surface' + (className ? ' ' + className : '')}
         style={{ background: style.background, padding: PADDING }}
         onMouseDown={() => setTimeout(() => termRef.current?.focus(), 0)}>
      <div ref={hostRef} className="term-host" />
      {veil && <ReconnectVeil text={everConnected || phase === 'reconnecting' ? 'Reconnecting…' : 'Connecting…'} delayed={!everConnected} />}
    </div>
  );
}

/** iOS ReconnectVeil: a pulsing capsule over a dimmed surface. The first
 *  connect shows it only after a beat (a quick attach never flashes it). */
function ReconnectVeil({ text, delayed }: { text: string; delayed: boolean }) {
  const [shown, setShown] = useState(!delayed);
  useEffect(() => {
    if (!delayed) { setShown(true); return; }
    const t = setTimeout(() => setShown(true), 700);
    return () => clearTimeout(t);
  }, [delayed]);
  if (!shown) return null;
  return (
    <div className="term-veil">
      <div className="term-veil-pill"><Spinner size={14} /><span>{text}</span></div>
    </div>
  );
}
