// SessionReviewWindow.swift (ReviewView): what a session's agent changed —
// files on the left (viewed marks, comment counts), the whole diff on the
// right, against a chosen base (Since <parent> / Uncommitted / Last commit).
// Comments pin to a line, a file or the whole change and live on the
// server's session record until sent to the agent in one message.

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import type { AgentSession } from '../../core/remote/types';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { Button, Spinner, TextField, cx, useTooltip } from '../../ui/kit';
import { isMod } from '../../platform';
import { Unavailable, SF } from './parts';
import { baseKey, fingerprint, parseReview, patchOf, sessionReviewCommand, type Base, type DiffFile, type ReviewData } from './reviewData';
import { accentOf, copyText, guestPath, prettyGuestPath } from './util';
import { actions } from './actions';
import type { WindowsAPI } from './index';
import './machines.css';

interface Comment { id: string; text: string; file?: string; line?: number; createdAt?: string; sentAt?: string; undelivered?: boolean }

const isBranch = (s?: AgentSession) => !!(s?.worktreeBranch as string | undefined);

export function ReviewView({ host, sessionID, files: focusFiles, since }: { host: RemoteHost; sessionID: string; files?: string[]; since?: Date }) {
  const { select, setViewMode } = useHostCtx();
  const s = useRemote(host, st => st.agentSessions?.find(x => x.id === sessionID));
  const ws = useRemote(host, st => s ? st.workspaces?.find(w => w.id.toUpperCase() === s.profileID.toUpperCase()) : undefined);
  const a = actions(host);
  const parent = s?.branchParent as string | undefined;
  const bases = useMemo(() => {
    const out: { base: Base; label: string }[] = [];
    if (since) out.push({ base: { kind: 'since', at: since }, label: 'This turn' });
    if (isBranch(s) && parent) out.push({ base: { kind: 'branch', parent }, label: `Since ${parent}` });
    out.push({ base: { kind: 'uncommitted' }, label: 'Uncommitted' }, { base: { kind: 'lastCommit' }, label: 'Last commit' });
    return out;
  }, [s?.worktreeBranch, parent, since]); // eslint-disable-line
  const [base, setBase] = useState<Base>(() => since ? { kind: 'since', at: since } : isBranch(s) && parent ? { kind: 'branch', parent } : { kind: 'uncommitted' });
  const [data, setData] = useState<ReviewData | null>(null);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const [showAll, setShowAll] = useState(!focusFiles);
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [draftFile, setDraftFile] = useState<string | null>(null);
  const ticket = useRef(0);
  const scroller = useRef<HTMLDivElement>(null);
  const tip = useTooltip();

  const load = useCallback(async (quiet = false, b: Base = base) => {
    if (!s) return;
    const t = ++ticket.current;
    if (!quiet) { setLoading(true); setFailed(false); }
    const fetch = async () => {
      try { return parseReview(await host.guestExec(s.profileID, sessionReviewCommand(guestPath(s.cwd), b, focusFiles ?? []), 30)); }
      catch { return null; }
    };
    let got = await fetch();
    if (!got) { await new Promise(r => setTimeout(r, 400)); got = await fetch(); }
    if (t !== ticket.current) return;
    setLoading(false);
    if (got) { setData(got); setFailed(false); } else if (!quiet) { setData(null); setFailed(true); }
  }, [host, s?.profileID, s?.cwd, base, focusFiles]); // eslint-disable-line
  useEffect(() => { void load(); }, [baseKey(base), s?.id]); // eslint-disable-line
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (isMod(e) && e.key.toLowerCase() === 'r') { e.preventDefault(); void load(); }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [load]);

  if (!s) return <div className="rv-root"><Unavailable icon="doc.text.magnifyingglass" title="Session removed" /></div>;

  const comments = ((s.reviewComments as Comment[]) ?? []);
  const viewedMap = (s.reviewViewed as Record<string, string>) ?? {};
  const drafts = comments.filter(c => !c.sentAt);
  const all = data?.files ?? [];
  const visible = showAll || !focusFiles?.length ? all : all.filter(f => focusFiles.some(w => { const e = w.replace(/^\.\//, ''); return e === f.path || e.endsWith('/' + f.path); }));
  const isViewed = (f: DiffFile) => viewedMap[f.path] === fingerprint(f);
  const viewedCount = visible.filter(isViewed).length;
  const setViewed = (path: string, fp: string | null) => a.session(sessionID, 'review', fp ? { op: 'viewed', path, fingerprint: fp } : { op: 'viewed', path });
  const addComment = (text: string, file?: string | null, line?: number) => {
    const body: Record<string, unknown> = { op: 'add', text };
    if (file) body.file = file;
    if (line != null) body.line = line;
    a.session(sessionID, 'review', body);
  };
  const send = () => { if (drafts.length) a.session(sessionID, 'review', { op: 'send' }); };
  const sendLabel = drafts.length === 0 ? 'Send to Agent' : drafts.length === 1 ? 'Send 1 Comment to Agent' : `Send ${drafts.length} Comments to Agent`;
  const accent = accentOf(ws);
  const untracked = data?.statusLines.filter(l => l.startsWith('??')).length ?? 0;
  const merge = s.branchMerge as any;

  const commit = () => { const t = draft.trim(); if (!t) return; addComment(t, draftFile); setDraft(''); setDraftFile(null); };

  return (
    <div className="rv-root">
      <div className="rv-bar" style={{ padding: '9px 14px' }}>
        <span style={{ width: 4, height: 34, borderRadius: 2, background: accent, flexShrink: 0 }} />
        <span className="mc-col" style={{ gap: 2, minWidth: 0 }}>
          <span className="mc-ellipsis" style={{ fontSize: 14, fontWeight: 700 }}>{s.title}</span>
          <span className="mc-row mc-secondary mc-ellipsis" style={{ gap: 6, fontSize: 11 }}>
            {isBranch(s) ? <>
              <SF name="arrow.triangle.branch" size={11} /><span style={{ fontFamily: 'var(--font-mono)' }}>{s.worktreeBranch as string}</span>
              {parent && <><SF name="arrow.right" size={8} className="mc-tertiary" /><span style={{ fontFamily: 'var(--font-mono)' }}>{parent}</span></>}
            </> : <><SF name="folder" size={11} /><span style={{ fontFamily: 'var(--font-mono)' }}>{prettyGuestPath(guestPath(s.cwd))}</span></>}
            {ws?.name && <span className="mc-tertiary">· {ws.name}</span>}
          </span>
        </span>
        <span className="mc-spacer" />
        <div className="mc-seg" {...tip.bind('What the changes are compared against')}>
          {bases.map(o => <button key={baseKey(o.base)} className={cx(baseKey(o.base) === baseKey(base) && 'on')} onClick={() => setBase(o.base)}>{o.label}</button>)}
        </div>
        <Button icon="arrow.clockwise" title="Refresh the diff" onClick={() => void load()} />
        <Button icon="doc.on.doc" title="Copy the whole diff shown here as a patch" disabled={!visible.length} onClick={() => copyText(patchOf(visible))} />
        <Button onClick={() => { select({ kind: 'session', sessionID }); setViewMode('terminal'); }}>Open Terminal</Button>
        {isBranch(s) && merge?.phase !== 'merged' && (merge && merge.phase !== 'failed' && merge.phase !== 'requested'
          ? <span className="mc-row mc-secondary" style={{ gap: 6, fontSize: 12, fontWeight: 500, padding: '5px 10px', borderRadius: 999, background: 'rgba(var(--mc-ink-rgb), 0.05)' }}><Spinner size={12} />{merge.detail ?? 'Merging…'}</span>
          : (s.branchInfo as any)?.ahead === 0 && (s.branchInfo as any)?.changed === 0 ? null
          : <Button className="mc-btn-bordered" icon="arrow.triangle.merge" title={`Merge this branch into ${parent ?? 'parent'}, then remove its checkout. Uncommitted work or a conflict is handed to the agent to finish.`}
                    onClick={() => a.session(sessionID, 'branch-merge', { squash: false, removeAfter: true })}>{merge?.phase === 'failed' ? 'Retry Merge' : `Merge into ${parent ?? 'parent'}`}</Button>)}
      </div>

      <div className="rv-split">
        <div className="rv-files">
          <div className="mc-col" style={{ padding: 10, gap: 6 }}>
            <div className="mc-row">
              <span style={{ fontSize: 12, fontWeight: 600 }}>{!data || (loading && !visible.length) ? 'Files' : visible.length === 1 ? '1 file' : `${visible.length} files`}</span>
              <span className="mc-spacer" />
              {visible.length > 0 && <span className="mc-secondary mc-num" style={{ fontSize: 11 }}>{viewedCount} of {visible.length} viewed</span>}
            </div>
            {visible.length > 0 && <div className="rv-progress"><span style={{ width: `${(viewedCount / visible.length) * 100}%`, background: viewedCount === visible.length ? 'var(--green)' : 'var(--accent)' }} /></div>}
            {!!focusFiles?.length && (
              <div className="mc-row" style={{ gap: 6, fontSize: 11 }}>
                <SF name="line.3.horizontal.decrease.circle.fill" size={12} color="var(--accent)" />
                <span>{showAll ? 'All changes' : 'Changed in this turn'}</span>
                <span className="mc-spacer" />
                <Button variant="link" onClick={() => setShowAll(v => !v)}>{showAll ? 'This turn' : 'Show all'}</Button>
              </div>
            )}
          </div>
          <div className="mc-divider" />
          <div className="mc-scroll" style={{ padding: 6 }}>
            {visible.map(f => {
              const v = isViewed(f);
              const n = comments.filter(c => c.file === f.path).length;
              const i = f.path.lastIndexOf('/');
              return (
                <div key={f.path} className={cx('rv-file', selected === f.path && 'sel')} title={f.path}
                     onClick={() => { setSelected(f.path); document.getElementById('rv-' + f.path)?.scrollIntoView({ behavior: 'smooth', block: 'start' }); }}>
                  <button className="mc-icon-btn" title={v ? 'Viewed — click to unmark' : 'Mark as viewed'} onClick={e => { e.stopPropagation(); setViewed(f.path, v ? null : fingerprint(f)); }}>
                    <SF name={v ? 'checkmark.circle.fill' : 'circle'} size={13} color={v ? 'var(--green)' : 'color-mix(in srgb, var(--label-secondary) 60%, transparent)'} />
                  </button>
                  <span className="mc-col" style={{ minWidth: 0, flex: 1 }}>
                    <span className="mc-ellipsis" style={{ fontWeight: selected === f.path ? 600 : 400, color: v ? 'var(--label-secondary)' : undefined }}>{f.path.slice(i + 1)}</span>
                    {i > 0 && <span className="mc-tertiary mc-ellipsis" style={{ fontSize: 10, direction: 'rtl', textAlign: 'left' }}><bdi>{f.path.slice(0, i)}</bdi></span>}
                  </span>
                  {n > 0 && <span className="mc-row" style={{ gap: 2, fontSize: 10, color: 'var(--purple)' }}><SF name="text.bubble.fill" size={10} />{n}</span>}
                  <span className="mc-num" style={{ fontSize: 10.5, color: 'var(--green)' }}>+{f.added}</span>
                  <span className="mc-num" style={{ fontSize: 10.5, color: 'var(--red)' }}>−{f.removed}</span>
                </div>
              );
            })}
          </div>
          {data && (data.logLines.length > 0 || untracked > 0) && <>
            <div className="mc-divider" />
            <div className="mc-col mc-secondary" style={{ padding: 10, gap: 3 }}>
              {data.logLines.length > 0 && <>
                <span className="mc-row" style={{ gap: 5, fontSize: 11, fontWeight: 600 }}><SF name="point.topleft.down.curvedto.point.bottomright.up" size={11} />{data.logLines.length === 1 ? '1 commit' : `${data.logLines.length} commits`}</span>
                {data.logLines.slice(0, 6).map(l => <span key={l} className="mc-ellipsis" style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5 }}>{l}</span>)}
              </>}
              {untracked > 0 && base.kind !== 'lastCommit' && <span className="mc-row" style={{ gap: 5, fontSize: 11 }}><SF name="plus.square.dashed" size={11} />{untracked === 1 ? '1 new file not added to git yet' : `${untracked} new files not added to git yet`}</span>}
            </div>
          </>}
        </div>

        <div className="mc-col" style={{ flex: 1, minWidth: 0 }}>
          {data && !(loading && !visible.length && data.files.length) ? (
            !visible.length || data.diffFailed ? (
              <div className="mc-col" style={{ flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12 }}>
                {data.diffFailed || (data.statusFailed && !data.files.length)
                  ? <Unavailable icon="exclamationmark.triangle" title="Git couldn't read the changes" description="Git fails in this checkout without the repository's own filter program, which Bromure doesn't run. Look at it in a terminal." />
                  : <>
                      <Unavailable icon="checkmark.seal" title={!showAll && focusFiles && data.files.length ? 'This turn\'s files have no changes here' : 'No changes'}
                                   description={!showAll && focusFiles && data.files.length ? 'They may already be committed — try Last commit, or show everything.'
                                     : base.kind === 'uncommitted' ? 'Nothing uncommitted: the agent may have committed its work.'
                                     : base.kind === 'branch' ? `The branch has nothing ${base.parent} doesn't have.`
                                     : base.kind === 'lastCommit' ? 'The last commit changed nothing that can be shown.' : 'Nothing has changed since this turn began.'} />
                      <div className="mc-row" style={{ gap: 8, marginTop: -20 }}>
                        {!showAll && focusFiles && data.files.length > 0 && <Button onClick={() => setShowAll(true)}>Show All Changes</Button>}
                        {base.kind === 'uncommitted' && <Button onClick={() => setBase({ kind: 'lastCommit' })}>Show the Last Commit</Button>}
                      </div>
                    </>}
              </div>
            ) : (
              <div className="mc-scroll" ref={scroller}><div className="mc-col" style={{ padding: 14, gap: 12 }}>
                {visible.map(f => (
                  <DiffFileView key={f.path} file={f} viewed={isViewed(f)} comments={comments.filter(c => c.file === f.path && c.line != null)}
                                onComment={() => setDraftFile(f.path)} onToggleViewed={() => setViewed(f.path, isViewed(f) ? null : fingerprint(f))}
                                onLineComment={(line, text) => addComment(text, f.path, line)}
                                onRemove={id => a.session(sessionID, 'review', { op: 'remove', comment: id })} />
                ))}
              </div></div>
            )
          ) : failed
            ? <Unavailable icon="bolt.horizontal.circle" title="Can't reach the machine" description="The changes are read live from the machine — start it and refresh." />
            : <div className="mc-col" style={{ flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8 }}><Spinner /><span className="mc-secondary" style={{ fontSize: 11 }}>Reading the changes from the machine…</span></div>}
        </div>
      </div>

      <div className="mc-divider" />
      <div className="mc-col" style={{ padding: 12, gap: 8 }}>
        {comments.filter(c => c.line == null).length > 0 && (
          <div className="mc-col" style={{ gap: 5, maxHeight: 96, overflow: 'auto' }}>
            {comments.filter(c => c.line == null).map(c => (
              <div key={c.id} className="mc-row" style={{ alignItems: 'flex-start', gap: 6 }}>
                <SF name={c.sentAt ? 'checkmark.bubble' : 'bubble.left.fill'} size={10} color={c.sentAt ? 'var(--label-secondary)' : 'var(--purple)'} style={{ marginTop: 2 }} />
                <span className="mc-col" style={{ gap: 1, flex: 1, minWidth: 0 }}>
                  {c.file && <span className="mc-secondary" style={{ fontFamily: 'var(--font-mono)', fontSize: 10 }}>{c.file}</span>}
                  <span className="selectable" style={{ fontSize: 11.5, color: c.sentAt ? 'var(--label-secondary)' : undefined }}>{c.text}</span>
                </span>
                {!c.sentAt && c.undelivered && <span title="The agent handed the task back before this comment reached it." style={{ fontSize: 9, fontWeight: 600, color: 'var(--orange)' }}>not delivered</span>}
                {!c.sentAt
                  ? <button className="mc-icon-btn mc-tertiary" title="Remove this comment" onClick={() => a.session(sessionID, 'review', { op: 'remove', comment: c.id })}><SF name="xmark.circle.fill" size={10} /></button>
                  : <span className="mc-tertiary" style={{ fontSize: 9 }}>sent</span>}
              </div>
            ))}
          </div>
        )}
        {draftFile && (
          <span className="mc-row" style={{ gap: 3, alignSelf: 'flex-start', padding: '3px 6px', borderRadius: 999, background: 'color-mix(in srgb, var(--purple) 15%, transparent)' }}>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10 }}>{draftFile}</span>
            <button className="mc-icon-btn" title="Comment on the whole change instead" onClick={() => setDraftFile(null)}><SF name="xmark.circle.fill" size={9} /></button>
          </span>
        )}
        <div className="rv-composer">
          <div className="mc-col" style={{ flex: 1, gap: 4 }}>
            <textarea rows={1} value={draft} placeholder={draftFile ? 'A comment on this file' : 'A comment on the whole change — or hover a line to comment on it'}
                      onChange={e => { setDraft(e.target.value); e.target.style.height = '0'; e.target.style.height = e.target.scrollHeight + 'px'; }}
                      onKeyDown={e => {
                        if (e.key === 'Enter' && e.shiftKey && isMod(e)) { e.preventDefault(); send(); }
                        else if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); commit(); }
                      }} />
            <span className="mc-tertiary" style={{ fontSize: 10 }}>⏎ add comment   ⇧⏎ newline   ⇧⌘⏎ send to agent</span>
          </div>
          <button className="rv-send" disabled={drafts.length === 0} onClick={send}
                  title={drafts.length === 0 ? 'Add comments first — on a line, a file or the whole change' : 'Sends every draft comment to the agent in one message (⇧⌘⏎)'}
                  style={{ color: drafts.length ? 'var(--purple)' : 'var(--label-tertiary)', background: `color-mix(in srgb, var(--purple) ${drafts.length ? 12 : 4}%, transparent)` }}>
            <SF name="paperplane.fill" size={10} weight={600} />{sendLabel}
          </button>
          <button className="mc-icon-btn" disabled={!draft.trim()} title="Add the comment (⏎) — it waits with the others until you send them" onClick={commit}>
            <SF name="plus.bubble.fill" size={22} color={draft.trim() ? 'var(--purple)' : undefined} />
          </button>
        </div>
      </div>
      {tip.node}
    </div>
  );
}

function DiffFileView({ file, viewed, comments, onComment, onToggleViewed, onLineComment, onRemove }: {
  file: DiffFile; viewed: boolean; comments: Comment[]; onComment: () => void; onToggleViewed: () => void;
  onLineComment: (line: number, text: string) => void; onRemove: (id: string) => void;
}) {
  const [expanded, setExpanded] = useState(!viewed);
  useEffect(() => setExpanded(!viewed), [viewed]);
  const [composing, setComposing] = useState<number | null>(null);
  const [draft, setDraft] = useState('');
  const MAX = 800;
  const submit = (n: number) => { const t = draft.trim(); if (!t) return; onLineComment(n, t); setDraft(''); setComposing(null); };
  return (
    <div className="rv-dfile" id={'rv-' + file.path}>
      <div className="rv-dfile-head" onClick={() => setExpanded(v => !v)}>
        <SF name={expanded ? 'chevron.down' : 'chevron.right'} size={8} weight={700} className="mc-tertiary" />
        <span className="mc-ellipsis" style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5, fontWeight: 600 }}>{file.path}</span>
        <span className="mc-num" style={{ fontSize: 10, color: 'var(--green)' }}>+{file.added}</span>
        <span className="mc-num" style={{ fontSize: 10, color: 'var(--red)' }}>−{file.removed}</span>
        <span className="mc-spacer" />
        <button className="mc-icon-btn" title="Copy this file's diff" onClick={e => { e.stopPropagation(); copyText(file.raw); }}><SF name="doc.on.doc" size={10} /></button>
        <button className="mc-icon-btn" title="Comment on this file" onClick={e => { e.stopPropagation(); onComment(); }}><SF name="text.bubble" size={10} /></button>
        <button className="mc-icon-btn" title="Mark as looked at — it folds away until it changes again" style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 10.5, color: 'var(--label)' }}
                onClick={e => { e.stopPropagation(); onToggleViewed(); }}>
          <SF name={viewed ? 'checkmark.square.fill' : 'square'} size={11} color={viewed ? 'var(--accent)' : 'var(--label-secondary)'} />Viewed
        </button>
      </div>
      {expanded && (
        <div>
          {file.lines.slice(0, MAX).map(l => {
            const annotatable = l.newLine != null && l.kind !== 'hunk';
            return (
              <React.Fragment key={l.id}>
                <div className={cx('df-line', l.kind === 'added' && 'df-add', l.kind === 'removed' && 'df-del', l.kind === 'hunk' && 'df-hunk')} style={{ padding: '0 4px' }}>
                  <button className={cx('df-ann', annotatable && 'on')} disabled={!annotatable} title="Comment on this line"
                          onClick={() => { setDraft(''); setComposing(c => (c === l.id ? null : l.id)); }} style={{ width: 16 }}>
                    <SF name="plus.bubble" size={9} />
                  </button>
                  <span className="df-text" style={{ paddingLeft: 0, color: l.kind === 'hunk' || l.kind === 'context' ? 'var(--label-secondary)' : 'var(--label)' }}>{l.text || ' '}</span>
                </div>
                {l.newLine != null && l.kind !== 'hunk' && comments.filter(c => c.line === l.newLine).map(c => (
                  <div key={c.id} className="df-comment">
                    <SF name={c.sentAt ? 'checkmark.bubble' : 'bubble.left.fill'} size={9} color={c.sentAt ? 'var(--label-secondary)' : 'var(--purple)'} style={{ marginTop: 2 }} />
                    <span className="selectable" style={{ flex: 1, color: c.sentAt ? 'var(--label-secondary)' : undefined }}>{c.text}</span>
                    {!c.sentAt && <button className="mc-icon-btn" onClick={() => onRemove(c.id)}><SF name="xmark.circle.fill" size={10} /></button>}
                  </div>
                ))}
                {composing === l.id && l.newLine != null && (
                  <div className="df-compose">
                    <SF name="text.bubble" size={10} color="var(--purple)" />
                    <TextField autoFocus value={draft} placeholder={`Comment on line ${l.newLine}`} style={{ flex: 1, fontSize: 11 }}
                               onChange={e => setDraft(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') submit(l.newLine!); if (e.key === 'Escape') setComposing(null); }} />
                    <Button size="small" disabled={!draft.trim()} onClick={() => submit(l.newLine!)}>Add</Button>
                    <button className="mc-icon-btn" title="Cancel" onClick={() => setComposing(null)}><SF name="xmark.circle.fill" size={11} /></button>
                  </div>
                )}
              </React.Fragment>
            );
          })}
          {file.lines.length > MAX && (
            <div className="mc-row" style={{ gap: 10, padding: 6 }}>
              <span className="mc-tertiary" style={{ fontSize: 10 }}>… {file.lines.length - MAX} more lines (open the terminal for the full diff)</span>
              <Button variant="borderless" size="small" icon="doc.on.doc" onClick={() => copyText(file.raw)}>Copy this file's diff</Button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export function openSessionReviewWindow(wm: WindowsAPI, host: RemoteHost, sessionID: string, opts: { files?: string[]; since?: Date } = {}) {
  const title = host.state?.agentSessions?.find(s => s.id === sessionID)?.title ?? '';
  wm.open({
    id: `review:${sessionID}`, title: `Review — ${title}`, width: 1180, height: 780, minWidth: 760, minHeight: 520,
    render: () => <ReviewView host={host} sessionID={sessionID} files={opts.files} since={opts.since} />,
  });
}
