// Hosts the new-session screen over the stage (RemoteHostWindow.showNewSession:
// it takes the stage until a session is started, picked, or another surface
// takes the stage). Opened by `bromure:open {what:'new-session', room?}`
// (⌘N, the sidebar's New session button, the palette).

import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { useHostCtx } from '../../app/hostContext';
import { useOpenListener } from '../palette/events';
import { buildListModel, initialSession } from '../sidebar/model';
import { NewSessionView } from './NewSessionView';

/** Surfaces that take the stage away from the new-session screen. */
const STAGE_TAKERS = new Set(['task-board', 'automation-board', 'machines', 'machine']);

export function NewSessionHost() {
  const { host, selection, select } = useHostCtx();
  const [open, setOpen] = useState<{ room?: string; key: number } | null>(null);
  const [slot, setSlot] = useState<HTMLElement | null>(null);
  const selAtOpen = useRef(selection);

  useOpenListener(d => {
    if (d.what === 'new-session') {
      selAtOpen.current = selection;
      setOpen({ room: typeof d.room === 'string' ? d.room : undefined, key: Date.now() });
    } else if (STAGE_TAKERS.has(d.what)) setOpen(null);
  });
  useEffect(() => {
    (window as any).__bromure = { ...(window as any).__bromure, newSession: () => { selAtOpen.current = selection; setOpen({ key: Date.now() }); } };
  });
  // Another session / room / machine picked in the sidebar: the stage is theirs.
  useEffect(() => { if (open && selection !== selAtOpen.current) setOpen(null); }, [selection]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (open) setSlot(document.querySelector<HTMLElement>('.hw-stage')); }, [open]);

  if (!open || !slot) return null;

  const onCancel = () => {
    const st = host.state;
    const s = st && initialSession(st.agentSessions ?? [], buildListModel(st));
    setOpen(null);
    if (s) select({ kind: 'session', sessionID: s.id });
  };
  const onStarted = (id: string) => {
    const room = open.room;
    const finish = () => {
      setOpen(null);
      if (room && host.state?.agentRooms?.some(r => r.id === room)) select({ kind: 'room', roomID: room });
      else select({ kind: 'session', sessionID: id });
    };
    // The mirror gets it with the next push/poll; select it then.
    if (host.state?.agentSessions?.some(s => s.id === id)) { finish(); return; }
    let off = () => {};
    const timer = setTimeout(() => { off(); finish(); }, 10000);
    off = host.onState(() => {
      if (host.state?.agentSessions?.some(s => s.id === id)) { clearTimeout(timer); off(); finish(); }
    });
  };

  return createPortal(
    <div className="ns-host">
      <NewSessionView key={open.key} room={open.room} onCancel={onCancel} onStarted={onStarted} />
    </div>, slot);
}
