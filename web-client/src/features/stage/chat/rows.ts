// TranscriptActivity.swift: a chat is the words; what the agent did between
// them (tool calls, results, thinking) folds into one quiet line per run;
// a turn that edited files ends with "Changed N files +a −r".

import type { TranscriptItem } from '../transcript/types';

// ── Delegation notices (AgentDelegation.swift DelegationNotice) ─────────

const NOTICE = '[Delegation notice]';
const SWITCHBOARD = '[Switchboard]';
export function noticeStrip(text: string): string | null {
  const t = text.trim();
  return t.startsWith(NOTICE) ? t.slice(NOTICE.length).trim() : null;
}
export function switchboardStrip(text: string): string | null {
  const t = text.trim();
  if (!t.startsWith(SWITCHBOARD)) return null;
  let rest = t.slice(SWITCHBOARD.length).trim();
  const i = rest.lastIndexOf(' — call next_events');
  if (i >= 0) rest = rest.slice(0, i);
  return rest;
}
export const isHostAside = (t: string) => noticeStrip(t) != null || switchboardStrip(t) != null;

// ── Display MCP (DisplayCards.swift DisplayRequest.parse) ───────────────

export type DisplayRequest =
  | { kind: 'media'; path: string; title?: string; caption?: string }
  | { kind: 'chart'; spec: string; title?: string; caption?: string }
  | { kind: 'file'; path: string; note?: string };

export function displayRequest(name: string, detail: string): DisplayRequest | null {
  const n = name.toLowerCase();
  const media = n.endsWith('show_media'), chart = n.endsWith('show_chart'), send = n.endsWith('send_file');
  if (!(media || chart || send)) return null;
  if (!(n.includes('display') || n === 'show_media' || n === 'show_chart' || n === 'send_file')) return null;
  let input: any;
  try { input = JSON.parse(detail); } catch { return null; }
  if (!input || typeof input !== 'object') return null;
  const s = (v: unknown) => (typeof v === 'string' && v ? v : undefined);
  if (send) return typeof input.path === 'string' && input.path.startsWith('/') ? { kind: 'file', path: input.path, note: s(input.note) } : null;
  if (media) return typeof input.path === 'string' && input.path.startsWith('/') ? { kind: 'media', path: input.path, title: s(input.title), caption: s(input.caption) } : null;
  let spec = input.spec;
  if (typeof spec === 'string') { try { spec = JSON.parse(spec); } catch { spec = null; } }
  if (!spec || typeof spec !== 'object') return null;
  return { kind: 'chart', spec: JSON.stringify(spec), title: s(input.title), caption: s(input.caption) };
}

// ── Rows ────────────────────────────────────────────────────────────────

export const NARRATION_LIMIT = 600;
export function isNarration(thought: string) {
  const t = thought.trim();
  return !!t && t.length <= NARRATION_LIMIT;
}

export function isActivity(item: TranscriptItem): boolean {
  switch (item.kind.t) {
    case 'toolUse': return displayRequest(item.kind.name, item.kind.detail) == null;
    case 'toolResult': return true;
    case 'thinking': return !isNarration(item.kind.text);
    default: return false;
  }
}

export interface TurnChanges { files: string[]; added: number; removed: number; since?: number }

export type Row =
  | { t: 'item'; id: string; item: TranscriptItem }
  | { t: 'activity'; id: string; items: TranscriptItem[] }
  | { t: 'changes'; id: string; changes: TurnChanges };

export interface LongMessage { itemID: string; whole: string; total: number; expanded: boolean }

export interface Layout {
  rows: Row[];
  /** Row id → the whole reply (Copy takes all of it). */
  replies: Map<string, string>;
  /** Row id → a long message shown collapsed / opened. */
  longs: Map<string, LongMessage>;
}

export const CHUNK_CHARS = 2000;
export const USER_LINES_PER_PIECE = 40;
export const USER_PREVIEW_LINES = 12;
export const EXPANDED_CHARS = 40_000;

export function userCollapses(text: string, limit = CHUNK_CHARS) {
  let lines = 1;
  for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) lines++;
  return text.length > (limit * 3) / 2 || lines > (USER_LINES_PER_PIECE * 3) / 2;
}
export function userPreview(text: string, limit = CHUNK_CHARS) {
  const cap = Math.max(200, limit / 2);
  const out: string[] = [];
  let size = 0;
  for (const line of text.split('\n')) {
    const part = line.slice(0, cap);
    if (out.length && (size + part.length + 1 > cap || out.length >= USER_PREVIEW_LINES)) break;
    out.push(part); size += part.length + 1;
  }
  return out.join('\n');
}

/** TranscriptRow.layout — no reply chunking (the DOM lays out a tall row
 *  fine); a long message of yours collapses, a huge reply shows its start. */
export function layoutRows(items: TranscriptItem[], expanded: Set<string>): Layout {
  const rows: Row[] = [];
  const replies = new Map<string, string>();
  const longs = new Map<string, LongMessage>();
  let run: TranscriptItem[] = [];
  let turn: TranscriptItem[] = [];
  const closeTurn = () => {
    const c = turnChanges(turn);
    const last = turn[turn.length - 1];
    if (c && last) rows.push({ t: 'changes', id: 'chg:' + last.id, changes: c });
    turn = [];
  };
  for (const item of items) {
    if (isActivity(item)) { run.push(item); turn.push(item); continue; }
    if (run.length) { rows.push({ t: 'activity', id: 'act:' + run[0].id, items: run }); run = []; }
    if (item.kind.t === 'userText') closeTurn();
    if (item.kind.t === 'assistantText') {
      const text = item.kind.text;
      replies.set(item.id, text);
      if (text.length > EXPANDED_CHARS) {
        const open = expanded.has(item.id);
        longs.set(item.id, { itemID: item.id, whole: text, total: text.length, expanded: open });
        rows.push({ t: 'item', id: item.id, item: open ? item : { ...item, kind: { t: 'assistantText', text: text.slice(0, EXPANDED_CHARS) } } });
      } else rows.push({ t: 'item', id: item.id, item });
    } else if (item.kind.t === 'userText' && !isHostAside(item.kind.text) && userCollapses(item.kind.text)) {
      const text = item.kind.text;
      const open = expanded.has(item.id);
      longs.set(item.id, { itemID: item.id, whole: text, total: text.length, expanded: open });
      const shown = open ? text.slice(0, EXPANDED_CHARS) : userPreview(text);
      rows.push({ t: 'item', id: item.id, item: { ...item, kind: { t: 'userText', text: shown } } });
    } else {
      rows.push({ t: 'item', id: item.id, item });
    }
    turn.push(item);
  }
  if (run.length) rows.push({ t: 'activity', id: 'act:' + run[0].id, items: run });
  closeTurn();
  // No two rows with one id.
  const seen = new Set<string>();
  for (const r of rows) { let id = r.id, k = 0; while (seen.has(id)) id = r.id + '#' + ++k; r.id = id; seen.add(id); }
  return { rows, replies, longs };
}

// ── Turn changes ────────────────────────────────────────────────────────

function isUnsettledEdit(i: number, items: TranscriptItem[]): boolean {
  const k = items[i].kind;
  if (k.t !== 'toolUse') return false;
  const after = items.slice(i + 1).filter(x => x.kind.t !== 'thinking');
  if (!after.length) return true;
  for (const x of after) if (x.kind.t === 'toolResult' && x.kind.tool === k.name) return x.kind.isError;
  return false;
}

function splitLines(s: string) {
  const t = s.endsWith('\n') ? s.slice(0, -1) : s;
  return t ? t.split('\n') : [];
}

export function lineDiff(oldS: string, newS: string): { added: number; removed: number } {
  let a = splitLines(oldS), b = splitLines(newS);
  let lo = 0;
  while (lo < a.length && lo < b.length && a[lo] === b[lo]) lo++;
  a = a.slice(lo); b = b.slice(lo);
  while (a.length && b.length && a[a.length - 1] === b[b.length - 1]) { a.pop(); b.pop(); }
  const n = a.length, m = b.length;
  if (!n || !m || n * m > 1_000_000) return { added: m, removed: n };
  let prev = new Array(m + 1).fill(0), cur = new Array(m + 1).fill(0);
  for (let i = 1; i <= n; i++) {
    for (let j = 1; j <= m; j++) cur[j] = a[i - 1] === b[j - 1] ? prev[j - 1] + 1 : Math.max(prev[j], cur[j - 1]);
    [prev, cur] = [cur, prev];
  }
  const common = prev[m];
  return { added: m - common, removed: n - common };
}

export function turnChanges(items: TranscriptItem[]): TurnChanges | null {
  const c: TurnChanges = { files: [], added: 0, removed: 0 };
  const ts = items.map(i => i.timestamp).filter((x): x is number => x != null);
  if (ts.length) c.since = Math.min(...ts);
  const touch = (p?: string) => { const t = p?.trim(); if (t && !c.files.includes(t)) c.files.push(t); };
  const count = (o: string, n: string) => { const d = lineDiff(o, n); c.added += d.added; c.removed += d.removed; };
  const patch = (text: string, path?: string) => {
    touch(path);
    for (const line of text.split('\n')) {
      for (const h of ['*** Update File: ', '*** Add File: ', '*** Delete File: ', '+++ b/']) if (line.startsWith(h)) touch(line.slice(h.length));
      if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('***')) continue;
      if (line.startsWith('+')) c.added++; else if (line.startsWith('-')) c.removed++;
    }
  };
  items.forEach((item, i) => {
    const k = item.kind;
    if (k.t !== 'toolUse' || category(k.name) !== 'edit' || isUnsettledEdit(i, items)) return;
    let input: any = null;
    try { input = JSON.parse(k.detail); } catch {}
    if (!input || typeof input !== 'object') { patch(k.detail); return; }
    const path = ['file_path', 'path', 'notebook_path', 'filePath'].map(x => input[x]).find(v => typeof v === 'string');
    if (typeof input.old_string === 'string' && typeof input.new_string === 'string') { touch(path); count(input.old_string, input.new_string); }
    else if (Array.isArray(input.edits)) {
      touch(path);
      for (const e of input.edits) count(e?.old_string ?? e?.oldText ?? '', e?.new_string ?? e?.newText ?? '');
    } else if (typeof input.content === 'string') { touch(path); c.added += splitLines(input.content).length; }
    else {
      const p = ['patch', 'input', 'diff'].map(x => input[x]).find(v => typeof v === 'string');
      if (p) patch(p, path); else touch(path);
    }
  });
  return !c.files.length && !c.added && !c.removed ? null : c;
}

// ── Activity summary ────────────────────────────────────────────────────

export type Category = 'command' | 'read' | 'edit' | 'search' | 'web' | 'agent' | 'other' | 'delegation';

export const CATEGORY_SYMBOL: Record<Category, string> = {
  command: 'terminal', read: 'doc.text', edit: 'pencil', search: 'magnifyingglass', web: 'globe',
  agent: 'person.2', other: 'wrench.and.screwdriver', delegation: 'arrow.left.arrow.right',
};

function countText(c: Category, n: number): string {
  const one = n === 1;
  switch (c) {
    case 'command': return one ? '1 command' : `${n} commands`;
    case 'read': return one ? '1 file read' : `${n} files read`;
    case 'edit': return one ? '1 edit' : `${n} edits`;
    case 'search': return one ? '1 search' : `${n} searches`;
    case 'web': return one ? '1 web page' : `${n} web pages`;
    case 'agent': return one ? '1 subagent' : `${n} subagents`;
    case 'other': return one ? '1 tool call' : `${n} tool calls`;
    case 'delegation': return one ? '1 delegation call' : `${n} delegation calls`;
  }
}
function doing(c: Category, what: string): string {
  switch (c) {
    case 'command': return `Running ${what}`;
    case 'read': return `Reading ${what}`;
    case 'edit': return `Editing ${what}`;
    case 'search': return `Searching ${what}`;
    case 'web': return `Fetching ${what}`;
    case 'agent': return `Delegating ${what}`;
    default: return `Using ${what}`;
  }
}

export function category(tool: string): Category {
  const t = tool.toLowerCase();
  if (t.startsWith('mcp__')) return t.includes('delegat') ? 'delegation' : 'other';
  switch (t) {
    case 'bash': case 'shell': case 'exec_command': case 'exec': case 'run': case 'run_command': case 'terminal': case 'local_shell':
      return 'command';
    case 'read': case 'read_file': case 'view': case 'cat': case 'notebookread': case 'read_many_files':
      return 'read';
    case 'edit': case 'write': case 'multiedit': case 'apply_patch': case 'str_replace': case 'str_replace_editor': case 'create':
    case 'notebookedit': case 'write_file': case 'edit_file': case 'patch':
      return 'edit';
    case 'grep': case 'glob': case 'find': case 'search': case 'ls': case 'list': case 'list_dir': case 'toolsearch': case 'codebase_search': case 'rg':
      return 'search';
    case 'webfetch': case 'websearch': case 'fetch': case 'web_search': case 'browse': case 'web_fetch':
      return 'web';
    case 'task': case 'agent': case 'subagent': case 'spawn_agent':
      return 'agent';
    default: return 'other';
  }
}

/** "mcp__delegation__request" → "delegation request". */
export function humanTool(name: string): string {
  if (name === 'tool_lookup') return 'tool lookup';
  if (name === 'read_output') return 'earlier output';
  if (!name.startsWith('mcp__')) return name;
  const rest = name.slice(5);
  const sep = rest.indexOf('__');
  let words: string[];
  if (sep >= 0) {
    const server = rest.slice(0, sep);
    let tool = rest.slice(sep + 2);
    const s = server.toLowerCase(), t = tool.toLowerCase();
    if (s && t.length > s.length && t.startsWith(s) && (t[s.length] === '_' || t[s.length] === '-')) tool = tool.slice(s.length + 1);
    words = [...server.split(/[_-]/), ...tool.split('_')].filter(Boolean);
  } else words = rest.split('_').filter(Boolean);
  return words.join(' ');
}

type ResultKind = 'media' | 'chart' | 'file' | 'other';
function resultKind(tool: string): ResultKind {
  const t = tool.toLowerCase();
  const display = t.includes('display') || !t.includes('__');
  if (display && t.endsWith('show_media')) return 'media';
  if (display && t.endsWith('show_chart')) return 'chart';
  if (display && t.endsWith('send_file')) return 'file';
  return 'other';
}
const RESULT_SYMBOL: Record<ResultKind, string> = { media: 'photo', chart: 'chart.bar', file: 'arrow.down.doc', other: 'wrench.and.screwdriver' };
function resultCount(k: ResultKind, n: number) {
  const one = n === 1;
  switch (k) {
    case 'media': return one ? '1 media item shown' : `${n} media items shown`;
    case 'chart': return one ? '1 chart shown' : `${n} charts shown`;
    case 'file': return one ? '1 file sent' : `${n} files sent`;
    default: return one ? '1 tool result' : `${n} tool results`;
  }
}

export function thoughtsOnly(items: TranscriptItem[]): string[] | null {
  const out: string[] = [];
  for (const it of items) {
    if (it.kind.t !== 'thinking') return null;
    const t = it.kind.text.trim();
    if (t && out[out.length - 1] !== t) out.push(t);
  }
  return items.length ? out : null;
}

export function isPhrase(s: string): boolean {
  const t = s.trim();
  if (!t || !/^\p{Lu}/u.test(t)) return false;
  const sp = t.indexOf(' ');
  if (sp < 0) return false;
  if (/[/.=:_$\\-]/.test(t.slice(0, sp))) return false;
  const words = t.split(' ').filter(Boolean);
  if (words.length < 2) return false;
  return !(words[1].startsWith('-') || words[1].includes('/'));
}

export function isProbeExit(tool: string, content: string): boolean {
  if (category(tool) !== 'command') return false;
  const lines = content.trim().split(/\r?\n/).filter(Boolean);
  const tail = lines.slice(-3).join('\n').toLowerCase();
  const head = (lines[0] ?? '').toLowerCase();
  const re = /(exited with code|exit code:?|exit status:?|process exited with code) 1(?![0-9])/;
  return re.test(tail) || re.test(head);
}

export interface ActivityLine { text: string; symbols: string[]; failures: number }

export function activityLine(items: TranscriptItem[]): ActivityLine {
  const counts = new Map<Category, number>();
  const order: Category[] = [];
  let failures = 0, thought = false;
  const calls: { name: string; summary: string }[] = [];
  const results: string[] = [];
  for (const it of items) {
    const k = it.kind;
    if (k.t === 'toolUse') {
      const c = category(k.name);
      if (!counts.has(c)) order.push(c);
      counts.set(c, (counts.get(c) ?? 0) + 1);
      calls.push({ name: k.name, summary: k.summary });
    } else if (k.t === 'toolResult') {
      if (k.isError && !isProbeExit(k.tool, k.content)) failures++;
      results.push(k.tool);
    } else if (k.t === 'thinking') thought = true;
  }
  if (!calls.length && results.length) {
    const rc = new Map<ResultKind, number>(); const ro: ResultKind[] = [];
    for (const t of results) { const r = resultKind(t); if (!rc.has(r)) ro.push(r); rc.set(r, (rc.get(r) ?? 0) + 1); }
    const parts = [...(thought ? ['Thought'] : []), ...ro.map(r => resultCount(r, rc.get(r)!))];
    return { text: parts.join(' · '), symbols: ro.slice(0, 3).map(r => RESULT_SYMBOL[r]), failures };
  }
  const parts: string[] = thought ? ['Thought'] : [];
  if (calls.length === 1) {
    const c = calls[0];
    const tool = humanTool(c.name);
    const summary = c.summary.replace(/\n/g, ' ');
    parts.push(!summary ? tool : isPhrase(summary) ? summary : tool + ' ' + summary);
  } else parts.push(...order.map(c => countText(c, counts.get(c)!)));
  return { text: parts.join(' · '), symbols: order.slice(0, 3).map(c => CATEGORY_SYMBOL[c]), failures };
}

export function currentStep(items: TranscriptItem[]): string {
  for (let i = items.length - 1; i >= 0; i--) {
    const k = items[i].kind;
    if (k.t === 'toolUse') {
      const what = k.summary ? k.summary.replace(/\n/g, ' ') : humanTool(k.name);
      if (isPhrase(what)) return what.endsWith('…') ? what : what + '…';
      return doing(category(k.name), what) + '…';
    }
    if (k.t === 'toolResult' || k.t === 'thinking') return 'Thinking…';
  }
  return 'Working…';
}

// ── Copy (TranscriptCopy) ───────────────────────────────────────────────

export const OUTPUT_LIMIT = 20_000;
export const ERROR_LIMIT = 4_000;

export function plainText(markdown: string): string {
  const out: string[] = [];
  let fence = false;
  for (const raw of markdown.split('\n')) {
    const t = raw.trim();
    if (t.startsWith('```') || t.startsWith('~~~')) { fence = !fence; continue; }
    if (fence) { out.push(raw); continue; }
    let l = raw.replace(/^\s{0,3}#{1,6}\s+/, '').replace(/^\s{0,3}(>\s?)+/, '')
      .replace(/!?\[([^\]]*)\]\(([^)]*)\)/g, '$1').replace(/(\*\*|__)(.+?)\1/g, '$2')
      .replace(/(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])/g, '$1').replace(/~~(.+?)~~/g, '$1').replace(/`/g, '');
    out.push(l);
  }
  return out.join('\n');
}
