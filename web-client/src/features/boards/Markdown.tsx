import { safeHref } from '../../ui/kit';
// Lightweight markdown (CodingKanbanView's MarkdownBlocks): headings,
// bullets, numbered lists, fenced code, quotes and inline bold / italic /
// code / links. No HTML is ever injected — everything is React text.

import React from 'react';

function inline(s: string, key = 0): React.ReactNode[] {
  const out: React.ReactNode[] = [];
  const re = /(`[^`]+`)|(\*\*[^*]+\*\*|__[^_]+__)|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)|(\[[^\]]+\]\((https?:\/\/[^)\s]+)\))|(https?:\/\/[^\s)]+)/g;
  let last = 0, m: RegExpExecArray | null, k = key * 1000;
  while ((m = re.exec(s))) {
    if (m.index > last) out.push(s.slice(last, m.index));
    const t = m[0];
    if (m[1]) out.push(<code key={k++} className="bx-md-code">{t.slice(1, -1)}</code>);
    else if (m[2]) out.push(<strong key={k++}>{inline(t.slice(2, -2), k)}</strong>);
    else if (m[3]) out.push(<em key={k++}>{inline(t.slice(1, -1), k)}</em>);
    else if (m[4]) { const label = t.slice(1, t.indexOf('](')); out.push(<a key={k++} href={safeHref(m[5])} target="_blank" rel="noreferrer">{label}</a>); }
    else out.push(<a key={k++} href={safeHref(t)} target="_blank" rel="noreferrer">{t}</a>);
    last = m.index + t.length;
  }
  if (last < s.length) out.push(s.slice(last));
  return out;
}

export function Markdown({ text, compact, className }: { text: string; compact?: boolean; className?: string }) {
  const lines = (text ?? '').split(/\r?\n/);
  const blocks: React.ReactNode[] = [];
  let para: string[] = [], list: { ordered: boolean; items: string[] } | null = null, i = 0, k = 0;
  const flushPara = () => { if (para.length) { blocks.push(<p key={k++}>{inline(para.join(' '), k)}</p>); para = []; } };
  const flushList = () => {
    if (list) {
      const items = list.items.map((it, j) => <li key={j}>{inline(it, k * 100 + j)}</li>);
      blocks.push(list.ordered ? <ol key={k++}>{items}</ol> : <ul key={k++}>{items}</ul>);
      list = null;
    }
  };
  while (i < lines.length) {
    const raw = lines[i], line = raw.trim();
    if (line.startsWith('```')) {
      flushPara(); flushList();
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) body.push(lines[i++]);
      i++;
      blocks.push(<pre key={k++} className="bx-md-pre">{body.join('\n')}</pre>);
      continue;
    }
    const h = /^(#{1,6})\s+(.*)$/.exec(line);
    const b = /^[-*+]\s+(.*)$/.exec(line);
    const n = /^\d+[.)]\s+(.*)$/.exec(line);
    if (!line) { flushPara(); flushList(); }
    else if (h) { flushPara(); flushList(); const L = Math.min(h[1].length, 4); blocks.push(React.createElement('h' + (L + 1), { key: k++, className: 'bx-md-h' }, inline(h[2], k))); }
    else if (b || n) {
      flushPara();
      const ordered = !!n;
      if (list && list.ordered !== ordered) flushList();
      if (!list) list = { ordered, items: [] };
      list.items.push((b ?? n)![1]);
    }
    else if (line.startsWith('>')) { flushPara(); flushList(); blocks.push(<blockquote key={k++}>{inline(line.replace(/^>\s?/, ''), k)}</blockquote>); }
    else { flushList(); para.push(line); }
    i++;
  }
  flushPara(); flushList();
  return <div className={'bx-md' + (compact ? ' compact' : '') + (className ? ' ' + className : '')}>{blocks}</div>;
}
