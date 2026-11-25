import { safeHref } from '../../../ui/kit';
// A small markdown renderer for assistant prose — the macOS app renders
// replies with MarkdownUI's `.claudeReader` theme (ClaudeTranscriptView.swift).
// Blocks: paragraphs (single newlines kept as line breaks, MarkdownHardBreaks),
// ATX/setext headings, fenced + indented code, block quotes, ordered/unordered
// (nested, task) lists, GFM tables, thematic breaks. Inline: code, strong,
// emphasis, strikethrough, links, autolinks, images (as links). No HTML.

import React, { useState } from 'react';
import { SF } from '../../../ui/icons';

type Block =
  | { t: 'p'; text: string }
  | { t: 'h'; level: number; text: string }
  | { t: 'code'; lang: string; text: string }
  | { t: 'quote'; blocks: Block[] }
  | { t: 'list'; ordered: boolean; start: number; loose?: boolean; items: { blocks: Block[]; task?: boolean; checked?: boolean }[] }
  | { t: 'table'; align: ('left' | 'center' | 'right' | undefined)[]; rows: string[][] }
  | { t: 'hr' };

const LIST_RE = /^( {0,3})([-*+]|\d{1,9}[.)])([ \t]+|$)/;
const FENCE_RE = /^ {0,3}(`{3,}|~{3,})\s*([^`\s]*)?.*$/;
const isBlank = (l: string) => !l.trim();
const isHr = (l: string) => /^ {0,3}([-*_])( *\1){2,} *$/.test(l);
const isTableDelim = (l: string) => /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(l) && l.includes('-');

function splitRow(line: string): string[] {
  let t = line.trim();
  if (t.startsWith('|')) t = t.slice(1);
  if (t.endsWith('|') && !t.endsWith('\\|')) t = t.slice(0, -1);
  const cells: string[] = [];
  let cur = '', code = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (c === '\\' && t[i + 1] === '|') { cur += '|'; i++; continue; }
    if (c === '`') code = !code;
    if (c === '|' && !code) { cells.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  cells.push(cur.trim());
  return cells;
}

export function parseBlocks(src: string): Block[] {
  const lines = src.replace(/\r\n?/g, '\n').split('\n');
  const out: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line)) { i++; continue; }
    const fence = FENCE_RE.exec(line);
    if (fence) {
      const marker = fence[1];
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith(marker[0].repeat(marker.length))) body.push(lines[i++]);
      i++;
      out.push({ t: 'code', lang: (fence[2] ?? '').trim(), text: body.join('\n') });
      continue;
    }
    const h = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
    if (h) { out.push({ t: 'h', level: h[1].length, text: h[2] }); i++; continue; }
    if (isHr(line)) { out.push({ t: 'hr' }); i++; continue; }
    if (/^ {0,3}>/.test(line)) {
      const body: string[] = [];
      while (i < lines.length && !isBlank(lines[i]) && (/^ {0,3}>/.test(lines[i]) || body.length)) {
        if (!/^ {0,3}>/.test(lines[i]) && (LIST_RE.test(lines[i]) || FENCE_RE.test(lines[i]))) break;
        body.push(lines[i].replace(/^ {0,3}> ?/, '')); i++;
      }
      out.push({ t: 'quote', blocks: parseBlocks(body.join('\n')) });
      continue;
    }
    if (/^( {4}|\t)/.test(line)) {
      const body: string[] = [];
      while (i < lines.length && (/^( {4}|\t)/.test(lines[i]) || (isBlank(lines[i]) && i + 1 < lines.length && /^( {4}|\t)/.test(lines[i + 1])))) {
        body.push(lines[i].replace(/^( {4}|\t)/, '')); i++;
      }
      out.push({ t: 'code', lang: '', text: body.join('\n') });
      continue;
    }
    if (line.includes('|') && i + 1 < lines.length && isTableDelim(lines[i + 1])) {
      const head = splitRow(line);
      const align = splitRow(lines[i + 1]).map(c => {
        const l = c.startsWith(':'), r = c.endsWith(':');
        return l && r ? 'center' as const : r ? 'right' as const : l ? 'left' as const : undefined;
      });
      const rows = [head];
      i += 2;
      while (i < lines.length && !isBlank(lines[i]) && lines[i].includes('|')) rows.push(splitRow(lines[i++]));
      const n = head.length;
      out.push({ t: 'table', align: align.slice(0, n), rows: rows.map(r => Array.from({ length: n }, (_, k) => r[k] ?? '')) });
      continue;
    }
    const lm = LIST_RE.exec(line);
    if (lm) {
      const ordered = /\d/.test(lm[2]);
      const start = ordered ? parseInt(lm[2], 10) : 1;
      const items: { blocks: Block[]; task?: boolean; checked?: boolean }[] = [];
      let loose = false;
      while (i < lines.length) {
        const m = LIST_RE.exec(lines[i]);
        if (!m || /\d/.test(m[2]) !== ordered) break;
        const indent = m[0].length;
        const body: string[] = [lines[i].slice(indent)];
        i++;
        while (i < lines.length) {
          const l = lines[i];
          if (isBlank(l)) {
            // A blank line continues the item only when indented text follows.
            if (i + 1 < lines.length && /^\s+\S/.test(lines[i + 1]) && lines[i + 1].search(/\S/) >= Math.min(indent, 2)) { body.push(''); i++; continue; }
            break;
          }
          const ind = l.search(/\S/);
          if (ind >= Math.min(indent, 2)) { body.push(l.slice(Math.min(ind, indent))); i++; continue; }
          if (LIST_RE.test(l) || isHr(l) || FENCE_RE.test(l) || /^ {0,3}(#|>)/.test(l)) break;
          body.push(l); i++;   // lazy continuation
        }
        let task: boolean | undefined, checked: boolean | undefined;
        const tm = /^\[([ xX])\]\s+/.exec(body[0]);
        if (tm) { task = true; checked = tm[1] !== ' '; body[0] = body[0].slice(tm[0].length); }
        if (body.some(isBlank)) loose = true;
        items.push({ blocks: parseBlocks(body.join('\n')), task, checked });
        while (i < lines.length && isBlank(lines[i]) && i + 1 < lines.length && LIST_RE.test(lines[i + 1])) { i++; loose = true; }
      }
      out.push({ t: 'list', ordered, start, items, loose });
      continue;
    }
    // Paragraph (with a setext heading underline).
    const para: string[] = [line];
    i++;
    while (i < lines.length && !isBlank(lines[i])) {
      const l = lines[i];
      if (/^ {0,3}=+\s*$/.test(l)) { out.push({ t: 'h', level: 1, text: para.join(' ') }); para.length = 0; i++; break; }
      if (/^ {0,3}-+\s*$/.test(l) && para.length) { out.push({ t: 'h', level: 2, text: para.join(' ') }); para.length = 0; i++; break; }
      if (FENCE_RE.test(l) || /^ {0,3}(#{1,6}\s|>)/.test(l) || isHr(l) || LIST_RE.test(l)) break;
      if (l.includes('|') && i + 1 < lines.length && isTableDelim(lines[i + 1])) break;
      para.push(l); i++;
    }
    if (para.length) out.push({ t: 'p', text: para.join('\n') });
  }
  return out;
}

// ── Inline ──────────────────────────────────────────────────────────────

let keySeq = 0;
export function renderInline(text: string): React.ReactNode[] {
  const out: React.ReactNode[] = [];
  let buf = '';
  const flush = () => { if (buf) { out.push(buf); buf = ''; } };
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '\\' && i + 1 < text.length && /[\\`*_{}[\]()#+\-.!|~<>]/.test(text[i + 1])) { buf += text[i + 1]; i += 2; continue; }
    if (c === '\\' && text[i + 1] === '\n') { flush(); out.push(<br key={'br' + keySeq++} />); i += 2; continue; }
    if (c === '\n') { flush(); out.push(<br key={'br' + keySeq++} />); i++; continue; }
    if (c === '`') {
      let n = 1; while (text[i + n] === '`') n++;
      const fence = '`'.repeat(n);
      const end = text.indexOf(fence, i + n);
      if (end > 0) {
        flush();
        let code = text.slice(i + n, end);
        if (code.startsWith(' ') && code.endsWith(' ') && code.trim()) code = code.slice(1, -1);
        out.push(<code key={'c' + keySeq++} className="md-code">{code}</code>);
        i = end + n; continue;
      }
    }
    if ((c === '*' || c === '_') && text[i + 1] === c) {
      const end = text.indexOf(c + c, i + 2);
      if (end > i + 2 && text[i + 2] !== ' ') {
        flush(); out.push(<strong key={'s' + keySeq++}>{renderInline(text.slice(i + 2, end))}</strong>); i = end + 2; continue;
      }
    }
    if (c === '~' && text[i + 1] === '~') {
      const end = text.indexOf('~~', i + 2);
      if (end > i + 2) { flush(); out.push(<del key={'d' + keySeq++}>{renderInline(text.slice(i + 2, end))}</del>); i = end + 2; continue; }
    }
    if ((c === '*' || c === '_') && text[i + 1] && text[i + 1] !== ' ' && text[i + 1] !== c) {
      const prev = text[i - 1];
      if (c === '*' || !prev || !/\w/.test(prev)) {
        let end = -1;
        for (let j = i + 1; j < text.length; j++) {
          if (text[j] === '`') { const e = text.indexOf('`', j + 1); if (e > 0) { j = e; continue; } }
          if (text[j] === c && text[j - 1] !== ' ' && text[j + 1] !== c && (c === '*' || !/\w/.test(text[j + 1] ?? ''))) { end = j; break; }
        }
        if (end > i + 1) { flush(); out.push(<em key={'e' + keySeq++}>{renderInline(text.slice(i + 1, end))}</em>); i = end + 1; continue; }
      }
    }
    if (c === '[' || (c === '!' && text[i + 1] === '[')) {
      const img = c === '!';
      const open = img ? i + 1 : i;
      let depth = 0, close = -1;
      for (let j = open; j < text.length; j++) {
        if (text[j] === '[') depth++;
        else if (text[j] === ']') { depth--; if (!depth) { close = j; break; } }
      }
      if (close > 0 && text[close + 1] === '(') {
        const end = text.indexOf(')', close + 2);
        if (end > 0) {
          flush();
          const label = text.slice(open + 1, close);
          const href = text.slice(close + 2, end).trim().split(/\s+/)[0];
          out.push(<a key={'a' + keySeq++} className="md-link" href={safeHref(href)} target="_blank" rel="noopener noreferrer">{img ? label || href : renderInline(label)}</a>);
          i = end + 1; continue;
        }
      }
    }
    if (c === '<') {
      const m = /^<(https?:\/\/[^\s>]+)>/.exec(text.slice(i));
      if (m) { flush(); out.push(<a key={'a' + keySeq++} className="md-link" href={safeHref(m[1])} target="_blank" rel="noopener noreferrer">{m[1]}</a>); i += m[0].length; continue; }
    }
    if ((c === 'h') && (!text[i - 1] || /[\s(]/.test(text[i - 1]))) {
      const m = /^https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"]/.exec(text.slice(i));
      if (m) { flush(); out.push(<a key={'a' + keySeq++} className="md-link" href={safeHref(m[0])} target="_blank" rel="noopener noreferrer">{m[0]}</a>); i += m[0].length; continue; }
    }
    buf += c; i++;
  }
  flush();
  return out;
}

// ── Rendering ───────────────────────────────────────────────────────────

const LANG_PLACEHOLDERS = ['', 'code', 'text', 'plain', 'plaintext', 'txt'];

export function CopyButton({ text, size = 11 }: { text: string; size?: number }) {
  const [copied, setCopied] = useState(false);
  return (
    <button className="chat-copy" title="Copy" onClick={() => {
      navigator.clipboard?.writeText(text).catch(() => {});
      setCopied(true); setTimeout(() => setCopied(false), 1200);
    }}>
      <SF name={copied ? 'checkmark' : 'doc.on.doc'} size={size} color={copied ? 'var(--green)' : undefined} />
    </button>
  );
}

function CodeFence({ lang, text }: { lang: string; text: string }) {
  const l = lang.trim().toLowerCase();
  const label = LANG_PLACEHOLDERS.includes(l) ? null : l;
  return (
    <div className="md-fence chat-card">
      <div className="md-fence-head">
        {label && <span className="md-fence-lang">{label}</span>}
        <span style={{ flex: 1 }} />
        <CopyButton text={text} size={10} />
      </div>
      <pre className="md-fence-body selectable"><code>{highlight(text, l)}</code></pre>
    </div>
  );
}

/** A light token highlighter (strings, comments, numbers, keywords) — the
 *  macOS app uses Highlightr (highlight.js); this keeps the code readable. */
const KEYWORDS = new Set(('abstract and as async await break case catch class const continue def default defer del do elif else enum export extends ' +
  'false final finally fn for from func function go guard if impl import in interface is let match mod module mut new nil none not null of or ' +
  'package pass private protected pub public raise return self static struct super switch this throw throws true try type typeof undefined use ' +
  'var void where while with yield None True False').split(' '));
function highlight(code: string, lang: string): React.ReactNode {
  if (!lang || code.length > 12_000) return code;
  const hash = ['python', 'py', 'sh', 'bash', 'shell', 'zsh', 'ruby', 'rb', 'yaml', 'yml', 'toml', 'perl', 'r', 'dockerfile', 'make', 'makefile'].includes(lang);
  const re = hash
    ? /(#[^\n]*)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|\b(\d+(?:\.\d+)?)\b|\b([A-Za-z_]\w*)\b/g
    : /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|\b(\d+(?:\.\d+)?)\b|\b([A-Za-z_]\w*)\b/g;
  const out: React.ReactNode[] = [];
  let last = 0, m: RegExpExecArray | null, k = 0;
  while ((m = re.exec(code))) {
    if (m[4] && !KEYWORDS.has(m[4])) continue;
    if (m.index > last) out.push(code.slice(last, m.index));
    const cls = m[1] ? 'hl-c' : m[2] ? 'hl-s' : m[3] ? 'hl-n' : 'hl-k';
    out.push(<span key={k++} className={cls}>{m[0]}</span>);
    last = m.index + m[0].length;
  }
  if (last < code.length) out.push(code.slice(last));
  return out;
}

function BlockView({ b }: { b: Block }) {
  switch (b.t) {
    case 'p': return <p className="md-p">{renderInline(b.text)}</p>;
    case 'h': {
      const H = (`h${Math.min(b.level, 6)}`) as 'h1';
      return <H className={`md-h md-h${Math.min(b.level, 3)}`}>{renderInline(b.text)}</H>;
    }
    case 'code': return <CodeFence lang={b.lang} text={b.text} />;
    case 'quote': return <blockquote className="md-quote">{b.blocks.map((x, i) => <BlockView key={i} b={x} />)}</blockquote>;
    case 'hr': return <hr className="md-hr" />;
    case 'list': {
      const L = b.ordered ? 'ol' : 'ul';
      return (
        <L className={'md-list' + (b.loose ? ' loose' : '')} start={b.ordered && b.start !== 1 ? b.start : undefined}>
          {b.items.map((it, i) => (
            <li key={i} className={it.task ? 'md-task' : undefined}>
              {it.task && <input type="checkbox" checked={!!it.checked} readOnly />}
              {it.blocks.map((x, j) => x.t === 'p' && !b.loose ? <span key={j} className="md-li-p">{renderInline(x.text)}</span> : <BlockView key={j} b={x} />)}
            </li>
          ))}
        </L>
      );
    }
    case 'table': return (
      <div className="md-table-wrap">
        <table className="md-table">
          <thead><tr>{b.rows[0].map((c, i) => <th key={i} style={{ textAlign: b.align[i] }}>{renderInline(c)}</th>)}</tr></thead>
          <tbody>{b.rows.slice(1).map((r, i) => <tr key={i}>{r.map((c, j) => <td key={j} style={{ textAlign: b.align[j] }}>{renderInline(c)}</td>)}</tr>)}</tbody>
        </table>
      </div>
    );
  }
}

const cache = new Map<string, Block[]>();
export function Markdown({ text, className }: { text: string; className?: string }) {
  let blocks = cache.get(text);
  if (!blocks) {
    blocks = parseBlocks(text);
    if (cache.size > 2000) cache.clear();
    cache.set(text, blocks);
  }
  return <div className={'md selectable ' + (className ?? '')}>{blocks.map((b, i) => <BlockView key={i} b={b} />)}</div>;
}
