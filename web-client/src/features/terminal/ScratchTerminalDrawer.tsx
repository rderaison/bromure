// The chat's scratch terminal (/term) — ScratchTerminalDrawer.swift.
// A shell of its own in the session's folder on the same machine: its own
// guest tmux session ("scratch-<key>"), never a tab, never a session.
// The chat (owned by the chat feature) mounts this above its composer:
//
//   <ScratchTerminalDrawer workspaceID sessionKey cwd maxHeight onHide onClose accent? />
//
// Hiding (chevron, ⌃`) unmounts the surface but the guest shell keeps
// running — shown again, it re-attaches to the same tmux session. ✕ ends the
// shell (kills its tmux session); `exit` in it ends it too (→ onClose).
// The height is the user's, remembered.

import React, { useMemo, useRef, useState } from 'react';
import { useHostCtx, usePersisted } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { SF } from '../../ui/icons';
import { TermView } from './TermView';
import { resolveStyle } from './termStyle';
import { scratchSessionName } from './attach';
import './terminal.css';

const MIN_HEIGHT = 140;
const HOME = '/home/ubuntu';
/** prettyGuestPath(SessionHome.guestPath(cwd)): "~/proj" for the guest home. */
function prettyFolder(cwd: string) {
  const t = (cwd ?? '').trim();
  const abs = !t || t === '~' ? HOME : t.startsWith('~/') ? HOME + t.slice(1) : t.startsWith('/') ? t : HOME + '/' + t;
  return abs === HOME ? '~' : abs.startsWith(HOME + '/') ? '~' + abs.slice(HOME.length) : abs;
}

export function ScratchTerminalDrawer({ workspaceID, sessionKey, cwd, maxHeight, onHide, onClose, accent }: {
  workspaceID: string;
  /** One scratch shell per key (the session's id). */
  sessionKey: string;
  /** Guest folder ("~" forms allowed). */
  cwd: string;
  maxHeight: number;
  onHide: () => void;
  /** The shell ended (✕, or `exit` in it). */
  onClose: () => void;
  accent?: string;
}) {
  const { host } = useHostCtx();
  const ws = useRemote(host, s => s.workspaces?.find(w => w.id === workspaceID));
  const style = useMemo(() => resolveStyle(ws), [ws?.fontFamily, ws?.fontSize, ws?.backgroundHex, ws?.foregroundHex]);   // eslint-disable-line react-hooks/exhaustive-deps
  const [stored, setStored] = usePersisted<number>('chat.scratchTerminalHeight', 280);
  const height = Math.min(Math.max(stored, MIN_HEIGHT), maxHeight);
  const [drag, setDrag] = useState(false);
  const folder = prettyFolder(cwd || '~');
  const session = scratchSessionName(sessionKey);
  const ended = useRef(false);

  const startDrag = (e: React.MouseEvent) => {
    e.preventDefault();
    const y0 = e.clientY, h0 = height;
    setDrag(true);
    const mm = (ev: MouseEvent) => setStored(Math.min(Math.max(h0 - (ev.clientY - y0), MIN_HEIGHT), maxHeight));
    const mu = () => { setDrag(false); window.removeEventListener('mousemove', mm); window.removeEventListener('mouseup', mu); };
    window.addEventListener('mousemove', mm); window.addEventListener('mouseup', mu);
  };

  const close = () => {
    if (ended.current) return;
    ended.current = true;
    // ✕ ends the shell: kill its tmux session in the guest.
    host.guestExec(workspaceID, `tmux kill-session -t '${session}' 2>/dev/null; true`, 10).catch(() => {});
    onClose();
  };

  return (
    <div className="scratch" style={accent ? { ['--scratch-accent' as any]: accent } : undefined}>
      <div className={'scratch-grab' + (drag ? ' dragging' : '')} onMouseDown={startDrag} title="Drag to resize">
        <span />
      </div>
      <div className="scratch-header">
        <span className="scratch-icon"><SF name="terminal.fill" size={10.5} weight={600} color="#fff" /></span>
        <span className="scratch-title">Terminal</span>
        <span className="scratch-folder" title={folder}>
          <SF name="folder" size={9.5} />
          <span className="mono">{folder}</span>
        </span>
        <span style={{ flex: 1 }} />
        <span className="scratch-keycap mono">⌃`</span>
        <button className="scratch-btn" title="Hide — the shell keeps running (⌃`)" onClick={onHide}>
          <SF name="chevron.down" size={10.5} weight={700} />
        </button>
        <button className="scratch-btn" title="Close the terminal (ends the shell)" onClick={close}>
          <SF name="xmark" size={10.5} weight={700} />
        </button>
      </div>
      <div className="scratch-content" style={{ height }}>
        <TermView host={host} style={style} autoFocus
                  target={{ vmID: workspaceID, windowIndex: -1, scratch: { session, cwd: cwd || '~' } }}
                  onCleanExit={() => { if (!ended.current) { ended.current = true; onClose(); } }} />
      </div>
    </div>
  );
}
