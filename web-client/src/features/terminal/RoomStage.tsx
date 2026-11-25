// A room on stage — RoomStage.swift (RoomStageController + RoomStageView)
// over the mirror, with RemoteRoomBackend's verbs:
//   POST /agent-rooms/<id>/{layout|rename|unarchive|switchboard}
//   POST /agent-rooms/move {session[, room]}
//   POST /agent-sessions/<id>/{resume[, {message}]|close|nickname}
//
// Header (room tile, name — double-click renames —, count, layout picker,
// timeline, room menu, Add to Room), tabs (one per page; at 1×1 each session
// plus the Switchboard's own tab), the grid of cells (each a session's chat,
// or its resting tail under a Paused bar), zoom on a cell's title bar, the
// Switchboard dock, and the room's one composer with its "To" picker.

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useHostCtx, usePersisted } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { useWindows } from '../../app/windows';
import { seg } from '../../core/remote/host';
import type { AgentRoom, AgentSession, RemoteState } from '../../core/remote/types';
import { SF } from '../../ui/icons';
import { Button, Popover, Spinner, TextField, useMenu, useTooltip, cx } from '../../ui/kit';
import { AgentAvatar, AgentStatusDot } from '../sidebar/AgentAvatar';
import {
  buildListModel, bucket, bucketTitle, bucketTint, dotFor, statusLine, distinctTitle, isSwitchboard, isDeleted,
  isArchived, isLaunching, hasEnded, liveTab, workspaceState, checkNickname, normalizeNickname, type ListModel, type Bucket,
} from '../sidebar/model';
import { showSheet, showAlert } from '../sidebar/Dialogs';
import { openSurface } from '../sidebar/actions';
import { SessionChat } from '../chat/SessionChat';
import './room.css';

// ── layout (RoomLayout) ──────────────────────────────────────────────────

interface Layout { cols: number; rows: number }
const ALL: Layout[] = [[1, 1], [2, 1], [2, 2], [3, 2], [3, 3], [4, 4]].map(([cols, rows]) => ({ cols, rows }));
const size = (l: Layout) => l.cols * l.rows;
const same = (a: Layout, b: Layout) => a.cols === b.cols && a.rows === b.rows;
function parseLayout(s: unknown): Layout | null {
  if (typeof s !== 'string') return null;
  const p = s.split('x').map(Number);
  return p.length === 2 && p.every(n => Number.isInteger(n) && n >= 1 && n <= 6) ? { cols: p[0], rows: p[1] } : null;
}
const fitting = (n: number) => ALL.find(l => size(l) >= n) ?? ALL[ALL.length - 1];
function paginate<T>(items: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += n) out.push(items.slice(i, i + n));
  return out;
}

const roomArchived = (r?: AgentRoom) => !!r?.archivedAt;
const ts = (d: unknown) => (typeof d === 'string' ? Date.parse(d) || 0 : 0);

/** RoomTally.members: the room's sessions, its own Switchboard left out. */
function membersOf(room: AgentRoom, sessions: AgentSession[]) {
  return sessions.filter(s => s.roomID === room.id && !isSwitchboard(s) && !isDeleted(s) && (roomArchived(room) || !isArchived(s)));
}

/** RemoteRoomBackend.chatKey: a live chat exists for the session. */
function isLive(s: AgentSession, m: ListModel) {
  // A fixture session (manual / store screenshots: demoBucket) is shown as
  // its state says — its chat is the fixture transcript, no VM behind it.
  if (typeof s.demoBucket === 'number') { const b = bucket(s, m); return b !== 'asleep' && b !== 'ended'; }
  if (s.windowIndex == null || hasEnded(s) || !liveTab(s, m) || bucket(s, m) === 'ended') return false;
  const ws = workspaceState(s, m);
  return ws === 'running' || ws === 'booting';
}

type Target = 'switchboard' | 'focused';

export interface RoomStageProps { roomID: string; zoomedSessionID?: string }

export function RoomStage({ roomID, zoomedSessionID }: RoomStageProps) {
  const { host, select, selection } = useHostCtx();
  const windows = useWindows();
  const st = useRemote(host, s => s) as RemoteState | undefined;
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 2000); return () => clearInterval(t); }, []);
  const m = useMemo(() => buildListModel(st, now), [st, now]);
  const sessions = st?.agentSessions ?? [];
  const room = st?.agentRooms?.find(r => r.id === roomID);
  const accent = (room?.colorHex as string | undefined) ?? '#6366F1';

  const [hideEnded, setHideEnded] = usePersisted<boolean>(`room.hideEnded.${roomID}`, false);
  const [focusedID, setFocusedID] = useState<string | undefined>(zoomedSessionID);
  const [zoomID, setZoomID] = useState<string | undefined>(zoomedSessionID);
  useEffect(() => { setZoomID(zoomedSessionID); if (zoomedSessionID) setFocusedID(zoomedSessionID); }, [zoomedSessionID]);
  const [target, setTarget] = useState<Target>('switchboard');
  const [page, setPage] = useState(0);
  const [dockOpen, setDockOpen] = useState(true);
  const [dockPeek, setDockPeek] = useState(false);
  const [dockHeight, setDockHeight] = useState(220);
  const [renaming, setRenaming] = useState<string | null>(null);
  const [wave, setWave] = useState<{ x: number; y: number; key: number } | null>(null);
  const stageRef = useRef<HTMLDivElement>(null);

  const allMembers = room ? membersOf(room, sessions) : [];
  const members = allMembers
    .filter(s => !hideEnded || s.id === focusedID || s.id === zoomID || bucket(s, m) !== 'ended')
    .sort((a, b) => ts(a.createdAt) - ts(b.createdAt));
  const switchboard = room ? sessions.find(s => isSwitchboard(s) && s.roomID === room.id && !isDeleted(s)) : undefined;
  const autoLayout = !parseLayout(room?.layout);
  const layout = parseLayout(room?.layout) ?? fitting(members.length);
  const pages = paginate(members, size(layout));
  const shownPage = Math.min(page, Math.max(0, pages.length - 1));
  const zoomed = zoomID ? members.find(s => s.id === zoomID) : undefined;
  const singleLayout = size(layout) === 1 && !zoomed;
  const [switchboardTab, setSwitchboardTab] = useState(target === 'switchboard');
  const dockShown = zoomed ? dockPeek : dockOpen;
  const focused = focusedID ? members.find(s => s.id === focusedID) : undefined;
  const effTarget: Target = !switchboard ? 'focused' : target;

  // Focus defaults to the first member; moves only once its member has left.
  useEffect(() => {
    if (!focusedID || !allMembers.some(s => s.id === focusedID)) setFocusedID(members[0]?.id);
  }, [focusedID, allMembers.map(s => s.id).join()]);   // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (page !== shownPage) setPage(shownPage); }, [page, shownPage]);
  useEffect(() => { setDockPeek(false); }, [zoomID]);
  // At 1×1 the tab on show and the composer's target agree.
  useEffect(() => {
    if (!singleLayout) return;
    setSwitchboardTab(effTarget === 'switchboard');
    if (effTarget !== 'switchboard' && pages[shownPage]?.[0]) setFocusedID(pages[shownPage][0].id);
  }, [singleLayout]);   // eslint-disable-line react-hooks/exhaustive-deps

  // ── verbs ──────────────────────────────────────────────────────────────
  const roomCommand = useCallback(async (id: string | null, action: string, body: unknown = {}) => {
    try { return await host.request('POST', '/agent-rooms/' + (id ? seg(id) + '/' : '') + action, body); }
    catch (e) { console.warn('room', action, e); return null; }
    finally { host.refreshSoon(); }
  }, [host]);
  const sessionCommand = (id: string, action: string, body?: unknown) =>
    host.send('POST', `/agent-sessions/${seg(id)}/${action}`, body ?? {});

  const setLayout = (l: Layout | null) => {
    roomCommand(roomID, 'layout', { layout: l ? `${l.cols}x${l.rows}` : '' });
    // Keep the focused session on screen.
    const i = l && focusedID ? members.findIndex(s => s.id === focusedID) : -1;
    setPage(l && i >= 0 ? Math.floor(i / size(l)) : 0);
  };
  const showPage = (p: number) => {
    const n = pages.length;
    if (!n) return;
    const t = ((p % n) + n) % n;
    if (t === shownPage) return;
    setPage(t);
    if (!focusedID || !pages[t].some(s => s.id === focusedID)) setFocusedID(pages[t][0]?.id);
  };
  const reveal = (id: string) => {
    const i = members.findIndex(s => s.id === id);
    if (i >= 0) showPage(Math.floor(i / size(layout)));
  };
  const setZoom = (id: string | undefined) => {
    setZoomID(id);
    if (selection.kind === 'room' && selection.roomID === roomID) select({ kind: 'room', roomID, zoomedSessionID: id });
  };
  const toggleZoom = (s: AgentSession, e: React.MouseEvent) => {
    setFocusedID(s.id);
    setTarget('focused');
    const zoomingIn = zoomID !== s.id;
    const r = stageRef.current?.getBoundingClientRect();
    if (zoomingIn && r) setWave({ x: e.clientX - r.left, y: e.clientY - r.top, key: Date.now() });
    setZoom(zoomingIn ? s.id : undefined);
  };
  const focusCell = (s: AgentSession) => { setFocusedID(s.id); setTarget('focused'); };

  // Esc backs out of a zoom; ⌃Tab / ⌃⇧Tab walk the tabs.
  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && zoomID && !e.defaultPrevented) {
        const t = e.target as HTMLElement | null;
        if (t?.closest('.popover, .menu, .sheet')) return;
        setZoom(undefined);
      } else if (e.key === 'Tab' && e.ctrlKey && !e.metaKey && !e.altKey && !zoomID) {
        e.preventDefault();
        showPage(shownPage + (e.shiftKey ? -1 : 1));
      }
    };
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  });

  const onNewSession = () => {
    select({ kind: 'new-session', roomID } as any);
    openSurface('new-session', { room: roomID });
  };
  const removeFromRoom = (id: string) => roomCommand(null, 'move', { session: id });

  if (!room) {
    return <div className="room-stage room-missing"><span className="secondary">This room is gone.</span></div>;
  }

  const live = (s: AgentSession) => isLive(s, m);
  const tally = members.length === 1 ? '1 session' : `${members.length} sessions`;

  return (
    <div className="room-stage" style={{ ['--room-accent' as any]: accent }}>
      <RoomHeader
        room={room} accent={accent} tally={tally} zoomed={!!zoomed} renaming={renaming}
        setRenaming={setRenaming}
        onRename={name => { setRenaming(null); if (name.trim() && name !== room.name) roomCommand(roomID, 'rename', { name: name.trim() }); }}
        onBack={() => setZoom(undefined)}
        onUnarchive={() => roomCommand(roomID, 'unarchive')}
        layoutPicker={!zoomed && members.length > 0
          ? <LayoutPicker layout={layout} auto={autoLayout} accent={accent} onAuto={() => setLayout(null)} onPick={setLayout} />
          : null}
        onTimeline={() => openTimeline()}
        menuItems={() => {
          const asleep = allMembers.filter(s => !live(s) && !isLaunching(s));
          const running = allMembers.filter(s => live(s));
          return [
            { label: 'Resume All', icon: 'play.fill', disabled: !asleep.length, action: () => asleep.forEach(s => sessionCommand(s.id, 'resume')) },
            { label: 'End All', icon: 'stop.fill', disabled: !running.length, action: () => running.forEach(s => sessionCommand(s.id, 'close')) },
            { separator: true },
            { label: 'Hide Ended Sessions', icon: 'eye.slash', checked: hideEnded, action: () => setHideEnded(!hideEnded) },
          ];
        }}
        onAdd={onNewSession}
      />
      {!zoomed && (pages.length > 1 || size(layout) === 1) && (
        <div className="room-tabs">
          {size(layout) === 1 && switchboard !== undefined && (
            <SwitchboardTab selected={switchboardTab} accent={accent} dot={dotFor(bucket(switchboard, m))}
                            onClick={() => { setSwitchboardTab(true); setTarget('switchboard'); }} />
          )}
          {pages.map((p, i) => (
            <RoomTab key={i} page={p} single={size(layout) === 1} m={m}
                     selected={i === shownPage && !(size(layout) === 1 && switchboardTab)}
                     onClick={() => {
                       showPage(i);
                       if (size(layout) === 1) { setSwitchboardTab(false); setFocusedID(p[0]?.id); setTarget('focused'); }
                     }} />
          ))}
        </div>
      )}
      <div className="room-body" ref={stageRef}>
        {zoomed ? (
          <div className="room-zoomed">
            <Cell s={zoomed} zoomed m={m} members={members} accent={accent} live={live(zoomed)}
                  focused={focusedID === zoomed.id} addressed={focusedID === zoomed.id && effTarget === 'focused'}
                  delegations onFocus={focusCell} onToggleZoom={toggleZoom}
                  onOpen={id => select({ kind: 'session', sessionID: id })}
                  onNickname={s => nicknameSheet(s)} onRemove={removeFromRoom}
                  onResume={id => sessionCommand(id, 'resume')} />
          </div>
        ) : singleLayout && switchboardTab ? (
          <SwitchboardPane sb={switchboard} live={!!switchboard && live(switchboard)} accent={accent}
                           onResume={id => sessionCommand(id, 'resume')} onStart={() => roomCommand(roomID, 'switchboard')} />
        ) : pages.length === 0 ? (
          <div className="room-empty">
            <SF name="square.grid.2x2" size={34} weight={300} style={{ opacity: 0.3 }} />
            <div className="room-empty-title">This room is empty</div>
            <div className="secondary">Drag sessions onto the room in the sidebar, or start one here.</div>
            <Button variant="prominent" onClick={onNewSession}>New Session</Button>
          </div>
        ) : (
          <Grid page={pages[shownPage]} cols={layout.cols} render={s => (
            <Cell key={s.id} s={s} m={m} members={members} accent={accent} live={live(s)}
                  focused={focusedID === s.id} addressed={focusedID === s.id && effTarget === 'focused'}
                  delegations={size(layout) === 1} onFocus={focusCell} onToggleZoom={toggleZoom}
                  onOpen={id => select({ kind: 'session', sessionID: id })}
                  onNickname={x => nicknameSheet(x)} onRemove={removeFromRoom}
                  onResume={id => sessionCommand(id, 'resume')} />
          )} />
        )}
        {wave && <div key={wave.key} className="room-wave" style={{ left: wave.x, top: wave.y }} onAnimationEnd={() => setWave(null)} />}
      </div>
      {!singleLayout && (
        <Dock sb={switchboard} live={!!switchboard && live(switchboard)} launching={!!switchboard && isLaunching(switchboard)}
              shown={dockShown} height={dockHeight} setHeight={setDockHeight} accent={accent}
              onToggle={() => zoomed ? setDockPeek(!dockPeek) : setDockOpen(!dockOpen)}
              onResume={id => sessionCommand(id, 'resume')} onStart={() => roomCommand(roomID, 'switchboard')}
              onAim={() => setTarget('switchboard')} />
      )}
      <ComposerBar
        accent={accent} m={m} members={members} switchboard={switchboard} focused={focused}
        target={effTarget} liveOf={live}
        onPick={id => {
          if (id === 'switchboard') { setTarget('switchboard'); if (singleLayout) setSwitchboardTab(true); }
          else { setFocusedID(id); reveal(id); setTarget('focused'); if (singleLayout) setSwitchboardTab(false); }
        }}
        onWake={(s, text) => sessionCommand(s.id, 'resume', { message: text })}
        onStartSwitchboard={() => roomCommand(roomID, 'switchboard')}
      />
    </div>
  );

  // ── sheets / windows ───────────────────────────────────────────────────

  function nicknameSheet(s: AgentSession) {
    showSheet(380, close => <NicknameSheet s={s} sessions={sessions} close={close}
      onSet={(nick, reclaim) => sessionCommand(s.id, 'nickname', { nickname: nick, reclaim })} />);
  }

  function openTimeline() {
    windows.open({
      id: `room-timeline-${roomID}`, title: `${room!.name} — timeline`, width: 640, height: 360,
      render: () => <RoomTimeline roomID={roomID} />,
    });
  }
}
export default RoomStage;

// ── header ───────────────────────────────────────────────────────────────

function RoomHeader({ room, accent, tally, zoomed, renaming, setRenaming, onRename, onBack, onUnarchive, layoutPicker, onTimeline, menuItems, onAdd }: {
  room: AgentRoom; accent: string; tally: string; zoomed: boolean; renaming: string | null;
  setRenaming: (v: string | null) => void; onRename: (n: string) => void; onBack: () => void; onUnarchive: () => void;
  layoutPicker: React.ReactNode; onTimeline: () => void; menuItems: () => any[]; onAdd: () => void;
}) {
  const menu = useMenu();
  const tip = useTooltip();
  return (
    <div className="room-header">
      {zoomed && (
        <button className="room-back" onClick={onBack} {...tip.bind('Back to the whole room (Esc)')}>
          <SF name="chevron.left" size={12} weight={600} /><span>Room</span>
        </button>
      )}
      <span className="room-tile"><SF name="square.grid.2x2.fill" size={12} weight={700} color="#fff" /></span>
      {renaming != null ? (
        <TextField autoFocus value={renaming} style={{ maxWidth: 240 }}
                   onChange={e => setRenaming(e.target.value)}
                   onBlur={() => onRename(renaming)}
                   onKeyDown={e => { if (e.key === 'Enter') onRename(renaming); if (e.key === 'Escape') setRenaming(null); }} />
      ) : (
        <span className="room-name" onDoubleClick={() => setRenaming(room.name)} {...tip.bind('Double-click to rename')}>{room.name}</span>
      )}
      <span className="room-tally">{tally}</span>
      {roomArchived(room) && (
        <>
          <span className="room-archived"><SF name="archivebox" size={11} weight={600} /> Archived</span>
          <Button size="small" onClick={onUnarchive}>Unarchive Room</Button>
        </>
      )}
      <span style={{ flex: 1 }} />
      {layoutPicker}
      <button className="room-icon-btn" onClick={onTimeline} {...tip.bind('Room timeline: who worked when, and on what')}>
        <SF name="chart.bar.xaxis" size={12} weight={600} />
      </button>
      <button className="room-menu-btn" {...tip.bind('Room actions')}
              onClick={e => menu((e.currentTarget as HTMLElement).getBoundingClientRect(), menuItems())}>
        <SF name="ellipsis" size={13} weight={600} />
      </button>
      <button className="room-add" onClick={onAdd} {...tip.bind('Start a session in this room')}>
        <SF name="plus" size={12} weight={600} /><span className="room-add-label">Add to Room</span>
      </button>
      {tip.node}
    </div>
  );
}

function LayoutPicker({ layout, auto, accent, onAuto, onPick }: {
  layout: Layout; auto: boolean; accent: string; onAuto: () => void; onPick: (l: Layout) => void;
}) {
  const menu = useMenu();
  const quick = [{ cols: 2, rows: 2 }, { cols: 3, rows: 3 }];
  const others = ALL.filter(l => !quick.some(q => same(q, l)));
  const custom = !auto && others.some(o => same(o, layout));
  const tip = useTooltip();
  return (
    <div className="room-layouts">
      <button className={cx('room-chip', auto && 'on')} onClick={onAuto} {...tip.bind('Sized to fit the room')}>
        <span className="room-chip-text" style={{ color: auto ? accent : undefined }}>Auto</span>
      </button>
      {quick.map(l => {
        const on = !auto && same(l, layout);
        return (
          <button key={l.cols} className={cx('room-chip', on && 'on')} onClick={() => onPick(l)} {...tip.bind(`${l.cols} × ${l.rows} grid`)}>
            <GridGlyph cols={l.cols} rows={l.rows} on={on} accent={accent} />
          </button>
        );
      })}
      <button className={cx('room-chip', custom && 'on')} {...tip.bind('Other layouts')}
              onClick={e => menu((e.currentTarget as HTMLElement).getBoundingClientRect(),
                others.map(l => ({ label: `${l.cols} × ${l.rows} grid`, action: () => onPick(l) })))}>
        <span className="room-chip-text" style={{ color: custom ? accent : undefined }}>{custom ? `${layout.cols}×${layout.rows}` : '⋯'}</span>
      </button>
      {tip.node}
    </div>
  );
}

function GridGlyph({ cols, rows, on, accent }: { cols: number; rows: number; on: boolean; accent: string }) {
  return (
    <span className="room-glyph" style={{ gridTemplateColumns: `repeat(${cols}, 1fr)`, gridTemplateRows: `repeat(${rows}, 1fr)` }}>
      {Array.from({ length: cols * rows }, (_, i) => <span key={i} style={{ background: on ? accent : undefined }} />)}
    </span>
  );
}

// ── tabs ─────────────────────────────────────────────────────────────────

function RoomTab({ page, single, selected, m, onClick }: { page: AgentSession[]; single: boolean; selected: boolean; m: ListModel; onClick: () => void }) {
  const short = (t: string) => t.length > 18 ? t.slice(0, 17) + '…' : t;
  const names = page.slice(0, 2).map(s => short(s.title));
  const label = single ? page[0]?.title ?? '' : names.join(', ') + (page.length > names.length ? ` +${page.length - names.length}` : '');
  return (
    <button className={cx('room-tab', selected && 'selected')} onClick={onClick} title={page.map(s => s.title).join('\n')}>
      {single && page[0] ? <AgentAvatar tool={page[0].tool} size={16} status={dotFor(bucket(page[0], m))} />
        : <span className="room-tab-stack">{page.slice(0, 4).map(s => <AgentAvatar key={s.id} tool={s.tool} size={15} status={dotFor(bucket(s, m))} />)}</span>}
      <span className="room-tab-label" style={{ maxWidth: single ? 200 : 260 }}>{label}</span>
    </button>
  );
}

function SwitchboardTab({ selected, accent, dot, onClick }: { selected: boolean; accent: string; dot: ReturnType<typeof dotFor>; onClick: () => void }) {
  return (
    <button className={cx('room-tab', selected && 'selected')} onClick={onClick} title="The room's Switchboard">
      <span className="room-sb-mark">
        <SF name="wand.and.rays" size={10} weight={600} color={accent} />
        {dot && <AgentStatusDot status={dot} scale={0.8} style={{ position: 'absolute', right: -2, bottom: -2 }} />}
      </span>
      <span className="room-tab-label">Switchboard</span>
    </button>
  );
}

// ── grid + cells ─────────────────────────────────────────────────────────

function Grid({ page, cols, render }: { page: AgentSession[]; cols: number; render: (s: AgentSession) => React.ReactNode }) {
  // Rows as filled as the page needs, the last one stretched: three in a
  // 2×2 is two over one, not a hole.
  const rows = paginate(page, Math.max(1, cols));
  return (
    <div className="room-grid">
      {rows.map((r, i) => <div key={i} className="room-row">{r.map(render)}</div>)}
    </div>
  );
}

interface CellProps {
  s: AgentSession; m: ListModel; members: AgentSession[]; accent: string; live: boolean; zoomed?: boolean;
  focused: boolean; addressed: boolean; delegations?: boolean;
  onFocus: (s: AgentSession) => void; onToggleZoom: (s: AgentSession, e: React.MouseEvent) => void;
  onOpen: (id: string) => void; onNickname: (s: AgentSession) => void; onRemove: (id: string) => void; onResume: (id: string) => void;
}

function Cell(p: CellProps) {
  const { s, m, live, focused, addressed, zoomed } = p;
  const b = bucket(s, m);
  const menu = useMenu();
  const tip = useTooltip();
  return (
    <div className={cx('room-cell', focused && 'focused', addressed && 'addressed')} onMouseDown={() => p.onFocus(s)}>
      <div className="room-cell-title" onClick={e => p.onToggleZoom(s, e)} {...tip.bind(zoomed ? 'Back to the whole room' : 'Zoom in')}>
        <AgentAvatar tool={s.tool} size={18} status={dotFor(b)} />
        <span className="room-cell-name">{distinctTitle(s, p.members, m)}</span>
        {s.nickname && <span className="room-cell-nick">@{s.nickname}</span>}
        {live && (b === 'working' || b === 'needsYou') && (
          <span className="room-cell-chip" style={{ ['--chip' as any]: bucketTint[b] }}>{statusLine(s, m)}</span>
        )}
        <span style={{ flex: 1, minWidth: 4 }} />
        <button className="room-cell-more" onClick={e => {
          e.stopPropagation();
          menu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
            { label: 'Open as Session', action: () => p.onOpen(s.id) },
            { label: s.nickname ? `Nickname: @${s.nickname}…` : 'Nickname…', action: () => p.onNickname(s) },
            { label: 'Remove from Room', action: () => p.onRemove(s.id) },
          ]);
        }}><SF name="ellipsis" size={13} weight={600} /></button>
        <SF name={zoomed ? 'arrow.down.right.and.arrow.up.left' : 'arrow.up.left.and.arrow.down.right'} size={11} weight={600}
            style={{ color: 'var(--label-secondary)' }} />
      </div>
      <div className="room-cell-body">
        {live ? (
          <>
            <SessionChat sessionID={s.id} parts="transcript" delegations={zoomed || p.delegations} />
            <div className="room-cell-fade" />
          </>
        ) : isLaunching(s) ? (
          <div className="room-cell-starting"><Spinner size={18} /><span className="secondary">Starting…</span></div>
        ) : (
          <RestingCell s={s} b={b} onResume={() => p.onResume(s.id)} />
        )}
      </div>
      {tip.node}
    </div>
  );
}

/** A stopped member: its conversation, faded, under a floating bar that
 *  says so and picks it back up. */
function RestingCell({ s, b, onResume }: { s: AgentSession; b: Bucket; onResume: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [fit, setFit] = useState(2);   // 2 = hint + label, 1 = label, 0 = icon
  useEffect(() => {
    const el = ref.current; if (!el) return;
    const ro = new ResizeObserver(() => { const w = el.clientWidth; setFit(w > 360 ? 2 : w > 200 ? 1 : 0); });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return (
    <div className="room-resting" ref={ref}>
      <div className="room-resting-content"><SessionChat sessionID={s.id} parts="transcript" /></div>
      <div className="room-resting-fade" />
      <div className="room-resting-bar">
        <SF name="pause.circle.fill" size={13} style={{ color: 'var(--label-secondary)' }} />
        <span className="room-resting-title">{bucketTitle[b]}</span>
        {fit >= 2 && <span className="room-resting-hint">a message picks it up</span>}
        <span style={{ flex: 1, minWidth: 6 }} />
        <button className="room-resume" onClick={e => { e.stopPropagation(); onResume(); }} title="Resume">
          <SF name="play.fill" size={10} />{fit >= 1 && <span>Resume</span>}
        </button>
      </div>
    </div>
  );
}

// ── Switchboard dock / pane ──────────────────────────────────────────────

function SwitchboardBody({ sb, live, launching, accent, onResume, onStart, onAim }: {
  sb?: AgentSession; live: boolean; launching: boolean; accent: string; onResume: (id: string) => void; onStart: () => void; onAim?: () => void;
}) {
  if (sb && live) return <div className="room-sb-chat" onMouseDown={onAim}><SessionChat sessionID={sb.id} parts="transcript" /></div>;
  if (sb && launching) return <div className="room-sb-center"><Spinner size={12} /><span className="secondary">The room's Switchboard is starting…</span></div>;
  if (sb) return (
    <div className="room-sb-center col">
      <SF name="pause.circle" size={22} weight={300} style={{ opacity: 0.3 }} />
      <Button onClick={() => onResume(sb.id)}>Resume</Button>
    </div>
  );
  return (
    <div className="room-sb-center col">
      <div className="secondary" style={{ maxWidth: 520, textAlign: 'center' }}>
        Ask about everything in this room at once — what's stuck, what's done — or have it answer and start sessions for you.
      </div>
      <Button variant="prominent" onClick={onStart} style={{ ['--accent' as any]: accent }}>Start the Room's Switchboard</Button>
    </div>
  );
}

function Dock({ sb, live, launching, shown, height, setHeight, accent, onToggle, onResume, onStart, onAim }: {
  sb?: AgentSession; live: boolean; launching: boolean; shown: boolean; height: number; setHeight: (h: number) => void; accent: string;
  onToggle: () => void; onResume: (id: string) => void; onStart: () => void; onAim: () => void;
}) {
  const paused = !!sb && !live && !launching;
  const startDrag = (e: React.MouseEvent) => {
    e.preventDefault();
    const y0 = e.clientY, h0 = height;
    const mm = (ev: MouseEvent) => setHeight(Math.min(560, Math.max(120, h0 - (ev.clientY - y0))));
    const mu = () => { window.removeEventListener('mousemove', mm); window.removeEventListener('mouseup', mu); };
    window.addEventListener('mousemove', mm); window.addEventListener('mouseup', mu);
  };
  return (
    <div className="room-dock">
      <div className="room-dock-head">
        <div className="room-dock-grip" onMouseDown={startDrag} />
        <SF name="wand.and.rays" size={13} color={accent} />
        <span className="room-dock-title">Switchboard</span>
        {paused ? (
          <>
            <span className="room-dock-sub">Paused — your next message picks it up</span>
            <span style={{ flex: 1 }} />
            <Button size="small" onClick={() => onResume(sb!.id)}>Resume</Button>
          </>
        ) : (
          <><span className="room-dock-sub">keeps track of this room's sessions</span><span style={{ flex: 1 }} /></>
        )}
        <button className="room-dock-chev" onClick={onToggle} title={shown ? 'Fold the Switchboard' : 'Show the Switchboard'}>
          <SF name={shown ? 'chevron.down' : 'chevron.up'} size={12} weight={500} />
        </button>
      </div>
      {!paused && shown && (
        <div className="room-dock-body" style={{ height }}>
          <SwitchboardBody sb={sb} live={live} launching={launching} accent={accent} onResume={onResume} onStart={onStart} onAim={onAim} />
        </div>
      )}
    </div>
  );
}

function SwitchboardPane({ sb, live, accent, onResume, onStart }: {
  sb?: AgentSession; live: boolean; accent: string; onResume: (id: string) => void; onStart: () => void;
}) {
  const launching = !!sb && isLaunching(sb);
  const paused = !!sb && !live && !launching;
  return (
    <div className="room-sb-pane">
      <div className="room-sb-pane-head">
        <SF name="wand.and.rays" size={13} color={accent} />
        <span className="room-dock-title" style={{ fontSize: 12.5 }}>Switchboard</span>
        <span className="room-dock-sub">keeps track of this room's sessions</span>
      </div>
      <div className="room-sb-pane-body">
        {paused ? (
          <div className="room-sb-center col">
            <SF name="pause.circle" size={22} weight={300} style={{ opacity: 0.3 }} />
            <span className="secondary">Paused — your next message picks it up</span>
            <Button onClick={() => onResume(sb!.id)}>Resume</Button>
          </div>
        ) : <SwitchboardBody sb={sb} live={live} launching={launching} accent={accent} onResume={onResume} onStart={onStart} />}
      </div>
    </div>
  );
}

function SwitchboardGlyph({ accent, size: sz = 26 }: { accent: string; size?: number }) {
  return (
    <span className="room-sb-glyph" style={{ width: sz, height: sz, borderRadius: sz * 0.28, background: `linear-gradient(180deg, color-mix(in srgb, ${accent} 85%, #fff), ${accent})` }}>
      <SF name="wand.and.rays" size={sz * 0.5} weight={600} color="#fff" />
    </span>
  );
}

// ── the one composer ─────────────────────────────────────────────────────

function ComposerBar({ accent, m, members, switchboard, focused, target, liveOf, onPick, onWake, onStartSwitchboard }: {
  accent: string; m: ListModel; members: AgentSession[]; switchboard?: AgentSession; focused?: AgentSession; target: Target;
  liveOf: (s: AgentSession) => boolean; onPick: (id: string) => void; onWake: (s: AgentSession, text: string) => void;
  onStartSwitchboard: () => void;
}) {
  const toSwitchboard = target === 'switchboard' || !focused;
  const name = toSwitchboard ? 'Switchboard' : focused!.title;
  const who = toSwitchboard ? 'the Switchboard' : name;
  const aimed = toSwitchboard ? switchboard : focused;
  const [picker, setPicker] = useState<DOMRect | null>(null);
  const [draft, setDraft] = useState('');
  void onStartSwitchboard;
  return (
    <div className="room-composer">
      <div className="room-to">
        <span className="room-to-label">To</span>
        <button className={cx('room-to-token', picker && 'open')}
                title="Who this message goes to — the room's Switchboard, or the session you clicked"
                onClick={e => setPicker(picker ? null : (e.currentTarget as HTMLElement).getBoundingClientRect())}>
          {toSwitchboard ? <SwitchboardGlyph accent={accent} size={16} />
            : <AgentAvatar tool={focused!.tool} size={16} status={dotFor(bucket(focused!, m))} />}
          <span className="room-to-name">{name}</span>
          <SF name="chevron.down" size={8} weight={700} style={{ color: 'var(--label-secondary)' }} />
        </button>
      </div>
      {aimed && liveOf(aimed) ? (
        <SessionChat key={aimed.id} sessionID={aimed.id} parts="composer" placeholder={`Message ${who}… (or drop files)`} />
      ) : aimed ? (
        <WakeComposer accent={accent} placeholder={`Message ${who} — it wakes up and carries on…`} value={draft} onChange={setDraft}
                      onSend={() => { const t = draft.trim(); if (t) { onWake(aimed, t); setDraft(''); } }} />
      ) : (
        <div className="room-composer-none">Start the room's Switchboard to ask it about everything here.</div>
      )}
      {picker && (
        <Popover anchor={picker} onClose={() => setPicker(null)} width={320} edge="top">
          <TargetPicker accent={accent} m={m} members={members} switchboard={switchboard} liveOf={liveOf}
                        selected={toSwitchboard ? 'switchboard' : focused!.id}
                        pick={id => { onPick(id); setPicker(null); }} />
        </Popover>
      )}
    </div>
  );
}

/** ChatComposer for an asleep target: the message wakes it. */
function WakeComposer({ accent, placeholder, value, onChange, onSend }: {
  accent: string; placeholder: string; value: string; onChange: (v: string) => void; onSend: () => void;
}) {
  return (
    <div className="room-wake" style={{ ['--room-accent' as any]: accent }}>
      <textarea className="room-wake-field" placeholder={placeholder} value={value} rows={2}
                onChange={e => onChange(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); onSend(); } }} />
      <div className="room-wake-foot">
        <span className="room-wake-hint">⏎ send</span><span className="room-wake-hint">⇧⏎ newline</span>
        <span style={{ flex: 1 }} />
        <button className={cx('room-wake-send', value.trim() && 'ready')} onClick={onSend} disabled={!value.trim()} title="Send">
          <SF name="arrow.up" size={12} weight={700} />
        </button>
      </div>
    </div>
  );
}

function TargetPicker({ accent, m, members, switchboard, liveOf, selected, pick }: {
  accent: string; m: ListModel; members: AgentSession[]; switchboard?: AgentSession; liveOf: (s: AgentSession) => boolean;
  selected: string; pick: (id: string) => void;
}) {
  const [q, setQ] = useState('');
  const rows = [{ id: 'switchboard', s: undefined as AgentSession | undefined, title: 'Switchboard', sub: 'The whole room at once' },
    ...members.map(s => ({ id: s.id, s, title: s.title, sub: (s.nickname ? `@${s.nickname} · ` : '') + statusLine(s, m) }))]
    .filter(r => !q.trim() || (r.title + ' ' + r.sub).toLowerCase().includes(q.trim().toLowerCase()));
  return (
    <div className="room-picker">
      <div className="room-picker-search">
        <SF name="magnifyingglass" size={13} style={{ color: 'var(--label-secondary)' }} />
        <input autoFocus placeholder="Send to…" value={q} onChange={e => setQ(e.target.value)}
               onKeyDown={e => { if (e.key === 'Enter' && rows[0]) pick(rows[0].id); }} />
      </div>
      <div className="room-picker-list">
        {rows.map(r => {
          const live = r.s ? liveOf(r.s) : !!switchboard;
          return (
            <button key={r.id} className={cx('room-picker-row', r.id === selected && 'selected')} onClick={() => pick(r.id)}
                    style={{ opacity: live ? 1 : 0.55 }}>
              {r.s ? <AgentAvatar tool={r.s.tool} size={26} status={dotFor(bucket(r.s, m))} /> : <SwitchboardGlyph accent={accent} size={26} />}
              <span className="room-picker-text"><span className="t">{r.title}</span><span className="s">{r.sub}</span></span>
              {r.id === selected && <SF name="checkmark" size={11} weight={700} color={accent} />}
            </button>
          );
        })}
        {!rows.length && <div className="room-picker-none">No match</div>}
      </div>
    </div>
  );
}

// ── nickname sheet (NicknameSheet) ───────────────────────────────────────

function NicknameSheet({ s, sessions, close, onSet }: {
  s: AgentSession; sessions: AgentSession[]; close: () => void; onSet: (nick: string, reclaim: boolean) => void;
}) {
  const [v, setV] = useState(s.nickname ?? '');
  const verdict = checkNickname(s.id, v, sessions);
  const save = async () => {
    const nick = normalizeNickname(v) ?? '';
    if (verdict.kind === 'refused') return;
    if (verdict.kind === 'reclaim') {
      const r = await showAlert('Reuse this nickname?', verdict.question, [{ label: 'Reuse', value: 'ok', default: true }, { label: 'Cancel', value: 'cancel' }]);
      if (r !== 'ok') return;
      onSet(nick, true);
    } else onSet(nick, false);
    close();
  };
  return (
    <div className="room-nick">
      <div className="room-nick-title">Nickname</div>
      <div className="secondary">Other sessions reach this one as @name.</div>
      <TextField autoFocus value={v} onChange={e => setV(e.target.value)} placeholder="nickname"
                 onKeyDown={e => { if (e.key === 'Enter') save(); }} />
      {verdict.kind === 'refused' && <div className="room-nick-why">{verdict.why}</div>}
      <div className="room-nick-buttons">
        <Button onClick={close}>Cancel</Button>
        <Button variant="prominent" onClick={save} disabled={verdict.kind === 'refused'}>Set</Button>
      </div>
    </div>
  );
}

// ── timeline window (RoomTimelineWindow, reduced) ────────────────────────

function RoomTimeline({ roomID }: { roomID: string }) {
  const { host } = useHostCtx();
  const st = useRemote(host, s => s) as RemoteState | undefined;
  const m = useMemo(() => buildListModel(st), [st]);
  const room = st?.agentRooms?.find(r => r.id === roomID);
  if (!room) return null;
  const sessions = st?.agentSessions ?? [];
  const lanes = [...membersOf(room, sessions), ...sessions.filter(s => isSwitchboard(s) && s.roomID === roomID && !isDeleted(s))];
  const t0 = Math.min(...lanes.map(s => ts(s.createdAt)).filter(Boolean), Date.now());
  const t1 = Date.now();
  const x = (t: number) => `${Math.max(0, Math.min(100, ((t - t0) / Math.max(1, t1 - t0)) * 100))}%`;
  return (
    <div className="room-timeline">
      {lanes.map(s => {
        const start = ts(s.createdAt), end = ts(s.endedAt) || ts(s.lastSeenAt) || t1;
        const b = bucket(s, m);
        return (
          <div key={s.id} className="room-timeline-lane">
            <AgentAvatar tool={s.tool} size={16} status={dotFor(b)} />
            <span className="room-timeline-name">{s.title}{s.nickname ? ` @${s.nickname}` : ''}</span>
            <span className="room-timeline-track">
              <span style={{ left: x(start), width: `calc(${x(end)} - ${x(start)})`, background: bucketTint[b] }} />
            </span>
          </div>
        );
      })}
    </div>
  );
}
