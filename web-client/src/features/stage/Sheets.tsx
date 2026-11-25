// The header's NewWorktreeSheet ("New Branch…")
// from SessionStageViews.swift. The new-branch sheet is reduced: no
// git-state probe / base-branch picker (see NOT_PORTED.md).

import React, { useState } from 'react';
import { Button, TextField, Checkbox, PopUp } from '../../ui/kit';
import { SF } from '../../ui/icons';
import { useHostCtx } from '../../app/hostContext';
import type { AgentSession } from '../../core/remote/types';
import { seg } from '../../core/remote/host';
import { AGENTS } from '../newsession/agents';
import { prettyGuestPath } from './sessionState';

export function NewBranchSheet({ s, close }: { s: AgentSession; close: () => void }) {
  const { host, select } = useHostCtx();
  const [message, setMessage] = useState('');
  const [name, setName] = useState('');
  const [tool, setTool] = useState<string>(s.tool);
  const [initGit, setInitGit] = useState(false);
  const [busy, setBusy] = useState(false);
  const folder = prettyGuestPath(s.cwd ?? '~');
  const start = async () => {
    setBusy(true);
    try {
      const r = await host.request<any>('POST', `/agent-sessions/${seg(s.id)}/worktree`,
        { name: name.trim(), tool, initGit, ...(message.trim() ? { message: message.trim() } : {}) });
      host.refreshSoon();
      if (r?.id) select({ kind: 'session', sessionID: r.id });
      close();
    } catch (e) { console.warn('worktree', e); setBusy(false); }
  };
  return (
    <div className="stage-sheet" style={{ width: 480 }}>
      <div className="chat-hstack" style={{ gap: 12, alignItems: 'flex-start' }}>
        <span className="stage-sheet-badge"><SF name="arrow.triangle.branch" size={16} weight={600} color="var(--accent)" /></span>
        <div>
          <div className="stage-sheet-title">New branch</div>
          <div className="stage-sheet-sub">A session of its own, on a copy of {folder} with its own git branch. Your work in “{s.title}” isn't touched; merge it back when it's ready.</div>
        </div>
      </div>
      <div className="chat-vstack" style={{ gap: 6 }}>
        <span className="stage-sheet-label">What should it do?</span>
        <textarea className="field stage-sheet-area" value={message} placeholder="e.g. Try moving the session cache to SQLite"
                  onChange={e => setMessage(e.target.value)} autoFocus rows={3} />
      </div>
      <div className="chat-hstack" style={{ gap: 12 }}>
        <div className="chat-vstack" style={{ gap: 6, flex: 1 }}>
          <span className="stage-sheet-label">Name</span>
          <TextField value={name} placeholder={message.trim() ? 'From the message' : 'e.g. Session cache in SQLite'} onChange={e => setName(e.target.value)} />
        </div>
        <div className="chat-vstack" style={{ gap: 6 }}>
          <span className="stage-sheet-label">Agent</span>
          <PopUp bordered value={tool} options={AGENTS.map(a => ({ value: a.id as string, label: a.displayName }))} onChange={setTool} />
        </div>
      </div>
      <Checkbox checked={initGit} onChange={setInitGit}>If it isn't a git repository, make it one</Checkbox>
      <div className="chat-hstack" style={{ gap: 8 }}>
        <span style={{ flex: 1 }} />
        <Button onClick={close}>Cancel</Button>
        <Button variant="prominent" disabled={busy || (!message.trim() && !name.trim())} onClick={start}>Start</Button>
      </div>
    </div>
  );
}
