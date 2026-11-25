// The Grid stage — Terminal/GridStageView.swift: the host-owned grid layout
// (/state.gridLayout, last-writer-wins via POST /grid-layout) as live terminal
// tiles. Rows×cols by GridLayoutStore.dimensions, 6pt gaps, 24pt cell header
// (status dot · workspace · label; hover: open in workspace / remove), an
// Off/Suspended placeholder with Start, drag a header onto another to swap,
// double-click a header (or ⌘↩) to zoom one cell, Esc to unzoom.

import React, { useEffect, useMemo, useState } from 'react';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { SF } from '../../ui/icons';
import { Button, useMenu } from '../../ui/kit';
import { isMod } from '../../platform';
import { seg } from '../../core/remote/host';
import { TermView } from './TermView';
import { resolveStyle } from './termStyle';
import { AgentStatusDot } from '../sidebar/AgentAvatar';
import './terminal.css';

interface Cell { profileID: string; windowIndex: number; label: string }
const cellID = (c: Cell) => `${c.profileID}:${c.windowIndex}`;

export function gridDimensions(n: number): [rows: number, cols: number] {
  if (n <= 1) return [1, 1];
  if (n === 2) return [1, 2];
  if (n <= 4) return [2, 2];
  if (n <= 6) return [2, 3];
  if (n <= 9) return [3, 3];
  if (n <= 12) return [3, 4];
  if (n <= 16) return [4, 4];
  if (n <= 20) return [4, 5];
  return [5, 5];
}

export function GridStage() {
  const { host, select } = useHostCtx();
  const grid = useRemote(host, s => s.gridLayout);
  const workspaces = useRemote(host, s => s.workspaces) ?? [];
  const vms = useRemote(host, s => s.vms) ?? [];
  const cells: Cell[] = (grid?.cells ?? []) as Cell[];
  const [zoomed, setZoomed] = useState<string | null>(null);
  const [focused, setFocused] = useState<string | null>(null);
  const [dropOn, setDropOn] = useState<string | null>(null);
  const menu = useMenu();

  const push = (next: Cell[], autoFill?: boolean) =>
    host.send('POST', '/grid-layout', { cells: next.map(c => ({ profileID: c.profileID, windowIndex: c.windowIndex, label: c.label })), autoFill: autoFill ?? grid?.autoFill ?? true });
  const remove = (id: string) => { if (zoomed === id) setZoomed(null); push(cells.filter(c => cellID(c) !== id)); };
  const swap = (a: string, b: string) => {
    const i = cells.findIndex(c => cellID(c) === a), j = cells.findIndex(c => cellID(c) === b);
    if (i < 0 || j < 0 || i === j) return;
    const next = [...cells]; [next[i], next[j]] = [next[j], next[i]];
    push(next, false);   // a rearrangement by hand: auto-fill stands down
  };
  const jump = (c: Cell) => select({ kind: 'workspace', workspaceID: c.profileID, windowIndex: c.windowIndex });

  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && zoomed) { e.preventDefault(); setZoomed(null); }
      else if (e.key === 'Enter' && isMod(e) && focused) { e.preventDefault(); setZoomed(z => z ? null : focused); }
    };
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  }, [zoomed, focused]);

  if (!cells.length) {
    return (
      <div className="grid-stage grid-empty">
        <SF name="square.grid.2x2" size={36} weight={300} color="rgba(255,255,255,0.35)" />
        <div className="grid-empty-title">Monitor several terminals at once</div>
        <div className="grid-empty-sub">Drag terminals from the sidebar into this view to add them to the grid.</div>
      </div>
    );
  }
  const [rows, cols] = gridDimensions(cells.length);
  return (
    <div className="grid-stage" style={zoomed ? { padding: 4 } : {
      display: 'grid', gap: 6, padding: 6,
      gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`, gridTemplateRows: `repeat(${rows}, minmax(0, 1fr))`,
    }}>
      {cells.map(c => {
        const id = cellID(c);
        if (zoomed && zoomed !== id) return null;
        const ws = workspaces.find(w => w.id === c.profileID);
        const vm = vms.find(v => v.id === c.profileID);
        const state = (ws?.state as string) ?? (vm ? 'running' : 'off');
        const running = state === 'running' || state === 'booting';
        const tab = vm?.tabs?.find(t => t.index === c.windowIndex) as any;
        const status = tab?.agentStatus as ('working' | 'done' | 'needsInput' | undefined);
        const accent = (ws?.accentHex as string) ?? '#888888';
        return (
          <div key={id} className={'grid-cell' + (focused === id ? ' focused' : '')} style={zoomed ? { height: '100%' } : undefined}
               onMouseDown={() => setFocused(id)}>
            <div className={'grid-cell-header' + (dropOn === id ? ' drop' : '')} draggable
                 onDragStart={e => { e.dataTransfer.setData('application/x-bromure-grid-cell', id); e.dataTransfer.effectAllowed = 'move'; }}
                 onDragOver={e => { if (e.dataTransfer.types.includes('application/x-bromure-grid-cell')) { e.preventDefault(); setDropOn(id); } }}
                 onDragLeave={() => setDropOn(d => d === id ? null : d)}
                 onDrop={e => { setDropOn(null); const from = e.dataTransfer.getData('application/x-bromure-grid-cell'); if (from && from !== id) swap(from, id); }}
                 onDoubleClick={() => setZoomed(z => z ? null : id)}
                 onContextMenu={e => { e.preventDefault(); menu(e, [
                   { label: 'Open in Workspace', action: () => jump(c) }, { separator: true },
                   { label: 'Remove from Grid', action: () => remove(id) }]); }}>
              <span className="grid-handle" title="Drag to rearrange"><SF name="line.3.horizontal" size={9} weight={600} /></span>
              {status ? <AgentStatusDot status={status} /> : <span className="grid-dot" />}
              <span className="grid-ws" style={{ color: accent }}>{ws?.name ?? ''}</span>
              <span className="grid-label">{tab?.title ?? c.label}</span>
              <span style={{ flex: 1 }} />
              <button className="grid-hbtn" title="Open in workspace" onClick={() => jump(c)}><SF name="arrow.up.forward.app" size={11} /></button>
              <button className="grid-hbtn" title="Remove from grid — the terminal keeps running" onClick={() => remove(id)}><SF name="xmark.circle.fill" size={11} /></button>
            </div>
            <div className="grid-cell-body">
              {running && vm ? (
                <TermView host={host} target={{ vmID: c.profileID, windowIndex: c.windowIndex }} style={resolveStyle(ws)} />
              ) : (
                <div className="grid-placeholder">
                  <SF name="moon.zzz" size={20} color="var(--label-secondary)" />
                  <span>{state === 'suspended' ? 'Suspended' : 'Off'}</span>
                  <Button size="small" onClick={() => host.send('POST', '/vms', { profile: c.profileID, detach: true })}>Start</Button>
                </div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
export default GridStage;
