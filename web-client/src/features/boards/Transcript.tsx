// A finished agent's transcript (ClaudeTranscriptPane / AgentTranscript):
// the prompt card, the agent's prose as markdown, and its thinking, tool
// calls and results as folded one-line rows. Reads Claude Code's JSONL and,
// loosely, Codex's; anything else is shown as plain text.

import React, { useState } from 'react';
import { SF } from '../../ui/icons';
import { Markdown } from './Markdown';

export type Item =
  | { kind: 'user'; text: string }
  | { kind: 'assistant'; text: string }
  | { kind: 'thinking'; text: string }
  | { kind: 'tool'; name: string; summary: string; detail: string }
  | { kind: 'result'; name: string; summary: string; detail: string; error?: boolean };

function toolSummary(name: string, input: any): string {
  if (!input || typeof input !== 'object') return String(input ?? '');
  return String(input.command ?? input.cmd ?? input.file_path ?? input.path ?? input.pattern ?? input.url ?? input.query ?? input.description ?? JSON.stringify(input));
}
const firstLine = (s: string) => (s.split(/\r?\n/).find(l => l.trim()) ?? '').trim();
const textOf = (c: any): string => typeof c === 'string' ? c : Array.isArray(c) ? c.map(x => typeof x === 'string' ? x : x?.text ?? '').join('\n') : c?.text ?? '';

export function parseTranscript(raw: string): Item[] {
  const out: Item[] = [];
  const names = new Map<string, string>();
  let parsedAny = false;
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let o: any; try { o = JSON.parse(line); } catch { continue; }
    parsedAny = true;
    // Claude Code
    if ((o.type === 'user' || o.type === 'assistant') && o.message) {
      if (o.isMeta || o.isSidechain) continue;
      const content = o.message.content;
      if (typeof content === 'string') {
        if (o.type === 'user' && /^<(command|local-command|system)/.test(content.trim())) continue;
        out.push({ kind: o.type, text: content });
        continue;
      }
      for (const c of content ?? []) {
        if (c.type === 'text' && c.text?.trim()) {
          if (o.type === 'user' && /^<(command|local-command|system)/.test(c.text.trim())) continue;
          out.push({ kind: o.type === 'user' ? 'user' : 'assistant', text: c.text });
        } else if (c.type === 'thinking' && (c.thinking ?? '').trim()) out.push({ kind: 'thinking', text: c.thinking });
        else if (c.type === 'tool_use') {
          const name = c.name === 'Bash' ? 'shell' : c.name;
          names.set(c.id, name);
          out.push({ kind: 'tool', name, summary: toolSummary(c.name, c.input), detail: JSON.stringify(c.input, null, 2) });
        } else if (c.type === 'tool_result') {
          const t = textOf(c.content);
          out.push({ kind: 'result', name: names.get(c.tool_use_id) ?? 'tool', summary: firstLine(t), detail: t, error: !!c.is_error });
        }
      }
      continue;
    }
    // Codex (response items)
    const p = o.payload ?? o;
    if (p.type === 'message' && (p.role === 'user' || p.role === 'assistant')) {
      const t = textOf((p.content ?? []).map((x: any) => x.text ?? ''));
      if (t.trim() && !/^<(environment_context|user_instructions)/.test(t.trim())) out.push({ kind: p.role, text: t });
    } else if (p.type === 'reasoning') {
      const t = (p.summary ?? []).map((x: any) => x.text ?? '').join('\n');
      out.push({ kind: 'thinking', text: t });
    } else if (p.type === 'function_call') {
      let args: any = p.arguments; try { args = JSON.parse(p.arguments); } catch {}
      const cmd = Array.isArray(args?.command) ? args.command.join(' ') : toolSummary(p.name, args);
      names.set(p.call_id, p.name === 'shell' ? 'shell' : p.name);
      out.push({ kind: 'tool', name: p.name === 'shell' ? 'shell' : p.name, summary: cmd, detail: typeof p.arguments === 'string' ? p.arguments : JSON.stringify(args, null, 2) });
    } else if (p.type === 'function_call_output') {
      let t = p.output; try { const j = JSON.parse(p.output); t = j.output ?? p.output; } catch {}
      out.push({ kind: 'result', name: names.get(p.call_id) ?? 'tool', summary: firstLine(String(t)), detail: String(t) });
    }
  }
  if (!parsedAny && raw.trim()) out.push({ kind: 'assistant', text: raw });
  return out;
}

function Fold({ icon, label, summary, detail, mono, error }: { icon: string; label: string; summary?: string; detail: string; mono?: boolean; error?: boolean }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="bx-tr-fold">
      <button className="bx-tr-fold-row" onClick={() => setOpen(!open)}>
        <SF name={open ? 'chevron.down' : 'chevron.right'} size={11} weight={600} />
        <SF name={icon} size={14} />
        <span className="bx-tr-fold-label">{label}</span>
        {summary && <span className={'bx-tr-fold-sum truncate' + (mono ? ' mono' : '')} style={error ? { color: 'var(--red)' } : undefined}>{summary}</span>}
      </button>
      {open && <pre className="bx-tr-fold-detail selectable">{detail}</pre>}
    </div>
  );
}

export function TranscriptView({ items }: { items: Item[] }) {
  return (
    <div className="bx-tr-scroll">
      <div className="bx-tr-col selectable">
        {items.map((it, i) => {
          switch (it.kind) {
            case 'user': return (
              <div key={i} className="bx-tr-prompt">
                <div className="bx-tr-prompt-head"><SF name="person.fill" size={11} /> Prompt</div>
                <div className="bx-tr-prompt-text">{it.text}</div>
              </div>
            );
            case 'assistant': return <div key={i} className="bx-tr-text"><Markdown text={it.text} /></div>;
            case 'thinking': return <Fold key={i} icon="brain" label="Thinking" detail={it.text} />;
            case 'tool': return <Fold key={i} icon="wrench.and.screwdriver" label={it.name} summary={it.summary} detail={it.detail} mono />;
            case 'result': return <Fold key={i} icon="arrow.turn.down.right" label={`${it.name} result`} summary={it.summary} detail={it.detail} mono error={it.error} />;
          }
        })}
      </div>
    </div>
  );
}

export function b64utf8(b64: string) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}
