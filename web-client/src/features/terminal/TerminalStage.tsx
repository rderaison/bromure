// A workspace's terminal on stage — RemoteHostWindow.mountTerminal over the
// web: one xterm.js surface attached to the workspace's tmux window, the
// boot dive screen while the VM boots and its roster hasn't landed, and the
// machine's tab strip (its tmux windows: select, new, close).
//
//   <TerminalStage workspaceID windowIndex? sessionID? showTabs? />
//
// windowIndex: the tmux window to show (default: the roster's active tab).
// sessionID: a session's own terminal — its window, no tab strip.

import React, { useEffect, useMemo, useState } from 'react';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { isMac, modKey } from '../../platform';
import { SF } from '../../ui/icons';
import { Button } from '../../ui/kit';
import type { VMTab } from '../../core/remote/types';
import { AgentAvatar } from '../sidebar/AgentAvatar';
import { TermView } from './TermView';
import { BootCue } from './BootCue';
import { resolveStyle } from './termStyle';
import { useWorkspaceTabs, tabVerbs, tabLabel, orderedTabs, dropTabLocally } from './tabs';
import type { AttachPhase } from './attach';
import './terminal.css';

export interface TerminalStageProps {
  workspaceID: string;
  windowIndex?: number;
  sessionID?: string;
  /** The machine's tab strip (default: on unless a session's terminal). */
  showTabs?: boolean;
  /** Told when the shown window changes (a tab click, a fallback). */
  onWindowChange?: (index: number) => void;
}

export function TerminalStage({ workspaceID, windowIndex, sessionID, showTabs, onWindowChange }: TerminalStageProps) {
  const { host } = useHostCtx();
  const ws = useRemote(host, s => s.workspaces?.find(w => w.id === workspaceID));
  const vm = useRemote(host, s => s.vms?.find(v => v.id === workspaceID));
  const session = useRemote(host, s => sessionID ? s.agentSessions?.find(a => a.id === sessionID) : undefined);
  const tabs = useWorkspaceTabs(host, workspaceID) ?? [];
  const style = useMemo(() => resolveStyle(ws), [ws?.fontFamily, ws?.fontSize, ws?.backgroundHex, ws?.foregroundHex]);   // eslint-disable-line react-hooks/exhaustive-deps

  const wanted = sessionID ? session?.windowIndex : windowIndex;
  const [picked, setPicked] = useState<number | undefined>(wanted);
  useEffect(() => { setPicked(wanted); }, [wanted, workspaceID]);

  const active = tabs.find(t => t.active) ?? tabs[0];
  // Never attach to a window the roster doesn't list (a stale reference
  // falls back to the active tab); an empty roster = still booting, and
  // window 0 is about to exist.
  let win = picked ?? active?.index ?? 0;
  if (tabs.length && !tabs.some(t => t.index === win)) win = active?.index ?? tabs[0].index;
  useEffect(() => { onWindowChange?.(win); }, [win]);   // eslint-disable-line react-hooks/exhaustive-deps

  const state = (ws?.state as string | undefined) ?? (vm ? 'running' : 'off');
  const running = state === 'running' || state === 'booting';
  const booting = running && tabs.length === 0;

  const [phase, setPhase] = useState<AttachPhase>('connecting');
  const [revive, setRevive] = useState(0);
  // A cleanly exited surface whose window is (back) in the roster — a guest
  // reboot rebuilt tmux on the same index: re-arm it.
  useEffect(() => {
    if (phase === 'exited' && tabs.some(t => t.index === win)) {
      const t = setTimeout(() => setRevive(r => r + 1), 2000);
      return () => clearTimeout(t);
    }
  }, [phase, tabs, win]);

  const select = (t: VMTab) => {
    tabVerbs.select(host, workspaceID, t.index);
    setPicked(t.index);
  };
  const [awaitingNew, setAwaitingNew] = useState<Set<number> | null>(null);
  const newTab = () => {
    setAwaitingNew(new Set(tabs.map(t => t.index)));
    tabVerbs.create(host, workspaceID);
  };
  // ⌘T's window becomes the shown one once the roster reports it
  // (showNewestTab).
  useEffect(() => {
    if (!awaitingNew) return;
    const fresh = tabs.find(t => !awaitingNew.has(t.index));
    if (fresh) { setPicked(fresh.index); setAwaitingNew(null); return; }
    const t = setTimeout(() => setAwaitingNew(null), 15000);
    return () => clearTimeout(t);
  }, [tabs, awaitingNew]);
  const closeTab = (index: number) => tabVerbs.close(host, workspaceID, index);

  // ⌘T / ⌘W / ⌘1–9 while this stage is up (the window's own shortcuts).
  // The Mac fat client lists a machine's tabs in the sidebar only; the strip is opt-in.
  const withTabs = showTabs ?? false;
  useEffect(() => {
    if (!withTabs || !running) return;
    const on = (e: KeyboardEvent) => {
      const mod = isMac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
      if (!mod || e.altKey || e.shiftKey) return;
      if (e.key === 't') { e.preventDefault(); e.stopPropagation(); newTab(); }
      else if (e.key === 'w') { e.preventDefault(); e.stopPropagation(); closeTab(win); }
      else if (/^[1-9]$/.test(e.key)) {
        const t = orderedTabs(tabs)[+e.key - 1];
        if (t) { e.preventDefault(); e.stopPropagation(); select(t); }
      }
    };
    window.addEventListener('keydown', on, true);
    return () => window.removeEventListener('keydown', on, true);
  });

  if (!ws && !vm) {
    return <div className="term-stage term-empty"><span className="secondary">This machine is no longer on the server.</span></div>;
  }

  if (!running) {
    return (
      <div className="term-stage term-empty">
        <SF name="desktopcomputer" size={34} weight={300} style={{ opacity: 0.35 }} />
        <div className="term-empty-title">{ws?.name ?? 'Machine'} is {state === 'suspended' ? 'suspended' : 'off'}</div>
        <Button variant="prominent" onClick={() => host.send('POST', '/vms', { profile: workspaceID, detach: true })}>
          {state === 'suspended' ? 'Resume' : 'Start'}
        </Button>
      </div>
    );
  }

  return (
    <div className="term-stage">
      {withTabs && tabs.length > 0 && (
        <MachineTabStrip tabs={tabs} shown={win} onSelect={select} onClose={closeTab} onNew={newTab} />
      )}
      <div className="term-body" style={{ background: style.background }}>
        <TermView
          key={`${workspaceID}#${win}`}
          host={host}
          target={{ vmID: workspaceID, windowIndex: win }}
          style={style}
          autoFocus
          reviveTick={revive}
          onPhase={setPhase}
          onRelinked={() => host.refreshSoon()}
          onCleanExit={() => {
            // ctrl-D / exit: the tab goes now, not on the next poll.
            dropTabLocally(workspaceID, win);
            host.refreshSoon();
          }}
        />
        {booting && <BootCue name={ws?.name ?? ''} accentHex={ws?.accentHex} />}
      </div>
    </div>
  );
}
export default TerminalStage;

const DOT: Record<string, 'working' | 'needsInput' | 'done'> = { working: 'working', needsInput: 'needsInput', done: 'done' };

/** The machine's tmux windows, in the room stage's tab style (RoomTab): the
 *  shown one raised with an accent underline; hover shows its close button;
 *  middle-click closes; "+" opens a new shell window. */
export function MachineTabStrip({ tabs, shown, onSelect, onClose, onNew, accent }: {
  tabs: VMTab[]; shown: number; onSelect: (t: VMTab) => void; onClose: (index: number) => void; onNew: () => void; accent?: string;
}) {
  const ordered = orderedTabs(tabs);
  return (
    <div className="term-tabs" role="tablist" style={accent ? { ['--tab-accent' as any]: accent } : undefined}>
      {tabs.map(t => {
        const sel = t.index === shown;
        const tool = (t.tool as string | undefined) || undefined;
        const n = ordered.indexOf(t);
        return (
          <div key={t.index} className={'term-tab' + (sel ? ' selected' : '')} role="tab" aria-selected={sel}
               title={tabLabel(t) + (n >= 0 && n < 9 ? `  (${modKey}${n + 1})` : '')}
               onMouseDown={e => { if (e.button === 1) { e.preventDefault(); onClose(t.index); } }}
               onClick={() => onSelect(t)}>
            {tool ? <AgentAvatar tool={tool} size={16} status={DOT[t.agentStatus as string] ?? null} />
                  : <span className="term-tab-glyph"><SF name="terminal" size={12} weight={500} /></span>}
            <span className="term-tab-label">{tabLabel(t)}</span>
            <button className="term-tab-close" title={`Close (${modKey}W)`}
                    onClick={e => { e.stopPropagation(); onClose(t.index); }}>
              <SF name="xmark" size={8} weight={700} />
            </button>
          </div>
        );
      })}
      <button className="term-tab-new" title={`New Terminal (${modKey}T)`} onClick={onNew}>
        <SF name="plus" size={12} weight={600} />
      </button>
    </div>
  );
}
