import { safeHref } from '../../ui/kit';
// A small Markdown renderer for notes and previews (headings, paragraphs,
// lists, fenced code, quotes, inline code / bold / italic / links). Text is
// rendered through React (never as HTML), so guest-provided content is inert.

import React from 'react';

function inline(text: string, key = 0): React.ReactNode[] {
  const out: React.ReactNode[] = [];
  const re = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)|(\[[^\]]+\]\([^)\s]+\))/g;
  let last = 0, m: RegExpExecArray | null, i = key;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const t = m[0];
    if (m[1]) out.push(<code key={i++}>{t.slice(1, -1)}</code>);
    else if (m[2]) out.push(<strong key={i++}>{inline(t.slice(2, -2), i * 100)}</strong>);
    else if (m[3]) out.push(<em key={i++}>{inline(t.slice(1, -1), i * 100)}</em>);
    else if (m[4]) {
      const lm = /^\[([^\]]+)\]\(([^)\s]+)\)$/.exec(t)!;
      const href = /^(https?:|mailto:)/i.test(lm[2]) ? lm[2] : undefined;
      out.push(<a key={i++} href={safeHref(href)} target="_blank" rel="noopener noreferrer">{lm[1]}</a>);
    }
    last = m.index + t.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function Markdown({ text, className }: { text: string; className?: string }) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const blocks: React.ReactNode[] = [];
  let i = 0, k = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (/^\s*```/.test(l)) {
      const body: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) body.push(lines[i++]);
      i++;
      blocks.push(<pre key={k++}>{body.join('\n')}</pre>);
      continue;
    }
    const h = /^(#{1,6})\s+(.*)$/.exec(l);
    if (h) { const T = (`h${Math.min(3, h[1].length)}`) as 'h1'; blocks.push(<T key={k++}>{inline(h[2])}</T>); i++; continue; }
    if (/^\s*([-*+]|\d+[.)])\s+/.test(l)) {
      const ordered = /^\s*\d/.test(l);
      const items: string[] = [];
      while (i < lines.length && /^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*([-*+]|\d+[.)])\s+/, ''));
      const L = ordered ? 'ol' : 'ul';
      blocks.push(<L key={k++}>{items.map((t, j) => <li key={j}>{inline(t)}</li>)}</L>);
      continue;
    }
    if (/^>\s?/.test(l)) {
      const q: string[] = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) q.push(lines[i++].replace(/^>\s?/, ''));
      blocks.push(<blockquote key={k++} style={{ margin: '0 0 8px', paddingLeft: 10, borderLeft: '3px solid var(--separator)', color: 'var(--label-secondary)' }}>{inline(q.join(' '))}</blockquote>);
      continue;
    }
    if (!l.trim()) { i++; continue; }
    const p: string[] = [];
    while (i < lines.length && lines[i].trim() && !/^(#{1,6}\s|\s*```|\s*([-*+]|\d+[.)])\s+|>)/.test(lines[i])) p.push(lines[i++]);
    blocks.push(<p key={k++}>{p.flatMap((t, j) => j ? [<br key={'b' + j} />, ...inline(t, j * 1000)] : inline(t))}</p>);
  }
  return <div className={'mc-md selectable ' + (className ?? '')}>{blocks}</div>;
}
