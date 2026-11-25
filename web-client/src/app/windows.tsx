// Secondary windows (Security, Trace Inspector, workspace Settings, boards…)
// as in-app floating windows: the same in Electron and the browser, and they
// share the one SSH link. Draggable by the titlebar, resizable from the
// corner, click-to-front, ⌘W / Ctrl+W closes the key window.

import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { cx } from '../ui/kit';
import { isMod } from '../platform';
import { ErrorBoundary } from './ErrorBoundary';

export interface WindowSpec {
  id: string;                 // one window per id (re-open focuses it)
  title?: string;             // shown in the titlebar (omit for toolbar-style windows)
  width: number; height: number;
  minWidth?: number; minHeight?: number;
  /** 'titled' = 32pt titlebar with the title; 'toolbar' = 52pt strip the
   *  content draws into (render receives the titlebar slot); 'none' = content
   *  draws everything (still draggable via [data-drag]). */
  chrome?: 'titled' | 'toolbar' | 'none';
  render: (ctx: WindowCtx) => React.ReactNode;
  /** Asked before ⌘W closes the window (false = it handles the close itself). */
  closeGuard?: { current?: () => boolean };
}

export interface WindowCtx { close: () => void; id: string; setTitle: (t: string) => void }

interface Live extends WindowSpec { x: number; y: number; z: number }

interface WM {
  open: (w: WindowSpec) => void;
  close: (id: string) => void;
  isOpen: (id: string) => boolean;
}
const Ctx = createContext<WM>({ open: () => {}, close: () => {}, isOpen: () => false });
export const useWindows = () => useContext(Ctx);

let zTop = 10;

export function WindowHost({ children }: { children: React.ReactNode }) {
  const [wins, setWins] = useState<Live[]>([]);
  const winsRef = useRef(wins); winsRef.current = wins;

  const open = useCallback((spec: WindowSpec) => {
    setWins(ws => {
      const existing = ws.find(w => w.id === spec.id);
      if (existing) return ws.map(w => w.id === spec.id ? { ...w, ...spec, x: w.x, y: w.y, width: w.width, height: w.height, z: ++zTop } : w);
      const vw = window.innerWidth, vh = window.innerHeight;
      const width = Math.min(spec.width, vw - 24), height = Math.min(spec.height, vh - 24);
      const n = ws.length;
      return [...ws, { ...spec, width, height, x: Math.max(12, (vw - width) / 2 + n * 22), y: Math.max(12, (vh - height) / 2.6 + n * 22), z: ++zTop }];
    });
  }, []);
  const close = useCallback((id: string) => setWins(ws => ws.filter(w => w.id !== id)), []);
  const isOpen = useCallback((id: string) => winsRef.current.some(w => w.id === id), []);
  const wm = useMemo(() => ({ open, close, isOpen }), [open, close, isOpen]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isMod(e) && e.key.toLowerCase() === 'w' && winsRef.current.length) {
        const top = [...winsRef.current].sort((a, b) => b.z - a.z)[0];
        e.preventDefault(); e.stopPropagation();
        if (top.closeGuard?.current && !top.closeGuard.current()) return;
        close(top.id);
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [close]);

  const topZ = Math.max(0, ...wins.map(w => w.z));
  return (
    <Ctx.Provider value={wm}>
      {children}
      <div className="win-layer">
        {wins.map(w => (
          <FloatingWindow key={w.id} w={w} isKey={w.z === topZ}
            onFocus={() => setWins(ws => ws.map(x => x.id === w.id ? { ...x, z: ++zTop } : x))}
            onMove={(x, y) => setWins(ws => ws.map(o => o.id === w.id ? { ...o, x, y } : o))}
            onResize={(width, height) => setWins(ws => ws.map(o => o.id === w.id ? { ...o, width, height } : o))}
            onClose={() => close(w.id)}
            setTitle={t => setWins(ws => ws.map(o => o.id === w.id ? { ...o, title: t } : o))} />
        ))}
      </div>
    </Ctx.Provider>
  );
}

function FloatingWindow({ w, isKey, onFocus, onMove, onResize, onClose, setTitle }: {
  w: Live; isKey: boolean; onFocus: () => void; onMove: (x: number, y: number) => void;
  onResize: (w: number, h: number) => void; onClose: () => void; setTitle: (t: string) => void;
}) {
  const startDrag = (e: React.MouseEvent) => {
    const t = e.target as HTMLElement;
    if (t.closest('button, input, select, textarea, a, [data-nodrag]')) return;
    e.preventDefault();
    const sx = e.clientX - w.x, sy = e.clientY - w.y;
    const mm = (ev: MouseEvent) => onMove(Math.max(-w.width + 80, Math.min(ev.clientX - sx, window.innerWidth - 80)), Math.max(0, Math.min(ev.clientY - sy, window.innerHeight - 40)));
    const mu = () => { window.removeEventListener('mousemove', mm); window.removeEventListener('mouseup', mu); };
    window.addEventListener('mousemove', mm); window.addEventListener('mouseup', mu);
  };
  const startResize = (e: React.MouseEvent) => {
    e.preventDefault(); e.stopPropagation();
    const sx = e.clientX, sy = e.clientY, sw = w.width, sh = w.height;
    const mm = (ev: MouseEvent) => onResize(Math.max(w.minWidth ?? 360, sw + ev.clientX - sx), Math.max(w.minHeight ?? 240, sh + ev.clientY - sy));
    const mu = () => { window.removeEventListener('mousemove', mm); window.removeEventListener('mouseup', mu); };
    window.addEventListener('mousemove', mm); window.addEventListener('mouseup', mu);
  };
  const chrome = w.chrome ?? 'titled';
  const ctx: WindowCtx = { close: onClose, id: w.id, setTitle };
  return (
    <div className={cx('win', isKey && 'key')} style={{ left: w.x, top: w.y, width: w.width, height: w.height, zIndex: w.z }}
         onMouseDown={onFocus}
         onMouseDownCapture={e => { if ((e.target as HTMLElement).closest('[data-drag]')) startDrag(e); }}>
      {chrome !== 'none' && (
        <div className={cx('win-titlebar', chrome === 'toolbar' && 'toolbar')} onMouseDown={startDrag}>
          <Lights onClose={onClose} />
          {w.title && <span className="win-title">{w.title}</span>}
        </div>
      )}
      <div className="win-body"><ErrorBoundary name={'window:' + w.id}>{w.render(ctx)}</ErrorBoundary></div>
      <div className="win-resize" onMouseDown={startResize} />
    </div>
  );
}

export function Lights({ onClose, onMinimize, onZoom }: { onClose?: () => void; onMinimize?: () => void; onZoom?: () => void }) {
  return (
    <div className="lights" data-nodrag>
      <span onClick={onClose} title="Close" />
      <span onClick={onMinimize} title="Minimize" />
      <span onClick={onZoom} title="Zoom" />
    </div>
  );
}
