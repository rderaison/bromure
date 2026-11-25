// TranscriptItemView and the cards it draws (ClaudeTranscriptView.swift),
// ActivityGroupView / TurnChangesView (TranscriptActivity.swift), the live
// cues (BeautifiedSessionView.swift ThinkingRow / StreamingCaret).

import React, { useEffect, useMemo, useState } from 'react';
import { SF } from '../../../ui/icons';
import { cx, Spinner } from '../../../ui/kit';
import type { TodoRow, TranscriptItem, TranscriptQuestion } from '../transcript/types';
import { questionResolved } from '../transcript/types';
import { Markdown, CopyButton } from './Markdown';
import {
  activityLine, currentStep, displayRequest, humanTool, isNarration, category, noticeStrip, switchboardStrip,
  thoughtsOnly, OUTPUT_LIMIT, ERROR_LIMIT, type TurnChanges, type DisplayRequest, type LongMessage,
} from './rows';

// ── Helpers ─────────────────────────────────────────────────────────────

const firstLine = (s: string) => {
  const l = s.split(/\r?\n/).find(x => x.length) ?? '';
  return l.length > 160 ? l.slice(0, 160) + '…' : l;
};
const fmtTime = (ms: number) => new Date(ms).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

/** TranscriptStyle.toolTint. */
function toolTint(name: string): string {
  const n = name.toLowerCase();
  if (n.includes('bash') || n.includes('shell') || n.includes('command') || n.includes('execute') || n.includes('run_')) return 'var(--green)';
  if (n.includes('write') || n.includes('create') || n.includes('edit') || n.includes('patch') || n.includes('notebook')) return 'var(--orange)';
  if (n.includes('grep') || n.includes('search')) return 'var(--teal)';
  if (n.includes('web') || n.includes('fetch')) return 'var(--indigo)';
  if (n.includes('read') || n.includes('glob') || n.includes('ls')) return 'var(--blue)';
  return 'var(--label-secondary)';
}

/** CodingTask.displayPrompt: a task prompt shows the brief only. */
export function displayPrompt(text: string): string {
  const i = text.indexOf('\n\n---\nBromure task notes');
  return i > 0 ? text.slice(0, i) : text;
}

// ── Collapsible row ─────────────────────────────────────────────────────

function CollapsibleRow({ icon, title, subtitle, tint, children }: {
  icon: string; title: string; subtitle?: string; tint: string; children?: React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  return (
    <div className="chat-collapsible">
      <button className="chat-collapsible-head" onClick={() => setOpen(o => !o)}>
        <SF name={open ? 'chevron.down' : 'chevron.right'} size={8} weight={700} color="var(--label-tertiary)" />
        <SF name={icon} size={10} color={tint} />
        <span className="chat-collapsible-title" style={{ color: tint }}>{title}</span>
        {subtitle && <span className="chat-collapsible-sub mono">{subtitle}</span>}
      </button>
      {open && <div className="chat-collapsible-body">{children}</div>}
    </div>
  );
}

function ClippedBlock({ text, limit }: { text: string; limit: number }) {
  if (text.length <= limit) return <pre className="chat-codeblock chat-card selectable">{text}</pre>;
  return (
    <div className="chat-vstack" style={{ gap: 6 }}>
      <pre className="chat-codeblock chat-card selectable">{text.slice(0, limit) + '\n…'}</pre>
      <div className="chat-hstack" style={{ gap: 10, fontSize: 11 }}>
        <span className="secondary"><SF name="scissors" size={11} /> Showing first {limit.toLocaleString()} of {text.length.toLocaleString()} characters</span>
        <button className="chat-linkbtn" onClick={() => navigator.clipboard?.writeText(text)}><SF name="doc.on.doc" size={11} /> Copy full output</button>
      </div>
    </div>
  );
}

// ── Tool call cards ─────────────────────────────────────────────────────

function parseInput(detail: string): Record<string, any> {
  try { const o = JSON.parse(detail); return o && typeof o === 'object' ? o : {}; } catch { return {}; }
}

export function todoRowsFrom(input: Record<string, any>): TodoRow[] {
  const st = (s?: string): TodoRow['status'] => {
    switch ((s ?? '').toLowerCase()) {
      case 'completed': case 'complete': case 'done': case 'x': return 'done';
      case 'in_progress': case 'inprogress': case 'active': case 'doing': case 'running': return 'active';
      case 'blocked': return 'blocked';
      default: return 'pending';
    }
  };
  if (Array.isArray(input.todos)) return input.todos.map((t: any) => ({ text: t?.content ?? t?.activeForm ?? '', status: st(t?.status) })).filter((r: TodoRow) => r.text);
  if (Array.isArray(input.plan)) return input.plan.map((t: any) => ({ text: t?.step ?? '', status: st(t?.status) })).filter((r: TodoRow) => r.text);
  if (Array.isArray(input.list)) return input.list.map((t: any) => ({ text: t?.content ?? t?.task ?? t?.text ?? '', status: st(t?.status), phase: t?.phase })).filter((r: TodoRow) => r.text);
  return [];
}

export function TodoListView({ title, rows }: { title: string; rows: TodoRow[] }) {
  const showPhases = new Set(rows.map(r => r.phase).filter(Boolean)).size > 1;
  const done = rows.filter(r => r.status === 'done').length;
  return (
    <div className="chat-card chat-todo">
      <div className="chat-card-head">
        <SF name="checklist" size={11} weight={600} color="var(--label-secondary)" />
        <span className="chat-card-title">{title}</span>
        <span style={{ flex: 1 }} />
        {rows.length > 0 && <span className="mono chat-todo-count" style={{ color: done === rows.length ? 'var(--green)' : 'var(--label-secondary)' }}>{done}/{rows.length}</span>}
      </div>
      <div className="chat-todo-rows">
        {rows.map((r, i) => {
          const icon = r.status === 'done' ? 'checkmark.circle.fill' : r.status === 'active' ? 'circle.dashed' : r.status === 'blocked' ? 'exclamationmark.circle' : 'circle';
          const tint = r.status === 'done' ? 'var(--green)' : r.status === 'active' ? 'var(--orange)' : r.status === 'blocked' ? 'var(--red)' : 'var(--label-secondary)';
          return (
            <React.Fragment key={i}>
              {showPhases && r.phase && r.phase !== rows[i - 1]?.phase && <div className="chat-todo-phase">{r.phase}</div>}
              <div className="chat-todo-row">
                <SF name={icon} size={11} color={tint} style={{ width: 14 }} />
                <span className={cx(r.status === 'done' && 'done')}>{r.text}</span>
              </div>
            </React.Fragment>
          );
        })}
      </div>
    </div>
  );
}

function TodoCard({ input, intent }: { input: Record<string, any>; intent: string }) {
  const rows = todoRowsFrom(input);
  const title = intent.trim() || 'To-dos';
  if (rows.length) return <TodoListView title={title} rows={rows} />;
  let line = title;
  if (typeof input.op === 'string') {
    const what = input.task ?? input.phase ?? '';
    const verb = ({ done: 'Completed', unblock: 'Reopened', block: 'Blocked', add: 'Added' } as Record<string, string>)[input.op]
      ?? input.op.charAt(0).toUpperCase() + input.op.slice(1);
    line = what ? `${verb}: ${what}` : verb;
  }
  return (
    <div className="chat-card chat-hstack" style={{ padding: '6px 10px', gap: 6 }}>
      <SF name="checklist" size={11} weight={600} color="var(--label-secondary)" />
      <span className="secondary" style={{ fontSize: 12 }}>{line}</span>
    </div>
  );
}

type DiffRow = { kind: 'context' | 'add' | 'remove'; text: string };
function computeDiff(oldS: string, newS: string, cap: number): { lines: DiffRow[]; truncatedBy: number } {
  const a = oldS ? oldS.split('\n') : [], b = newS ? newS.split('\n') : [];
  let lines: DiffRow[];
  if (a.length * b.length > 250_000 || a.length + b.length > 4000) {
    lines = [...a.map(t => ({ kind: 'remove' as const, text: t })), ...b.map(t => ({ kind: 'add' as const, text: t }))];
  } else {
    const n = a.length, m = b.length;
    const dp = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    lines = [];
    let i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) { lines.push({ kind: 'context', text: a[i] }); i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) lines.push({ kind: 'remove', text: a[i++] });
      else lines.push({ kind: 'add', text: b[j++] });
    }
    while (i < n) lines.push({ kind: 'remove', text: a[i++] });
    while (j < m) lines.push({ kind: 'add', text: b[j++] });
  }
  return lines.length > cap ? { lines: lines.slice(0, cap), truncatedBy: lines.length - cap } : { lines, truncatedBy: 0 };
}

function DiffCard({ title, path, oldText, newText }: { title: string; path?: string; oldText: string; newText: string }) {
  const [open, setOpen] = useState(true);
  const res = useMemo(() => computeDiff(oldText, newText, 200), [oldText, newText]);
  const adds = res.lines.filter(l => l.kind === 'add').length, dels = res.lines.filter(l => l.kind === 'remove').length;
  return (
    <div className="chat-card">
      <div className="chat-card-head">
        <button className="chat-card-toggle" onClick={() => setOpen(o => !o)}>
          <SF name="pencil" size={11} weight={600} color={toolTint(title)} style={{ width: 14 }} />
          <span className="chat-card-title">{title}</span>
          {path && <span className="mono chat-card-path secondary">{path}</span>}
          <span style={{ flex: 1 }} />
          <span className="mono chat-diffstat">{adds > 0 && <span style={{ color: 'var(--green)' }}>+{adds}</span>}{dels > 0 && <span style={{ color: 'var(--red)' }}>−{dels}</span>}</span>
          <SF name={open ? 'chevron.down' : 'chevron.right'} size={9} color="var(--label-tertiary)" />
        </button>
        {newText && <CopyButton text={newText} />}
      </div>
      {open && (
        <div className="chat-diff mono selectable">
          {res.lines.map((l, i) => (
            <div key={i} className={'chat-diff-row ' + l.kind}>
              <span className="chat-diff-mark">{l.kind === 'add' ? '+' : l.kind === 'remove' ? '−' : ''}</span>
              <span className="chat-diff-text">{l.text || ' '}</span>
            </div>
          ))}
          {res.truncatedBy > 0 && <div className="secondary" style={{ fontSize: 10.5, padding: '4px 12px' }}>… {res.truncatedBy} more lines</div>}
        </div>
      )}
    </div>
  );
}

function FileWriteCard({ tool, path, content }: { tool: string; path?: string; content: string }) {
  const [open, setOpen] = useState(true);
  const ext = (path ?? '').split('.').pop()?.toLowerCase() ?? '';
  return (
    <div className="chat-card">
      <div className="chat-card-head">
        <button className="chat-card-toggle" onClick={() => setOpen(o => !o)}>
          <SF name="square.and.pencil" size={11} weight={600} color={toolTint(tool)} style={{ width: 14 }} />
          <span className="chat-card-title">{tool}</span>
          {path && <span className="mono chat-card-path" style={{ fontWeight: 500 }}>{path}</span>}
          <span style={{ flex: 1 }} />
          <span className="mono chat-diffstat" style={{ color: 'var(--green)' }}>+{content.split('\n').length}</span>
          {ext && ext !== path && <span className="chat-langchip">{ext}</span>}
          <SF name={open ? 'chevron.down' : 'chevron.right'} size={9} color="var(--label-tertiary)" />
        </button>
        <CopyButton text={content} />
      </div>
      {open && <pre className="chat-source mono selectable">{content}</pre>}
    </div>
  );
}

function ShellLine({ command }: { command: string }) {
  return (
    <div className="chat-card chat-shell">
      <div className="chat-shell-scroll mono selectable">
        <span style={{ color: toolTint('bash') }}>$</span>
        <span className="chat-shell-cmd">{command}</span>
      </div>
      <CopyButton text={command} />
    </div>
  );
}

function FileCard({ icon, tool, value }: { icon: string; tool: string; value: string }) {
  return (
    <div className="chat-card chat-filecard">
      <SF name={icon} size={12} color={toolTint(tool)} style={{ width: 16 }} />
      <span className="chat-card-title">{tool}</span>
      <span className="mono chat-filecard-value selectable">{value}</span>
    </div>
  );
}

function splitPatch(patch: string): [string, string] {
  const o: string[] = [], n: string[] = [];
  for (const raw of patch.split('\n')) {
    if (/^(\+\+\+|---|@@|\*\*\* |diff |index )/.test(raw)) continue;
    if (raw.startsWith('+')) n.push(raw.slice(1));
    else if (raw.startsWith('-')) o.push(raw.slice(1));
    else { const c = raw.startsWith(' ') ? raw.slice(1) : raw; o.push(c); n.push(c); }
  }
  return [o.join('\n'), n.join('\n')];
}

export function ToolCallCard({ name, summary, detail }: { name: string; summary: string; detail: string }) {
  const n = name.toLowerCase();
  const input = useMemo(() => parseInput(detail), [detail]);
  const str = (keys: string[]) => { for (const k of keys) if (typeof input[k] === 'string' && input[k]) return input[k] as string; return undefined; };
  const display = displayRequest(name, detail);
  if (display) return <DisplayCard req={display} />;
  if (n.includes('todo') || n === 'update_plan' || n === 'updateplan') return <TodoCard input={input} intent={summary} />;
  if ((n.includes('write') || n.includes('create')) && input.old_string == null && typeof input.content === 'string')
    return <FileWriteCard tool={name} path={str(['file_path', 'path', 'notebook_path'])} content={input.content} />;
  const path = str(['file_path', 'path', 'notebook_path']);
  if (typeof input.old_string === 'string' && typeof input.new_string === 'string')
    return <DiffCard title={name} path={path} oldText={input.old_string} newText={input.new_string} />;
  if (n.includes('patch')) {
    const p = str(['patch', 'input', 'diff']);
    if (p) { const [o, nw] = splitPatch(p); return <DiffCard title={name} path={path} oldText={o} newText={nw} />; }
  }
  if (['bash', 'shell', 'run_command', 'execute', 'local_shell'].some(x => n.includes(x)) && str(['command']))
    return <ShellLine command={str(['command'])!} />;
  if ((n.includes('web') || n.includes('fetch')) && str(['url', 'query'])) return <FileCard icon="globe" tool={name} value={str(['url', 'query'])!} />;
  if (['read', 'glob', 'grep', 'ls', 'search', 'notebook'].some(x => n.includes(x))) {
    const v = str(['file_path', 'path', 'pattern', 'query', 'notebook_path']);
    if (v) {
      const icon = n.includes('read') || n.includes('notebook') ? 'doc.text' : n.includes('grep') || n.includes('search') ? 'magnifyingglass' : n.includes('glob') || n.includes('ls') ? 'folder' : 'doc';
      return <FileCard icon={icon} tool={name} value={v} />;
    }
  }
  return (
    <CollapsibleRow icon={category(name) === 'delegation' ? 'arrow.left.arrow.right' : 'wrench.and.screwdriver'}
                    title={humanTool(name)} subtitle={summary} tint="var(--label-secondary)">
      {detail && <pre className="chat-codeblock chat-card selectable">{detail}</pre>}
    </CollapsibleRow>
  );
}

/** DisplayCard (DisplayCards.swift): what the agent shows the user. The web
 *  client shows the request (title, caption, path); see NOT_PORTED.md. */
function DisplayCard({ req }: { req: DisplayRequest }) {
  const title = req.kind === 'file' ? req.path.split('/').pop() : req.title;
  const caption = req.kind === 'file' ? req.note : req.caption;
  const icon = req.kind === 'media' ? 'photo' : req.kind === 'chart' ? 'chart.bar' : 'doc';
  return (
    <div className="chat-card chat-display">
      <div className="chat-hstack" style={{ gap: 8 }}>
        <SF name={icon} size={14} color="var(--accent)" />
        <div className="chat-vstack" style={{ gap: 2, minWidth: 0 }}>
          {title && <span style={{ fontWeight: 600, fontSize: 12.5 }}>{title}</span>}
          {req.kind !== 'chart' && <span className="mono secondary" style={{ fontSize: 11 }}>{req.path}</span>}
        </div>
      </div>
      {req.kind === 'chart' && <pre className="chat-codeblock selectable" style={{ maxHeight: 160 }}>{req.spec}</pre>}
      {caption && <div className="secondary" style={{ fontSize: 12 }}>{caption}</div>}
    </div>
  );
}

// ── Questions ───────────────────────────────────────────────────────────

const BRAND = 'var(--chat-brand)';

function OptionRow({ index, label, description, multi, picked, interactive, tint = BRAND, onClick }: {
  index: number; label: string; description: string; multi: boolean; picked: boolean; interactive: boolean; tint?: string; onClick?: () => void;
}) {
  return (
    <div className={cx('chat-qopt', picked && 'picked', interactive && 'interactive')} onClick={onClick}
         style={picked ? { borderColor: `color-mix(in srgb, ${tint} 60%, transparent)`, background: `color-mix(in srgb, ${tint} 10%, transparent)` } : undefined}>
      <span className="chat-qopt-mark" style={{ color: interactive || picked ? tint : 'var(--label-secondary)', borderColor: 'currentColor' }}>
        {multi ? (picked ? <SF name="checkmark" size={8} weight={700} /> : null) : <span className={cx('chat-qnum', picked && 'filled')}>{index + 1}</span>}
      </span>
      <div className="chat-vstack" style={{ gap: 1 }}>
        <span className="chat-qopt-label">{label}</span>
        {description && <span className="chat-qopt-desc">{description}</span>}
      </div>
    </div>
  );
}

export function QuestionCard({ q }: { q: TranscriptQuestion }) {
  const [expanded, setExpanded] = useState(false);
  const resolved = questionResolved(q);
  const pick = q.declined ? 'dismissed' : q.answer || null;
  if (resolved && !expanded) {
    return (
      <button className="chat-qresolved" onClick={() => setExpanded(true)} title="Show the question and its options">
        <SF name={q.declined ? 'xmark.circle' : 'checkmark.circle'} size={11} color="var(--label-tertiary)" />
        <span className="chat-qresolved-q">{q.question}</span>
        {pick && <span className="chat-qresolved-a">→ {pick}</span>}
        <span style={{ flex: 1 }} />
        <SF name="chevron.right" size={9} weight={600} color="var(--label-tertiary)" />
      </button>
    );
  }
  const tint = resolved ? 'var(--label-secondary)' : BRAND;
  const labels = new Set(q.options.map(o => o.label));
  const picked = !q.answer ? new Set<string>() : labels.has(q.answer) ? new Set([q.answer])
    : new Set(q.answer.split(',').map(s => s.trim()).filter(s => labels.has(s)));
  return (
    <div className={cx('chat-qcard', resolved && 'resolved')}>
      <div className="chat-hstack" style={{ gap: 6 }}>
        <SF name="questionmark.bubble.fill" size={11} color={tint} />
        {q.header && <span className="chat-qheader" style={{ color: tint }}>{q.header}</span>}
        <span className="chat-qeyebrow">{resolved ? 'The agent asked — answered' : 'The agent asked'}</span>
        <span style={{ flex: 1 }} />
        {resolved && <button className="chat-iconbtn" onClick={() => setExpanded(false)} title="Fold"><SF name="chevron.down" size={9} weight={600} color="var(--label-tertiary)" /></button>}
      </div>
      <div className="chat-qtext" style={resolved ? { color: 'var(--label-secondary)' } : undefined}>{q.question}</div>
      {q.options.map((o, i) => <OptionRow key={i} index={i} label={o.label} description={o.description} multi={q.multiSelect}
                                           picked={picked.has(o.label)} interactive={false} tint={tint} />)}
    </div>
  );
}

/** TranscriptQuestionBatchCard: the live round, picked locally, one Submit. */
export function QuestionBatchCard({ questions, onSubmit }: { questions: TranscriptQuestion[]; onSubmit: (keys: string[]) => Promise<boolean> }) {
  const [tab, setTab] = useState(0);
  const [picks, setPicks] = useState<Map<number, Set<number>>>(new Map());
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [failed, setFailed] = useState(false);
  const answered = (i: number) => questions[i]?.multiSelect ? picks.has(i) : (picks.get(i)?.size ?? 0) > 0;
  const all = questions.every((_, i) => answered(i));
  const q = questions[Math.min(tab, questions.length - 1)];
  const toggle = (opt: number) => {
    if (sending || sent) return;
    const next = new Map(picks);
    let sel = new Set(next.get(tab) ?? []);
    if (questions[tab].multiSelect) { sel.has(opt) ? sel.delete(opt) : sel.add(opt); } else sel = new Set([opt]);
    next.set(tab, sel);
    setPicks(next);
    if (!questions[tab].multiSelect) {
      const nx = questions.findIndex((qq, i) => !(qq.multiSelect ? next.has(i) : (next.get(i)?.size ?? 0) > 0));
      if (nx >= 0) setTab(nx);
    }
  };
  const keys = () => {
    const out: string[] = [];
    questions.forEach((qq, i) => {
      const sel = [...(picks.get(i) ?? [])].sort((a, b) => a - b);
      if (qq.multiSelect) { out.push(...sel.map(s => String(s + 1)), 'Right'); if (i === questions.length - 1) out.push('Enter'); }
      else if (sel.length) out.push(String(sel[0] + 1), 'Enter');
    });
    return out;
  };
  return (
    <div className="chat-qcard live">
      <div className="chat-hstack" style={{ gap: 6 }}>
        <SF name="questionmark.bubble.fill" size={11} color={BRAND} />
        <span className="chat-qeyebrow">{questions.length > 1 ? `The agent is asking ${questions.length} questions — answer them all, then Submit` : 'The agent is asking'}</span>
      </div>
      {questions.length > 1 && (
        <div className="chat-hstack" style={{ gap: 4 }}>
          {questions.map((qq, i) => (
            <button key={i} className={cx('chat-qtab', tab === i && 'on', answered(i) && 'done')} onClick={() => { if (!sending && !sent) setTab(i); }}>
              <SF name={answered(i) ? 'checkmark.circle.fill' : 'circle'} size={9} />
              {qq.header || `Q${i + 1}`}
            </button>
          ))}
        </div>
      )}
      <div className="chat-qtext">{q.question}</div>
      {q.options.map((o, i) => <OptionRow key={i} index={i} label={o.label} description={o.description} multi={q.multiSelect}
                                           picked={picks.get(tab)?.has(i) ?? false} interactive onClick={() => toggle(i)} />)}
      {q.multiSelect && !picks.has(tab) && (
        <button className="btn small" style={{ alignSelf: 'flex-start' }} disabled={sending || sent}
                onClick={() => setPicks(p => new Map(p).set(tab, new Set()))}>None of these</button>
      )}
      <div className="chat-hstack" style={{ gap: 8 }}>
        <button className="chat-qsubmit" disabled={!all || sending || sent} onClick={async () => {
          if (!all || sending || sent) return;
          setSending(true); setFailed(false);
          const ok = await onSubmit(keys());
          setSending(false);
          ok ? setSent(true) : setFailed(true);
        }}>
          <SF name={sending ? 'ellipsis.circle' : 'arrow.up.circle.fill'} size={12} />
          {sending ? 'Sending answers…' : 'Submit'}
        </button>
        {sent ? <span className="chat-qnote">Answers sent to the agent.</span>
          : failed ? <span className="chat-qnote" style={{ color: 'var(--red)' }}>Couldn't reach the session — try again.</span>
          : !all && questions.length > 1 ? <span className="chat-qnote">Submit enables once every tab is answered.</span> : null}
      </div>
    </div>
  );
}

// ── The item view ───────────────────────────────────────────────────────

function NoticeRow({ text, switchboard }: { text: string; switchboard?: boolean }) {
  return (
    <div className="chat-notice">
      <SF name={switchboard ? 'antenna.radiowaves.left.and.right' : 'arrow.left.arrow.right'} size={10} color="var(--label-tertiary)" />
      <span>{text}</span>
    </div>
  );
}

const ERROR_HEADLINE: Record<string, string> = {
  auth: "The agent couldn't authenticate", quota: 'The agent hit a usage limit', rateLimit: 'The agent hit a usage limit',
  overloaded: 'The agent stopped with an error', other: 'The agent stopped with an error', blocked: 'Blocked by Bromure',
};

export function TranscriptItemView({ item, continuesMessage, images }: { item: TranscriptItem; continuesMessage?: boolean; images?: string[] }) {
  const k = item.kind;
  switch (k.t) {
    case 'userText': {
      const n = noticeStrip(k.text);
      if (n != null) return <NoticeRow text={n} />;
      const sb = switchboardStrip(k.text);
      if (sb != null) return <NoticeRow text={sb} switchboard />;
      const words = displayPrompt(k.text);
      return (
        <div className={cx('chat-user', continuesMessage && 'cont')}>
          {!continuesMessage && (
            <div className="chat-user-head">
              <span className="chat-user-you">You</span>
              {item.timestamp != null && <><span className="chat-user-sep">·</span><span className="chat-user-time">{fmtTime(item.timestamp)}</span></>}
            </div>
          )}
          {words && <div className="chat-user-text selectable">{words}</div>}
          {images && images.length > 0 && (
            <div className="chat-user-pics">{images.map((src, i) => <img key={i} src={src} alt="" />)}</div>
          )}
        </div>
      );
    }
    case 'assistantText': return <Markdown text={k.text} className="chat-reply" />;
    case 'question': return <QuestionCard q={k.q} />;
    case 'thinking':
      if (isNarration(k.text)) return <div className="chat-narration selectable">{k.text.trim()}</div>;
      return (
        <CollapsibleRow icon="brain" title="Thinking" tint="var(--label-secondary)">
          <div className="chat-thought selectable">{k.text}</div>
        </CollapsibleRow>
      );
    case 'toolUse': return <ToolCallCard name={k.name} summary={k.summary} detail={k.detail} />;
    case 'todo': return <TodoListView title={k.title} rows={k.rows} />;
    case 'agentError': {
      const e = k.error;
      return (
        <CollapsibleRow icon="exclamationmark.triangle.fill" title={ERROR_HEADLINE[e.kind] ?? ERROR_HEADLINE.other}
                        subtitle={e.kind === 'blocked' ? '' : firstLine(e.message)} tint="var(--orange)">
          {e.message && <ClippedBlock text={e.message} limit={ERROR_LIMIT} />}
        </CollapsibleRow>
      );
    }
    case 'toolResult':
      return (
        <CollapsibleRow icon={k.isError ? 'exclamationmark.octagon' : 'arrow.turn.down.right'} title={`${k.tool} result`}
                        subtitle={firstLine(k.content)} tint={k.isError ? 'var(--red)' : 'var(--label-secondary)'}>
          {k.content && <ClippedBlock text={k.content} limit={OUTPUT_LIMIT} />}
        </CollapsibleRow>
      );
  }
}

// ── Activity / changes / cues ───────────────────────────────────────────

export function ActivityGroupView({ items, live }: { items: TranscriptItem[]; live?: boolean }) {
  const [open, setOpen] = useState(false);
  const line = activityLine(items);
  const thoughts = open ? thoughtsOnly(items) : null;
  return (
    <div className="chat-activity">
      <button className={cx('chat-activity-pill', open && 'open')} onClick={() => setOpen(o => !o)}
              title={open ? 'Hide the details' : 'Show what the agent did'}>
        {live ? <Spinner size={10} /> : (
          <span className="chat-activity-syms">
            {(line.symbols.length ? line.symbols : ['sparkle']).map(s => <SF key={s} name={s} size={10} weight={600} />)}
          </span>
        )}
        <span className="chat-activity-text">{live ? currentStep(items) : line.text}</span>
        {line.failures > 0 && <span className="chat-activity-fail">{line.failures === 1 ? '1 failed' : `${line.failures} failed`}</span>}
        <SF name="chevron.right" size={8.5} weight={700} color="var(--label-tertiary)" style={{ transform: open ? 'rotate(90deg)' : undefined, transition: 'transform .2s' }} />
      </button>
      {open && (
        <div className="chat-activity-body">
          {thoughts ? thoughts.map((t, i) => <div key={i} className="chat-thought selectable">{t}</div>)
            : items.map(it => <TranscriptItemView key={it.id} item={it} />)}
        </div>
      )}
    </div>
  );
}

export function TurnChangesView({ changes, onOpen }: { changes: TurnChanges; onOpen?: () => void }) {
  return (
    <button className="chat-changes" onClick={onOpen} title={changes.files.map(f => f.split('/').pop()).join('\n')}>
      <SF name="doc.badge.gearshape" size={13} weight={600} color="var(--accent)" />
      <span className="chat-changes-label">{changes.files.length === 1 ? 'Changed 1 file' : `Changed ${changes.files.length} files`}</span>
      {changes.added > 0 && <span className="mono chat-changes-add">+{changes.added}</span>}
      {changes.removed > 0 && <span className="mono chat-changes-del">−{changes.removed}</span>}
      <SF name="arrow.up.right" size={10} weight={700} color="var(--label-tertiary)" />
    </button>
  );
}

const VERBS = ['Thinking', 'Working', 'Crafting', 'Pondering', 'Reasoning', 'Cooking', 'Churning', 'Noodling', 'Brewing', 'Simmering',
  'Percolating', 'Ruminating', 'Mulling', 'Synthesizing', 'Conjuring', 'Tinkering', 'Wrangling', 'Untangling', 'Deliberating',
  'Contemplating', 'Scheming', 'Calculating', 'Processing', 'Weaving', 'Distilling', 'Formulating', 'Marinating', 'Puzzling'];

function useTick(ms: number) {
  const [, set] = useState(0);
  useEffect(() => { const t = setInterval(() => set(x => x + 1), ms); return () => clearInterval(t); }, [ms]);
}

export function ThinkingRow({ since }: { since?: number }) {
  useTick(1000);
  const now = Date.now();
  const verb = VERBS[Math.floor(now / 7200) % VERBS.length];
  const s = since ? Math.floor((now - since) / 1000) : 0;
  return (
    <div className="chat-thinking">
      <Spinner size={14} />
      <span className="chat-thinking-verb">{verb}…</span>
      {since != null && s >= 4 && <span className="mono chat-thinking-time">{s < 60 ? `· ${s}s` : `· ${Math.floor(s / 60)}m ${s % 60}s`}</span>}
    </div>
  );
}

export function StreamingCaret() {
  return <div className="chat-caret" aria-hidden />;
}

export function LongMessageBar({ m, onToggle }: { m: LongMessage; onToggle: () => void }) {
  return (
    <div className="chat-longbar">
      <button className="chat-linkbtn" onClick={onToggle}>
        <SF name={m.expanded ? 'chevron.up' : 'chevron.down'} size={10} />
        {m.expanded ? 'Show less' : `Show all (${m.total.toLocaleString()} characters)`}
      </button>
      <button className="chat-linkbtn" onClick={() => navigator.clipboard?.writeText(m.whole)}><SF name="doc.on.doc" size={10} /> Copy</button>
    </div>
  );
}
