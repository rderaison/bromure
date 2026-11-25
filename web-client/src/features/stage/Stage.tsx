// The stage (RemoteHostWindow's presentation): a session — its header over
// the chat (or its terminal, View › Terminal) —, a room, a machine's
// dashboard / terminal, or the placeholder.

import React, { useEffect, useMemo } from 'react';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import type { AgentSession, RemoteState } from '../../core/remote/types';
import { TerminalStage } from '../terminal/TerminalStage';
import { RoomStage } from '../terminal/RoomStage';
import { MachineStage } from '../machines/MachineStage';
import { StagePlaceholder } from '../sidebar/StagePlaceholder';
import { TaskBoardView, AutomationHubView } from '../boards';
import { buildListModel, bucket, liveTab, hasEnded, isLaunching, statusLine, type ListModel } from '../sidebar/model';
import { SessionHeader } from './SessionHeader';
import { ChatView } from './chat/ChatView';
import './stage.css';

export type ChatMode = 'live' | 'fixture' | 'rest';

/** Which chat a session gets: its live tab, a demo fixture's, or the read-back. */
export function chatModeFor(s: AgentSession, m: ListModel): ChatMode {
  if (!hasEnded(s) && !isLaunching(s) && liveTab(s, m)) return 'live';
  if (typeof s.demoBucket === 'number' && (s.demoBucket as number) <= 2 && !s.endedAt) return 'fixture';
  return 'rest';
}

/** The rest footer's line for a session on its way back (else null: "Paused"). */
export function restStatusFor(s: AgentSession, m: ListModel): string | null {
  const b = bucket(s, m);
  return isLaunching(s) || b === 'needsYou' || b === 'working' || b === 'idle' ? statusLine(s, m) : null;
}

export function accentFor(st: RemoteState | null | undefined, s: AgentSession): string {
  return st?.workspaces?.find(w => w.id === s.profileID)?.accentHex ?? '#3B82F6';
}

function SessionStage({ sessionID }: { sessionID: string }) {
  const { host, viewMode } = useHostCtx();
  const st = useRemote(host, x => x);
  const m = useMemo(() => buildListModel(st), [st]);
  const sessions = st?.agentSessions ?? [];
  const s = sessions.find(x => x.id === sessionID);
  if (!s) return <StagePlaceholder />;
  const mode = chatModeFor(s, m);
  const terminal = viewMode === 'terminal' && mode === 'live' && s.windowIndex != null;
  return (
    <div className="stage-session">
      <SessionHeader s={s} m={m} sessions={sessions} workspaces={st?.workspaces ?? []} />
      <div className="stage-body">
        {terminal
          ? <TerminalStage workspaceID={s.profileID} windowIndex={s.windowIndex ?? undefined} sessionID={s.id} />
          : <ChatView key={s.id + ':' + mode} session={s} accent={accentFor(st, s)} mode={mode}
                      restStatus={mode === 'rest' ? restStatusFor(s, m) : null} />}
      </div>
    </div>
  );
}

export function Stage() {
  const { selection, select, host, setViewMode } = useHostCtx();
  // Dev/screenshot hook: __bromure.showSession('<title or id>'[, 'terminal']).
  useEffect(() => {
    const w = window as any;
    w.__bromure = { ...w.__bromure, showSession: (q: string, view?: 'chat' | 'terminal') => {
      const s = host.state?.agentSessions?.find(x => x.id === q || x.title === q || x.nickname === q);
      if (!s) return false;
      setViewMode(view ?? 'chat');
      select({ kind: 'session', sessionID: s.id });
      return true;
    } };
  });
  switch (selection.kind) {
    case 'session': return <SessionStage key={selection.sessionID} sessionID={selection.sessionID} />;
    case 'room': return <RoomStage roomID={selection.roomID} zoomedSessionID={selection.zoomedSessionID} />;
    case 'workspace': case 'machines': case 'cluster': case 'registry': case 'docker': case 'grid':
      return <MachineStage selection={selection} />;
    // The boards live on the stage, as in the Mac window (their sidebar row selected).
    case 'task-board': return <TaskBoardView host={host} newTaskToken={selection.newTaskToken} />;
    case 'automation-board': return <AutomationHubView key={selection.tab ?? ''} host={host} initialTab={selection.tab as any} />;
    default: return <StagePlaceholder />;
  }
}
