// ⌘K command palette (CommandPalette.swift): one search field over the
// window — jump to any session, room or machine, or run an action. Arrow keys
// move, Return runs, Esc or a click outside closes. Items are built from the
// mirrored /state like RemoteHostWindow.showCommandPalette (plus the actions
// the local window offers, which the reference shows).

import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { SF } from '../../ui/icons';
import { cx } from '../../ui/kit';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { modKey } from '../../platform';
import { openSurface, useOpenListener } from './events';
import {
  buildListModel, orderedAll, archivedSessions, bucket, bucketTitle, bucketTint, distinctTitle, roomSummary,
  hasFolder, isBranch, isSwitchboard, isDeleted,
} from '../sidebar/model';
import type { RemoteState } from '../../core/remote/types';
import type { StageSelection } from '../../app/hostContext';
import './palette.css';

type Section = 'actions' | 'sessions' | 'rooms' | 'machines' | 'messages';
const SECTION_ORDER: Section[] = ['actions', 'sessions', 'rooms', 'machines', 'messages'];
const SECTION_TITLE: Record<Section, string> = {
  actions: 'Actions', sessions: 'Sessions', rooms: 'Rooms', machines: 'Machines', messages: 'In conversations',
};

export interface PaletteItem {
  id: string;
  section: Section;
  title: string;
  subtitle?: string;
  icon: string;
  tint?: string;
  keywords?: string;
  shortcut?: string;
  /** Menu-bar commands with no row of their own in the Swift palette: found
   *  by typing, never listed in the empty-query view. */
  searchOnly?: boolean;
  run: () => void;
}

/** PaletteItem.score: every word must be found; a title prefix beats a word
 *  start beats anywhere. */
export function score(item: PaletteItem, query: string): number {
  const q = query.toLowerCase().split(' ').filter(Boolean);
  if (!q.length) return 1;
  const t = item.title.toLowerCase();
  const hay = `${item.title} ${item.subtitle ?? ''} ${item.keywords ?? ''}`.toLowerCase();
  let total = 0;
  for (const w of q) {
    if (t.startsWith(w)) total += 30;
    else if (t.includes(' ' + w)) total += 20;
    else if (t.includes(w)) total += 12;
    else if (hay.includes(w)) total += 5;
    else return 0;
  }
  return total;
}

export function paletteResults(items: PaletteItem[], query: string): PaletteItem[] {
  const q = query.trim();
  if (!q) {
    return [
      ...items.filter(i => i.section === 'actions' && !i.searchOnly),
      ...items.filter(i => i.section === 'sessions').slice(0, 8),
      ...items.filter(i => i.section === 'rooms').slice(0, 4),
    ];
  }
  return items.map(item => ({ item, s: score(item, q) })).filter(x => x.s > 0)
    .sort((a, b) => a.s !== b.s ? b.s - a.s : SECTION_ORDER.indexOf(a.item.section) - SECTION_ORDER.indexOf(b.item.section))
    .slice(0, 40).map(x => x.item);
}

const sc = (k: string) => (modKey === '⌘' ? '⌘' + k : modKey + k);

/** The window's palette items (RemoteHostWindow.showCommandPalette). */
export function buildPaletteItems(st: RemoteState, selection: StageSelection, select: (s: StageSelection) => void,
                                  extra: { toggleSidebar: () => void }): PaletteItem[] {
  const items: PaletteItem[] = [
    { id: 'a.new-session', section: 'actions', title: 'New session', icon: 'plus', keywords: 'start agent', shortcut: sc('N'), run: () => openSurface('new-session') },
    { id: 'a.new-room', section: 'actions', title: 'New room…', icon: 'square.grid.2x2', tint: 'var(--indigo)', keywords: 'group', run: () => openSurface('new-room') },
    { id: 'a.security', section: 'actions', title: 'Security', icon: 'shield.lefthalf.filled', tint: 'var(--green)', keywords: 'security events firewall audit log overview', run: () => openSurface('security') },
    { id: 'a.tasks', section: 'actions', title: 'Coding Tasks', icon: 'checklist', tint: 'var(--blue)', keywords: 'board kanban', run: () => openSurface('task-board') },
    { id: 'a.automations', section: 'actions', title: 'Automations', icon: 'bolt.badge.clock.fill', tint: 'var(--orange)', keywords: 'board schedule', run: () => openSurface('automation-board') },
    { id: 'a.prefs', section: 'actions', title: 'Preferences', icon: 'gearshape', tint: 'var(--gray)', keywords: 'settings defaults', shortcut: sc(','), run: () => openSurface('preferences') },
    { id: 'a.new-machine', section: 'actions', title: 'New machine…', icon: 'cpu', tint: 'var(--teal)', keywords: 'workspace vm create', run: () => openSurface('new-machine') },
  ];
  // The session on stage: branch it, review it, or merge its branch.
  const m = buildListModel(st);
  const all = st.agentSessions ?? [];
  const sessions = all.filter(s => !isDeleted(s) && !isSwitchboard(s));
  if (selection.kind === 'session') {
    const cur = sessions.find(s => s.id === selection.sessionID);
    if (cur && !cur.archivedAt) {
      const sid = cur.id;
      if (hasFolder(cur)) {
        items.push({ id: 'a.branch', section: 'actions', title: 'New Branch…', subtitle: cur.title, icon: 'arrow.triangle.branch', tint: 'var(--purple)', keywords: 'worktree git fork try', run: () => openSurface('new-branch', { sessionID: sid }) });
        items.push({ id: 'a.review', section: 'actions', title: 'Review Changes', subtitle: cur.title, icon: 'doc.text.magnifyingglass', tint: 'var(--purple)', keywords: 'diff review comments git', run: () => openSurface('review-branch', { sessionID: sid }) });
      }
      const merge = cur.branchMerge as { phase?: string } | undefined;
      if (isBranch(cur) && (!merge || merge.phase === 'failed')) {
        items.push({ id: 'a.merge', section: 'actions', title: `Merge into ${(cur.branchParent as string) || 'parent'}`, subtitle: cur.title, icon: 'arrow.triangle.merge', tint: 'var(--purple)', keywords: 'worktree git branch', run: () => openSurface('merge-branch', { sessionID: sid }) });
      }
    }
  }
  // Menu-bar commands (no menu bar here): found by typing.
  const menu: [string, string, string, string, () => void, string?][] = [
    ['m.connect', 'Connect to Remote Bromure…', 'network', 'server remote mirror ssh', () => openSurface('connect'), '⇧' + sc('K')],
    ['m.machines', 'Machines', 'desktopcomputer', 'workspaces vms overview', () => openSurface('machines')],
    ['m.trace', 'Trace Inspector…', 'waveform.path.ecg', 'trace requests http log', () => openSurface('trace'), '⇧' + sc('I')],
    ['m.sidebar', 'Toggle Sidebar', 'sidebar.left', 'hide show sidebar', extra.toggleSidebar, '⌃' + sc('S')],
    ['m.files', 'Toggle Files Pane', 'folder', 'files browser pane', () => openSurface('toggle-files'), '⌃' + sc('E')],
    ['m.remote', 'Remote Access…', 'antenna.radiowaves.left.and.right', 'ssh remote access server', () => openSurface('remote-access')],
  ];
  for (const [id, title, icon, keywords, run, shortcut] of menu) {
    items.push({ id, section: 'actions', title, icon, tint: 'var(--gray)', keywords, run, shortcut, searchOnly: true });
  }
  const wsName = (pid: string) => st.workspaces.find(w => w.id === pid)?.name ?? '';
  for (const s of [...orderedAll(sessions, m), ...archivedSessions(sessions)]) {
    const b = bucket(s, m);
    items.push({
      id: 's.' + s.id, section: 'sessions', title: distinctTitle(s, sessions, m),
      subtitle: [wsName(s.profileID), s.archivedAt ? 'Archived' : bucketTitle[b]].filter(Boolean).join(' · '),
      icon: 'text.bubble.fill', tint: bucketTint[b],
      keywords: (s.nickname ? '@' + s.nickname : '') + ' ' + (s.cwd ?? ''),
      run: () => select({ kind: 'session', sessionID: s.id }),
    });
  }
  for (const r of st.agentRooms ?? []) {
    items.push({ id: 'r.' + r.id, section: 'rooms', title: r.name, subtitle: roomSummary(r, all, m), icon: 'square.grid.2x2.fill',
      tint: r.colorHex ?? 'var(--indigo)', keywords: 'room', run: () => select({ kind: 'room', roomID: r.id }) });
  }
  for (const p of st.workspaces) {
    const tint = p.accentHex ?? 'var(--gray)';
    items.push({ id: 'b.' + p.id, section: 'machines', title: `Branches on ${p.name}`, icon: 'arrow.triangle.branch', tint: 'var(--purple)',
      keywords: 'worktrees git stale', run: () => openSurface('branches', { profileID: p.id }) });
    items.push({ id: 'm.' + p.id, section: 'machines', title: p.name, subtitle: 'Machine Details', icon: 'cpu', tint,
      keywords: 'machine workspace vm', run: () => openSurface('machine', { profileID: p.id }) });
    items.push({ id: 'p.' + p.id, section: 'machines', title: `“${p.name}” Settings…`, icon: 'gearshape.fill', tint,
      keywords: 'settings configure edit', run: () => openSurface('settings', { profileID: p.id }) });
  }
  return items;
}

export function CommandPaletteView({ items, onClose }: { items: PaletteItem[]; onClose: () => void }) {
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState(0);
  const hovered = useRef<number | null>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const results = useMemo(() => paletteResults(items, query), [items, query]);

  useEffect(() => { inputRef.current?.focus(); const t = setTimeout(() => inputRef.current?.focus(), 0); return () => clearTimeout(t); }, []);
  useEffect(() => { setSelected(0); }, [query]);
  useLayoutEffect(() => {
    if (selected === hovered.current) return;
    listRef.current?.querySelector(`[data-row="${selected}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [selected]);

  const run = (i: number) => {
    const item = results[i];
    if (!item) return;
    onClose();
    item.run();
  };
  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); hovered.current = null; setSelected(s => Math.min(s + 1, Math.max(0, results.length - 1))); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); hovered.current = null; setSelected(s => Math.max(s - 1, 0)); }
    else if (e.key === 'Enter') { e.preventDefault(); run(selected); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); onClose(); }
  };

  return createPortal(
    <div className="pal-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) onClose(); }} onKeyDown={onKey}>
      <div className="pal-card" role="dialog" aria-label="Command palette">
        <div className="pal-head">
          <SF name="magnifyingglass" size={17} weight={500} className="pal-glass" />
          <input ref={inputRef} className="pal-input" value={query} spellCheck={false} autoComplete="off"
                 placeholder="Search sessions, rooms, machines, actions…" onChange={e => setQuery(e.target.value)} />
          <span className="pal-esc">esc</span>
        </div>
        <div className="pal-divider" />
        <div className="pal-list" ref={listRef}>
          {!results.length && <div className="pal-empty">No match</div>}
          {results.map((item, i) => (
            <React.Fragment key={item.id}>
              {(i === 0 || results[i - 1].section !== item.section) &&
                <div className={cx('pal-section', i === 0 && 'first')}>{SECTION_TITLE[item.section]}</div>}
              <div data-row={i} className={cx('pal-row', i === selected && 'on')}
                   onMouseMove={() => { if (selected !== i) { hovered.current = i; setSelected(i); } }}
                   onClick={() => run(i)}>
                <span className="pal-icon" style={{ '--tint': item.tint ?? 'var(--accent)' } as React.CSSProperties}>
                  <SF name={item.icon} size={13} weight={600} />
                </span>
                <span className="pal-text">
                  <span className="pal-title">{item.title}</span>
                  {item.subtitle && <span className="pal-sub">{item.subtitle}</span>}
                </span>
                {item.shortcut && <span className="pal-shortcut">{item.shortcut}</span>}
                {i === selected && <SF name="return" size={12} weight={600} className="pal-return" />}
              </div>
            </React.Fragment>
          ))}
        </div>
      </div>
    </div>, document.body);
}

/** Mounted once per host window: toggles on `bromure:open {what:'palette'}`. */
export function PaletteHost() {
  const { host, selection, select, sidebarCollapsed, setSidebarCollapsed } = useHostCtx();
  const st = useRemote(host, s => s);
  const [open, setOpen] = useState(false);
  useOpenListener(d => {
    if (d.what === 'palette') setOpen(o => !o);
    else if (d.what === 'palette-close') setOpen(false);
  });
  useEffect(() => {
    (window as any).__bromure = { ...(window as any).__bromure, palette: () => setOpen(true) };
  }, []);
  const items = useMemo(() => st ? buildPaletteItems(st, selection, select, { toggleSidebar: () => setSidebarCollapsed(!sidebarCollapsed) }) : [],
    [st, selection, select, sidebarCollapsed, setSidebarCollapsed]);
  if (!open) return null;
  return <CommandPaletteView items={items} onClose={() => setOpen(false)} />;
}
