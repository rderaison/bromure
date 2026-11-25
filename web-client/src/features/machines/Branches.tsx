// BranchesWindow.swift: every git worktree Bromure made on a machine
// (~/.bromure/worktrees), with what it holds and whose it is — a branch
// whose session is gone, archived or merged can be picked up in a session
// again, reviewed, or thrown away. Listed live over guestExec; opening and
// discarding go to the server.

import React, { useCallback, useEffect, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import type { AgentSession } from '../../core/remote/types';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { Button, Checkbox, Spinner, useTooltip } from '../../ui/kit';
import { isMod } from '../../platform';
import { Confirm, Unavailable, SF } from './parts';
import { parseWorktrees, worktreeIsEmpty, worktreeListCommand, type WorktreeEntry } from './reviewData';
import { prettyGuestPath, relativeShort } from './util';
import { openSessionReviewWindow } from './Review';
import type { WindowsAPI } from './index';
import './machines.css';

type Owner = { kind: 'live' | 'archived'; s: AgentSession } | { kind: 'none' };

function ownerOf(e: WorktreeEntry, sessions: AgentSession[], profileID: string): Owner {
  const s = sessions.filter(x => x.profileID.toUpperCase() === profileID.toUpperCase() && x.worktreeBranch === e.branch && !x.deletedAt)
    .sort((a, b) => (Date.parse(b.lastSeenAt ?? '') || 0) - (Date.parse(a.lastSeenAt ?? '') || 0))[0];
  if (!s) return { kind: 'none' };
  return { kind: s.archivedAt ? 'archived' : 'live', s };
}

function summary(e: WorktreeEntry): string {
  if (worktreeIsEmpty(e)) return 'no changes yet';
  const parts: string[] = [];
  if (e.ahead > 0) parts.push(e.ahead === 1 ? '1 commit' : `${e.ahead} commits`);
  if (e.changed > 0) parts.push(e.changed === 1 ? '1 uncommitted file' : `${e.changed} uncommitted files`);
  return parts.join(' · ');
}

export function BranchesView({ host, profileID, wm }: { host: RemoteHost; profileID: string; wm: WindowsAPI }) {
  const { select } = useHostCtx();
  const ws = useRemote(host, s => s.workspaces?.find(w => w.id.toUpperCase() === profileID.toUpperCase()));
  const sessions = useRemote(host, s => s.agentSessions) ?? [];
  const [entries, setEntries] = useState<WorktreeEntry[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [onlyLoose, setOnlyLoose] = useState(false);
  const [discard, setDiscard] = useState<{ e: WorktreeEntry; own: Owner } | null>(null);
  const tip = useTooltip();
  const name = ws?.name ?? '';
  const isLoose = (e: WorktreeEntry) => ownerOf(e, sessions, profileID).kind !== 'live';

  const load = useCallback(async () => {
    setFailed(false);
    try {
      const out = await host.guestExec(profileID, worktreeListCommand(), 30);
      const got = parseWorktrees(out);
      setEntries(got.sort((a, b) => {
        const la = isLoose(a), lb = isLoose(b);
        if (la !== lb) return la ? -1 : 1;
        return (b.lastCommit?.getTime() ?? 0) - (a.lastCommit?.getTime() ?? 0);
      }));
    } catch { setEntries(null); setFailed(true); }
  }, [host, profileID]); // eslint-disable-line
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (isMod(e) && e.key.toLowerCase() === 'r') { e.preventDefault(); void load(); } };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [load]);

  const all = entries ?? [];
  const loose = all.filter(isLoose);
  const shown = onlyLoose ? loose : all;

  const openInSession = async (e: WorktreeEntry) => {
    try {
      const r = await host.request('POST', '/agent-sessions/worktree-open', {
        profile: profileID, dir: e.dir, branch: e.branch, parent: e.parent, root: e.root, display: e.display, tool: ws?.tool ?? 'claude' });
      host.refreshSoon();
      if (r?.id) select({ kind: 'session', sessionID: r.id });
    } catch (err) { console.warn('worktree-open', err); }
  };
  const doDiscard = (e: WorktreeEntry, own: Owner) => {
    const body: Record<string, unknown> = { profile: profileID, root: e.root, branch: e.branch };
    if (own.kind !== 'none') body.session = own.s.id;
    host.send('POST', '/agent-sessions/worktree-discard', body);
    setEntries(es => es?.filter(x => x.dir !== e.dir) ?? null);
    setTimeout(() => void load(), 2000);
  };

  const tag = (text: string, color: string, help: string) => (
    <span {...tip.bind(help || undefined)} style={{ fontSize: 10, fontWeight: 600, color, padding: '1.5px 6px', borderRadius: 999, background: `color-mix(in srgb, ${color} 12%, transparent)`, whiteSpace: 'nowrap' }}>{text}</span>
  );

  return (
    <div className="br-root">
      <div className="br-bar">
        <div className="mc-col" style={{ gap: 2 }}>
          <span style={{ fontSize: 14, fontWeight: 700 }}>Branches on {name}</span>
          <span className="mc-secondary" style={{ fontSize: 11.5 }}>{entries === null ? ' ' : !all.length ? 'No branches' : `${all.length} branches · ${loose.length} left behind`}</span>
        </div>
        <span className="mc-spacer" />
        <Checkbox checked={onlyLoose} onChange={setOnlyLoose}><span style={{ fontSize: 12 }}>Only without a session</span></Checkbox>
        <Button icon="arrow.clockwise" title="Refresh" onClick={() => void load()} />
      </div>
      {entries ? (
        !shown.length
          ? <Unavailable icon="checkmark.seal" title="Nothing left behind"
                         description={!entries.length ? 'This machine has no branches made by Bromure.' : 'Every branch has a session looking after it.'} />
          : <div className="mc-scroll"><div className="mc-col" style={{ padding: 14, gap: 8 }}>
              {shown.map(e => {
                const own = ownerOf(e, sessions, profileID);
                const empty = worktreeIsEmpty(e);
                const c = empty ? 'var(--label-secondary)' : 'var(--purple)';
                return (
                  <div key={e.dir} className="br-row">
                    <span className="br-icon" style={{ background: `color-mix(in srgb, ${c} 14%, transparent)` }}><SF name="arrow.triangle.branch" size={13} weight={600} color={c} /></span>
                    <span className="mc-col" style={{ gap: 3, flex: 1, minWidth: 0 }}>
                      <span className="mc-row" style={{ gap: 6 }}>
                        <span className="mc-ellipsis" style={{ fontSize: 13, fontWeight: 600 }}>{e.display || e.branch}</span>
                        {own.kind === 'live'
                          ? (own.s.windowIndex != null && !own.s.endedAt ? tag('In a session', 'var(--green)', own.s.title) : tag('Session paused', 'var(--label-secondary)', own.s.title))
                          : own.kind === 'archived'
                            ? tag((own.s.branchMerge as any)?.phase === 'merged' ? 'Merged' : 'Session archived', 'var(--orange)', own.s.title)
                            : tag('No session', 'var(--red)', '')}
                      </span>
                      <span className="mc-row mc-secondary mc-ellipsis" style={{ gap: 6, fontSize: 11 }}>
                        <span style={{ fontFamily: 'var(--font-mono)' }}>{e.branch}</span>
                        <SF name="arrow.right" size={8} className="mc-tertiary" />
                        <span style={{ fontFamily: 'var(--font-mono)' }}>{e.parent}</span>
                        <span className="mc-tertiary">·</span>
                        <span>{summary(e)}</span>
                        {e.lastCommit && <><span className="mc-tertiary">·</span><span>last commit {relativeShort(e.lastCommit)}</span></>}
                      </span>
                      <span className="mc-tertiary mc-ellipsis" style={{ fontSize: 10.5, fontFamily: 'var(--font-mono)', direction: 'rtl', textAlign: 'left' }}><bdi>{prettyGuestPath(e.dir)}</bdi></span>
                    </span>
                    {own.kind !== 'none' ? <>
                      <Button onClick={() => openSessionReviewWindow(wm, host, own.s.id)}>Review</Button>
                      <Button onClick={() => select({ kind: 'session', sessionID: own.s.id })}>Show Session</Button>
                    </> : <Button onClick={() => void openInSession(e)}>Open in a Session</Button>}
                    <Button icon="trash" title="Discard the branch and its checkout" style={{ color: 'var(--red)' }} onClick={() => setDiscard({ e, own })} />
                  </div>
                );
              })}
            </div></div>
      ) : failed
        ? <Unavailable icon="bolt.horizontal.circle" title="Can't reach the machine" description="Branches are read live from the machine — start it and refresh." />
        : <div style={{ flex: 1, display: 'grid', placeItems: 'center' }}><Spinner /></div>}
      {discard && (() => {
        const { e, own } = discard;
        let info = worktreeIsEmpty(e) ? 'Nothing was done on it, so nothing is lost.' : `Its work (${summary(e)}) is deleted with the checkout. This can't be undone.`;
        if (own.kind === 'archived') info += ` The archived session “${own.s.title}” goes too.`;
        return <Confirm title={`Discard ${e.branch}?`} message={info} confirm="Discard" destructive
                        onConfirm={() => { setDiscard(null); doDiscard(e, own); }} onCancel={() => setDiscard(null)} />;
      })()}
      {tip.node}
    </div>
  );
}

export function openBranchesWindow(wm: WindowsAPI, host: RemoteHost, workspaceID: string) {
  const name = host.state?.workspaces?.find(w => w.id.toUpperCase() === workspaceID.toUpperCase())?.name ?? '';
  wm.open({
    id: `branches:${workspaceID}`, title: `Branches on ${name}`, width: 820, height: 560, minWidth: 620, minHeight: 360,
    render: () => <BranchesView host={host} profileID={workspaceID} wm={wm} />,
  });
}
