// BeautifiedSessionView(model:parts:placeholder:delegations:) for surfaces
// other than the session stage — a room's cells, its Switchboard dock, its
// one composer. Contract (RoomStage relies on it):
//   <SessionChat sessionID parts? placeholder? delegations? />
//   parts: 'all' (default) | 'transcript' (no composer) | 'composer' (only
//   the composer, aimed at this session; placeholder is its hint).
// The chat itself lives in src/features/stage/chat.

import React, { useMemo } from 'react';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { buildListModel } from '../sidebar/model';
import { ChatView } from '../stage/chat/ChatView';
import { chatModeFor, restStatusFor, accentFor } from '../stage/Stage';

export interface SessionChatProps {
  sessionID: string;
  parts?: 'all' | 'transcript' | 'composer';
  placeholder?: string;
  delegations?: boolean;
}

export function SessionChat({ sessionID, parts = 'all', placeholder }: SessionChatProps) {
  const { host } = useHostCtx();
  const st = useRemote(host, x => x);
  const m = useMemo(() => buildListModel(st), [st]);
  const s = st?.agentSessions?.find(x => x.id === sessionID);
  if (!s) return <div style={{ flex: 1 }} />;
  const mode = chatModeFor(s, m);
  return <ChatView key={s.id + ':' + mode} session={s} accent={accentFor(st, s)} mode={mode} parts={parts}
                   placeholder={placeholder} restStatus={mode === 'rest' ? restStatusFor(s, m) : null} />;
}
export default SessionChat;
