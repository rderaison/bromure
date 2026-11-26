// The `bromure:open` events no single feature owns — the glue between the
// sidebar / palette / header and actions that span features. Ported from the
// Swift window's handlers (RemoteHostWindow tab actions, room creation, …).

import React, { useEffect, useRef, useState } from 'react';
import { useHostCtx } from './hostContext';
import { sessionActions, openSurface, selectInitial } from '../features/sidebar/actions';
import { useHost } from './store';
import { buildListModel } from '../features/sidebar/model';
import { showSheet, showAlert, RoomNameSheet } from '../features/sidebar/Dialogs';
import { NewBranchSheet } from '../features/stage/Sheets';
import { Button, PopUp, TextField } from '../ui/kit';
import { seg } from '../core/remote/host';
import { hasBrowser, toggleBrowser } from '../features/browser/browserWindow';

const TOOLS = ['claude', 'codex', 'kimi', 'grok', 'omp', 'hermes'];
/** AgentSession.worktreeSlug: diacritics folded, ASCII alnum, dash runs, ≤40. */
const slug = (s: string) => s.normalize('NFD').replace(/\p{M}+/gu, '').toLowerCase()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40).replace(/^-+|-+$/g, '') || 'worktree';

export function IntegrationBridge() {
  const ctx = useHostCtx();
  const ref = useRef(ctx); ref.current = ctx;
  useHost(ctx.host);

  // Dev/screenshot hook: put anything on stage.
  useEffect(() => { (window as any).__bromure = { ...(window as any).__bromure, select: (sel: any) => ref.current.select(sel) }; });

  // RemoteHostWindow.syncSessionsHome: on the host's first snapshot, the
  // remembered session if it's still live, else the first session by bucket,
  // else the new-session screen (selectInitialSession).
  const didInitial = useRef(false);
  const st0 = ctx.host.state;
  useEffect(() => {
    if (didInitial.current || !st0 || !st0.agentSessions) return;
    didInitial.current = true;
    const { selection, select, host } = ref.current;
    const sessions = st0.agentSessions ?? [];
    const keep = selection.kind === 'session'
      ? sessions.some(s => s.id === selection.sessionID && !s.endedAt && !s.archivedAt && !s.deletedAt)
      : selection.kind !== 'home';
    if (!keep) selectInitial({ host, selection, select, sessions: () => sessions, model: () => buildListModel(st0) });
  }, [st0]);
  useEffect(() => {
    const on = (e: Event) => {
      const d = (e as CustomEvent).detail ?? {};
      const { host, select, selection } = ref.current;
      const st = host.state;
      const actions = sessionActions({ host, selection, select, sessions: () => st?.agentSessions ?? [], model: () => buildListModel(st) });
      const worktree = (pid: string, action: string, args: string[]) =>
        host.send('POST', `/sessions/${seg(pid)}/worktree`, { action, args });
      const tabOf = (pid: string, index: number) => (st?.vms.find(v => v.id === pid)?.tabs ?? []).find(t => t.index === index) as any;
      const toolOf = (pid: string) => st?.workspaces.find(w => w.id === pid)?.tool ?? 'claude';
      switch (d.what) {
        case 'workspace-settings': openSurface('settings', { profileID: d.id ?? d.profileID }); break;
        case 'new-room':
          showSheet(380, close => <RoomNameSheet title="New Room" action="Create" close={close} onSet={n => actions.newRoom(n, d.sessionID)} />);
          break;
        case 'new-branch': {
          const s = st?.agentSessions?.find(x => x.id === d.sessionID);
          if (s) { select({ kind: 'session', sessionID: s.id }); showSheet(460, close => <NewBranchSheet s={s} close={close} />); }
          break;
        }
        case 'merge-branch': {
          const s = st?.agentSessions?.find(x => x.id === d.sessionID);
          if (s) actions.mergeBranch(s.id, null, false, true);
          break;
        }
        case 'new-worktree': {
          const pid = d.profileID as string, tab = tabOf(pid, d.index);
          // A session's tab: that session's own New Branch sheet.
          const s = st?.agentSessions?.find(x => x.profileID === pid && x.windowIndex === d.index && !x.deletedAt && !x.endedAt);
          if (s) { openSurface('new-branch', { sessionID: s.id }); break; }
          if (!tab?.cwd) break;
          showSheet(380, close => <NewWorktreeSheet close={close} tool={toolOf(pid)} onCreate={(n, t, p) =>
            worktree(pid, 'create', [tab.cwd, slug(n), `${n} (${t})`, t, p])} />);
          break;
        }
        case 'tab-merge': {
          const pid = d.profileID as string, tab = tabOf(pid, d.index);
          if (!tab?.worktreeBranch || !tab?.rootRepo) break;
          const tabs = (st?.vms.find(v => v.id === pid)?.tabs ?? []) as any[];
          const chain: { branch: string; label: string }[] = [];
          let pb: string | undefined = tab.parentBranch;
          for (let i = 0; pb && i < 8; i++) {
            const parent = tabs.find(t => t.worktreeBranch === pb);
            if (parent) { chain.push({ branch: pb, label: parent.title ?? pb }); pb = parent.parentBranch; }
            else { chain.push({ branch: pb, label: `${pb} (repo root)` }); break; }
          }
          if (!chain.length) break;
          const label = tab.title ?? tab.worktreeBranch;
          showSheet(440, close => <MergeSheet close={close} label={label} chain={chain}
            canPR={!!st?.workspaces.find(w => w.id === pid)?.hasGitHubToken}
            onMerge={(target, pr) => worktree(pid, pr ? 'pr' : 'merge', [tab.worktreeBranch, target, tab.rootRepo, label, toolOf(pid)])} />);
          break;
        }
        case 'tab-resolve': {
          const tab = tabOf(d.profileID, d.index);
          if (tab?.cwd) worktree(d.profileID, 'resolve', [tab.cwd, toolOf(d.profileID)]);
          break;
        }
        case 'toggle-browser':
          // The desktop app's built-in browser; the hosted app has no globe.
          if (hasBrowser) void toggleBrowser(ref.current.host);
          break;
      }
    };
    window.addEventListener('bromure:open', on);
    return () => window.removeEventListener('bromure:open', on);
  }, []);
  return null;
}

function NewWorktreeSheet({ close, tool, onCreate }: { close: () => void; tool: string; onCreate: (name: string, tool: string, prompt: string) => void }) {
  const [name, setName] = useState(''), [t, setT] = useState(TOOLS.includes(tool) ? tool : 'claude'), [prompt, setPrompt] = useState('');
  const ok = !!name.trim();
  return (
    <div className="sb-namesheet">
      <div>
        <div className="sb-namesheet-title">New worktree</div>
        <div className="sb-namesheet-sub">Creates a git worktree branched from this tab's current commit and opens a nested agent in it.</div>
      </div>
      <TextField autoFocus value={name} placeholder="Task name (e.g. Website refactoring)" onChange={e => setName(e.target.value)} />
      <PopUp bordered value={t} options={TOOLS.map(v => ({ value: v, label: v }))} onChange={setT} />
      <TextField value={prompt} placeholder="Initial prompt (optional)" onChange={e => setPrompt(e.target.value)}
                 onKeyDown={e => { if (e.key === 'Enter' && ok) { onCreate(name.trim(), t, prompt.trim()); close(); } }} />
      <div className="sb-namesheet-buttons">
        <span style={{ flex: 1 }} />
        <Button onClick={close}>Cancel</Button>
        <Button variant="prominent" disabled={!ok} onClick={() => { onCreate(name.trim(), t, prompt.trim()); close(); }}>Create</Button>
      </div>
    </div>
  );
}

function MergeSheet({ close, label, chain, canPR, onMerge }: {
  close: () => void; label: string; chain: { branch: string; label: string }[]; canPR: boolean; onMerge: (target: string, pr: boolean) => void;
}) {
  const [i, setI] = useState(0);
  return (
    <div className="sb-namesheet">
      <div>
        <div className="sb-namesheet-title">Merge “{label}”</div>
        <div className="sb-namesheet-sub">Runs the merge in a new tab in the destination's checkout. Uncommitted work on the branch is committed first by the coding agent, so nothing is left behind; conflicts start the agent right there to resolve them. The worktree isn't discarded — use “Discard worktree” once you're happy.</div>
      </div>
      <PopUp bordered value={i} onChange={setI}
             options={chain.map((c, k) => ({ value: k, label: k === 0 ? c.label : `${c.label}  ⚠︎ skips intermediates` }))} />
      <div className="sb-namesheet-buttons">
        {canPR && <Button onClick={() => { onMerge(chain[i].branch, true); close(); }}>Create Pull Request</Button>}
        <span style={{ flex: 1 }} />
        <Button onClick={close}>Cancel</Button>
        <Button variant="prominent" onClick={() => { onMerge(chain[i].branch, false); close(); }}>Merge</Button>
      </div>
    </div>
  );
}
