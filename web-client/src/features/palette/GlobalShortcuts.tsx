// The macOS menu bar's key equivalents, for a window with no menu bar
// (BromureAC.swift buildMainMenu). Each dispatches `bromure:open` (events.ts)
// for the surface that owns it; the palette lists the same commands.
//
//   ⌘K Go to… (palette)      ⌘N New Session…          ⌘, Preferences…
//   ⇧⌘K Connect to Remote…   ⇧⌘N New Workspace…       ⇧⌘A Automations
//   ⇧⌘T Tasks                ⇧⌘I Trace Inspector…     ⇧⌘G New worktree (branch)
//   ⌃⌘S Toggle Sidebar       ⌃⌘E Toggle Files Pane
//
// ⌘ is Ctrl off macOS; ⌃⌘ becomes Ctrl+Alt there. In a terminal off macOS,
// Ctrl chords belong to the shell (Ctrl+K kills a line), so they're left alone
// unless Shift or Alt is held too.

import { useEffect, useRef } from 'react';
import { useHostCtx } from '../../app/hostContext';
import { isMac } from '../../platform';
import { openSurface, useOpenListener } from './events';

export function GlobalShortcuts() {
  const ctx = useHostCtx();
  const ref = useRef(ctx);
  ref.current = ctx;
  // "Connect to Remote Bromure…": the picker (this mirror stays connected).
  useOpenListener(d => {
    if (d.what !== 'connect') return;
    try { sessionStorage.setItem('bromure.connect.returnTo', location.hash); } catch {}
    location.hash = '#/';
  });
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.repeat) return;
      const mod = isMac ? e.metaKey : e.ctrlKey;
      if (!mod) return;
      const ctrl2 = isMac ? e.ctrlKey : e.altKey;   // the ⌃ in ⌃⌘
      const target = e.target as HTMLElement | null;
      if (!isMac && !e.shiftKey && !e.altKey && target?.closest?.('.xterm')) return;
      const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
      const { selection, sidebarCollapsed, setSidebarCollapsed } = ref.current;
      let act: (() => void) | null = null;
      if (ctrl2 && !e.shiftKey) {
        if (k === 's') act = () => setSidebarCollapsed(!sidebarCollapsed);
        else if (k === 'e') act = () => openSurface('toggle-files');
      } else if (e.shiftKey && !ctrl2) {
        switch (k) {
          case 'k': act = () => openSurface('connect'); break;
          case 'n': act = () => openSurface('new-machine'); break;
          case 'a': act = () => openSurface('automation-board'); break;
          case 't': act = () => openSurface('task-board'); break;
          case 'i': act = () => openSurface('trace'); break;
          case 'g': if (selection.kind === 'session') act = () => openSurface('new-branch', { sessionID: selection.sessionID }); break;
        }
      } else if (!e.shiftKey && !ctrl2 && !e.altKey) {
        switch (k) {
          case 'k': act = () => openSurface('palette'); break;
          case 'n': act = () => openSurface('new-session'); break;
          case ',': act = () => openSurface('preferences'); break;
        }
      }
      if (!act) return;
      e.preventDefault();
      e.stopPropagation();
      act();
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, []);
  return null;
}
