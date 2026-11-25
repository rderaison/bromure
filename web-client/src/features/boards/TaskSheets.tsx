// The coding board's sheets: the task editor (TaskEditorSheet), "Who picks
// this up?" (AssignTaskSheet), the assignee's question (TaskAnswerSheet) and
// the batch merge confirmation (BatchMergeSheet).

import React, { useEffect, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import type { RemoteState } from '../../core/remote/types';
import { SF } from '../../ui/icons';
import { Button, Checkbox, Popover, Segmented, Sheet, Spinner, cx, useMenu, type MenuItem } from '../../ui/kit';
import { isMod } from '../../platform';
import { type CodingTask, type Assignment, assignmentIcon, toolName, NEW_AGENT, SWITCHBOARD, workspaceOf, isDemo } from './model';
import { Markdown } from './Markdown';
import { TaskDate } from './TaskBoard';
import { PrimaryButton } from './kanban';

export interface Choices {
  sessions: { id: string; label: string; workspace: string; busy: boolean; profileID?: string }[];
  rooms: { id: string; name: string }[];
}

export function assigneeChoices(st: RemoteState): Choices {
  const byName = (a: string, b: string) => a.replace(/^@/, '').localeCompare(b.replace(/^@/, ''), undefined, { numeric: true, sensitivity: 'base' });
  const sessions = (st.agentSessions ?? [])
    .filter(s => !s.archivedAt && !(s as any).deletedAt && (s as any).role !== 'switchboard')
    .slice(0, 40)
    .map(s => ({ id: s.id, label: s.nickname ? '@' + s.nickname : s.title, workspace: workspaceOf(st, s.profileID)?.name ?? '', busy: false, profileID: s.profileID }))
    .sort((a, b) => byName(a.label, b.label) || a.workspace.localeCompare(b.workspace));
  const rooms = (st.agentRooms ?? []).filter(r => !(r as any).archivedAt).map(r => ({ id: r.id, name: r.name })).sort((a, b) => byName(a.name, b.name));
  void isDemo;
  return { sessions, rooms };
}

/** A title from the first words of a description (AgentSession.title(fromMessage:)). */
function titleFrom(details: string) {
  const first = details.trim().split(/\r?\n/).find(l => l.trim())?.replace(/^[#>*\-+\s]+/, '').trim() ?? '';
  return first.length > 60 ? first.slice(0, 57).replace(/\s+\S*$/, '') + '…' : first;
}
const titled = (t: CodingTask): CodingTask => t.title.trim() ? t : { ...t, title: titleFrom(t.details) };

export function TaskEditorSheet({ host, st, task: initial, isNew, siblings, choices, onSave, onPlan, onDelete, onCancel }: {
  host: RemoteHost; st: RemoteState; task: CodingTask; isNew: boolean; siblings: CodingTask[]; choices: Choices;
  onSave: (t: CodingTask) => void; onPlan: (t: CodingTask) => void; onDelete: (id: string) => void; onCancel: () => void;
}) {
  const [t, setT] = useState<CodingTask>(initial);
  const [preview, setPreview] = useState(false);
  const [folderAnchor, setFolderAnchor] = useState<DOMRect | null>(null);
  const openMenu = useMenu();
  const titleRef = useRef<HTMLTextAreaElement>(null);
  void host;
  useEffect(() => { if (isNew) titleRef.current?.focus(); }, [isNew]);
  const ws = st.workspaces ?? [];
  const profile = ws.find(w => w.id === t.profileID);
  const tools = (profile?.readyTools?.map(x => x.tool) ?? [profile?.tool ?? 'claude']).filter((x, i, a) => a.indexOf(x) === i);
  const canSave = !!profile && !!titled(t).title.trim();
  const decided = t.assignment && t.assignment.kind !== 'worktree' ? t.assignment : undefined;
  const set = (p: Partial<CodingTask>) => setT(x => ({ ...x, ...p }));

  useEffect(() => {
    const on = (e: KeyboardEvent) => { if (isMod(e) && e.key === 'Enter' && canSave) { e.preventDefault(); onSave(titled(t)); } };
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  }, [t, canSave, onSave]);

  const chip = (icon: string, text: string, onClick: (e: React.MouseEvent) => void, opts?: { tint?: string; active?: boolean; disabled?: boolean; title?: string }) => (
    <button className={cx('bx-te-chip', opts?.active && 'active')} disabled={opts?.disabled} title={opts?.title}
            style={opts?.tint ? { ['--chip' as any]: opts.tint } : undefined} onClick={onClick}>
      <SF name={icon} size={11} weight={600} /><span className="truncate">{text}</span><SF name="chevron.down" size={8} weight={700} style={{ opacity: 0.6 }} />
    </button>
  );
  const assigneeMenu = (e: React.MouseEvent) => {
    const items: MenuItem[] = [
      { label: 'Unassigned — I\'ll start it', icon: 'tray', action: () => set({ assignment: undefined }) },
      { label: 'A new agent (in its own worktree)', icon: 'arrow.triangle.branch', action: () => set({ assignment: NEW_AGENT }) },
      { label: 'The Switchboard — it picks a session', icon: 'switch.2', action: () => set({ assignment: SWITCHBOARD }) },
    ];
    if (choices.sessions.length) {
      items.push({ separator: true }, { header: 'Sessions' });
      for (const s of choices.sessions) items.push({ label: s.label + (s.workspace ? '  ·  ' + s.workspace : ''), icon: 'person.crop.circle', action: () => set({ assignment: { kind: 'session', id: s.id, label: s.label }, ...(s.profileID ? { profileID: s.profileID } : {}) }) });
    }
    if (choices.rooms.length) {
      items.push({ separator: true }, { header: 'Rooms' });
      for (const r of choices.rooms) items.push({ label: '#' + r.name, icon: 'square.grid.2x2', action: () => set({ assignment: { kind: 'room', id: r.id, label: '#' + r.name } }) });
    }
    openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), items);
  };
  const finishLabel = (f?: string) => f === 'pullRequest' ? 'Open a pull request' : 'Merge into the branch';

  return (
    <Sheet width={720} onClose={onCancel}>
      <div className="bx-te">
        <div className="bx-te-top">
          <span className="bx-te-kind"><SF name={isNew ? 'plus.circle.fill' : 'pencil.circle.fill'} size={12} />{isNew ? 'New Task' : 'Edit Task'}</span>
          <span className="spacer" />
          {!isNew && <TaskDate t={t} full />}
          {t.stage !== 'backlog' && <span className="bx-te-stage">{t.stage[0].toUpperCase() + t.stage.slice(1)}</span>}
        </div>
        <textarea ref={titleRef} className="bx-te-title" rows={1} value={t.title}
                  placeholder={!t.title && titled(t).title ? titled(t).title : 'What needs doing?'}
                  onChange={e => set({ title: e.target.value.replace(/\n/g, ' ') })} />
        <div className="bx-te-chips">
          {t.stage === 'backlog' && chip(t.assignment ? assignmentIcon(t.assignment) : 'person.crop.circle.badge.plus',
            t.assignment ? `Assigned to ${t.assignment.label}` : 'Unassigned', assigneeMenu, { tint: 'var(--indigo)', active: !!t.assignment, title: 'Who picks it up' })}
          <span className={cx('bx-te-chip-group', decided && 'decided')} title={decided ? `${decided.label} works in its own workspace and folder, with its own agent` : undefined}>
            {chip('macwindow', profile?.name ?? 'Workspace', e => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(),
              ws.map(w => ({ label: w.name, action: () => set({ profileID: w.id, tool: (w.readyTools?.some(x => x.tool === t.tool) ? t.tool : w.tool) }) }))), { disabled: !!decided, title: 'Workspace' })}
            {chip('cpu', toolName(t.tool), e => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(),
              tools.map(x => ({ label: toolName(x), action: () => set({ tool: x }) }))), { disabled: !!decided, title: 'Agent' })}
            {chip('folder', t.repoPath || '~', e => setFolderAnchor((e.currentTarget as HTMLElement).getBoundingClientRect()), { disabled: !!decided, title: 'Start the agent in — a folder inside the workspace' })}
          </span>
        </div>
        {t.lastError && !isNew && <div className="bx-te-error"><SF name="exclamationmark.triangle.fill" size={11} /><span>{t.lastError}</span></div>}
        <div className="bx-te-options">
          {!decided && (
            <span title="Make the folder and an empty git repository when they don't exist yet — tasks run on their own branch.">
              <Checkbox checked={!!t.initRepo} onChange={v => set({ initRepo: v ? true : undefined })}>Create folder &amp; git repo if needed</Checkbox>
            </span>
          )}
          <span className="bx-te-finish" title="What happens when you approve the task in Review: merged into the branch it came from, or opened as a pull request.">
            When a task is approved
            <button className="bx-te-menu" onClick={e => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
              { label: `Workspace default (${finishLabel((profile as any)?.taskFinish)})`, checked: !t.finish, action: () => set({ finish: undefined }) },
              { label: 'Merge into the branch', checked: t.finish === 'merge', action: () => set({ finish: 'merge' }) },
              { label: 'Open a pull request', checked: t.finish === 'pullRequest', action: () => set({ finish: 'pullRequest' }) },
            ])}>
              {t.finish ? finishLabel(t.finish) : `Workspace default (${finishLabel((profile as any)?.taskFinish)})`}
              <SF name="chevron.up.chevron.down" size={9} weight={600} />
            </button>
          </span>
        </div>
        <div className="bx-te-desc">
          <div className="bx-te-desc-head">
            <span>Description</span><span className="spacer" />
            <Segmented value={preview ? 'p' : 'w'} onChange={v => setPreview(v === 'p')} options={[{ value: 'w', label: 'Write' }, { value: 'p', label: 'Preview' }]} />
          </div>
          {preview ? <div className="bx-te-preview"><Markdown text={t.details} /></div>
            : <textarea className="bx-te-details" value={t.details} onChange={e => set({ details: e.target.value })}
                        placeholder="Describe the task — what's wrong, where, what done looks like. Markdown welcome." />}
        </div>
        {!isNew && (t.mergeReport || t.deliverySummary || t.assigneeNote) && (
          <div className="bx-te-says">
            <div className="bx-te-says-head"><SF name="text.bubble" size={11.5} />{(t.assignment?.label ?? 'The agent')} says</div>
            <div className="bx-te-says-body"><Markdown compact text={String(t.mergeReport ?? t.deliverySummary ?? t.assigneeNote)} /></div>
          </div>
        )}
        {siblings.length > 0 && (
          <div className="bx-te-deps">
            <div className="bx-te-label">Depends on — phases that must finish first</div>
            <div className="bx-te-dep-row">
              {siblings.map(s => {
                const on = !!t.dependsOn?.includes(s.id);
                return (
                  <button key={s.id} className={cx('bx-te-dep', on && 'on', s.stage === 'done' && 'done')} onClick={() => {
                    let deps = (t.dependsOn ?? []).filter(x => x !== s.id);
                    if (!on) deps.push(s.id);
                    deps = deps.sort((a, b) => siblings.findIndex(x => x.id === a) - siblings.findIndex(x => x.id === b));
                    set({ dependsOn: deps.length ? deps : undefined });
                  }}>
                    <SF name={s.stage === 'done' ? 'checkmark.circle.fill' : on ? 'lock.fill' : 'circle'} size={11} />
                    <span className="truncate">{s.title}</span>
                  </button>
                );
              })}
            </div>
          </div>
        )}
        <div className="bx-te-footer">
          {!isNew && <Button size="large" destructive icon="trash" title="Remove Task" onClick={() => onDelete(t.id)} />}
          <span className="bx-te-hint">
            {t.assignment ? (t.assignment.kind === 'worktree' ? 'A new agent picks it up from the queue and takes it to Review.' : `${t.assignment.label} picks it up on its own and takes it to Review.`)
              : 'Start it from the board, or Plan First to split it into phases.'}
          </span>
          <span className="spacer" />
          {t.stage === 'backlog' && !t.assignment && (
            <Button size="large" icon="list.number" disabled={!canSave} onClick={() => onPlan(titled(t))}
                    title="Saves, then opens a visible planning session: the agent explores the repo (ask it things — it can see you) and files ordered phases with dependencies into the Plan column.">Plan First</Button>
          )}
          <Button size="large" onClick={onCancel}>Cancel</Button>
          <PrimaryButton disabled={!canSave} onClick={() => onSave(titled(t))} title="⌘↩"><span style={{ padding: '0 6px' }}>{isNew ? 'Add Task' : 'Save'}</span></PrimaryButton>
        </div>
      </div>
      {folderAnchor && (
        <Popover anchor={folderAnchor} onClose={() => setFolderAnchor(null)} width={380}>
          <div className="bx-te-folder">
            <div className="bx-te-label">Start the agent in — a folder inside the workspace</div>
            <input className="field mono" value={t.repoPath} placeholder="~/my-repo" onChange={e => set({ repoPath: e.target.value })} autoFocus />
            <div className="bx-te-label">Clone this repository first (optional)</div>
            <input className="field mono" value={String(t.cloneURL ?? '')} placeholder="https://github.com/org/repo.git"
                   title="Optional: clone this git repository into the folder above before the first start, using the workspace's git credentials. Skipped when the folder already holds a repository."
                   onChange={e => set({ cloneURL: e.target.value.trim() ? e.target.value : undefined })} />
            <Checkbox checked={!!t.initRepo} onChange={v => set({ initRepo: v ? true : undefined })}>Create folder &amp; git repo if needed</Checkbox>
          </div>
        </Popover>
      )}
    </Sheet>
  );
}

export function AssignTaskSheet({ task, choices, finishWithPR, setFinishWithPR, onPick, onCancel }: {
  task: CodingTask; choices: Choices; finishWithPR: boolean; setFinishWithPR: (v: boolean) => void;
  onPick: (a: Assignment | null) => void; onCancel: () => void;
}) {
  const [query, setQuery] = useState('');
  const q = query.trim().toLowerCase().replace(/^[@#]+|[@#]+$/g, '');
  const sessions = q ? choices.sessions.filter(s => s.label.toLowerCase().includes(q) || s.workspace.toLowerCase().includes(q)) : choices.sessions;
  const rooms = q ? choices.rooms.filter(r => r.name.toLowerCase().includes(q)) : choices.rooms;
  const a = task.assignment;
  const row = (icon: string, tint: string, title: string, sub: string, selected: boolean, pick: () => void) => (
    <button className={cx('bx-as-row', selected && 'selected')} onClick={pick}>
      <span className="bx-as-icon" style={{ color: tint }}><SF name={icon} size={16} /></span>
      <span className="bx-as-text"><span className="bx-as-title truncate">{title}</span>{sub && <span className="bx-as-sub truncate">{sub}</span>}</span>
      {selected && <SF name="checkmark" size={13} color="var(--accent)" />}
    </button>
  );
  return (
    <Sheet width={440} height={480} onClose={onCancel}>
      <div className="bx-as">
        <div className="bx-as-head">
          <div className="bx-as-h1">Who picks this up?</div>
          <div className="bx-as-h2 truncate">{task.title}</div>
        </div>
        <div className="bx-as-search">
          <SF name="magnifyingglass" size={13} color="var(--label-secondary)" />
          <input autoFocus value={query} placeholder="@nickname or #room" onChange={e => setQuery(e.target.value)}
                 onKeyDown={e => {
                   if (e.key !== 'Enter') return;
                   if (sessions[0]) onPick({ kind: 'session', id: sessions[0].id, label: sessions[0].label });
                   else if (rooms[0]) onPick({ kind: 'room', id: rooms[0].id, label: '#' + rooms[0].name });
                 }} />
        </div>
        <div className="bx-as-list">
          {!q && row('arrow.triangle.branch', 'var(--blue)', 'A new agent', 'In its own fresh worktree — queued with the other new-agent tasks', a?.kind === 'worktree', () => onPick(NEW_AGENT))}
          {(!q || 'switchboard'.startsWith(q)) && row('switch.2', 'var(--orange)', '@switchboard', "The app's Switchboard picks the session best placed for it", a?.kind === 'switchboard', () => onPick(SWITCHBOARD))}
          {sessions.length > 0 && <div className="bx-as-section">Sessions</div>}
          {sessions.map(s => <React.Fragment key={s.id}>{row('person.crop.circle.fill', 'var(--indigo)', s.label, [s.workspace, s.busy ? 'busy — it takes this after its current work' : ''].filter(Boolean).join(' · '),
            a?.kind === 'session' && a.id === s.id, () => onPick({ kind: 'session', id: s.id, label: s.label }))}</React.Fragment>)}
          {rooms.length > 0 && <div className="bx-as-section">Rooms</div>}
          {rooms.map(r => <React.Fragment key={r.id}>{row('square.grid.2x2.fill', 'var(--teal)', '#' + r.name, "The room's Switchboard picks a member",
            a?.kind === 'room' && a.id === r.id, () => onPick({ kind: 'room', id: r.id, label: '#' + r.name }))}</React.Fragment>)}
          {!sessions.length && !rooms.length && q && <div className="bx-as-empty">No session or room matches.</div>}
          {!choices.sessions.length && !q && <div className="bx-as-empty small">No sessions yet — start one, give it a @nickname, and it can take tasks from the board.</div>}
        </div>
        <div className="bx-as-foot">
          <span title="Off: the session or room hands its branch back for your review, and lands it once you approve. On: it pushes and opens a pull request before the task moves to Review.">
            <Checkbox checked={finishWithPR} onChange={setFinishWithPR}><span style={{ fontSize: 11.5 }}>Open a pull request at delivery (skips review)</span></Checkbox>
          </span>
          <span className="spacer" />
          {a && <Button onClick={() => onPick(null)}>Unassign</Button>}
          <span className="spacer" />
          <Button onClick={onCancel}>Cancel</Button>
        </div>
      </div>
    </Sheet>
  );
}

interface Dropped { name: string; data: string; isImage: boolean; size: number }
const ANSWER_LIMIT = 11 * 1024 * 1024;

export function TaskAnswerSheet({ host, task, onClose }: { host: RemoteHost; task: CodingTask; onClose: () => void }) {
  const [reply, setReply] = useState('');
  const [askID] = useState(task.pendingAskID);
  const [edited, setEdited] = useState(false);
  const [files, setFiles] = useState<Dropped[]>([]);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [over, setOver] = useState(false);
  const stale = !edited && askID !== task.pendingAskID;
  const total = files.reduce((n, f) => n + f.size, 0);
  const overLimit = total > ANSWER_LIMIT;
  const canSend = (!!reply.trim() || files.length > 0) && !stale && !sending && !overLimit;
  const send = async () => {
    if (!canSend) return;
    setSending(true); setError(null);
    const body: any = { text: reply.trim() };
    if (task.pendingAskID) body.ask = task.pendingAskID;
    if (files.length) body.attachments = files.map(f => ({ name: f.name, data: f.data, isImage: f.isImage }));
    try {
      const r = await host.request('POST', `/tasks/${seg(task.id)}/answer`, body, { timeoutMs: 180_000 } as any);
      if (r?.ok === true) { onClose(); return; }
      setError(r?.error ?? task.lastError ?? "The answer couldn't be sent.");
    } catch (e: any) { setError(e?.message ?? "The answer couldn't be sent."); }
    setSending(false);
  };
  const addFiles = async (list: FileList) => {
    const out: Dropped[] = [];
    for (const f of Array.from(list)) {
      const buf = new Uint8Array(await f.arrayBuffer());
      let s = ''; for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode(...buf.subarray(i, i + 0x8000));
      out.push({ name: f.name, data: btoa(s), isImage: f.type.startsWith('image/'), size: buf.length });
    }
    setFiles(x => [...x, ...out]);
  };
  return (
    <Sheet width={640} height={560} onClose={onClose}>
      <div className={cx('bx-ans', over && 'drop')} onDragOver={e => { e.preventDefault(); setOver(true); }} onDragLeave={() => setOver(false)}
           onDrop={e => { e.preventDefault(); setOver(false); if (e.dataTransfer.files.length) addFiles(e.dataTransfer.files); }}
           onKeyDown={e => { if (isMod(e as any) && e.key === 'Enter') { e.preventDefault(); send(); } }}>
        <div>
          <div className="bx-as-h1"><SF name="questionmark.bubble.fill" size={15} /> {task.assignment?.label ?? 'The agent'} asks</div>
          <div className="bx-as-h2 l2">{task.title}</div>
        </div>
        <div className="bx-ans-q"><Markdown text={task.pendingQuestion ?? ''} /></div>
        <div className="bd-stack" style={{ gap: 6 }}>
          <div className="bx-te-label" style={{ fontSize: 12 }}>Your answer</div>
          <textarea className="bx-ans-input" autoFocus value={reply} onChange={e => { setReply(e.target.value); setEdited(true); }} />
          {files.length === 0 ? <div className="bx-ans-hint"><SF name="paperclip" size={11} /> Drop files here to send them with your answer</div>
            : <div className="bx-ans-files">{files.map((f, i) => <span key={i} className="pill">{f.name}<button className="bd-link-btn" onClick={() => setFiles(x => x.filter((_, j) => j !== i))}><SF name="xmark" size={9} /></button></span>)}</div>}
          {overLimit && <div className="bx-ans-err"><SF name="exclamationmark.circle.fill" size={11} /> Too large to send from here: up to 11 MB of files.</div>}
          {stale ? <div className="bx-ans-err" style={{ color: 'var(--orange)' }}><SF name="exclamationmark.triangle.fill" size={11} /> The agent asked a new question since you wrote this. Change your answer to send it.</div>
            : error && <div className="bx-ans-err"><SF name="exclamationmark.circle.fill" size={11} /> {error}</div>}
        </div>
        <div className="bd-hrow" style={{ gap: 8 }}>
          <span className="tertiary" style={{ fontSize: 11 }}>⌘↩ to send</span>
          <span className="spacer" />
          {sending && <Spinner />}
          <Button onClick={onClose}>Cancel</Button>
          <Button variant="prominent" disabled={!canSend} onClick={send}>Send</Button>
        </div>
      </div>
    </Sheet>
  );
}

export function BatchMergeSheet({ titles, targets, agentName, onCancel, onConfirm }: {
  titles: string[]; targets: string[]; agentName: string; onCancel: () => void; onConfirm: (push: boolean) => void;
}) {
  return (
    <Sheet width={460} onClose={onCancel}>
      <div className="bx-bm">
        <div className="bx-bm-title">Merge {titles.length} tasks?</div>
        <div className="bx-bm-text">Into {targets.join(', ')}. Bromure merges each one directly when it can; the others go to one agent — {agentName} — which merges them all, fixes conflicts and runs the tests once. Afterwards the branches are removed and the sessions archived.</div>
        <div className="bx-bm-list">{titles.map((t, i) => <div key={i}>• {t}</div>)}</div>
        <div className="bd-hrow" style={{ gap: 8, justifyContent: 'flex-end', flexWrap: 'wrap' }}>
          <Button onClick={onCancel}>Cancel</Button>
          <Button variant="prominent" onClick={() => onConfirm(false)}>Merge</Button>
          <Button onClick={() => onConfirm(true)}>Merge &amp; Push</Button>
        </div>
      </div>
    </Sheet>
  );
}
