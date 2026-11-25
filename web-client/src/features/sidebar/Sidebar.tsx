// The mirror window's sidebar — SessionSidebar (UnifiedSessionWindow.swift)
// in its sessions-first form, as the fat client shows it: search, New
// session, the Coding Tasks and Automations rows, the Sessions list
// (Switchboard, rooms with their members, the state groups, Archived), and
// the Virtual Machines fold. Collapsed, the CompactRail.
//
// Events this module EMITS (window CustomEvent 'bromure:open', detail {what, …}):
//   new-session        { room? }                  New session button / rail "+" / "New Session in Room"
//   task-board                                     Coding Tasks title / status row
//   new-task                                       Coding Tasks "+" (the board with a blank task's editor)
//   automation-board                               Automations title / status row
//   new-automation     { profileID?, repoPath? }  Automations "+" / a tab's "New automation…"
//   settings           { profileID }               "“X” Settings…", a VM's "Edit…"
//   new-machine                                    Virtual Machines "+"
//   new-branch         { sessionID }               session menu "New Branch…" (and a session tab's "New worktree…")
//   new-worktree       { profileID, index }        a plain tab's "New worktree…"
//   review-branch      { sessionID }               Branch › Review Changes
//   rewind-home        { profileID }               a VM's "Rewind home…"
//   tab-merge          { profileID, index }        worktree tab "Merge…"
//   tab-resolve        { profileID, index }        merge tab "Have the agent resolve conflicts"
//   kube-action        { kind:'cluster'|'registry', id, action:'start'|'stop'|'restart'|'access'|'delete' }
//   new-cluster / new-registry                     Kubernetes / Registries "+"
// Selection goes through useHostCtx().select (session / room / workspace /
// grid / docker / cluster / registry / new-session). The sidebar LISTENS for
// `bromure:open {what:'toggle-sidebar'}` and binds ⌃⌘S (Ctrl+Alt+S off Mac)
// and ⌘1–9 (holding ⌘ shows the numbers, as on macOS).

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useHostCtx, usePersisted, type StageSelection } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { useMenu, cx, type MenuItem } from '../../ui/kit';
import { SF } from '../../ui/icons';
import { isMac } from '../../platform';
import type { AgentSession, AgentRoom } from '../../core/remote/types';
import * as M from './model';
import { AgentAvatar, AgentGlyph, AgentStatusDot, UnreadMark, STATUS_COLOR } from './AgentAvatar';
import { DialogHost, showSheet, confirmAlert, RoomNameSheet } from './Dialogs';
import { NicknameSheet } from './NicknameSheet';
import { sessionActions, workspaceActions, openSurface, sessionCommand, type SessionActions } from './actions';
import './sidebar.css';

export { StagePlaceholder } from './StagePlaceholder';

const DRAG_TYPE = 'application/x-bromure-session';
const AGENT_GLYPHS = ['claude', 'codex', 'grok', 'kimi', 'omp', 'hermes'];

/** Re-render every 30 s so "now" / "3m" stay true. */
function useNow(ms = 30_000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), ms); return () => clearInterval(t); }, [ms]);
  return now;
}

/** The mirrored model the sidebar (and the toolbar) read. */
export function useListModel() {
  const { host } = useHostCtx();
  const now = useNow();
  const workspaces = useRemote(host, s => s.workspaces);
  const vms = useRemote(host, s => s.vms);
  return useMemo(() => M.buildListModel(host.state, now), [host, workspaces, vms, now]);   // eslint-disable-line react-hooks/exhaustive-deps
}

export function Sidebar() {
  const { host, selection, select, sidebarCollapsed, setSidebarCollapsed } = useHostCtx();
  const sessions = useRemote(host, s => s.agentSessions) ?? EMPTY;
  const rooms = useRemote(host, s => s.agentRooms) ?? EMPTY_ROOMS;
  const m = useListModel();
  const sessRef = useRef(sessions); sessRef.current = sessions;
  const mRef = useRef(m); mRef.current = m;
  const actions = useMemo(() => sessionActions({
    host, selection, select, sessions: () => sessRef.current, model: () => mRef.current,
  }), [host, selection, select]);

  const markRead = useCallback((s: AgentSession) => {
    if (M.isUnread(s) && typeof s.replies === 'number') sessionCommand(host, s.id, 'read', { seen: s.replies });
  }, [host]);
  const selectSession = useCallback((id: string) => {
    select({ kind: 'session', sessionID: id });
    const s = sessRef.current.find(x => x.id === id);
    if (s) markRead(s);
  }, [select, markRead]);
  const newSession = () => { select({ kind: 'new-session' }); openSurface('new-session'); };

  // ⌃⌘S folds the sidebar to its rail; ⌘ held shows ⌘1–9; ⌘1–9 jumps.
  const [modHeld, setModHeld] = useState(false);
  useEffect(() => {
    const down = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() === 's' && e.ctrlKey && (isMac ? e.metaKey : e.altKey)) { e.preventDefault(); setSidebarCollapsed(!sidebarCollapsed); return; }
      const held = (isMac ? e.metaKey : e.ctrlKey) && !e.shiftKey && !e.altKey;
      setModHeld(held);
      if (held && /^[1-9]$/.test(e.key)) {
        const s = M.sidebarOrder(sessRef.current, rooms, mRef.current)[+e.key - 1];
        if (s) { e.preventDefault(); selectSession(s.id); }
      }
    };
    const up = (e: KeyboardEvent) => setModHeld(isMac ? e.metaKey : e.ctrlKey);
    const blur = () => setModHeld(false);
    const onOpen = (e: Event) => { if ((e as CustomEvent).detail?.what === 'toggle-sidebar') setSidebarCollapsed(!sidebarCollapsed); };
    window.addEventListener('keydown', down); window.addEventListener('keyup', up); window.addEventListener('blur', blur);
    window.addEventListener('bromure:open', onOpen);
    return () => {
      window.removeEventListener('keydown', down); window.removeEventListener('keyup', up); window.removeEventListener('blur', blur);
      window.removeEventListener('bromure:open', onOpen);
    };
  }, [sidebarCollapsed, setSidebarCollapsed, rooms, selectSession]);

  // Debug hook for screenshots (scripts/shot.mjs --js "__bromure.sidebar.select(...)").
  useEffect(() => {
    const w = window as any;
    w.__bromure = { ...(w.__bromure ?? {}), sidebar: { select, selectSession, setCollapsed: setSidebarCollapsed, actions } };
  }, [select, selectSession, setSidebarCollapsed, actions]);

  return (
    <div className={cx('sb', sidebarCollapsed && 'sb-collapsed')}>
      {sidebarCollapsed
        ? <CompactRail m={m} sessions={sessions} selection={selection} select={select} onSession={selectSession}
                       onNew={newSession} onSwitchboard={actions.openSwitchboard} />
        : <FullSidebar m={m} sessions={sessions} rooms={rooms} selection={selection} select={select}
                       onSession={selectSession} onNew={newSession} actions={actions} modHeld={modHeld} />}
      <DialogHost />
    </div>
  );
}

const EMPTY: AgentSession[] = [];
const EMPTY_ROOMS: AgentRoom[] = [];

// ── full sidebar ─────────────────────────────────────────────────────────

interface FullProps {
  m: M.ListModel; sessions: AgentSession[]; rooms: AgentRoom[];
  selection: StageSelection; select: (s: StageSelection) => void;
  onSession: (id: string) => void; onNew: () => void; actions: SessionActions; modHeld: boolean;
}

function FullSidebar(p: FullProps) {
  const [filter, setFilter] = useState('');
  return (
    <>
      <div className="sb-top">
        <div className="sb-search">
          <SF name="magnifyingglass" size={12} className="sb-search-icon" />
          <input value={filter} placeholder="Search sessions" spellCheck={false} onChange={e => setFilter(e.target.value)}
                 onKeyDown={e => { if (e.key === 'Escape') setFilter(''); }} />
          {filter && <span className="sb-search-clear" onClick={() => setFilter('')}><SF name="xmark.circle.fill" size={12} /></span>}
        </div>
        <button className="sb-new" onClick={p.onNew} title={`Start an agent (${isMac ? '⌘' : 'Ctrl+'}N)`}>
          <SF name="plus" size={13} weight={700} />
          <span className="sb-new-label">New session</span>
          <span className="sb-new-key">{isMac ? '⌘N' : 'Ctrl+N'}</span>
        </button>
      </div>
      <div className="sb-scroll">
        <div className="sb-list">
          <CodingTasksSection {...p} />
          <AutomationsSection {...p} />
          <SessionSections {...p} filter={filter} />
          <MachinesSection {...p} />
          <NativeSection {...p} />
        </div>
      </div>
    </>
  );
}

// ── SidebarSectionHeader ──────────────────────────────────────────────────

function SectionHeader({ title, expanded, selected, badges = [], count, help, onTitle, onAdd, addHelp, top = 12 }: {
  title: string; expanded?: boolean; selected?: boolean; badges?: [number, string][]; count?: number; help?: string;
  onTitle: () => void; onAdd?: () => void; addHelp?: string; top?: number;
}) {
  return (
    <div className="sb-sh" style={{ paddingTop: top }}>
      <div className="sb-sh-main" onClick={onTitle} title={help}>
        {expanded !== undefined && <span className="sb-sh-chev"><SF name={expanded ? 'chevron.down' : 'chevron.right'} size={10} weight={600} /></span>}
        <span className={cx('sb-sh-title', selected && 'selected')}>{title}</span>
        {badges.filter(([n]) => n > 0).map(([n, tint], i) => <span key={i} className="sb-badge" style={{ background: tint }}>{n}</span>)}
        <span style={{ flex: 1 }} />
        {count != null && count > 0 && <span className="sb-sh-count">{count}</span>}
      </div>
      {onAdd
        ? <span className="sb-sh-add" onClick={onAdd} title={addHelp}><SF name="plus" size={12} weight={600} /></span>
        : <span className="sb-sh-add placeholder" />}
    </div>
  );
}

function BoardRow({ icon, line, alert, selected, onClick }: { icon: string; line: string; alert: boolean; selected: boolean; onClick: () => void }) {
  return (
    <div className={cx('sb-board', selected && 'selected')} onClick={onClick}>
      <SF name={icon} size={12} color={alert ? 'var(--red)' : undefined} className="sb-board-icon" />
      <span className="sb-board-line">{line}</span>
    </div>
  );
}

function CodingTasksSection(p: FullProps) {
  const { host } = useHostCtx();
  const tasks = useRemote(host, s => s.tasks);
  const sum = useMemo(() => M.tasksSummary(host.state, p.sessions, p.m), [tasks, p.sessions, p.m]);   // eslint-disable-line react-hooks/exhaustive-deps
  const selected = p.selection.kind === 'task-board';
  const open = () => openSurface('task-board');
  return (
    <div className="sb-group">
      <SectionHeader title="Coding Tasks" selected={selected} badges={[[sum.attention, 'var(--red)'], [sum.reviewCount, 'var(--orange)']]}
                     count={sum.openCount} help={`Open Coding Tasks (${isMac ? '⇧⌘T' : 'Ctrl+Shift+T'})`} onTitle={open}
                     onAdd={() => openSurface('new-task')} addHelp="New Task" />
      <BoardRow icon="checklist" line={sum.line} alert={sum.attention > 0} selected={selected} onClick={open} />
    </div>
  );
}

function AutomationsSection(p: FullProps) {
  const { host } = useHostCtx();
  const autos = useRemote(host, s => s.automations);
  const sum = useMemo(() => M.automationsSummary(host.state, p.m), [autos, p.m]);   // eslint-disable-line react-hooks/exhaustive-deps
  const selected = p.selection.kind === 'automation-board';
  const open = () => openSurface('automation-board');
  return (
    <div className="sb-group">
      <SectionHeader title="Automations" selected={selected} badges={[[sum.attention, 'var(--red)'], [sum.openFindings, 'var(--orange)']]}
                     count={sum.count} help={`Open Automations (${isMac ? '⇧⌘A' : 'Ctrl+Shift+A'})`} onTitle={open}
                     onAdd={() => openSurface('new-automation')} addHelp="New automation" />
      <BoardRow icon="bolt.badge.clock" line={sum.line} alert={sum.attention > 0} selected={selected} onClick={open} />
    </div>
  );
}

// ── Sessions ──────────────────────────────────────────────────────────────

function SessionSections(p: FullProps & { filter: string }) {
  const { m, sessions, rooms, selection, actions, filter } = p;
  const menu = useMenu();
  const [expanded, setExpanded] = usePersisted('sessions.listExpanded', true);
  const [foldedRooms, setFoldedRooms] = usePersisted<string[]>('sessions.foldedRooms', []);
  const [archivedExpanded, setArchivedExpanded] = usePersisted('sessions.archivedExpanded', false);
  const [endedExpanded, setEndedExpanded] = usePersisted('sessions.endedExpanded', false);
  const [archivedRevealed, setArchivedRevealed] = useState(false);
  const [dropTarget, setDropTarget] = useState<string | null>(null);
  const selectedID = selection.kind === 'session' ? selection.sessionID : null;

  const q = filter.trim();
  const matching = useMemo(() => {
    if (!q) return sessions;
    const bare = q.startsWith('@') ? q.slice(1) : q;
    const has = (x: unknown) => typeof x === 'string' && x.toLowerCase().includes(q.toLowerCase());
    return sessions.filter(s => has(s.title) || has(s.openingMessage) || has(s.cwd)
      || (!!bare && (s.nickname ?? '').toLowerCase().includes(bare.toLowerCase())));
  }, [sessions, q]);
  const list = useMemo(() => M.orderedAll(matching, m), [matching, m]);
  const activeRooms = rooms.filter(r => !M.roomArchived(r));
  const archivedRooms = rooms.filter(M.roomArchived);
  const roomIDs = new Set(activeRooms.map(r => r.id));
  const loose = list.filter(s => !s.roomID || !roomIDs.has(s.roomID));
  const archivedRoomIDs = new Set(archivedRooms.map(r => r.id));
  const put = M.archivedSessions(matching).filter(s => !s.roomID || !archivedRoomIDs.has(s.roomID));
  const needsYou = list.filter(s => M.bucket(s, m) === 'needsYou').length;
  const open = expanded || !!q;
  const shortcuts = useMemo(() => {
    const out = new Map<string, number>();
    M.sidebarOrder(sessions, rooms, m).slice(0, 9).forEach((s, i) => out.set(s.id, i + 1));
    return out;
  }, [sessions, rooms, m]);

  // The selection moved into the Archived fold: open it, once.
  useEffect(() => {
    const s = selectedID ? sessions.find(x => x.id === selectedID) : undefined;
    if (!s || !M.isArchived(s) || M.isDeleted(s)) { if (archivedRevealed) setArchivedRevealed(false); return; }
    if (!archivedExpanded) setArchivedRevealed(true);
  }, [selectedID]);   // eslint-disable-line react-hooks/exhaustive-deps

  const workspaceName = (id: string) => m.rows.find(r => r.id === id)?.name ?? '';
  const accentHex = (id: string) => m.rows.find(r => r.id === id)?.accentHex ?? '#888888';

  const roomSubmenu = (s: AgentSession): MenuItem[] => [
    { header: 'Move to Room' },
    ...activeRooms.map(r => ({ label: r.name, disabled: s.roomID === r.id, action: () => actions.moveToRoom(s.id, r.id) })),
    ...(activeRooms.length ? [{ separator: true }] : []),
    { label: 'New Room…', action: () => showSheet(380, close => <RoomNameSheet title="New Room" action="Create" close={close} onSet={n => actions.newRoom(n, s.id)} />) },
  ];

  const sessionMenu = (e: React.MouseEvent, s: AgentSession) => {
    e.preventDefault();
    const at = { clientX: e.clientX, clientY: e.clientY };
    const gone = M.isGone(s, m);
    const live = s.windowIndex != null && !M.hasEnded(s);
    const items: MenuItem[] = [];
    if (!gone) {
      if (M.isArchived(s)) items.push({ label: 'Unarchive', action: () => actions.unarchive(s.id) });
      else items.push({ label: live ? 'End & Archive' : 'Archive', action: () => actions.archive(s.id) });
      if (live) items.push({ label: 'End session', action: () => actions.close(s.id) });
      items.push({ separator: true });
      items.push({ label: 'Nickname…', action: () => showSheet(420, close =>
        <NicknameSheet session={s} sessions={sessions} close={close} onSet={(n, r) => actions.setNickname(s.id, n, r)} />) });
      if (M.hasFolder(s)) items.push({ label: 'New Branch…', action: () => openSurface('new-branch', { sessionID: s.id }) });
      if (M.isBranch(s)) items.push(...branchItems(s, actions));
      if (!M.isArchived(s)) {
        items.push({ label: 'Move to Room  ▸', action: () => setTimeout(() => menu(at, roomSubmenu(s)), 0) });
        if (s.roomID && roomIDs.has(s.roomID)) items.push({ label: 'Remove from Room', action: () => actions.moveToRoom(s.id, null) });
      }
      items.push({ separator: true });
      items.push({ label: `“${workspaceName(s.profileID)}” Settings…`, action: () => actions.editMachine(s.profileID) });
      if (live) items.push({ label: 'Open in Linux Terminal', action: () => actions.openLinux(s.id) });
    } else if (M.isArchived(s)) {
      items.push({ label: 'Unarchive', action: () => actions.unarchive(s.id) });
    }
    items.push({ separator: true });
    items.push({ label: 'Delete session', destructive: true, action: () => actions.delete(s.id) });
    menu(at, items);
  };

  const roomMenu = (e: React.MouseEvent, r: AgentRoom) => {
    e.preventDefault();
    const at = { clientX: e.clientX, clientY: e.clientY };
    menu(at, [
      { label: 'New Session in Room', action: () => actions.newSessionInRoom(r.id) },
      { separator: true },
      { label: 'Rename…', action: () => showSheet(380, close => <RoomNameSheet title="Rename Room" action="Rename" initial={r.name} close={close} onSet={n => actions.renameRoom(r.id, n)} />) },
      { label: 'Color  ▸', action: () => setTimeout(() => menu(at, [{ header: 'Color' }, ...M.ROOM_PALETTE.map(hex => ({
        label: M.ROOM_COLOR_NAMES[hex] ?? hex, checked: r.colorHex === hex, action: () => actions.setRoomColor(r.id, hex),
      }))]), 0) },
      { separator: true },
      M.roomArchived(r) ? { label: 'Unarchive Room', action: () => actions.unarchiveRoom(r.id) } : { label: 'Archive Room', action: () => actions.archiveRoom(r.id) },
      { label: 'Ungroup Room', action: () => actions.ungroupRoom(r.id) },
      { separator: true },
      { label: 'Delete Room…', destructive: true, action: () => actions.deleteRoom(r.id, r.name) },
    ]);
  };

  const dragState = (key: string) => (inside: boolean) => setDropTarget(cur => inside ? key : (cur === key ? null : cur));

  const row = (s: AgentSession, depth = 0) => {
    const gone = M.isGone(s, m);
    return (
      <SessionRow key={s.id} session={s} m={m} depth={depth} gone={gone}
                  workspaceName={workspaceName(s.profileID)} accentHex={accentHex(s.profileID)}
                  title={M.distinctTitle(s, sessions, m)}
                  selected={selectedID === s.id}
                  shortcut={p.modHeld ? shortcuts.get(s.id) : undefined}
                  dropTarget={dropTarget === s.id}
                  onSelect={() => p.onSession(s.id)} onMenu={e => sessionMenu(e, s)}
                  onDragState={dragState(s.id)}
                  onDropSessions={ids => {
                    if (gone || M.isArchived(s)) return;
                    for (const id of ids) if (id !== s.id) actions.groupSessions(id, s.id);
                  }} />
    );
  };

  const roomBlock = (r: AgentRoom, from: AgentSession[]) => {
    const members = from.filter(s => s.roomID === r.id);
    const folded = foldedRooms.includes(r.id) && !q;
    return (
      <React.Fragment key={r.id}>
        <RoomRow room={r} summary={M.roomSummary(r, sessions, m)} dot={M.roomDot(r, sessions, m)} folded={folded}
                 hasMembers={members.length > 0} selected={selection.kind === 'room' && selection.roomID === r.id}
                 dropTarget={dropTarget === 'room:' + r.id}
                 onSelect={() => actions.openRoom(r.id)} onMenu={e => roomMenu(e, r)}
                 onFold={() => setFoldedRooms(folded ? foldedRooms.filter(x => x !== r.id) : [...foldedRooms, r.id])}
                 onDragState={dragState('room:' + r.id)}
                 onDropSessions={ids => ids.forEach(id => actions.moveToRoom(id, r.id))} />
        {!folded && M.nested(members).map(x => row(x.session, x.depth + 1))}
      </React.Fragment>
    );
  };

  const sb = M.globalSwitchboard(sessions);
  const openArchived = archivedExpanded || archivedRevealed || !!q;
  const orphans = put.filter(s => M.isGone(s, m));
  return (
    <div className="sb-sessions">
      <SectionHeader title="Sessions" expanded={open} badges={[[needsYou, 'var(--red)']]} count={list.length}
                     help="Your conversations with agents — click to fold the list" top={8}
                     onTitle={() => setExpanded(!expanded)} />
      {open && <>
        {!q && M.switchboardVisible(sessions, m) && (
          <SwitchboardRow summary={M.switchboardSummary(sessions, m)} dot={sb ? M.dot(sb, m) : null} started={!!sb}
                          selected={!!sb && selectedID === sb.id} onSelect={actions.openSwitchboard} />
        )}
        {list.length === 0 && activeRooms.length === 0 && (
          <div className="sb-empty">
            <div className="sb-empty-title">{q ? 'No matching sessions' : 'No sessions yet'}</div>
            {!q && <div className="sb-empty-sub">Start one: pick an agent, say what you're after, and go.</div>}
          </div>
        )}
        {activeRooms.map(r => roomBlock(r, list))}
        {M.BUCKETS.filter(b => b !== 'ended').map(b => {
          const group = loose.filter(s => M.bucket(s, m) === b);
          const stopped = b === 'asleep' ? loose.filter(s => M.bucket(s, m) === 'ended') : [];
          if (!group.length && !stopped.length) return null;
          const folded = stopped.length > 0 && !endedExpanded && !q;
          return (
            <React.Fragment key={b}>
              <GroupHeader bucket={b} count={group.length + stopped.length} foldable={stopped.length > 0} folded={folded}
                           onToggle={() => setEndedExpanded(!endedExpanded)} />
              {M.nested(folded ? group : [...group, ...stopped]).map(x => row(x.session, x.depth))}
            </React.Fragment>
          );
        })}
      </>}
      {(put.length > 0 || archivedRooms.length > 0) && <>
        <SectionHeader title="Archived" expanded={openArchived} count={put.length + archivedRooms.length}
                       help="Conversations you put away — still readable, back with one message"
                       onTitle={() => { if (archivedRevealed) { setArchivedRevealed(false); setArchivedExpanded(false); } else setArchivedExpanded(!archivedExpanded); }} />
        {openArchived && <>
          {archivedRooms.map(r => roomBlock(r, M.archivedSessions(matching)))}
          {put.filter(s => !M.isGone(s, m)).map(s => row(s))}
          {orphans.length > 0 && (
            <div className="sb-orphans">
              <SF name="trash" size={11} />
              <span className="sb-orphans-text">{orphans.length === 1 ? '1 session whose machine or folder is gone' : `${orphans.length} sessions whose machine or folder is gone`}</span>
              <span style={{ flex: 1 }} />
              <button className="sb-link" title="Their machines are gone — delete these conversations"
                      onClick={() => orphans.forEach(o => actions.delete(o.id))}>Delete</button>
            </div>
          )}
        </>}
      </>}
    </div>
  );
}

function branchItems(s: AgentSession, a: SessionActions): MenuItem[] {
  const parent = (s.branchParent as string) ?? 'its parent';
  const phase = (s.branchMerge as any)?.phase;
  const busy = phase === 'merging' || phase === 'conflicts';
  return [
    { separator: true }, { header: 'Branch' },
    { label: 'Review Changes', action: () => openSurface('review-branch', { sessionID: s.id }) },
    { label: `Merge into ${parent}`, disabled: busy, action: () => a.mergeBranch(s.id, null, false, true) },
    { label: `Squash and Merge into ${parent}`, disabled: busy, action: () => a.mergeBranch(s.id, null, true, true) },
    { label: 'Merge, Keep Working on the Branch', disabled: busy, action: () => a.mergeBranch(s.id, null, false, false) },
    { label: 'Open a Pull Request', disabled: busy, action: () => a.branchPullRequest(s.id) },
    { label: 'Open Terminal Here', action: () => a.openLinux(s.id) },
    { separator: true },
    { label: 'Discard Branch…', destructive: true, action: () => a.discardBranch(s.id) },
    { separator: true },
  ];
}

// ── drag & drop of session rows ──────────────────────────────────────────

function dropProps(onState: (inside: boolean) => void, onDrop: (ids: string[]) => void) {
  return {
    onDragOver: (e: React.DragEvent) => { if (e.dataTransfer.types.includes(DRAG_TYPE)) { e.preventDefault(); e.dataTransfer.dropEffect = 'move'; } },
    onDragEnter: (e: React.DragEvent) => { if (e.dataTransfer.types.includes(DRAG_TYPE)) onState(true); },
    onDragLeave: (e: React.DragEvent) => { if (!(e.currentTarget as Node).contains(e.relatedTarget as Node)) onState(false); },
    onDrop: (e: React.DragEvent) => {
      onState(false);
      const id = e.dataTransfer.getData(DRAG_TYPE);
      if (id) { e.preventDefault(); onDrop([id]); }
    },
  };
}

// ── rows ──────────────────────────────────────────────────────────────────

function SessionRow({ session: s, m, depth, gone, workspaceName, accentHex, title, selected, shortcut, dropTarget, onSelect, onMenu, onDragState, onDropSessions }: {
  session: AgentSession; m: M.ListModel; depth: number; gone: boolean; workspaceName: string; accentHex: string; title: string;
  selected: boolean; shortcut?: number; dropTarget: boolean; onSelect: () => void; onMenu: (e: React.MouseEvent) => void;
  onDragState: (inside: boolean) => void; onDropSessions: (ids: string[]) => void;
}) {
  const dot = M.dot(s, m);
  const status = M.statusLine(s, m);
  const when = M.rowWhen(s, m);
  const unread = M.showsUnread(s, m);
  const native = m.machineIDs.has(s.profileID);
  const ended = M.hasEnded(s);
  const merge = M.isBranch(s) ? M.mergeLine(s) : null;
  const tint = M.mergeTint(s);
  return (
    <div className={cx('sb-row', selected && 'selected', dropTarget && 'drop')} draggable
         style={{ paddingLeft: 8 + Math.min(depth, 3) * 16, opacity: gone ? 0.5 : undefined }}
         onClick={onSelect} onContextMenu={onMenu}
         onDragStart={e => { e.dataTransfer.setData(DRAG_TYPE, s.id); e.dataTransfer.setData('text/plain', s.id); e.dataTransfer.effectAllowed = 'move'; }}
         {...dropProps(onDragState, onDropSessions)}>
      <span className="sb-row-avatar" style={{ opacity: ended ? 0.6 : undefined }}
            title={native ? `Runs natively on ${workspaceName} — not in a sandboxed VM. Its agents can reach everything on that Mac.` : workspaceName}>
        <span className={cx('sb-row-ring', native && 'native')} style={{ borderColor: native ? undefined : workspaceName ? hexA(accentHex, 0.85) : 'transparent' }} />
        <AgentAvatar tool={s.tool} size={28} />
        {dot && <AgentStatusDot status={dot} scale={1.25} style={{ position: 'absolute', right: 0, bottom: 0 }} />}
        {native && <span className="sb-native-badge"><SF name="shield.slash.fill" size={9} color="var(--orange)" /></span>}
      </span>
      <span className="sb-row-text">
        <span className="sb-row-line1">
          <span className={cx('sb-row-title', (selected || unread) && 'strong', ended && !selected && 'dim')}>{title}</span>
          {shortcut != null
            ? <span className="sb-row-chord">{isMac ? '⌘' : '^'}{shortcut}</span>
            : when != null && <span className={cx('sb-row-when', unread && 'unread')}>{when}</span>}
          {unread && shortcut == null && <UnreadMark />}
        </span>
        <span className="sb-row-line2">
          {s.nickname && <span className="sb-row-nick">@{s.nickname}</span>}
          {M.isBranch(s) ? <>
            <SF name="arrow.triangle.branch" size={11} weight={600} color={tint ?? undefined} style={{ flexShrink: 0 }} />
            <span className="sb-row-status" style={merge && tint ? { color: tint } : undefined}>
              {merge ?? [status, M.branchSummary(s)].filter(Boolean).join(' · ')}
            </span>
          </> : <span className="sb-row-status">{status}</span>}
        </span>
      </span>
    </div>
  );
}

function SwitchboardRow({ summary, dot, started, selected, onSelect }: { summary: string; dot: M.AgentStatus | null; started: boolean; selected: boolean; onSelect: () => void }) {
  return (
    <div className={cx('sb-switch', selected && 'selected')} onClick={onSelect}
         title="The Switchboard keeps track of every session: ask what's going on, answer them, start new work">
      <span className="sb-switch-icon">
        <SF name="wand.and.rays" size={15} weight={600} />
        {dot && <span className="sb-dot7" style={{ background: STATUS_COLOR[dot] }} />}
      </span>
      <span className="sb-two">
        <span className="sb-two-title">Switchboard</span>
        <span className="sb-two-sub">{started ? summary : 'Ask about all your sessions at once'}</span>
      </span>
    </div>
  );
}

function RoomRow({ room, summary, dot, folded, hasMembers, selected, dropTarget, onSelect, onMenu, onFold, onDragState, onDropSessions }: {
  room: AgentRoom; summary: string; dot: M.AgentStatus | null; folded: boolean; hasMembers: boolean; selected: boolean; dropTarget: boolean;
  onSelect: () => void; onMenu: (e: React.MouseEvent) => void; onFold: () => void;
  onDragState: (inside: boolean) => void; onDropSessions: (ids: string[]) => void;
}) {
  const tint = room.colorHex ?? '#6366F1';
  return (
    <div className={cx('sb-room', selected && 'selected', dropTarget && 'drop')} onClick={onSelect} onContextMenu={onMenu}
         title="Open the room: all its sessions side by side, with its own Switchboard"
         style={{ background: selected ? hexA(tint, 0.16) : undefined, borderColor: dropTarget ? tint : selected ? hexA(tint, 0.35) : undefined, borderWidth: dropTarget ? 2 : undefined }}
         {...dropProps(onDragState, onDropSessions)}>
      <span className="sb-room-tile" style={{ color: '#fff', background: `linear-gradient(${lighten(tint)}, ${tint})`, boxShadow: `0 1px 3px ${hexA(tint, 0.35)}` }}>
        <SF name="square.grid.2x2.fill" size={14} weight={700} color="#fff" />
        {dot && <span className="sb-dot7" style={{ background: STATUS_COLOR[dot], right: -2, bottom: -2 }} />}
      </span>
      <span className="sb-two">
        <span className="sb-two-title">{room.name}</span>
        <span className="sb-two-sub">{summary}</span>
      </span>
      {hasMembers && (
        <span className={cx('sb-room-fold', folded && 'folded')} onClick={e => { e.stopPropagation(); onFold(); }}>
          <SF name="chevron.right" size={11} weight={600} style={{ transform: folded ? undefined : 'rotate(90deg)' }} />
        </span>
      )}
    </div>
  );
}

function GroupHeader({ bucket, count, foldable, folded, onToggle }: { bucket: M.Bucket; count: number; foldable: boolean; folded: boolean; onToggle: () => void }) {
  return (
    <div className={cx('sb-gh', foldable && 'foldable')} onClick={() => foldable && onToggle()}>
      <span className="sb-gh-dot" style={{ background: M.bucketTint[bucket] }} />
      <span className="sb-gh-title">{M.bucketTitle[bucket]}</span>
      <span className="sb-gh-count">{count}</span>
      <span style={{ flex: 1 }} />
      {foldable && <SF name="chevron.right" size={10} weight={700} className="sb-gh-chev" style={{ transform: folded ? undefined : 'rotate(90deg)' }} />}
    </div>
  );
}

// ── Virtual Machines ──────────────────────────────────────────────────────

function MachinesSection(p: FullProps) {
  const [expanded, setExpanded] = usePersisted('sidebar.machinesExpanded', false);
  const vms = p.m.rows.filter(r => !p.m.machineIDs.has(r.id));
  const running = vms.filter(r => r.state === 'running' || r.state === 'booting').length;
  return (
    <div className="sb-group">
      <SectionHeader title="Virtual Machines" expanded={expanded} badges={[[running, 'var(--green)']]} count={vms.length}
                     help="The isolated machines your sessions run in" onTitle={() => setExpanded(!expanded)}
                     onAdd={() => openSurface('new-machine')} addHelp="New workspace" />
      {expanded && <>
        <GridSection {...p} />
        {vms.map(r => <VMSection key={r.id} {...p} row={r} entry={p.m.entries.find(e => e.id === r.id)} />)}
        <KubeSections {...p} />
      </>}
    </div>
  );
}

function NativeSection(p: FullProps) {
  const [expanded, setExpanded] = usePersisted('sidebar.nativeExpanded', true);
  const rows = p.m.rows.filter(r => p.m.machineIDs.has(r.id));
  if (!rows.length) return null;
  return (
    <div className="sb-group">
      <SectionHeader title="Native Machines" expanded={expanded} badges={[[rows.filter(r => r.state === 'running').length, 'var(--orange)']]}
                     count={rows.length} help="Macs whose agents run natively — not sandboxed — attached with Bromure Agent Host"
                     onTitle={() => setExpanded(!expanded)} />
      {expanded && rows.map(r => <VMSection key={r.id} {...p} row={r} entry={p.m.entries.find(e => e.id === r.id)} native />)}
    </div>
  );
}

function GridSection(p: FullProps) {
  const { host } = useHostCtx();
  const grid = useRemote(host, s => s.gridLayout);
  const menu = useMenu();
  const [expanded, setExpanded] = useState(true);
  const cells: any[] = grid?.cells ?? [];
  const selected = p.selection.kind === 'grid';
  const push = (next: any[], autoFill = grid?.autoFill ?? false) =>
    host.send('POST', '/grid-layout', { cells: next.map(c => ({ profileID: c.profileID, windowIndex: c.windowIndex, label: c.label })), autoFill });
  return (
    <div className="sb-vm">
      <div className={cx('sb-grid', selected && 'selected')} onClick={() => p.select({ kind: 'grid' })}
           title={cells.length ? 'Show the terminal grid' : 'Drag terminals here to watch them side by side'}
           onContextMenu={e => { e.preventDefault(); menu(e, [{ label: 'Add new terminals automatically', checked: !!grid?.autoFill, action: () => push(cells, !grid?.autoFill) }]); }}>
        <SF name="square.grid.2x2" size={13} weight={600} className="sb-grid-icon" />
        <span className="sb-grid-label">Grid</span>
        {cells.length > 0 && <span className="sb-pill">{cells.length}</span>}
        <span style={{ flex: 1 }} />
        {cells.length > 0 && <span className="sb-grid-chev" onClick={e => { e.stopPropagation(); setExpanded(!expanded); }}><SF name={expanded ? 'chevron.down' : 'chevron.right'} size={10} weight={700} /></span>}
      </div>
      {expanded && cells.length > 0 && (
        <div className="sb-vm-children">
          {cells.map((c, i) => {
            const ws = p.m.rows.find(r => r.id === c.profileID);
            const st = p.m.entries.find(e => e.id === c.profileID)?.tabs.find(t => t.index === c.windowIndex)?.agentStatus;
            return (
              <div key={c.id ?? i} className="sb-gridcell" onClick={() => p.select({ kind: 'grid' })}
                   onContextMenu={e => { e.preventDefault(); menu(e, [{ label: 'Remove from Grid', action: () => push(cells.filter(x => x !== c)) }]); }}>
                {st ? <AgentStatusDot status={st} /> : <span className="agent-dot" style={{ background: 'var(--label-tertiary)' }} />}
                <span className="sb-gridcell-label" style={{ color: ws?.accentHex ?? '#888' }} title={ws ? `${ws.name} — ${c.label}` : c.label}>{c.label}</span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

/** worktreeDepth(of:in:) — a worktree's parent chain; an attached terminal nests one under its worktree. */
function tabDepth(tab: M.MirrorTab, tabs: M.MirrorTab[]): number {
  if (!tab.worktreeBranch && !tab.parentBranch) return 0;
  let depth = 1;
  let parent = tab.worktreeBranch ? tab.parentBranch : tabs.find(t => t.worktreeBranch === tab.parentBranch)?.parentBranch;
  if (!tab.worktreeBranch) depth = 1 + (tabs.some(t => t.worktreeBranch === tab.parentBranch) ? 1 : 0);
  const seen = new Set<string>();
  while (parent && !seen.has(parent)) {
    seen.add(parent);
    const up = tabs.find(t => t.worktreeBranch === parent);
    if (!up) break;
    depth++;
    parent = up.parentBranch;
  }
  return depth;
}

function VMSection(p: FullProps & { row: M.ProfileRow; entry?: M.VMEntry; native?: boolean }) {
  const { host } = useHostCtx();
  const { row, entry } = p;
  const menu = useMenu();
  const wa = useMemo(() => workspaceActions(host), [host]);
  const live = row.state === 'running' || row.state === 'booting';
  const selected = p.selection.kind === 'workspace' && p.selection.workspaceID === row.id;
  const activeIdx = selected && p.selection.kind === 'workspace' ? p.selection.windowIndex : undefined;
  const stateLabel = row.state === 'off' ? 'Off' : row.state === 'booting' ? 'Starting…' : row.state === 'suspended' ? 'Suspended' : null;

  const controlItems = (alt: boolean): MenuItem[] => {
    const it: MenuItem[] = [];
    if (row.compromised) {
      it.push({ label: 'Wipe and Restore…', disabled: live, action: () => wa.compromise(row.id, row.name, 'wipe') });
      it.push({ label: 'Clear Compromised Mark…', action: () => wa.compromise(row.id, row.name, 'clear') });
      it.push({ separator: true });
    }
    if (row.state === 'off') it.push({ label: 'Start', action: () => wa.start(row.id) });
    else if (row.state === 'suspended') it.push({ label: 'Resume', action: () => wa.start(row.id) });
    else {
      it.push({ label: 'Shutdown', action: () => wa.shutdown(row.id) });
      it.push({ label: 'Suspend', action: () => wa.suspend(row.id) });
      it.push({ label: alt ? 'Force Reboot' : 'Reboot', action: () => wa.reboot(row.id, row.name, alt) });
    }
    it.push({ separator: true });
    it.push({ label: 'Edit…', action: () => openSurface('settings', { profileID: row.id }) });
    it.push({ label: 'Rewind home…', action: () => openSurface('rewind-home', { profileID: row.id }) });
    it.push({ separator: true });
    it.push({ label: 'Delete workspace', destructive: true, disabled: live, action: () => wa.deleteWorkspace(row.id, row.name) });
    return it;
  };

  const tabs = (entry?.tabs ?? []).filter(t => !t.containerID);
  const sessionOn = (t: M.MirrorTab) => p.sessions.find(x => x.profileID === row.id && x.windowIndex === t.index && !M.isDeleted(x));
  const tabLabel = (t: M.MirrorTab) => {
    const s = sessionOn(t);
    return (s && !M.hasEnded(s) && s.title.trim()) || t.label;
  };
  const worktreeCmd = (a: string, t: M.MirrorTab) => {
    const root = t.rootRepo ?? t.repoRoot ?? '';
    if (!root || !t.worktreeBranch) return;
    host.send('POST', `/sessions/${encodeURIComponent(row.id)}/worktree`, { action: a, args: [root, t.worktreeBranch] });
  };
  const tabMenu = (e: React.MouseEvent, t: M.MirrorTab) => {
    e.preventDefault();
    const isWT = !!t.worktreeBranch;
    const inRepo = !!t.isGitRepo || isWT;
    const items: MenuItem[] = [
      { label: inRepo ? 'New worktree…' : 'New worktree…  (Not in a git repo)', disabled: !inRepo, action: () => {
        const s = sessionOn(t);
        if (s && !M.hasEnded(s)) { p.onSession(s.id); openSurface('new-branch', { sessionID: s.id }); }
        else openSurface('new-worktree', { profileID: row.id, index: t.index });
      } },
      { label: 'New automation…', action: () => openSurface('new-automation', { profileID: row.id, repoPath: t.cwd }) },
    ];
    if (isWT) {
      items.push({ label: 'Merge…', action: () => openSurface('tab-merge', { profileID: row.id, index: t.index }) });
      items.push({ label: 'Attach terminal', action: () => worktreeCmd('terminal', t) });
      items.push({ separator: true });
      items.push({ label: 'Discard worktree', destructive: true, action: async () => {
        const ok = await confirmAlert(`Discard worktree “${tabLabel(t)}”?`,
          `Removes the checkout and deletes branch “${t.worktreeBranch}”. Any commits on this branch that haven't been merged will be lost.`, 'Discard', true);
        if (!ok) return;
        worktreeCmd('remove', t);
        wa.closeTab(row.id, t.index);
      } });
    }
    if (t.label.startsWith('Merge → ')) items.push({ label: 'Have the agent resolve conflicts', action: () => openSurface('tab-resolve', { profileID: row.id, index: t.index }) });
    menu(e, items);
  };
  const docker = ((entry?.vm.dockerContainers as any[] | undefined) ?? []).filter(c => c.state === 'running');

  return (
    <div className="sb-vm">
      <div className={cx('sb-vmhead', selected && 'selected')} style={{ background: selected ? hexA(row.accentHex, 0.16) : undefined }}
           onClick={() => p.select({ kind: 'workspace', workspaceID: row.id })}
           onContextMenu={e => { e.preventDefault(); if (!p.native) menu(e, controlItems(e.altKey)); }}>
        {selected && <span className="sb-vm-bar" style={{ background: row.accentHex }} />}
        <VMIcon accentHex={row.accentHex} state={row.state} native={p.native} />
        <span className="sb-vm-names">
          <span className="sb-vm-name" title={row.notes ? row.notes.slice(0, 200) : undefined}>
            <span className="sb-ellipsis">{row.name}</span>
            {row.compromised && <SF name="exclamationmark.triangle.fill" size={9} color="var(--red)" style={{ marginLeft: 5 }} />}
          </span>
          {p.native ? <span className="sb-vm-state" style={{ color: 'var(--orange)' }}>Not sandboxed</span>
                    : stateLabel && <span className="sb-vm-state">{stateLabel}</span>}
        </span>
        <span style={{ flex: 1 }} />
        {live && !p.native && <span className="sb-iconbtn" title={`New tab (${isMac ? '⌘T' : 'Ctrl+T'})`} onClick={e => { e.stopPropagation(); wa.newTab(row.id); }}><SF name="plus" size={11} weight={600} /></span>}
        {!p.native && <span className="sb-iconbtn wide" onClick={e => { e.stopPropagation(); menu((e.currentTarget as HTMLElement).getBoundingClientRect(), controlItems(e.altKey)); }}><SF name="ellipsis" size={12} weight={600} /></span>}
      </div>
      {entry && (tabs.length > 0 || docker.length > 0) && (
        <div className="sb-vm-children">
          {tabs.map((t, pos) => {
            const kind = M.agentKind(tabLabel(t)) ?? M.agentKind(t.label);
            const active = selected && (activeIdx != null ? activeIdx === t.index : t.active);
            const color = active ? row.accentHex : 'var(--label-secondary)';
            return (
              <div key={t.index} className={cx('sb-tab', active && 'active')} style={{ paddingLeft: 20 + tabDepth(t, tabs) * 14 }}
                   onClick={() => { wa.selectTab(row.id, t.index); p.select({ kind: 'workspace', workspaceID: row.id, windowIndex: t.index }); }}
                   onContextMenu={e => tabMenu(e, t)}>
                <span style={{ width: 10, flexShrink: 0 }} />
                {t.worktreeBranch && <SF name="arrow.triangle.branch" size={10} color={color} />}
                <span className="sb-tab-icon">
                  {kind ? <>
                    <AgentGlyph tool={AGENT_GLYPHS.includes(kind) ? kind : 'robot'} size={13} color={color} />
                    <AgentStatusDot status={t.agentStatus} style={{ position: 'absolute', right: 0, bottom: -1 }} />
                  </> : <SF name="terminal" size={11} color="var(--label-secondary)" />}
                </span>
                <span className="sb-tab-label">{tabLabel(t) || 'shell'}</span>
                <span style={{ flex: 1 }} />
                <span className="sb-tab-close sb-iconbtn" title={`Close tab (${isMac ? '⌘W' : 'Ctrl+W'})`}
                      onClick={e => { e.stopPropagation(); wa.closeTab(row.id, t.index); }}><SF name="xmark" size={9} weight={600} /></span>
                {selected && pos < 9 && <span className="sb-tab-chord">{isMac ? '⌘' : '^'}{pos + 1}</span>}
              </div>
            );
          })}
          {docker.length > 0 && (
            <div className={cx('sb-tab', p.selection.kind === 'docker' && p.selection.workspaceID === row.id && 'active')} style={{ paddingLeft: 20 }}
                 onClick={() => p.select({ kind: 'docker', workspaceID: row.id })}>
              <span style={{ width: 10 }} />
              <span className="sb-tab-icon"><SF name="shippingbox" size={12} color="var(--label-secondary)" /></span>
              <span className="sb-tab-label">Docker</span>
              <span style={{ flex: 1 }} />
              <span className="sb-pill">{docker.length}</span>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function VMIcon({ accentHex, state, native }: { accentHex: string; state: M.RunState; native?: boolean }) {
  const color = state === 'booting' ? 'var(--orange)' : state === 'running' ? 'var(--green)' : state === 'suspended' ? 'var(--yellow)' : 'var(--label-tertiary)';
  return (
    <span className="sb-vmicon" style={{ background: hexA(accentHex, state === 'off' ? 0.10 : 0.18) }}>
      <SF name={native ? 'desktopcomputer' : 'server.rack'} size={13} color={hexA(accentHex, state === 'off' ? 0.55 : 1)} />
      <span className={cx('sb-vmicon-dot', state === 'booting' && 'pulse')} style={{ background: color }} />
    </span>
  );
}

function KubeSections(p: FullProps) {
  const { host } = useHostCtx();
  const kube = useRemote(host, s => s.kubeClusters);
  const menu = useMenu();
  const clusters: any[] = kube?.clusters ?? [];
  const registries: any[] = kube?.registries ?? [];
  const status: Record<string, any> = kube?.status ?? {};
  const row = (kind: 'cluster' | 'registry', c: any) => {
    const st = status[c.id] ?? {};
    const phase: string = st.phase ?? 'stopped';
    const dot = phase === 'running' ? 'var(--green)' : phase === 'error' ? 'var(--red)' : phase === 'stopped' ? 'var(--label-tertiary)' : 'var(--orange)';
    const sel = kind === 'cluster' ? p.selection.kind === 'cluster' && p.selection.clusterID === c.id : p.selection.kind === 'registry' && p.selection.registryID === c.id;
    const act = (action: string) => () => openSurface('kube-action', { kind, id: c.id, action });
    const items = (): MenuItem[] => [
      ...(phase === 'running' ? [{ label: 'Restart', action: act('restart') }, { label: 'Stop', action: act('stop') }] : [{ label: 'Start', action: act('start') }]),
      ...(kind === 'cluster' ? [{ label: 'Workspace access…', action: act('access') }] : []),
      { separator: true },
      { label: kind === 'cluster' ? 'Delete cluster…' : 'Delete registry…', destructive: true, action: act('delete') },
    ];
    return (
      <div key={c.id} className={cx('sb-vmhead', sel && 'selected')} style={{ background: sel ? 'rgba(50,108,229,0.16)' : undefined }}
           onClick={() => p.select(kind === 'cluster' ? { kind: 'cluster', clusterID: c.id } : { kind: 'registry', registryID: c.id })}
           onContextMenu={e => { e.preventDefault(); menu(e, items()); }}>
        {sel && <span className="sb-vm-bar" style={{ background: '#326CE5' }} />}
        <span className="sb-kube-icon"><SF name={kind === 'cluster' ? 'helm' : 'shippingbox'} size={13} color={sel ? '#326CE5' : 'var(--label-secondary)'} />
          <span className="agent-dot" style={{ background: dot, position: 'absolute', right: -2, bottom: -1 }} /></span>
        <span className="sb-vm-names">
          <span className="sb-vm-name"><span className="sb-ellipsis">{c.name}</span></span>
          <span className="sb-vm-state">{st.step ?? phase.charAt(0).toUpperCase() + phase.slice(1)}</span>
        </span>
        <span style={{ flex: 1 }} />
        <span className="sb-iconbtn" onClick={e => { e.stopPropagation(); menu((e.currentTarget as HTMLElement).getBoundingClientRect(), items()); }}><SF name="ellipsis" size={11} weight={600} /></span>
      </div>
    );
  };
  return <>
    {clusters.length > 0 && <>
      <SectionHeader title="Kubernetes" count={clusters.length} onTitle={() => {}} onAdd={() => openSurface('new-cluster')} addHelp="New Kubernetes cluster" />
      {clusters.map(c => row('cluster', c))}
    </>}
    {registries.length > 0 && <>
      <SectionHeader title="Registries" count={registries.length} onTitle={() => {}} onAdd={() => openSurface('new-registry')} addHelp="New registry" />
      {registries.map(c => row('registry', c))}
    </>}
  </>;
}

// ── CompactRail ───────────────────────────────────────────────────────────

function CompactRail({ m, sessions, selection, select, onSession, onNew, onSwitchboard }: {
  m: M.ListModel; sessions: AgentSession[]; selection: StageSelection; select: (s: StageSelection) => void;
  onSession: (id: string) => void; onNew: () => void; onSwitchboard: () => void;
}) {
  const sb = M.globalSwitchboard(sessions);
  const sbSummary = M.switchboardSummary(sessions, m);
  const sbDot = sb ? M.dot(sb, m) : null;
  const sel = selection.kind === 'session' ? selection.sessionID : null;
  return (
    <div className="sb-rail">
      <button className={cx('sb-rail-btn', selection.kind === 'new-session' && 'on')} onClick={onNew} title={`New session (${isMac ? '⌘N' : 'Ctrl+N'})`}>
        <SF name="plus" size={15} weight={600} />
      </button>
      {M.switchboardVisible(sessions, m) && (
        <button className={cx('sb-rail-btn', sb && sel === sb.id && 'on')} onClick={onSwitchboard} title={'Switchboard' + (sbSummary ? ' — ' + sbSummary : '')}>
          <span className="sb-rail-sb"><SF name="wand.and.rays" size={13} weight={600} />
            {sbDot && <AgentStatusDot status={sbDot} style={{ position: 'absolute', right: -2, bottom: -2 }} />}</span>
        </button>
      )}
      {M.orderedAll(sessions, m).map(s => {
        const b = M.bucket(s, m);
        const accent = m.rows.find(r => r.id === s.profileID)?.accentHex ?? '#888888';
        return (
          <button key={s.id} className="sb-rail-btn" onClick={() => onSession(s.id)} title={`${s.title} — ${M.statusLine(s, m)}`}
                  style={sel === s.id ? { background: hexA(accent, 0.16) } : undefined}>
            <span style={{ position: 'relative', display: 'inline-flex', opacity: b === 'ended' || b === 'asleep' ? 0.55 : 1 }}>
              <AgentAvatar tool={s.tool} size={22} status={M.dotFor(b)} />
              {M.showsUnread(s, m) && <UnreadMark size={7} style={{ position: 'absolute', right: -3, top: -2 }} />}
            </span>
          </button>
        );
      })}
      <div className="sb-rail-div" />
      <button className={cx('sb-rail-btn', selection.kind === 'grid' && 'on')} onClick={() => select({ kind: 'grid' })} title="Grid">
        <SF name="square.grid.2x2" size={15} weight={600} />
      </button>
      {m.entries.map(e => {
        const row = m.rows.find(r => r.id === e.id);
        const accent = row?.accentHex ?? e.accentHex;
        const name = row?.name ?? e.name;
        return (
          <React.Fragment key={e.id}>
            <div className="sb-rail-div" />
            {e.tabs.filter(t => !t.containerID).map(t => {
              const kind = M.agentKind(t.label);
              const active = selection.kind === 'workspace' && selection.workspaceID === e.id && (selection.windowIndex ?? -1) === t.index;
              const color = active ? accent : 'var(--label-secondary)';
              return (
                <button key={t.index} className="sb-rail-btn" style={active ? { background: hexA(accent, 0.16) } : undefined}
                        onClick={() => select({ kind: 'workspace', workspaceID: e.id, windowIndex: t.index })}
                        title={t.label ? `${name} — ${t.label}` : name}>
                  <span style={{ position: 'relative', display: 'inline-flex' }}>
                    {kind ? <AgentGlyph tool={AGENT_GLYPHS.includes(kind) ? kind : 'robot'} size={13} color={color} />
                          : <SF name="terminal" size={12} color={color} />}
                    <AgentStatusDot status={t.agentStatus} style={{ position: 'absolute', right: -2, bottom: -1 }} />
                  </span>
                </button>
              );
            })}
          </React.Fragment>
        );
      })}
    </div>
  );
}

// ── colour helpers ───────────────────────────────────────────────────────

export function hexA(hex: string, a: number): string {
  const h = hex.replace('#', '');
  if (h.length !== 6) return hex;
  return `rgba(${parseInt(h.slice(0, 2), 16)}, ${parseInt(h.slice(2, 4), 16)}, ${parseInt(h.slice(4, 6), 16)}, ${a})`;
}
/** SwiftUI's `.gradient`: a slightly lighter top. */
function lighten(hex: string): string {
  const h = hex.replace('#', '');
  if (h.length !== 6) return hex;
  const c = [0, 2, 4].map(i => parseInt(h.slice(i, i + 2), 16)).map(v => Math.round(v + (255 - v) * 0.12));
  return `rgb(${c.join(',')})`;
}
