// The coding kanban (CodingKanbanView.swift): Backlog → Plan → In Progress →
// Review → Done, with the card menus, the confirmations and the editor /
// assign / answer sheets. Every verb POSTs /tasks/<id>/<action> (or /tasks,
// DELETE /tasks/<id>) and the mirror confirms on the next state push.

import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import type { RemoteState } from '../../core/remote/types';
import { useRemote } from '../../app/store';
import { useHostCtx, usePersisted } from '../../app/hostContext';
import { useWindows } from '../../app/windows';
import { SF } from '../../ui/icons';
import { Button, cx, useMenu, type MenuItem, safeHref } from '../../ui/kit';
import {
  type CodingTask, type Assignment, type Bucket, tasksOf, backlogTasks, inStage, plainExcerpt, isStarting, validationInFlight,
  queuePosition, assignmentIcon, taskBucket, couldntStart, needsAttention, bucketTitle, bucketTint, isNoCode, isLocating,
  LOCATING_TEXT, landingLine, landingTarget, workerName, unsentComments, effectiveCompletion, doneText, unmetDependencies,
  relShort, relNamed, dateTimeLong, workspaceOf, accentOf, backlogRank, NEW_AGENT, SWITCHBOARD, taskSession,
} from './model';
import { BoardBackdrop, KanbanColumn, Card, WorkspaceChip, StatusPill, MiniSpinner, PrimaryButton, columnWidth, confirm, useTick } from './kanban';
import { TaskEditorSheet, AssignTaskSheet, TaskAnswerSheet, BatchMergeSheet, assigneeChoices } from './TaskSheets';
import { openTaskReview, openTaskTranscript } from './TaskReview';
import './boards.css';

const post = (host: RemoteHost, id: string, action: string, body?: unknown) => host.send('POST', `/tasks/${seg(id)}/${action}`, body);

export function droppedSuffix(t: CodingTask) {
  const n = unsentComments(t);
  return n === 0 ? '' : '\n\n' + (n === 1 ? '1 review comment that never reached the agent will be discarded.'
    : `${n} review comments that never reached the agent will be discarded.`);
}

export function TaskBoardView({ host, newTaskToken }: { host: RemoteHost; newTaskToken?: number }) {
  useTick();
  const st = useRemote(host, s => s) as RemoteState | undefined;
  const tasks = tasksOf(st);
  const ctx = useHostCtx();
  const wm = useWindows();
  const [editing, setEditing] = useState<{ task: CodingTask; isNew: boolean } | null>(null);
  const [assigning, setAssigning] = useState<CodingTask | null>(null);
  const [answering, setAnswering] = useState<CodingTask | null>(null);
  const [autoAssign, setAutoAssign] = usePersisted<Assignment | null>('bromure.tasks.autoAssign', null);
  const [finishWithPR, setFinishWithPR] = usePersisted('bromure.tasks.finishWithPR', false);
  const [selPhases, setSelPhases] = useState<Set<string>>(new Set());
  const [selReview, setSelReview] = useState<Set<string>>(new Set());
  const [batchMerge, setBatchMerge] = useState<CodingTask[] | null>(null);
  const boardRef = useRef<HTMLDivElement>(null);
  const [avail, setAvail] = useState(1000);
  const openMenu = useMenu();

  useLayoutEffect(() => {
    const el = boardRef.current; if (!el) return;
    const ro = new ResizeObserver(() => setAvail(el.clientWidth));
    ro.observe(el); setAvail(el.clientWidth);
    return () => ro.disconnect();
  }, []);

  const lastDraft = () => {
    let last: { ws?: string; folders?: Record<string, string> } = {};
    try { last = JSON.parse(localStorage.getItem('bromure.tasks.lastDraft') || '{}'); } catch {}
    return last;
  };
  const newDraft = (): CodingTask => {
    const ws = st?.workspaces ?? [];
    const last = lastDraft();
    const p = ws.find(w => w.id === last.ws) ?? ws[0];
    return {
      id: crypto.randomUUID().toUpperCase(), title: '', details: '', stage: 'backlog', profileID: p?.id ?? '',
      repoPath: (p && last.folders?.[p.id]) || '~', tool: p?.tool ?? 'claude', comments: [], merged: false,
      createdAt: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), assignment: autoAssign ?? undefined,
    };
  };
  const remember = (t: CodingTask) => {
    const last = lastDraft(); last.ws = t.profileID; last.folders = last.folders ?? {};
    const f = t.repoPath.trim(); if (f && f !== '~') last.folders[t.profileID] = f;
    try { localStorage.setItem('bromure.tasks.lastDraft', JSON.stringify(last)); } catch {}
  };
  useEffect(() => { if (newTaskToken) setEditing({ task: newDraft(), isNew: true }); }, [newTaskToken]); // eslint-disable-line

  if (!st) return <BoardBackdrop tints={['var(--blue)', 'var(--purple)', 'var(--indigo)']} className="bd-board" />;

  const wsName = (id: string) => workspaceOf(st, id)?.name ?? 'Deleted workspace';
  const accent = (id: string) => accentOf(st, id);
  const byID = (id?: string) => tasks.find(t => t.id === id);

  // ── actions ──
  const A = {
    start: (id: string) => post(host, id, 'start'),
    plan: (id: string) => post(host, id, 'plan'),
    openReview: (id: string) => openTaskReview(wm, host, id),
    openTranscript: (id: string) => openTaskTranscript(wm, host, id),
    jumpToRun: (t: CodingTask) => {
      const s = taskSession(t, st);
      if (s) { ctx.select({ kind: 'session', sessionID: s.id }); return; }
      ctx.select({ kind: 'workspace', workspaceID: t.profileID });
    },
    openAssignee: (t: CodingTask) => {
      const a = t.assignment;
      if (a?.kind === 'session') ctx.select({ kind: 'session', sessionID: a.id });
      else if (a?.kind === 'room') ctx.select({ kind: 'room', roomID: a.id });
      else A.jumpToRun(t);
    },
    toTesting: (id: string) => post(host, id, 'to-testing'),
    toInProgress: (id: string) => post(host, id, 'to-in-progress'),
    closeNoMerge: (id: string) => post(host, id, 'close-no-merge'),
    markDone: (id: string) => post(host, id, 'mark-done'),
    stop: (id: string) => post(host, id, 'stop'),
    startOver: (id: string) => post(host, id, 'start-over'),
    destroy: (id: string) => post(host, id, 'destroy'),
    resume: (id: string) => post(host, id, 'resume'),
    recall: (id: string) => post(host, id, 'recall'),
    retryLanding: (id: string) => post(host, id, 'retry-landing'),
    delete: (id: string) => host.send('DELETE', `/tasks/${seg(id)}`),
    save: (t: CodingTask) => host.send('POST', '/tasks', t),
    assign: (id: string, a: Assignment | null) => post(host, id, 'assign', a ? { kind: a.kind, id: a.id, label: a.label } : { kind: 'none' }),
    rank: (id: string, rank: number) => post(host, id, 'rank', { rank }),
    merge: (id: string) => openTaskReview(wm, host, id, 'merge'),
  };
  const requestMarkDone = (t: CodingTask) => {
    if (t.stage === 'testing' && isNoCode(t)) { A.markDone(t.id); return; }
    const br = t.branch ?? (t.branchSlug ? 'wt/' + t.branchSlug : '');
    confirm({
      title: 'Mark done without merging?',
      message: (t.stage === 'inProgress'
        ? `The agent is stopped. Nothing is merged; the branch ${br} and its checkout are kept in the workspace.`
        : `Nothing is merged. The branch ${t.branch ?? ''} and its checkout are kept in the workspace.`) + droppedSuffix(t),
      buttons: [{ label: 'Mark Done', role: 'default', action: () => A.markDone(t.id) }, { label: 'Cancel', role: 'cancel' }],
    });
  };
  const confirmDiscard = (t: CodingTask) => confirm({
    title: 'Discard this branch?',
    message: `The branch ${t.branch ?? (t.branchSlug ? 'wt/' + t.branchSlug : '')} and its checkout are deleted and the agent's session is put away. The task goes to Done as closed without merging; its transcript is kept.` + droppedSuffix(t),
    buttons: [{ label: 'Discard Branch', role: 'destructive', action: () => A.closeNoMerge(t.id) }, { label: 'Cancel', role: 'cancel' }],
  });
  const confirmRemove = (t: CodingTask, destroy?: () => void) => {
    const backing = !!destroy && (t.stage === 'inProgress' || t.stage === 'testing');
    confirm({
      title: `Remove “${t.title}”?`,
      message: backing ? 'Discarding ends the agent\'s session and deletes its branch and worktree, with any uncommitted or unmerged work. “Remove Task Only” leaves them in the workspace.'
                       : "This can't be undone.",
      buttons: backing
        ? [{ label: t.stage === 'inProgress' ? 'Stop & Discard Branch' : 'Discard Branch', role: 'destructive', action: destroy },
           { label: 'Remove Task Only', action: () => A.delete(t.id) }, { label: 'Cancel', role: 'cancel' }]
        : [{ label: 'Remove', role: 'destructive', action: () => A.delete(t.id) }, { label: 'Cancel', role: 'cancel' }],
    });
  };

  // ── columns ──
  const backlog = backlogTasks(tasks);
  const planning = inStage(tasks, 'planning').sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt));
  const inProgress = inStage(tasks, 'inProgress');
  const testing = inStage(tasks, 'testing');
  const done = inStage(tasks, 'done');
  const planEmpty = planning.length === 0;
  const w = columnWidth(planEmpty ? 4 : 5, avail);

  const stuck = inProgress.filter(t => needsAttention(t, st)).length;
  const landingStuck = testing.filter(t => t.landing?.phase === 'needsYou').length;
  const needsYou = stuck + landingStuck, running = inProgress.length - stuck, review = testing.length - landingStuck;
  const choices = assigneeChoices(st);

  const autoAssignMenu = (e: React.MouseEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const items: MenuItem[] = [
      { header: 'Assign new tasks to' },
      { label: 'Unassigned — I\'ll start it', checked: !autoAssign, action: () => setAutoAssign(null) },
      { label: 'The Switchboard — it picks a session', checked: autoAssign?.kind === 'switchboard', action: () => setAutoAssign(SWITCHBOARD) },
      { label: 'A new agent each (2 at a time)', checked: autoAssign?.kind === 'worktree', action: () => setAutoAssign(NEW_AGENT) },
    ];
    if (choices.sessions.length) {
      items.push({ separator: true }, { header: 'A session' });
      for (const s of choices.sessions) items.push({ label: s.label + (s.workspace ? '  ·  ' + s.workspace : ''), checked: autoAssign?.kind === 'session' && autoAssign.id === s.id, action: () => setAutoAssign({ kind: 'session', id: s.id, label: s.label }) });
    }
    if (choices.rooms.length) {
      items.push({ separator: true }, { header: 'A room' });
      for (const r of choices.rooms) items.push({ label: '#' + r.name, checked: autoAssign?.kind === 'room' && autoAssign.id === r.id, action: () => setAutoAssign({ kind: 'room', id: r.id, label: '#' + r.name }) });
    }
    items.push({ separator: true }, { label: 'Sessions and rooms open a pull request at delivery (skips review)', checked: finishWithPR, action: () => setFinishWithPR(!finishWithPR) });
    openMenu(r, items);
  };

  const reorder = (ids: string[], before: string | null) => {
    let col = [...backlog];
    for (const id of ids) {
      if (id === before) continue;
      const t = byID(id); if (!t || t.stage !== 'backlog') continue;
      const others = col.filter(x => x.id !== id);
      const i = before ? others.findIndex(x => x.id === before) : -1;
      const rank = i < 0 ? Math.max(others.length ? backlogRank(others[others.length - 1]) : 0, Date.now() / 1000) + 0.001
        : i === 0 ? backlogRank(others[0]) - 1 : (backlogRank(others[i - 1]) + backlogRank(others[i])) / 2;
      A.rank(id, rank);
      col = others; col.splice(i < 0 ? col.length : i, 0, { ...t, queueRank: rank });
    }
  };

  const toggle = (set: Set<string>, id: string, upd: (s: Set<string>) => void) => { const n = new Set(set); n.has(id) ? n.delete(id) : n.add(id); upd(n); };
  const batchable = (t: CodingTask) => !isNoCode(t) && !isLocating(t) && !!t.branch && (!t.landing || t.landing.phase === 'needsYou');
  const selectedPhases = planning.filter(t => selPhases.has(t.id));
  const selectedReview = testing.filter(t => selReview.has(t.id) && batchable(t));

  return (
    <BoardBackdrop tints={['var(--blue)', 'var(--purple)', 'var(--indigo)']} className="bd-board">
      <div className="bd-header-wrap bx-tb">
        <div className="bd-header bd-glass" data-drag>
          <SF name="checklist" size={16} weight={500} color="var(--accent)" />
          <span className="bd-title">Coding Tasks</span>
          <span className="bd-header-pills">
            {needsYou > 0 && <StatusPill text={`${needsYou} need you`} tint="var(--red)" />}
            {running > 0 && <StatusPill text={`${running} in progress`} tint="var(--blue)" />}
            {review > 0 && <StatusPill text={`${review} to review`} tint="var(--purple)" />}
          </span>
          <span className="spacer" />
          <button className="bd-menu-btn" onClick={autoAssignMenu}
                  title="Who new tasks are queued for when you create them — they pick them up on their own and take them to Review. Each task can still be assigned by hand.">
            <SF name={autoAssign ? 'bolt.fill' : 'tray.and.arrow.down'} size={13} />
            <span>{autoAssign ? `New tasks: assigned to ${autoAssign.label}` : 'New tasks: Unassigned'}</span>
            <SF name="chevron.down" size={10} weight={600} />
          </button>
          <PrimaryButton icon="plus" onClick={() => setEditing({ task: newDraft(), isNew: true })}
                         title="New task — or ⇧⌥Space from any app for a quick one">New Task</PrimaryButton>
        </div>
      </div>
      <div className="bd-columns" ref={boardRef}>
        <div className="bd-columns-strip">
          <KanbanColumn title="Backlog" icon="tray" count={backlog.length} width={w} subtitle="Tasks waiting to start"
                        emptyText="No tasks yet — write one." onDrop={ids => reorder(ids, null)}>
            {backlog.map(t => (
              <div key={t.id} className="bd-drop-slot"
                   onDragOver={e => { if (e.dataTransfer.types.includes('text/x-bromure-task')) { e.preventDefault(); e.stopPropagation(); } }}
                   onDrop={e => { const id = e.dataTransfer.getData('text/x-bromure-task'); if (id) { e.preventDefault(); e.stopPropagation(); reorder([id], t.id); } }}>
                <Removable onRemove={() => confirmRemove(t)}>
                  <BacklogCard t={t} st={st} all={tasks} ws={wsName(t.profileID)} accent={accent(t.profileID)}
                               parentTitle={byID(t.parentTaskID)?.title}
                               onEdit={() => setEditing({ task: t, isNew: false })}
                               onOpenSession={() => A.jumpToRun(t)}
                               onStart={() => A.start(t.id)} onPlan={() => A.plan(t.id)} onDelete={() => A.delete(t.id)}
                               onAssign={() => setAssigning(t)} onUnassign={() => A.assign(t.id, null)} />
                </Removable>
              </div>
            ))}
          </KanbanColumn>
          {!planEmpty && (
            <KanbanColumn title="Plan" icon="list.number" count={planning.length} tint="var(--blue)" width={w} subtitle="Phases, in order"
                          emptyText="No phases yet — click Plan First on a Backlog task.">
              {selectedPhases.length > 0 && (
                <div className="bd-selbar">
                  <Button size="small" variant="prominent" icon="play.fill"
                          title="Starts every selected phase. Phases whose dependencies aren't Done queue and start automatically when they are."
                          onClick={() => { selectedPhases.forEach(t => A.start(t.id)); setSelPhases(new Set()); }}>Start {selectedPhases.length} Selected</Button>
                  <Button size="small" onClick={() => setSelPhases(new Set())}>Clear</Button>
                  <span className="spacer" />
                  <Button size="small" destructive icon="trash" title="Remove every selected phase from the board"
                          onClick={() => confirm({ title: `Remove ${selectedPhases.length} selected phase(s)?`, message: "This can't be undone.",
                            buttons: [{ label: 'Remove', role: 'destructive', action: () => { selectedPhases.forEach(t => A.delete(t.id)); setSelPhases(new Set()); } }, { label: 'Cancel', role: 'cancel' }] })}>Remove</Button>
                </div>
              )}
              {planning.map((t, i) => (
                <Removable key={t.id} onRemove={() => confirmRemove(t)}>
                  <PlanCard t={t} n={i + 1} accent={accent(t.profileID)} parentTitle={byID(t.parentTaskID)?.title}
                            deps={(t.dependsOn ?? []).map(d => planning.findIndex(x => x.id === d) + 1).filter(n => n > 0)}
                            depsMet={unmetDependencies(t, tasks).length === 0}
                            selected={selPhases.has(t.id)} onToggle={() => toggle(selPhases, t.id, setSelPhases)}
                            onEdit={() => setEditing({ task: t, isNew: false })}
                            menu={() => [
                              { label: 'Start', action: () => A.start(t.id) },
                              { label: 'Edit…', action: () => setEditing({ task: t, isNew: false }) },
                              { label: selPhases.has(t.id) ? 'Deselect' : 'Select', action: () => toggle(selPhases, t.id, setSelPhases) },
                              { separator: true },
                              { label: 'Remove Task', destructive: true, action: () => A.delete(t.id) },
                            ]} />
                </Removable>
              ))}
            </KanbanColumn>
          )}
          <KanbanColumn title="In Progress" icon="play.circle" count={inProgress.length} tint="var(--blue)" width={w} subtitle="Agents at work"
                        emptyText="Nothing running"
                        onDrop={ids => ids.forEach(id => { const t = byID(id); if (t && (t.stage === 'backlog' || t.stage === 'planning') && t.title.trim()) A.start(id); })}>
            {inProgress.map(t => t.assignment && t.assignment.kind !== 'worktree'
              ? <AssignedCard key={t.id} t={t} ws={wsName(t.profileID)} onOpen={() => A.openAssignee(t)} onAnswer={() => setAnswering(t)} onRecall={() => A.recall(t.id)} />
              : (
                <Removable key={t.id} onRemove={() => confirmRemove(t, () => A.destroy(t.id))}>
                  <InProgressCard t={t} st={st} ws={wsName(t.profileID)} accent={accent(t.profileID)}
                                  onOpen={() => A.jumpToRun(t)} onResume={() => A.resume(t.id)} onStartOver={() => A.startOver(t.id)}
                                  onMarkDone={() => requestMarkDone(t)}
                                  menu={() => [
                                    { label: 'Open Session', action: () => A.jumpToRun(t) },
                                    t.restartNeeded ? { label: 'Start Over', action: () => A.startOver(t.id) } : { label: 'Restart Session', action: () => A.resume(t.id) },
                                    { label: 'Move to Review', action: () => A.toTesting(t.id) },
                                    { label: 'Mark Done', action: () => requestMarkDone(t) },
                                    { label: 'Stop & Return to Backlog', action: () => A.stop(t.id) },
                                    { separator: true },
                                    { label: 'Stop & Discard Branch', destructive: true, action: () => A.destroy(t.id) },
                                    { label: 'Remove Task Only', destructive: true, action: () => A.delete(t.id) },
                                  ]} />
                </Removable>
              ))}
          </KanbanColumn>
          <KanbanColumn title="Review" icon="eye" count={testing.length} tint="var(--purple)" width={w} subtitle="Waiting for your review"
                        emptyText="Nothing to review">
            {selectedReview.length > 0 && (
              <div className="bd-selbar">
                <Button size="small" variant="prominent" icon="arrow.triangle.merge" onClick={() => setBatchMerge(selectedReview)}
                        title="Merges every selected task into its target in one go: Bromure merges the clean ones itself; the rest go to one agent, which merges them all, fixes conflicts and runs the checks once.">Merge {selectedReview.length} Selected…</Button>
                <Button size="small" onClick={() => setSelReview(new Set())}>Clear</Button>
              </div>
            )}
            {testing.map(t => {
              const landable = !t.landing || t.landing.phase === 'needsYou';
              const menu = (): MenuItem[] => {
                const m: MenuItem[] = [
                  { label: isNoCode(t) ? 'Read Report' : 'Review Changes', action: () => A.openReview(t.id) },
                  { label: 'Open Session', action: () => t.delegationID ? A.openAssignee(t) : A.jumpToRun(t) },
                ];
                if (t.landing?.phase === 'needsYou') m.push({ label: 'Retry Landing', action: () => A.retryLanding(t.id) });
                if (landable) m.push({ label: 'Mark Done', action: () => requestMarkDone(t) });
                if (batchable(t)) m.push({ label: selReview.has(t.id) ? 'Deselect' : 'Select for a Batch Merge', action: () => toggle(selReview, t.id, setSelReview) });
                if (!isNoCode(t) && !isLocating(t) && landable) m.push({ label: `Merge into ${landingTarget(t) ?? 'parent'}…`, action: () => A.merge(t.id) });
                m.push({ label: 'Back to In Progress', action: () => A.toInProgress(t.id) }, { separator: true });
                if (t.branch) m.push({ label: 'Discard Branch…', destructive: true, action: () => confirmDiscard(t) });
                m.push({ label: 'Remove Task Only', destructive: true, action: () => A.delete(t.id) });
                return m;
              };
              return (
                <Removable key={t.id} onRemove={() => confirmRemove(t, () => confirmDiscard(t))}>
                  <TestingCard t={t} ws={wsName(t.profileID)} accent={accent(t.profileID)}
                               onOpen={() => A.openReview(t.id)} onOpenSession={() => t.delegationID ? A.openAssignee(t) : A.jumpToRun(t)}
                               onMarkDone={() => requestMarkDone(t)} onRetry={() => A.retryLanding(t.id)}
                               selected={batchable(t) ? selReview.has(t.id) : undefined} onToggle={() => toggle(selReview, t.id, setSelReview)}
                               menu={menu} />
                </Removable>
              );
            })}
          </KanbanColumn>
          <KanbanColumn title="Done" icon="checkmark.circle" count={done.length} tint="var(--green)" width={w} subtitle="Landed or closed"
                        emptyText="Nothing done yet"
                        onDrop={ids => { const t = byID(ids[0]); if (t?.stage === 'testing') requestMarkDone(t); }}>
            {done.map(t => (
              <Removable key={t.id} onRemove={() => confirmRemove(t)}>
                <DoneCard t={t} st={st} ws={wsName(t.profileID)} accent={accent(t.profileID)} onOpen={() => A.openTranscript(t.id)}
                          menu={() => {
                            const b = taskBucket(t, st);
                            const m: MenuItem[] = [{ label: 'Read Transcript', action: () => A.openTranscript(t.id) }];
                            if (b && b !== 'ended' && b !== 'asleep') m.push({ label: 'Open Session', action: () => A.jumpToRun(t) });
                            if (t.pullRequestURL) m.push({ label: 'Open Pull Request', action: () => { const u = safeHref(t.pullRequestURL); if (u) window.open(u, '_blank', 'noopener'); } });
                            m.push({ separator: true }, { label: 'Remove Task', destructive: true, action: () => A.delete(t.id) });
                            return m;
                          }} />
              </Removable>
            ))}
          </KanbanColumn>
        </div>
      </div>

      {editing && (
        <TaskEditorSheet host={host} st={st} task={editing.task} isNew={editing.isNew} choices={choices}
                         siblings={editing.task.parentTaskID ? tasks.filter(x => x.parentTaskID === editing.task.parentTaskID && x.id !== editing.task.id).sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt)) : []}
                         onSave={t => {
                           remember(t); A.save(t);
                           if (t.stage === 'backlog' && t.assignment) A.assign(t.id, t.assignment);
                           setEditing(null);
                         }}
                         onPlan={t => { A.save(t); A.plan(t.id); setEditing(null); }}
                         onDelete={id => { A.delete(id); setEditing(null); }}
                         onCancel={() => setEditing(null)} />
      )}
      {assigning && (
        <AssignTaskSheet task={assigning} choices={choices} finishWithPR={finishWithPR} setFinishWithPR={setFinishWithPR}
                         onPick={a => { A.assign(assigning.id, a); setAssigning(null); }}
                         onCancel={() => setAssigning(null)} />
      )}
      {answering && <TaskAnswerSheet host={host} task={tasks.find(t => t.id === answering.id) ?? answering} onClose={() => setAnswering(null)} />}
      {batchMerge && (
        <BatchMergeSheet titles={batchMerge.map(t => t.title)} targets={[...new Set(batchMerge.map(t => landingTarget(t)).filter(Boolean) as string[])].sort()}
                         agentName={batchMerge[0] ? workerName(batchMerge[0]) : ''}
                         onCancel={() => setBatchMerge(null)}
                         onConfirm={push => {
                           const [first, ...rest] = batchMerge;
                           if (first) post(host, first.id, 'merge-batch', { with: rest.map(t => t.id), push });
                           setBatchMerge(null); setSelReview(new Set());
                         }} />
      )}
    </BoardBackdrop>
  );
}

/** Hover-revealed ✕ just outside the card's corner (RemovableCard). */
function Removable({ children, onRemove }: { children: React.ReactNode; onRemove: () => void }) {
  return (
    <div className="bd-removable">
      {children}
      <button className="bd-remove" title="Remove Task" onClick={onRemove}><SF name="xmark.circle.fill" size={14} /></button>
    </div>
  );
}

function TaskDate({ t, full }: { t: CodingTask; full?: boolean }) {
  const mod = t.updatedAt && Date.parse(t.updatedAt) - Date.parse(t.createdAt) > 1000 ? t.updatedAt : undefined;
  const tip = [`Created ${dateTimeLong(t.createdAt)}`, ...(mod ? [`Modified ${dateTimeLong(mod)}`] : [])].join('\n');
  const text = full
    ? `Created ${dateTimeLong(t.createdAt)}` + (mod ? `  ·  Modified ${dateTimeLong(mod)}` : '')
    : mod ? `Updated ${relShort(mod)}` : `Created ${relShort(t.createdAt)}`;
  return <span className="bd-date" style={full ? { fontSize: 11 } : undefined} title={tip}>{text}</span>;
}
export { TaskDate };

/** CardDateSlot: the date when it fits whole beside the chip and the controls, else nothing. */
function DateSlot({ t }: { t: CodingTask }) {
  const ref = useRef<HTMLSpanElement>(null);
  const [fits, setFits] = useState(true);
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const check = () => { const inner = el.firstElementChild as HTMLElement | null; setFits(!inner || inner.offsetWidth <= el.clientWidth + 0.5); };
    const ro = new ResizeObserver(check); ro.observe(el); check();
    return () => ro.disconnect();
  }, []);
  return <span ref={ref} className="bd-date-slot" style={{ visibility: fits ? 'visible' : 'hidden' }}><TaskDate t={t} /></span>;
}

function ErrorLine({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  return (
    <button className={cx('bd-error', open && 'open')} title={text} onClick={() => setOpen(!open)}>
      <SF name="exclamationmark.triangle.fill" size={9.5} />
      <span>{text}</span>
    </button>
  );
}

function BacklogCard({ t, st, all, ws, accent, parentTitle, onEdit, onOpenSession, onStart, onPlan, onDelete, onAssign, onUnassign }: {
  t: CodingTask; st: RemoteState; all: CodingTask[]; ws: string; accent: string; parentTitle?: string;
  onEdit: () => void; onOpenSession: () => void; onStart: () => void; onPlan: () => void; onDelete: () => void; onAssign: () => void; onUnassign: () => void;
}) {
  const planningLive = validationInFlight(t) && !!t.branchSlug;
  const untitled = !t.title.trim();
  const pos = queuePosition(t, all);
  const excerpt = plainExcerpt(t.details);
  const menu = (): MenuItem[] => {
    const m: MenuItem[] = [];
    if (planningLive) m.push({ label: 'Open Session', action: onOpenSession });
    m.push({ label: 'Edit…', action: onEdit });
    if (!untitled && !planningLive) {
      m.push({ label: 'Start', action: onStart });
      if (!validationInFlight(t)) m.push({ label: 'Plan First', action: onPlan });
    }
    m.push({ label: 'Assign…', action: onAssign });
    if (t.assignment) m.push({ label: 'Unassign', action: onUnassign });
    m.push({ separator: true }, { label: 'Remove Task', destructive: true, action: onDelete });
    return m;
  };
  void st;
  return (
    <Card tint={t.lastError ? 'var(--red)' : undefined} onClick={planningLive ? onOpenSession : onEdit} menu={menu} draggableID={t.id}>
      <div className="bd-stack" style={{ gap: 8 }}>
        <div className="bd-hrow">
          <WorkspaceChip name={ws} accent={accent} />
          <DateSlot t={t} />
          <span className="spacer" />
          {!planningLive && (
            <button className={cx('bd-assign', t.assignment && 'on')} onClick={onAssign}
                    title={t.assignment ? `Assigned to ${t.assignment.label} — click to change` : 'Who picks this task up'}>
              <SF name={t.assignment ? assignmentIcon(t.assignment) : 'person.crop.circle.badge.plus'} size={12} />
              <span className="truncate">{t.assignment ? t.assignment.label : 'Assign'}</span>
            </button>
          )}
          {planningLive ? <StatusPill text="Planning" tint="var(--blue)" spinning title="A visible planning session is running — click the task to open it; phases appear in the Plan column as it files them." />
            : t.validation ? <span title="Plan reviewed by the agent"><SF name="person.fill.checkmark" size={10} color="var(--purple)" /></span> : null}
        </div>
        <div className="bd-card-title">{untitled ? 'Untitled task' : t.title}</div>
        {excerpt && <div className="bd-excerpt l3">{excerpt}</div>}
        {parentTitle && <div className="bd-meta-line"><SF name="arrow.turn.down.right" size={10} /><span className="truncate">part of “{parentTitle}”</span></div>}
        {t.lastError && <ErrorLine text={t.lastError} />}
        {isStarting(t) ? (
          <div className="bd-hrow"><span className="spacer" /><StatusPill text="Starting…" tint="var(--blue)" spinning title="Checking the workspace and the folder — the task moves to In Progress once its agent can start." /></div>
        ) : t.assignment && pos && !t.lastError ? (
          <div className="bd-queue">
            <SF name="hourglass" size={10.5} />
            <span className="truncate">{pos === 1 ? `Next for ${t.assignment.label}` : `#${pos} in ${t.assignment.label}'s queue`}</span>
            <span className="spacer" />
            <button className="bd-link-btn" onClick={onUnassign}>Unassign</button>
          </div>
        ) : (
          <div className="bd-hrow bd-actions">
            <span className="spacer" />
            <Button size="small" disabled={untitled || validationInFlight(t)} onClick={onPlan}
                    title="A planner agent reads the task and the repository, then files ordered phases (with dependencies) in the Plan column.">Plan First</Button>
            <Button size="small" variant="prominent" icon="play.fill" disabled={untitled || planningLive} onClick={onStart}
                    title="Straight to In Progress: a new agent does the whole task in a fresh worktree and hands you the diff in Review. To give it to a session or a room, use Assign.">Start</Button>
          </div>
        )}
      </div>
    </Card>
  );
}

function PlanCard({ t, n, accent, parentTitle, deps, depsMet, selected, onToggle, onEdit, menu }: {
  t: CodingTask; n: number; accent: string; parentTitle?: string; deps: number[]; depsMet: boolean; selected: boolean;
  onToggle: () => void; onEdit: () => void; menu: () => MenuItem[];
}) {
  const excerpt = plainExcerpt(t.details);
  return (
    <Card className={cx(selected && 'selected')} onClick={onEdit} menu={menu} draggableID={t.id}>
      <div className="bd-hrow" style={{ alignItems: 'flex-start', gap: 8 }}>
        <button className="bd-check" onClick={onToggle}><SF name={selected ? 'checkmark.circle.fill' : 'circle'} size={14} color={selected ? 'var(--accent)' : 'var(--label-tertiary)'} /></button>
        <div className="bd-stack" style={{ gap: 4, flex: 1, minWidth: 0 }}>
          <div className="bd-hrow" style={{ gap: 6 }}>
            <span className="bd-num" style={{ background: accent }}>{n}</span>
            <span className="bd-card-title sm truncate">{t.title}</span>
          </div>
          {excerpt && <div className="bd-excerpt l2">{excerpt}</div>}
          <div className="bd-hrow" style={{ gap: 6 }}>
            {parentTitle && <span className="bd-meta-line xs"><SF name="arrow.turn.down.right" size={9.5} /><span className="truncate">{parentTitle}</span></span>}
            <span className="spacer" />
            {isStarting(t) ? <StatusPill text="Starting…" tint="var(--blue)" spinning />
              : t.queuedAt ? <span className="bd-queued" title="Starts automatically when its dependencies are Done.">queued</span> : null}
            {deps.length > 0 && (
              <span className="bd-deps" style={{ color: depsMet ? 'var(--label-secondary)' : 'var(--orange)' }} title="Phases that must be Done before this one starts.">
                <SF name={depsMet ? 'lock.open' : 'lock'} size={9.5} />{deps.join(',')}
              </span>
            )}
          </div>
          {t.lastError && <ErrorLine text={t.lastError} />}
        </div>
      </div>
    </Card>
  );
}

function InProgressCard({ t, st, ws, accent, onOpen, onResume, onStartOver, onMarkDone, menu }: {
  t: CodingTask; st: RemoteState; ws: string; accent: string; onOpen: () => void; onResume: () => void; onStartOver: () => void; onMarkDone: () => void; menu: () => MenuItem[];
}) {
  const [hover, setHover] = useState(false);
  const status: Bucket | null = taskBucket(t, st);
  const cant = couldntStart(t, st);
  const started = t.startedAt ? Date.parse(t.startedAt) : NaN;
  const fresh = !isNaN(started) && Date.now() - started < 300_000;
  const lost = status === 'asleep' || status === 'ended' || (status == null && (!!t.lastError || !fresh));
  let pill: React.ReactNode = null;
  if (cant) pill = <StatusPill text="Couldn't start" tint="var(--red)" icon="exclamationmark.triangle.fill" />;
  else if (status && status !== 'asleep' && status !== 'ended')
    pill = <StatusPill text={bucketTitle[status]} tint={bucketTint[status]} spinning={status === 'working'} icon={status === 'needsYou' ? 'hand.raised.fill' : undefined}
                       title={status === 'idle' ? 'The agent is waiting at its prompt without having handed the task over — open its session to see where it is.' : undefined} />;
  else if (status) pill = <StatusPill text="Paused" tint="var(--label-secondary)" icon="pause.fill" />;
  else if (t.lastError) pill = null;
  else if (fresh) pill = <StatusPill text="Starting…" tint="var(--label-secondary)" spinning />;
  else pill = <StatusPill text="Session gone" tint="var(--orange)" icon="exclamationmark" />;
  return (
    <Card tint={status === 'needsYou' || t.lastError ? 'var(--red)' : 'var(--blue)'} onClick={onOpen} menu={menu} title="Open the task's live session"
          onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}>
      <div className="bd-stack" style={{ gap: 8 }}>
        <div className="bd-hrow"><WorkspaceChip name={ws} accent={accent} /><DateSlot t={t} /><span className="spacer" />{pill}</div>
        <div className="bd-card-title">{t.title}</div>
        {t.startedAt && <div className="bd-meta-line"><SF name="clock" size={10.5} /><span className="truncate">started {relNamed(t.startedAt)}</span></div>}
        {t.lastError && <ErrorLine text={t.lastError} />}
        <div className="bd-hrow" style={{ gap: 6 }}>
          {t.restartNeeded ? <Button size="small" icon="arrow.counterclockwise" style={{ flex: 1 }} onClick={onStartOver} title="Runs the task again from scratch on a new branch.">Start Over</Button>
            : lost ? <Button size="small" icon="arrow.clockwise" style={{ flex: 1 }} onClick={onResume} title="The session is gone — boot the workspace if needed and relaunch the agent on this task's worktree.">Restart Session</Button>
            : <><span className="bd-open-link">Open Session <SF name="arrow.up.right" size={9} weight={600} /></span><span className="spacer" /></>}
          {hover && <QuickDone onClick={onMarkDone} />}
        </div>
      </div>
    </Card>
  );
}

function QuickDone({ onClick }: { onClick: () => void }) {
  return <button className="bd-quickdone" title="Mark Done" onClick={onClick}><SF name="checkmark" size={10.5} weight={700} /></button>;
}

function TestingCard({ t, ws, accent, onOpen, onOpenSession, onMarkDone, onRetry, selected, onToggle, menu }: {
  t: CodingTask; ws: string; accent: string; onOpen: () => void; onOpenSession: () => void; onMarkDone: () => void; onRetry: () => void;
  selected?: boolean; onToggle: () => void; menu: () => MenuItem[];
}) {
  const [hover, setHover] = useState(false);
  const unsent = unsentComments(t);
  const needsYou = t.landing?.phase === 'needsYou';
  const noCode = isNoCode(t);
  const quick = hover && (!t.landing || needsYou) ? <QuickDone onClick={onMarkDone} /> : null;
  let state: React.ReactNode;
  if (t.landing && !needsYou) {
    state = (
      <div className="bd-stack" style={{ gap: 3 }}>
        <div className="bd-hrow" style={{ gap: 5 }}><MiniSpinner /><span className="bd-state med l2">{landingLine(t)}</span></div>
        {t.landing.agentLine && <div className="bd-state l2" title={t.landing.agentLine}>{t.landing.agentLine}</div>}
      </div>
    );
  } else if (needsYou) {
    state = (
      <div className="bd-stack" style={{ gap: 6 }}>
        <div className="bd-state med l2" style={{ color: 'var(--red)' }} title={t.landing?.detail ?? landingLine(t) ?? ''}>{landingLine(t)}</div>
        <div className="bd-hrow" style={{ gap: 6 }}>
          <Button size="small" onClick={onRetry} title="Land it again with the same choices">Retry</Button>
          <Button size="small" onClick={onOpenSession}>Open Session</Button>
          <span className="spacer" />{quick}
        </div>
      </div>
    );
  } else if (t.lastError && !isLocating(t)) {
    state = <div className="bd-hrow" style={{ alignItems: 'flex-start', gap: 6 }}><ErrorLine text={t.lastError} /><span className="spacer" />{quick}</div>;
  } else {
    state = (
      <div className="bd-stack" style={{ gap: 6 }}>
        <div className="bd-state truncate">{isLocating(t) ? LOCATING_TEXT : noCode ? 'No code changes' : 'Ready to land'}</div>
        <div className="bd-hrow" style={{ gap: 6 }}>
          <span className="bd-review-pill"><SF name={noCode ? 'doc.text' : 'eye'} size={11} weight={600} />{noCode ? 'Read Report' : 'Review Changes'}</span>
          <span className="spacer" />{quick}
        </div>
      </div>
    );
  }
  return (
    <Card tint={needsYou ? 'var(--red)' : selected ? 'var(--accent)' : 'var(--purple)'} onClick={onOpen} menu={menu} draggableID={t.id}
          onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}>
      <div className="bd-stack" style={{ gap: 8 }}>
        <div className="bd-hrow">
          <WorkspaceChip name={ws} accent={accent} /><DateSlot t={t} /><span className="spacer" />
          {unsent > 0 && <StatusPill text={unsent === 1 ? '1 comment' : `${unsent} comments`} tint="var(--purple)" icon="text.bubble.fill" title="Draft review comments" />}
          {selected !== undefined && (selected || hover) && (
            <button className="bd-check" onClick={onToggle} title={selected ? 'Deselect' : 'Select for a batch merge'}>
              <SF name={selected ? 'checkmark.circle.fill' : 'circle'} size={14} color={selected ? 'var(--accent)' : 'var(--label-tertiary)'} />
            </button>
          )}
        </div>
        <div className="bd-card-title">{t.title}</div>
        {t.branch && !noCode && <div className="bd-meta-line mono"><SF name="arrow.triangle.branch" size={10.5} /><span className="truncate">{t.branch}</span></div>}
        {t.pullRequestURL && (
          <a className="bd-pr-link" href={safeHref(t.pullRequestURL)} target="_blank" rel="noreferrer" title={t.pullRequestURL}>
            <SF name="arrow.triangle.pull" size={11} />Pull request #{t.pullRequestURL.split('/').pop()}
          </a>
        )}
        {t.deliverySummary && (
          <div className="bd-stack" style={{ gap: 2 }}>
            {t.assignment && <div className="bd-says">{t.assignment.label} says:</div>}
            <div className="bd-excerpt l3" style={{ fontSize: 11 }}>{plainExcerpt(t.deliverySummary)}</div>
          </div>
        )}
        {state}
      </div>
    </Card>
  );
}

function DoneCard({ t, st, ws, accent, onOpen, menu }: { t: CodingTask; st: RemoteState; ws: string; accent: string; onOpen: () => void; menu: () => MenuItem[] }) {
  const c = effectiveCompletion(t);
  const glyph = c?.kind === 'merged' ? ['arrow.triangle.merge', 'var(--green)'] : c?.kind === 'prOpened' ? ['arrow.triangle.pull', 'var(--blue)']
    : c?.kind === 'markedDone' ? ['checkmark.circle', 'var(--green)'] : ['xmark.circle', 'var(--label-secondary)'];
  const closed = !c || c.kind === 'closed';
  void st;
  return (
    <Card onClick={onOpen} menu={menu} title="Read the agent's full session transcript">
      <div className="bd-hrow" style={{ alignItems: 'flex-start', gap: 9 }}>
        <span style={{ width: 18, display: 'grid', placeItems: 'center', paddingTop: 1 }}><SF name={glyph[0]} size={12} weight={600} color={glyph[1]} /></span>
        <div className="bd-stack" style={{ gap: 4, minWidth: 0, flex: 1 }}>
          <div className="bd-card-title done l2" style={closed ? { color: 'var(--label-secondary)' } : undefined} title={t.title}>{t.title}</div>
          <div className="bd-state l2">{doneText(t)}</div>
          {t.completedAt && <div className="bd-date" style={{ fontSize: 10 }}>{relNamed(t.completedAt)}</div>}
          {ws && <div><WorkspaceChip name={ws} accent={accent} /></div>}
        </div>
      </div>
    </Card>
  );
}

function AssignedCard({ t, ws, onOpen, onAnswer, onRecall }: { t: CodingTask; ws: string; onOpen: () => void; onAnswer: () => void; onRecall: () => void }) {
  void ws;
  return (
    <Card tint={t.pendingQuestion ? 'var(--red)' : 'var(--indigo)'} onClick={onOpen} title="Show the session working on it"
          menu={() => [
            { label: 'Open Session', action: onOpen },
            ...(t.pendingQuestion ? [{ label: 'Answer…', action: onAnswer }] : []),
            { separator: true }, { label: 'Stop & Return to Backlog', destructive: true, action: onRecall },
          ]}>
      <div className="bd-stack" style={{ gap: 8 }}>
        <div className="bd-hrow">
          <span className="bd-assignee"><SF name={t.assignment?.kind === 'session' ? 'person.crop.circle.fill' : assignmentIcon(t.assignment)} size={10.5} /><span className="truncate">{t.assignment?.label}</span></span>
          <TaskDate t={t} /><span className="spacer" />
          {t.pendingQuestion ? <StatusPill text="Question" tint="var(--red)" icon="questionmark" />
            : !t.delegationID ? <StatusPill text="Handing over" tint="var(--label-secondary)" spinning />
            : <StatusPill text="Working" tint="var(--blue)" spinning />}
        </div>
        <div className="bd-card-title">{t.title}</div>
        {t.pendingQuestion ? (
          <div className="bd-question">
            <div className="l5">{t.pendingQuestion}</div>
            <Button size="small" variant="prominent" destructive icon="arrowshape.turn.up.left.fill" style={{ width: '100%' }} onClick={onAnswer}>Answer…</Button>
          </div>
        ) : t.assigneeNote ? <div className="bd-meta-line l3" style={{ fontSize: 11 }}><SF name="text.bubble" size={11} /><span>{t.assigneeNote}</span></div> : null}
        {t.lastError && <div className="bd-state l2" style={{ color: 'var(--red)' }} title={t.lastError}>{t.lastError}</div>}
      </div>
    </Card>
  );
}

export function useTasks(host: RemoteHost) {
  const tasks = useRemote(host, s => s.tasks);
  return useMemo(() => ((tasks?.tasks ?? []) as CodingTask[]), [tasks]);
}
