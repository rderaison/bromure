// SessionHeaderView (SessionStageViews.swift): the title (double-click to
// rename), one quiet line — @nick · status · agent · machine · folder ·
// branch · squelch — stepping its detail down until it fits (ViewThatFits),
// the branch's merge control, Resume, and the ⋯ menu.

import React, { useLayoutEffect, useRef, useState } from 'react';
import { SF } from '../../ui/icons';
import { useMenu, useTooltip, type MenuItem } from '../../ui/kit';
import { useHostCtx } from '../../app/hostContext';
import type { AgentSession, Workspace } from '../../core/remote/types';
import { AgentAvatar, AgentStatusDot } from '../sidebar/AgentAvatar';
import {
  bucket as bucketOf, dot, goneReason, hasEnded, hasFolder, isArchived, isBranch, branchSummary, mergeLine,
  type ListModel,
} from '../sidebar/model';
import { sessionActions, sessionCommand, openSurface, type SessionActions } from '../sidebar/actions';
import { showSheet } from '../sidebar/Dialogs';
import { bucketTint, headerStatusText, prettyGuestPath, shortFolder, toolDisplayName } from './sessionState';
import { NewBranchSheet } from './Sheets';
import { NicknameSheet } from '../sidebar/NicknameSheet';

/** line.3.horizontal.decrease.circle(.fill) — no Lucide twin. */
function SquelchGlyph({ filled }: { filled: boolean }) {
  return (
    <svg width="11" height="11" viewBox="0 0 16 16" style={{ display: 'block' }}>
      <circle cx="8" cy="8" r="7" fill={filled ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="1.3" />
      <g stroke={filled ? 'var(--ac-canvas)' : 'currentColor'} strokeWidth="1.3" strokeLinecap="round">
        <path d="M4.5 6h7" /><path d="M5.8 8.3h4.4" /><path d="M7 10.6h2" />
      </g>
    </svg>
  );
}

const MetaDot = () => <span className="sh-dot">·</span>;

function MetaLine({ s, m, ws, detail, onMachine, onMachineMenu, tip }: {
  s: AgentSession; m: ListModel; ws?: Workspace; detail: number;
  onMachine: () => void; onMachineMenu: (e: React.MouseEvent) => void; tip: ReturnType<typeof useTooltip>['bind'];
}) {
  const b = bucketOf(s, m);
  const st = dot(s, m);
  const gone = goneReason(s, m);
  const branch = s.worktreeBranch as string | undefined;
  const squelch = !!(ws as any)?.squelch;
  const native = m.machineIDs.has(s.profileID);
  return (
    <div className="sh-meta">
      {s.nickname && <><span className="sh-nick mono" {...tip('How agents and the composer reach this session')}>@{s.nickname}</span><MetaDot /></>}
      <span className="sh-item" style={{ color: bucketTint(b) }}>
        {st ? <AgentStatusDot status={st} scale={1.15} /> : <span className="sh-bdot" style={{ background: bucketTint(b) }} />}
        <span className="sh-status">{gone ?? headerStatusText(s, m)}</span>
      </span>
      <MetaDot />
      <span className="sh-item">
        <AgentAvatar tool={s.tool} size={13} />
        <span>{toolDisplayName(s.tool)}</span>
        {detail >= 3 && typeof s.lastModel === 'string' && s.lastModel && <span className="tertiary" {...tip('The model the agent last answered with')}>{s.lastModel}</span>}
      </span>
      {detail >= 2 && ws && (
        <>
          <MetaDot />
          <span className="sh-item sh-click" onClick={onMachine} onContextMenu={onMachineMenu}
                {...tip('The machine this session runs on — click for its details, right-click for its settings')}>
            <span className="sh-square" style={{ background: ws.accentHex ?? '#888' }} />
            <span>{ws.name}</span>
          </span>
          {native && <span className="sh-item" style={{ color: 'var(--orange)' }}><SF name="exclamationmark.triangle.fill" size={10} />Not sandboxed</span>}
        </>
      )}
      {detail >= 5 && (
        <>
          <MetaDot />
          <span className="sh-item" {...tip(prettyGuestPath(s.cwd ?? '~'))}>
            <SF name="folder" size={11} />
            <span className="mono sh-mono">{detail >= 6 ? prettyGuestPath(s.cwd ?? '~') : shortFolder(prettyGuestPath(s.cwd ?? '~'))}</span>
          </span>
        </>
      )}
      {detail >= 2 && branch && (
        <>
          <MetaDot />
          <span className="sh-item" {...tip(s.branchParent ? `Its own git branch, off ${s.branchParent} — merge it back when it's ready` : 'A git worktree: its own branch, off the session it was started from')}>
            <SF name="arrow.triangle.branch" size={11} />
            <span className="mono sh-mono">{branch}</span>
            {!s.branchMerge && branchSummary(s) && <span className="tertiary">{branchSummary(s)}</span>}
          </span>
        </>
      )}
      {detail >= 7 && typeof s.cloneURL === 'string' && s.cloneURL && (
        <>
          <MetaDot />
          <span className="sh-item" {...tip(s.cloneURL)}><SF name="arrow.down.circle" size={11} /><span className="mono sh-mono">{shortRepo(s.cloneURL)}</span></span>
        </>
      )}
      {detail >= 4 && ws && !native && (
        <>
          <MetaDot />
          <span className="sh-item" style={{ opacity: squelch ? 1 : 0.55 }}
                {...tip(squelch ? 'Squelch trims the noise out of command output before the model reads it — click for what it saved'
                  : 'Squelch is off on this machine — click to trim the noise out of command output')}>
            <SquelchGlyph filled={squelch} />
          </span>
        </>
      )}
    </div>
  );
}

function shortRepo(url: string) {
  return url.replace(/^https?:\/\//, '').replace(/^git@/, '').replace(/\.git$/, '').replace(/^github\.com[/:]/, '');
}

/** The ⋯ / right-click machine items. */
function machineItems(s: AgentSession, ws: Workspace | undefined, gone: boolean, a: SessionActions, showMachine: () => void): MenuItem[] {
  if (!ws) return [];
  const out: MenuItem[] = [{ label: `“${ws.name}” Settings…`, icon: 'gearshape', action: () => a.editMachine(s.profileID) }];
  if (!gone && s.windowIndex != null && !hasEnded(s)) out.push({ label: 'Open in Linux Terminal', icon: 'terminal', action: () => a.openLinux(s.id) });
  out.push({ label: 'Machine Details', icon: 'cpu', action: showMachine });
  out.push({ label: 'Branches on This Machine…', icon: 'arrow.triangle.branch', action: () => openSurface('branches', { profileID: s.profileID }) });
  return out;
}

function branchItems(s: AgentSession, a: SessionActions, includeMerge = true): MenuItem[] {
  const parent = (s.branchParent as string) ?? 'its parent';
  const phase = (s.branchMerge as any)?.phase;
  const busy = phase === 'merging' || phase === 'conflicts';
  return [
    { header: 'Branch' },
    { label: 'Review Changes', action: () => openSurface('review', { sessionID: s.id }) },
    ...(includeMerge ? [{ label: `Merge into ${parent}`, disabled: busy, action: () => a.mergeBranch(s.id, null, false, true) }] : []),
    { label: `Squash and Merge into ${parent}`, disabled: busy, action: () => a.mergeBranch(s.id, null, true, true) },
    { label: 'Merge, Keep Working on the Branch', disabled: busy, action: () => a.mergeBranch(s.id, null, false, false) },
    { label: 'Open a Pull Request', disabled: busy, action: () => a.branchPullRequest(s.id) },
    { label: 'Open Terminal Here', action: () => a.openLinux(s.id) },
    { separator: true },
    { label: 'Discard Branch…', destructive: true, action: () => a.discardBranch(s.id) },
  ];
}

/** BranchMergeControl: "Merge into main" (its menu has the other ways), or the merge as it goes. */
function MergeControl({ s, a }: { s: AgentSession; a: SessionActions }) {
  const menu = useMenu();
  const m = s.branchMerge as any;
  const parent = (s.branchParent as string) ?? 'parent';
  if (m?.phase === 'requested') return null;
  if (m && m.phase !== 'failed') {
    return (
      <span className="sh-merge-state" style={{ color: m.phase === 'merged' ? 'var(--green)' : 'var(--label-secondary)' }}>
        {m.phase === 'merged' ? <SF name="checkmark.circle.fill" size={13} color="var(--green)" /> : <span className="progress-spin" style={{ width: 12, height: 12 }} />}
        {mergeLine(s)}
      </span>
    );
  }
  const info = s.branchInfo as any;
  if (info && !(info.ahead > 0) && !(info.changed > 0) && !(info.behind > 0)) return null;
  return (
    <span className="sh-merge" title={m?.detail ?? `Merge this branch into ${parent}, then remove its checkout. Uncommitted work or a conflict is handed to the agent to finish.`}>
      <button className="sh-merge-main" onClick={() => a.mergeBranch(s.id, null, false, true)}>
        <SF name="arrow.triangle.merge" size={13} />{m?.phase === 'failed' ? 'Retry Merge' : `Merge into ${parent}`}
      </button>
      <span className="sh-merge-sep" />
      <button className="sh-merge-chev" onClick={e => menu((e.currentTarget as HTMLElement).getBoundingClientRect(), branchItems(s, a, false))}>
        <SF name="chevron.down" size={11} weight={600} />
      </button>
    </span>
  );
}

/** BranchMergeRequestBanner: an agent asked to merge. */
function MergeBanner({ s, sessions, a }: { s: AgentSession; sessions: AgentSession[]; a: SessionActions }) {
  const m = s.branchMerge as any;
  const asker = sessions.find(x => x.id === m?.askedBy);
  const who = asker && asker.id !== s.id ? `${toolDisplayName(asker.tool)} in “${asker.title}”` : toolDisplayName(s.tool);
  const sub = [m?.squash ? 'As one squashed commit' : null, branchSummary(s), 'The checkout is removed once it has landed.'].filter(Boolean).join(' · ');
  return (
    <div className="sh-banner">
      <span className="sh-banner-icon"><SF name="arrow.triangle.merge" size={13} weight={600} color="var(--orange)" /></span>
      <div className="sh-banner-text">
        <div className="sh-banner-title">{who} asks to merge {s.worktreeBranch as string} into {m?.target}</div>
        <div className="sh-banner-sub">{sub}</div>
      </div>
      <button className="btn" onClick={() => openSurface('review', { sessionID: s.id })}>Review Changes</button>
      <button className="btn" onClick={() => (a as any).declineMerge?.(s.id)}>Not Now</button>
      <button className="btn prominent" style={{ background: 'var(--orange)', minWidth: 56 }}
              onClick={() => m && a.mergeBranch(s.id, m.target, !!m.squash, m.removeAfter !== false)}>
        {m?.squash ? 'Squash and Merge' : 'Merge'}
      </button>
    </div>
  );
}

export function SessionHeader({ s, m, sessions, workspaces }: { s: AgentSession; m: ListModel; sessions: AgentSession[]; workspaces: Workspace[] }) {
  const ctx = useHostCtx();
  const { host, select } = ctx;
  const menu = useMenu();
  const tip = useTooltip();
  const a: SessionActions = Object.assign(sessionActions({
    host, selection: ctx.selection, select, sessions: () => host.state?.agentSessions ?? [], model: () => m,
  }), { declineMerge: (id: string) => sessionCommand(host, id, 'branch-decline') });
  const ws = workspaces.find(w => w.id === s.profileID);
  const b = bucketOf(s, m);
  const gone = goneReason(s, m) != null;
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState('');
  const [detail, setDetail] = useState(7);
  const metaBox = useRef<HTMLDivElement>(null);
  const showMachine = () => select({ kind: 'workspace', workspaceID: s.profileID });

  // ViewThatFits: the richest meta line that fits.
  useLayoutEffect(() => { setDetail(7); }, [s.id, s.nickname, s.cwd, s.worktreeBranch, b, ws?.name]);
  useLayoutEffect(() => {
    const el = metaBox.current?.firstElementChild as HTMLElement | null;
    if (el && el.scrollWidth > (metaBox.current!.clientWidth + 1) && detail > 0) setDetail(d => d - 1);
  });
  useLayoutEffect(() => {
    const box = metaBox.current; if (!box) return;
    let w = box.clientWidth;
    const ro = new ResizeObserver(() => { if (box.clientWidth > w) setDetail(7); w = box.clientWidth; });
    ro.observe(box);
    return () => ro.disconnect();
  }, []);

  const rename = (id: string, title: string) => { if (title.trim()) sessionCommand(host, id, 'rename', { title: title.trim() }); };
  const startRename = () => { if (gone) return; setDraft(s.title); setRenaming(true); };

  const menuItems = (): MenuItem[] => {
    const items: MenuItem[] = [];
    if (!gone) {
      items.push({ label: 'Rename…', action: startRename });
      items.push({ label: 'Nickname…', action: () => showSheet(380, close => <NicknameSheet session={s} sessions={sessions} close={close} onSet={(n: string, r: boolean) => a.setNickname(s.id, n, r)} />) });
      if (isArchived(s)) items.push({ label: 'Unarchive', action: () => a.unarchive(s.id) });
      else items.push({ label: s.windowIndex != null && !hasEnded(s) ? 'End & Archive' : 'Archive', action: () => a.archive(s.id) });
      if (s.windowIndex != null) items.push({ label: 'End session', action: () => a.close(s.id) });
      if (hasFolder(s)) {
        items.push({ separator: true });
        if (!isBranch(s)) items.push({ label: 'Review Changes', action: () => openSurface('review', { sessionID: s.id }) });
        items.push({ label: 'New Branch…', action: () => showSheet(460, close => <NewBranchSheet s={s} close={close} />) });
      }
      if (isBranch(s)) items.push(...branchItems(s, a));
    } else if (isArchived(s)) items.push({ label: 'Unarchive', action: () => a.unarchive(s.id) });
    items.push({ separator: true }, ...machineItems(s, ws, gone, a, showMachine), { separator: true },
      { label: 'Delete session', destructive: true, action: () => a.delete(s.id) });
    return items;
  };

  return (
    <div className="sh">
      <div className="sh-row">
        <div className="sh-left">
          {renaming ? (
            <input className="sh-title-edit" autoFocus value={draft} onChange={e => setDraft(e.target.value)}
                   onBlur={() => { rename(s.id, draft); setRenaming(false); }}
                   onKeyDown={e => {
                     if (e.key === 'Enter') { rename(s.id, draft); setRenaming(false); }
                     if (e.key === 'Escape') setRenaming(false);
                   }} />
          ) : (
            <div className="sh-title" onDoubleClick={startRename} {...tip.bind(gone ? undefined : 'Double-click to rename')}
                 onContextMenu={e => { e.preventDefault(); menu(e, machineItems(s, ws, gone, a, showMachine)); }}>{s.title}</div>
          )}
          <div className="sh-meta-box" ref={metaBox}>
            <MetaLine s={s} m={m} ws={ws} detail={detail} tip={tip.bind} onMachine={showMachine}
                      onMachineMenu={e => { e.preventDefault(); menu(e, machineItems(s, ws, gone, a, showMachine)); }} />
          </div>
        </div>
        {!gone && isBranch(s) && <MergeControl s={s} a={a} />}
        {!gone && (b === 'ended' || b === 'asleep') && (
          <button className="sh-resume" onClick={() => a.resume(s.id)}
                  {...tip.bind(b === 'asleep' ? 'Wake up and continue where it left off' : 'Resume where it left off')}>
            <SF name="play.fill" size={12} />Resume
          </button>
        )}
        <button className="sh-more" onClick={e => menu((e.currentTarget as HTMLElement).getBoundingClientRect(), menuItems())}>
          <SF name="ellipsis.circle" size={15} />
        </button>
      </div>
      {!gone && (s.branchMerge as any)?.phase === 'requested' && <MergeBanner s={s} sessions={sessions} a={a} />}
      {tip.node}
    </div>
  );
}
