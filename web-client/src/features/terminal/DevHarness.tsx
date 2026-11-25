// DEV ONLY — mounts a terminal or a room over the stage without going
// through the stage router, for testing / pixel shots:
//   #/host/demo?term=<workspaceID>[&win=<n>]     a workspace's terminal
//   #/host/demo?term=live                        the first VM workspace
//   #/host/demo?room=<roomID|first>[&zoom=<sessionID|first>]
//   #/host/demo?scratch=<workspaceID>             the scratch drawer
// Also exposes window.__bromure.{host, dumpState()} for scripted shots.

import React, { useEffect, useState } from 'react';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { TerminalStage } from './TerminalStage';
import { RoomStage } from './RoomStage';
import { ScratchTerminalDrawer } from './ScratchTerminalDrawer';
import { liveTerminals } from './TermView';
import { BootCue } from './BootCue';

function useHashParams() {
  const [h, setH] = useState(location.hash);
  useEffect(() => {
    const on = () => setH(location.hash);
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return new URLSearchParams(h.split('?')[1] ?? '');
}

export function TerminalDevHarness() {
  const { host } = useHostCtx();
  const p = useHashParams();
  const vms = useRemote(host, s => s.vms);
  const rooms = useRemote(host, s => s.agentRooms);
  const sessions = useRemote(host, s => s.agentSessions);
  useEffect(() => {
    (window as any).__bromure = Object.assign((window as any).__bromure ?? {}, {
      host,
      terms: liveTerminals,
      /** Type into the first live terminal. */
      type: (text: string) => { for (const t of liveTerminals.values()) { t.session.input(text); break; } },
      termInfo: () => { for (const t of liveTerminals.values()) console.error('TERM ' + JSON.stringify({ cols: t.term.cols, rows: t.term.rows, phase: t.session.phase, renderer: (t.term as any)._core?._renderService?._renderer?.value?.constructor?.name })); },
      dumpState: (keys?: string[]) => {
        const s: any = host.state ?? {};
        const out = keys ? Object.fromEntries(keys.map(k => [k, s[k]])) : s;
        console.error('STATE ' + JSON.stringify(out));
      },
    });
  }, [host]);
  if (!import.meta.env?.DEV && !new URLSearchParams(location.search).has('dev')) return null;
  let term = p.get('term');
  const room = p.get('room');
  const scratch = p.get('scratch');
  if (p.has('bootcue')) return <div style={{ position: 'absolute', inset: 0, zIndex: 50 }}><BootCue name="Live machine" accentHex="#3B82F6" statusText={p.get('bootcue') || null} /></div>;
  if (!term && !room && !scratch) return null;
  let body: React.ReactNode = null;
  if (term) {
    if (term === 'live') term = vms?.find(v => (v.tabs?.length ?? 0) > 0)?.id ?? vms?.[0]?.id ?? null;
    if (term) body = <TerminalStage workspaceID={term} windowIndex={p.has('win') ? +p.get('win')! : undefined} />;
  } else if (room) {
    const id = room === 'first' ? rooms?.[0]?.id : room;
    let zoom = p.get('zoom') ?? undefined;
    if (zoom === 'first') zoom = sessions?.find(s => s.roomID === id && s.role !== 'switchboard' && /Apple Pay/.test(s.title))?.id ?? sessions?.find(s => s.roomID === id && s.role !== 'switchboard')?.id;
    if (id) body = <RoomStage roomID={id} zoomedSessionID={zoom} />;
  } else if (scratch) {
    const ws = scratch === 'live' ? vms?.find(v => (v.tabs?.length ?? 0) > 0)?.id : scratch;
    if (ws) body = (
      <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
        <ScratchTerminalDrawer workspaceID={ws} sessionKey="dev-harness" cwd="~" maxHeight={420}
                               onHide={() => {}} onClose={() => {}} />
      </div>
    );
  }
  if (!body) return null;
  return <div style={{ position: 'absolute', inset: 0, zIndex: 50, display: 'flex', flexDirection: 'column', background: 'var(--ac-canvas)' }}>{body}</div>;
}
