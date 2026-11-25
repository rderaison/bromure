// SwitchboardThreads.swift: the Switchboard talks about many sessions at once;
// each item is attributed to the session(s) it's about (a tool call's
// `session`, a notice's quoted name, a reply's handles), a reply covering
// several is cut into per-session sections, and every chain gets a colour.

import type { AgentSession } from '../../../core/remote/types';
import type { TranscriptItem } from '../transcript/types';
import { switchboardStrip, type Row } from './rows';

export interface SwitchboardThread { id: string; name: string; sessionID?: string; count: number; last?: number; hue: number }

export interface ThreadedConversation {
  items: TranscriptItem[];
  threadsOf: Map<string, string[]>;
  visibleIn: Map<string, Set<string>>;
  threads: SwitchboardThread[];
}

export interface Alias { text: string; key: string; name: string; sessionID: string }

const isSB = (s: AgentSession) => s.role === 'switchboard';

/** SwitchboardEngine.handles(of:): nickname, else the title's first 3 words. */
export function switchboardHandles(sessions: AgentSession[]): Map<string, string> {
  const out = new Map<string, string>();
  const taken = new Set<string>();
  const list = sessions.filter(s => !isSB(s) && !s.deletedAt)
    .sort((a, b) => Date.parse(a.createdAt ?? '') - Date.parse(b.createdAt ?? ''));
  for (const s of list) if (s.nickname) { out.set(s.id, s.nickname); taken.add(s.nickname.toLowerCase()); }
  for (const s of list) {
    if (out.has(s.id)) continue;
    const words = s.title.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean).slice(0, 3).join('-');
    const base = words || s.tool;
    let h = base, n = 2;
    while (taken.has(h)) h = `${base}-${n++}`;
    taken.add(h);
    out.set(s.id, h);
  }
  return out;
}

export function switchboardAliases(sessions: AgentSession[]): Alias[] {
  const handles = switchboardHandles(sessions);
  const out: Alias[] = [];
  for (const s of sessions) {
    if (isSB(s) || s.deletedAt) continue;
    const h = handles.get(s.id);
    if (!h) continue;
    const key = h.toLowerCase();
    out.push({ text: key, key, name: h, sessionID: s.id });
    if (s.title && s.title.toLowerCase() !== key) out.push({ text: s.title.toLowerCase(), key, name: h, sessionID: s.id });
  }
  return out.sort((a, b) => [...b.text].length - [...a.text].length);
}

const isWord = (c?: string) => !!c && /[\p{L}\p{N}\p{M}_-]/u.test(c);
const LINE_BREAKS = '\n\r\u000B\u000C\u0085  ';
function leadsLine(chars: string[], p: number) {
  for (let i = p - 1; i >= 0; i--) {
    const c = chars[i];
    if (LINE_BREAKS.includes(c)) return true;
    if (!(' \t•-*>.'.includes(c) || /\p{N}/u.test(c))) return false;
  }
  return true;
}

/** The sessions `text` refers to, in order of mention (SwitchboardThreading.mentions). */
export function mentions(text: string, aliases: Alias[]): string[] {
  const usable = aliases.map((a, rank) => ({ ...a, rank, chars: [...a.text], compound: a.text.includes('-') || a.text.includes(' ') }))
    .filter(a => a.chars.length >= 3);
  if (!usable.length) return [];
  const byFirst = new Map<string, typeof usable>();
  for (const a of usable) { const l = byFirst.get(a.chars[0]) ?? []; l.push(a); byFirst.set(a.chars[0], l); }
  const lower = [...text.toLowerCase()];
  const hits: { rank: number; start: number; end: number; key: string }[] = [];
  for (let p = 0; p < lower.length; p++) {
    const entries = byFirst.get(lower[p]);
    if (!entries) continue;
    const before = p > 0 ? lower[p - 1] : undefined;
    if (isWord(before)) continue;
    for (const e of entries) {
      const end = p + e.chars.length;
      if (end > lower.length) continue;
      let ok = true;
      for (let k = 0; k < e.chars.length; k++) if (lower[p + k] !== e.chars[k]) { ok = false; break; }
      if (!ok || isWord(lower[end])) continue;
      const marked = before != null && '@`“"*\'‘'.includes(before);
      if (!(e.compound || marked || leadsLine(lower, p))) continue;
      hits.push({ rank: e.rank, start: p, end, key: e.key });
    }
  }
  const claimed: [number, number][] = [];
  const found: { at: number; key: string }[] = [];
  for (const h of hits.sort((a, b) => a.rank - b.rank || a.start - b.start)) {
    if (claimed.some(([s, e]) => h.start < e && s < h.end)) continue;
    claimed.push([h.start, h.end]);
    found.push({ at: h.start, key: h.key });
  }
  const keys: string[] = [];
  for (const f of found.sort((a, b) => a.at - b.at)) if (!keys.includes(f.key)) keys.push(f.key);
  return keys;
}

function sessionArgument(detail: string): string | null {
  try {
    const o = JSON.parse(detail);
    const s = o && typeof o === 'object' ? o.session : null;
    if (typeof s !== 'string' || !s) return null;
    return s.startsWith('@') ? s.slice(1) : s;
  } catch { return null; }
}
function isJSONObject(s: string) { try { const o = JSON.parse(s); return !!o && typeof o === 'object' && !Array.isArray(o); } catch { return false; } }
function quotedName(text: string): string | null {
  const a = text.indexOf('“'); if (a < 0) return null;
  const b = text.indexOf('”', a + 1); if (b < 0) return null;
  return text.slice(a + 1, b) || null;
}

/** `text` cut where one session's part ends (SwitchboardThreading.sections). */
export function sections(text: string, aliases: Alias[]): { text: string; keys: string[] }[] {
  const blocks: string[] = [];
  let cur: string[] = [];
  let fence = false;
  const flush = () => { if (cur.length) { blocks.push(cur.join('\n')); cur = []; } };
  for (const line of text.replace(/\r\n/g, '\n').split('\n')) {
    const t = line.trim();
    if (t.startsWith('```') || t.startsWith('~~~')) { fence = !fence; cur.push(line); continue; }
    if (fence) { cur.push(line); continue; }
    if (!t) { flush(); continue; }
    if (line.startsWith('• ') || line.startsWith('- ') || line.startsWith('* ')) flush();
    cur.push(line);
  }
  flush();
  const out: { text: string; keys: string[] }[] = [];
  for (const b of blocks) {
    const bt = b.trim();
    const last = out[out.length - 1];
    if ((bt.startsWith('```') || bt.startsWith('~~~')) && last) { last.text += '\n\n' + b; continue; }
    const keys = mentions(b, aliases);
    if (!keys.length && last && last.keys.length) last.text += '\n\n' + b;
    else if (last && keys.join('\u0001') === last.keys.join('\u0001')) last.text += '\n\n' + b;
    else out.push({ text: b, keys });
  }
  return out;
}

// ThreadInk: colours clearly apart in both appearances.
const INK_LIGHT = ['#0B7A75', '#B5541C', '#7A3FB8', '#2F7D32', '#A8326E', '#1F6FB2', '#8A6D00', '#5B6472'];
const INK_DARK = ['#4FD1C5', '#F6A06B', '#C4A1F5', '#8BD48F', '#F08DBC', '#7FBEF0', '#E3C75A', '#AAB4C4'];
export function threadInk(hue: number, dark: boolean) { const l = dark ? INK_DARK : INK_LIGHT; return l[((hue % l.length) + l.length) % l.length]; }
function inkSeed(key: string): number {
  let h = 2166136261 >>> 0;
  for (const b of new TextEncoder().encode(key)) h = Math.imul(h ^ b, 16777619) >>> 0;
  return h % INK_LIGHT.length;
}

/** SwitchboardThreading.analyze. */
export function analyzeSwitchboard(items: TranscriptItem[], aliases: Alias[]): ThreadedConversation {
  const c: ThreadedConversation = { items: [], threadsOf: new Map(), visibleIn: new Map(), threads: [] };
  const names = new Map<string, { name: string; id?: string }>();
  const resolve = (raw: string) => {
    const l = raw.toLowerCase();
    const a = aliases.find(x => x.text === l);
    if (a) { names.set(a.key, { name: a.name, id: a.sessionID }); return a.key; }
    if (!names.has(l)) names.set(l, { name: raw });
    return l;
  };
  const known = (keys: string[]) => {
    for (const k of keys) { const a = aliases.find(x => x.key === k); if (a) names.set(k, { name: a.name, id: a.sessionID }); }
    return keys;
  };
  let turn: string[] = [], lastTool: string[] = [];
  const order: string[] = [];
  const counts = new Map<string, number>(), lastAt = new Map<string, number>();
  const emit = (item: TranscriptItem, keys: string[]) => {
    c.items.push(item);
    if (!keys.length) return;
    c.threadsOf.set(item.id, keys);
    c.visibleIn.set(item.id, new Set(keys));
    for (const k of keys) {
      if (!order.includes(k)) order.push(k);
      counts.set(k, (counts.get(k) ?? 0) + 1);
      if (item.timestamp != null) lastAt.set(k, item.timestamp);
    }
  };
  for (const item of items) {
    const k = item.kind;
    switch (k.t) {
      case 'userText': {
        lastTool = [];
        const notice = switchboardStrip(k.text);
        if (notice != null) {
          const q = quotedName(notice);
          const keys = q ? [resolve(q)] : known(mentions(notice, aliases));
          turn = keys; emit(item, keys);
        } else { turn = known(mentions(k.text, aliases)); emit(item, turn); }
        break;
      }
      case 'toolUse': {
        const raw = isJSONObject(k.detail) ? [] : known(mentions(k.detail, aliases));
        const s = sessionArgument(k.detail);
        if (s) { lastTool = [resolve(s)]; if (!turn.includes(lastTool[0])) turn = turn.length ? [...turn, ...lastTool] : lastTool; }
        else if (raw.length === 1) { lastTool = raw; if (!turn.includes(raw[0])) turn = turn.length ? [...turn, ...raw] : raw; }
        else lastTool = turn.length === 1 ? turn : [];
        emit(item, lastTool);
        break;
      }
      case 'toolResult': emit(item, lastTool); break;
      case 'assistantText': {
        const parts = sections(k.text, aliases);
        const named = new Set(parts.flatMap(p => p.keys));
        if (named.size >= 2 && parts.length >= 2) {
          parts.forEach((p, i) => emit({ id: i === 0 ? item.id : `${item.id}#sb${i}`, kind: { t: 'assistantText', text: p.text }, timestamp: item.timestamp }, known(p.keys)));
        } else if (named.size) {
          emit(item, known([...new Set(parts.flatMap(p => p.keys))]));
        } else emit(item, turn.length === 1 ? turn : []);
        break;
      }
      default: emit(item, turn.length === 1 ? turn : []);
    }
  }
  let opening: string | null = null;
  for (const item of c.items) {
    if (item.kind.t === 'userText' && switchboardStrip(item.kind.text) == null) opening = item.id;
    else if (item.kind.t === 'userText') opening = null;
    else if (opening) {
      const keys = c.threadsOf.get(item.id);
      if (keys) { const s = c.visibleIn.get(opening) ?? new Set<string>(); keys.forEach(x => s.add(x)); c.visibleIn.set(opening, s); }
    }
  }
  let used = new Set<number>();
  const hues = new Map<string, number>();
  const n = INK_LIGHT.length;
  for (const key of order) {
    let h = inkSeed(key);
    for (let step = 0; step < n; step++) if (!used.has((h + step) % n)) { h = (h + step) % n; break; }
    used.add(h);
    if (used.size === n) used = new Set();
    hues.set(key, h);
  }
  c.threads = order.map(k => ({ id: k, name: names.get(k)?.name ?? k, sessionID: names.get(k)?.id, count: counts.get(k) ?? 0, last: lastAt.get(k), hue: hues.get(k) ?? 0 }))
    .sort((a, b) => (b.last ?? -Infinity) - (a.last ?? -Infinity));
  return c;
}

export const effectiveFilter = (c: ThreadedConversation, f: string | null) => (f && c.threads.some(t => t.id === f) ? f : null);
export function itemsIn(c: ThreadedConversation, f: string | null): TranscriptItem[] {
  const e = effectiveFilter(c, f);
  return e ? c.items.filter(i => c.visibleIn.get(i.id)?.has(e)) : c.items;
}

/** ThreadedConversation.headers: row id → the threads heading it (where the subject changes). */
export function threadHeaders(c: ThreadedConversation, rows: Row[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let current: string[] = [];
  const head = (id: string, keys: string[]) => {
    if (!keys.length) return;
    const a = new Set(keys), b = new Set(current);
    if (a.size !== b.size || [...a].some(x => !b.has(x))) out.set(id, keys);
    current = keys;
  };
  for (const r of rows) {
    if (r.t === 'changes') continue;
    if (r.t === 'item') {
      if (r.item.kind.t === 'userText') {
        current = switchboardStrip(r.item.kind.text) != null ? (c.threadsOf.get(r.item.id) ?? []) : [];
        continue;
      }
      head(r.id, c.threadsOf.get(r.item.id) ?? []);
    } else {
      const keys: string[] = [];
      for (const i of r.items) for (const k of c.threadsOf.get(i.id) ?? []) if (!keys.includes(k)) keys.push(k);
      head(r.id, keys);
    }
  }
  return out;
}
