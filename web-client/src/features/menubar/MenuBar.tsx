// The macOS menu bar, in the window. A web page / frameless Electron window
// has no menu bar, so the native one (BromureAC.swift `buildMainMenu`) is
// drawn in the titlebar strip — Bromure · Workspaces · Edit · View · Window ·
// Help — with every item the fat-client window answers, the same titles,
// order and shortcuts (⌘ → Ctrl off macOS), enabled by the same context
// (validateMenuItem: a machine / tab / worktree on stage). Commands reuse the
// `bromure:open` vocabulary (features/palette/events.ts). Items that act on the
// LOCAL Mac only (Rebuild Base Image, Install Command-Line Tool, Inference
// Metrics/Log, Credential Approvals, Quick Task, Open ext4 file…) are left out:
// see NOT_PORTED.md.

import React, { useEffect, useRef, useState } from 'react';
import { useHostCtx, type StageSelection } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { useMenu, type MenuItem } from '../../ui/kit';
import { electron, isMac, openExternal } from '../../platform';
import { openSurface } from '../palette/events';
import { workspaceActions } from '../sidebar/actions';
import { showAlert } from '../sidebar/Dialogs';
import type { RemoteState, VMTab } from '../../core/remote/types';
import './menubar.css';

const MANUAL_URL = 'https://bromure.io/en/docs/agentic-coding';

/** "⌘N" on macOS, "Ctrl+N" elsewhere; mods in macOS order ⌃⌥⇧⌘. */
export function shortcut(key: string, mods: ('ctrl' | 'opt' | 'shift' | 'cmd')[] = ['cmd']): string {
  if (isMac) {
    const sym = { ctrl: '⌃', opt: '⌥', shift: '⇧', cmd: '⌘' };
    return (['ctrl', 'opt', 'shift', 'cmd'] as const).filter(m => mods.includes(m)).map(m => sym[m]).join('') + key.toUpperCase();
  }
  // Off macOS ⌘ is Ctrl, and ⌃⌘ (two modifiers that both map to Ctrl) is Ctrl+Alt.
  const parts: string[] = [];
  if (mods.includes('cmd') || mods.includes('ctrl')) parts.push('Ctrl');
  if (mods.includes('opt') || (mods.includes('ctrl') && mods.includes('cmd'))) parts.push('Alt');
  if (mods.includes('shift')) parts.push('Shift');
  return [...parts, key.toUpperCase()].join('+');
}

interface MachineContext { profileID: string; name: string; tab?: VMTab & Record<string, any>; running: boolean }

/** The machine (and tmux tab) the stage is about — what the native menu's
 *  machine items act on (`machineOnStage` / the selected tab). */
function machineContext(sel: StageSelection, st: RemoteState | undefined): MachineContext | null {
  if (!st) return null;
  let pid: string | undefined, win: number | undefined;
  if (sel.kind === 'workspace') { pid = sel.workspaceID; win = sel.windowIndex; }
  else if (sel.kind === 'session') {
    const s = st.agentSessions?.find(x => x.id === sel.sessionID);
    pid = s?.profileID; win = s?.windowIndex;
  }
  if (!pid) return null;
  const ws = st.workspaces.find(w => w.id === pid);
  const vm = st.vms.find(v => v.id === pid);
  const tabs = (vm?.tabs ?? []) as (VMTab & Record<string, any>)[];
  const tab = tabs.find(t => t.index === win) ?? tabs.find(t => t.active) ?? tabs[0];
  return { profileID: pid, name: (ws?.name as string) ?? 'this machine', tab, running: !!vm && (ws?.state ?? 'running') !== 'off' };
}

export function MenuBar() {
  const ctx = useHostCtx();
  const { host, selection, select, viewMode, setViewMode, sidebarCollapsed, setSidebarCollapsed } = ctx;
  const st = useRemote(host, s => s);
  const menu = useMenu();
  const [openTitle, setOpenTitle] = useState<string | null>(null);
  const ref = useRef<HTMLDivElement>(null);

  const mc = machineContext(selection, st as RemoteState | undefined);
  const ws = workspaceActions(host);
  const tab = mc?.tab;
  const isWorktree = !!tab?.worktreeBranch;
  const isGit = !!(tab?.isGitRepo || tab?.repoRoot || isWorktree);
  const rooms = (st?.agentRooms ?? []).filter(r => !(r as any).archivedAt);

  const nextRoom = () => {
    if (!rooms.length) return;
    const i = selection.kind === 'room' ? rooms.findIndex(r => r.id === selection.roomID) : -1;
    select({ kind: 'room', roomID: rooms[(i + 1) % rooms.length].id });
  };
  const addToGrid = () => {
    if (!mc || !tab) return;
    const cells = ((st?.gridLayout?.cells ?? []) as any[]).filter(c => !(c.profileID === mc.profileID && c.windowIndex === tab.index));
    host.send('POST', '/grid-layout', { cells: [...cells, { profileID: mc.profileID, windowIndex: tab.index, label: tab.title ?? '' }], autoFill: st?.gridLayout?.autoFill ?? true });
  };
  const fullScreen = () => {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    else document.documentElement.requestFullscreen().catch(() => {});
  };
  const edit = (cmd: string) => () => { try { document.execCommand(cmd); } catch {} };
  const about = () => showAlert('Bromure Client',
    `The remote client for Bromure Agentic Coding${electron?.appVersion ? ` — version ${electron.appVersion}` : ''}.\n\nConnected to ${host.target.name}` +
    `${st?.build?.version ? ` (Bromure ${st.build.version}${st.build.commit ? ', ' + st.build.commit : ''})` : ''}.`,
    [{ label: 'OK', value: 'ok', default: true }]);

  const menus: { title: string; items: MenuItem[] }[] = [
    { title: 'Bromure', items: [
      { label: 'About Bromure Client', action: about },
      { separator: true },
      { label: 'Preferences…', shortcut: shortcut(','), action: () => openSurface('preferences') },
      ...(electron ? [{ separator: true } as MenuItem, { label: 'Quit Bromure Client', shortcut: shortcut('q'), action: () => electron!.windowControl('close') }] : []),
    ] },
    { title: 'Workspaces', items: [
      { label: 'New Session…', shortcut: shortcut('n'), action: () => openSurface('new-session') },
      { label: 'New Room…', action: () => openSurface('new-room') },
      { label: 'Go to…', shortcut: shortcut('k'), action: () => openSurface('palette') },
      { label: 'Next Room', shortcut: shortcut('r', ['ctrl', 'cmd']), disabled: !rooms.length, action: nextRoom },
      { separator: true },
      { label: 'New Workspace…', shortcut: shortcut('n', ['shift', 'cmd']), action: () => openSurface('new-machine') },
      { header: 'Infrastructure' },
      { label: 'Create Kubernetes Cluster…', action: () => openSurface('new-cluster') },
      { label: 'Create Registry…', action: () => openSurface('new-registry') },
      { separator: true },
      { label: 'Connect to Remote Bromure…', shortcut: shortcut('k', ['shift', 'cmd']), action: () => openSurface('connect') },
      { separator: true },
      { label: 'New tab', shortcut: shortcut('t'), disabled: !mc?.running, action: () => mc && ws.newTab(mc.profileID) },
      { label: 'Add Terminal to Grid', shortcut: shortcut('d'), disabled: !mc?.running || !tab || !!tab.containerID, action: addToGrid },
      { separator: true },
      { label: 'Automations', shortcut: shortcut('a', ['shift', 'cmd']), action: () => openSurface('automation-board') },
      { label: 'Tasks', shortcut: shortcut('t', ['shift', 'cmd']), action: () => openSurface('task-board') },
      { separator: true },
      { label: 'Terminal', shortcut: shortcut('u', ['opt', 'cmd']), disabled: selection.kind !== 'session',
        checked: selection.kind === 'session' ? viewMode === 'terminal' : undefined,
        action: () => setViewMode(viewMode === 'terminal' ? 'chat' : 'terminal') },
      { label: 'Delete', disabled: selection.kind !== 'workspace' || !mc, action: () => mc && ws.deleteWorkspace(mc.profileID, mc.name) },
      { separator: true },
      { label: 'New worktree', shortcut: shortcut('g', ['shift', 'cmd']), disabled: !mc?.running || !tab || !isGit,
        action: () => { if (!mc || !tab) return; if (selection.kind === 'session') openSurface('new-branch', { sessionID: selection.sessionID }); else openSurface('new-worktree', { profileID: mc.profileID, index: tab.index }); } },
      { label: 'Merge worktree', shortcut: shortcut('m', ['shift', 'cmd']), disabled: !isWorktree,
        action: () => mc && tab && openSurface('tab-merge', { profileID: mc.profileID, index: tab.index }) },
      { label: 'Attach terminal', disabled: !isWorktree,
        action: () => mc && tab && host.send('POST', `/sessions/${encodeURIComponent(mc.profileID)}/worktree`, { action: 'terminal', args: [tab.rootRepo ?? tab.repoRoot ?? '', tab.worktreeBranch ?? ''] }) },
      { label: 'Discard worktree', disabled: !isWorktree, destructive: true,
        action: async () => {
          if (!mc || !tab) return;
          const v = await showAlert(`Discard worktree “${tab.title ?? tab.worktreeBranch}”?`, 'Its branch and checkout are deleted, with any uncommitted or unmerged work. The tab closes.',
            [{ label: 'Discard', value: 'ok', destructive: true }, { label: 'Cancel', value: 'cancel', default: true }]);
          if (v !== 'ok') return;
          host.send('POST', `/sessions/${encodeURIComponent(mc.profileID)}/worktree`, { action: 'remove', args: [tab.rootRepo ?? tab.repoRoot ?? '', tab.worktreeBranch ?? ''] });
          ws.closeTab(mc.profileID, tab.index);
        } },
      ...(electron ? [{ separator: true } as MenuItem, { label: 'Close Window', shortcut: shortcut('w'), action: () => electron!.windowControl('close') }] : []),
    ] },
    { title: 'Edit', items: [
      { label: 'Undo', shortcut: shortcut('z'), action: edit('undo') },
      { label: 'Redo', shortcut: shortcut('z', ['shift', 'cmd']), action: edit('redo') },
      { separator: true },
      { label: 'Cut', shortcut: shortcut('x'), action: edit('cut') },
      { label: 'Copy', shortcut: shortcut('c'), action: edit('copy') },
      // A web page can't read the clipboard from a menu click; the shortcut works.
      { label: 'Paste', shortcut: shortcut('v'), disabled: !electron, action: edit('paste') },
      { label: 'Select All', shortcut: shortcut('a'), action: edit('selectAll') },
    ] },
    { title: 'View', items: [
      { label: 'Toggle Sidebar', shortcut: shortcut('s', ['ctrl', 'cmd']), action: () => setSidebarCollapsed(!sidebarCollapsed) },
      { label: 'Toggle Files Pane', shortcut: shortcut('e', ['ctrl', 'cmd']), action: () => openSurface('toggle-files') },
      // The browser: the desktop app's built-in browser window; the hosted
      // app has none (the user's own browser is right there).
      ...(electron ? [{ label: 'Toggle Browser Pane', shortcut: shortcut('b', ['ctrl', 'cmd']), action: () => openSurface('toggle-browser') } as MenuItem] : []),
      { separator: true },
      { label: document.fullscreenElement ? 'Exit Full Screen' : 'Enter Full Screen', shortcut: shortcut('f', ['ctrl', 'cmd']), action: fullScreen },
    ] },
    { title: 'Window', items: [
      ...(electron ? [
        { label: 'Minimize', shortcut: shortcut('m'), action: () => electron!.windowControl('minimize') } as MenuItem,
        { label: 'Zoom', action: () => electron!.windowControl('maximize') } as MenuItem,
        { separator: true } as MenuItem,
      ] : []),
      { label: 'Workspace Manager', shortcut: shortcut('0'), action: () => openSurface('machines') },
      { label: 'Trace Inspector…', shortcut: shortcut('i', ['shift', 'cmd']), action: () => openSurface('trace', mc ? { profileID: mc.profileID } : {}) },
      { label: 'Security…', action: () => openSurface('security') },
    ] },
    { title: 'Help', items: [
      { label: 'Bromure Agentic Coding Manual', shortcut: shortcut('?'), action: () => openExternal(MANUAL_URL) },
    ] },
  ];

  const openAt = (title: string, el: HTMLElement) => {
    const m = menus.find(x => x.title === title)!;
    setOpenTitle(title);
    menu(el.getBoundingClientRect(), m.items, 220);
  };
  // The kit menu closes on outside mousedown; clear our highlight with it.
  useEffect(() => {
    if (!openTitle) return;
    const off = () => setTimeout(() => { if (!document.querySelector('.menu')) setOpenTitle(null); }, 0);
    window.addEventListener('mouseup', off);
    window.addEventListener('keydown', off);
    return () => { window.removeEventListener('mouseup', off); window.removeEventListener('keydown', off); };
  }, [openTitle]);

  // Key equivalents not already handled elsewhere (GlobalShortcuts owns ⌘K/⌘N/⌘,/⇧⌘K/N/A/T/I/G, ⌃⌘S/E;
  // the terminal stage owns ⌘T/⌘W).
  const menusRef = useRef(menus); menusRef.current = menus;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.repeat) return;
      const cmd = isMac ? e.metaKey : e.ctrlKey;
      if (!cmd) return;
      const target = e.target as HTMLElement | null;
      if (!isMac && !e.shiftKey && !e.altKey && target?.closest?.('.xterm')) return;   // a terminal's own Ctrl chords
      const twoMod = isMac ? e.ctrlKey : e.altKey;   // ⌃⌘ (Ctrl+Alt off macOS)
      const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
      const find = (label: string) => menusRef.current.flatMap(m => m.items).find(i => i.label === label);
      let label: string | null = null;
      if (twoMod && !e.shiftKey) label = k === 'r' ? 'Next Room' : k === 'b' ? 'Toggle Browser Pane' : k === 'f' ? (document.fullscreenElement ? 'Exit Full Screen' : 'Enter Full Screen') : null;
      else if (e.altKey && isMac && !e.shiftKey && k === 'u') label = 'Terminal';
      else if (!isMac && e.altKey && !e.shiftKey && k === 'u') label = 'Terminal';
      else if (e.shiftKey && !twoMod && k === 'm') label = 'Merge worktree';
      else if (!e.shiftKey && !e.altKey && !twoMod) label = k === 'd' ? 'Add Terminal to Grid' : k === '0' ? 'Workspace Manager' : null;
      else if (e.shiftKey && (k === '?' || k === '/')) label = 'Bromure Agentic Coding Manual';
      const item = label ? find(label) : undefined;
      if (!item || item.disabled || !item.action) return;
      e.preventDefault(); e.stopPropagation();
      item.action();
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, []);

  return (
    <div className="mb" ref={ref} role="menubar">
      {menus.map(m => (
        <button key={m.title} role="menuitem" className={'mb-title' + (openTitle === m.title ? ' open' : '') + (m.title === 'Bromure' ? ' app' : '')}
                onMouseDown={e => { e.preventDefault(); openAt(m.title, e.currentTarget); }}
                onMouseEnter={e => { if (openTitle && openTitle !== m.title && document.querySelector('.menu')) openAt(m.title, e.currentTarget); }}>
          {m.title}
        </button>
      ))}
    </div>
  );
}
