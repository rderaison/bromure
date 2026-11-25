// Trace Inspector (⇧⌘I) — port of TraceInspectorView.swift backed by the
// fat client's RemoteTraceStore: polls GET /trace/records every 1.5 s while
// open, fetches decrypted bodies on demand (GET /trace/body?id=&kind=,
// base64) and keeps them in memory only, evicting bodies whose record
// rotated out. Two panes: the record list (filters on top, count + reload
// at the bottom) and the selected record's detail (Conversation / Raw).

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { RemoteHost } from '../../../core/remote/host';
import { useRemote } from '../../../app/store';
import { SF } from '../../../ui/icons';
import { Checkbox, PopUp, Segmented, cx, useTooltip } from '../../../ui/kit';
import { redactLegacy } from '../model';
import { parseConversation, type Block, type Conversation, type Message } from './conversation';
import './trace.css';

/** The native window: 1000×600 content, min 900×560 (+32 pt titlebar). */
export const TRACE_WINDOW = { width: 1000, height: 632, minWidth: 900, minHeight: 592 };

interface SwapEntry { header: string; fakePreview: string; realPreview: string }
interface LeakEntry { header: string; valuePreview: string; suspicion: string }
interface TraceRecord {
  id: string; sessionID: string; profileID: string; timestamp: number;
  host: string; port: number; method: string; path: string; statusCode: number;
  requestBytes: number; responseBytes: number; latencyMs: number;
  swaps: SwapEntry[]; leaks: LeakEntry[]; bodyStored: boolean; isConversation: boolean; servedBy?: string;
}

function decodeRecord(d: any): TraceRecord | null {
  if (!d || typeof d.id !== 'string' || typeof d.host !== 'string') return null;
  const t = Date.parse(d.timestamp);
  return {
    id: d.id.toUpperCase(), sessionID: String(d.sessionID ?? ''), profileID: String(d.profileID ?? '').toUpperCase(),
    timestamp: Number.isNaN(t) ? 0 : t, host: d.host, port: d.port ?? 443, method: String(d.method ?? ''),
    path: String(d.path ?? ''), statusCode: d.statusCode ?? 0, requestBytes: d.requestBytes ?? 0,
    responseBytes: d.responseBytes ?? 0, latencyMs: d.latencyMs ?? 0,
    swaps: Array.isArray(d.swaps) ? d.swaps : [], leaks: Array.isArray(d.leaks) ? d.leaks : [],
    bodyStored: !!d.bodyStored, isConversation: !!d.isConversation, servedBy: d.servedBy,
  };
}

function b64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ── store (RemoteTraceStore) ─────────────────────────────────────────────

function useTraceStore(host: RemoteHost) {
  const [recent, setRecent] = useState<TraceRecord[]>([]);
  const cache = useRef(new Map<string, Uint8Array | null>());
  const fetchRecords = useCallback(async () => {
    let records: TraceRecord[] = [];
    try {
      const r = await host.request<any>('GET', '/trace/records', undefined, { allowError: true, timeoutMs: 30000 });
      if (Array.isArray(r?.records)) records = r.records.map(decodeRecord).filter((x: any): x is TraceRecord => !!x);
    } catch { return; }
    if (demoRecords) records = demoRecords;
    records.sort((a, b) => b.timestamp - a.timestamp);
    setRecent(records);
    const live = new Set(records.map(r => r.id));
    for (const k of [...cache.current.keys()]) if (!live.has(k.slice(0, 36))) cache.current.delete(k);
  }, [host]);
  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout>;
    const loop = async () => { await fetchRecords(); if (!stop) timer = setTimeout(loop, 1500); };
    loop();
    return () => { stop = true; clearTimeout(timer); };
  }, [fetchRecords]);
  const fetchBody = useCallback(async (rec: TraceRecord, kind: 'request' | 'response'): Promise<Uint8Array | null> => {
    if (!rec.bodyStored) return null;
    const key = `${rec.id}.${kind}`;
    if (cache.current.has(key)) return cache.current.get(key)!;
    let data: Uint8Array | null = null;
    if (demoBodies) data = demoBodies(rec, kind);
    else try {
      const r = await host.request<any>('GET', `/trace/body?id=${rec.id}&kind=${kind}`, undefined, { allowError: true, timeoutMs: 30000 });
      if (typeof r?.body === 'string' && r.body) data = b64(r.body);
    } catch { return null; }
    cache.current.set(key, data);
    return data;
  }, [host]);
  return { recent, reload: () => { fetchRecords(); }, fetchBody };
}

// ── formatting ───────────────────────────────────────────────────────────

function statusColor(code: number) {
  if (code >= 200 && code < 300) return 'var(--green)';
  if (code >= 300 && code < 400) return 'var(--blue)';
  if (code >= 400 && code < 500) return 'var(--orange)';
  if (code >= 500) return 'var(--red)';
  return 'var(--gray)';
}
/** ByteCountFormatter(.file): decimal units. */
function bytes(n: number) {
  if (n === 0) return 'Zero KB';
  if (n < 1000) return `${n} bytes`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n / 1000, i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return i === 0 ? `${Math.round(v)} KB` : `${v.toFixed(1)} ${units[i]}`;
}
const dateFmt = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
const timeFmt = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', second: '2-digit' });
const stamp = (t: number) => `${dateFmt.format(t)} at ${timeFmt.format(t)}`;
const utf8 = new TextDecoder('utf-8', { fatal: true });
function asText(d: Uint8Array | null): string | null {
  if (!d) return null;
  try { return utf8.decode(d); } catch { return null; }
}
const prettyText = (s: string) => s.split('\n').map(l => l.trim()).join('\n');

// ── view ─────────────────────────────────────────────────────────────────

export function TraceInspector({ host, workspaceID }: { host: RemoteHost; workspaceID?: string }) {
  const store = useTraceStore(host);
  const workspaces = useRemote(host, s => s.workspaces) ?? [];
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const [profileFilter, setProfileFilter] = useState<string>(workspaceID?.toUpperCase() ?? '');
  // Reopened from another workspace: land on it (the native re-hosts the view).
  useEffect(() => { setProfileFilter(workspaceID?.toUpperCase() ?? ''); }, [workspaceID]);
  const [hostFilter, setHostFilter] = useState('');
  const [leaksOnly, setLeaksOnly] = useState(false);
  const [conversationsOnly, setConversationsOnly] = useState(false);
  const tip = useTooltip();

  const filtered = useMemo(() => store.recent.filter(r => {
    if (profileFilter && r.profileID !== profileFilter) return false;
    if (leaksOnly && !r.leaks.length) return false;
    if (conversationsOnly && !r.isConversation) return false;
    const q = hostFilter.trim().toLowerCase();
    if (q && !r.host.toLowerCase().includes(q)) return false;
    return true;
  }), [store.recent, profileFilter, leaksOnly, conversationsOnly, hostFilter]);

  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => { listRef.current?.focus(); }, []);
  const move = (delta: number | 'first' | 'last') => {
    if (!filtered.length) return;
    let idx: number;
    if (delta === 'first') idx = 0;
    else if (delta === 'last') idx = filtered.length - 1;
    else {
      const cur = filtered.findIndex(r => r.id === selectedID);
      idx = cur >= 0 ? Math.max(0, Math.min(filtered.length - 1, cur + delta)) : delta > 0 ? 0 : filtered.length - 1;
    }
    const id = filtered[idx].id;
    setSelectedID(id);
    requestAnimationFrame(() => listRef.current?.querySelector(`[data-id="${id}"]`)?.scrollIntoView({ block: delta === 'first' ? 'start' : delta === 'last' ? 'end' : 'center' }));
  };
  const onKey = (e: React.KeyboardEvent) => {
    const k: Record<string, number | 'first' | 'last'> = { ArrowUp: -1, ArrowDown: 1, PageUp: -10, PageDown: 10, Home: 'first', End: 'last' };
    if (e.key in k) { e.preventDefault(); move(k[e.key]); }
  };

  const selected = filtered.find(r => r.id === selectedID);
  const profileName = (id: string) => workspaces.find(w => w.id.toUpperCase() === id)?.name ?? '—';

  return (
    <div className="trace">
      <div className="trace-list-pane">
        <div className="trace-filters">
          <div className="trace-filter-row">
            <PopUp value={profileFilter} onChange={setProfileFilter}
                   options={[{ value: '', label: 'All workspaces' }, ...workspaces.map(w => ({ value: w.id.toUpperCase(), label: w.name }))]} />
            <Checkbox checked={leaksOnly} onChange={setLeaksOnly}>
              <span className="trace-check-label"><SF name="exclamationmark.triangle" size={12} />Leaks only</span>
            </Checkbox>
            <span {...tip.bind('Show only requests to known LLM hosts that captured a body — i.e. an actual chat exchange.')}>
              <Checkbox checked={conversationsOnly} onChange={setConversationsOnly}>
                <span className="trace-check-label"><SF name="bubble.left.and.bubble.right" size={12} />Conversations only</span>
              </Checkbox>
            </span>
          </div>
          <div className="trace-search">
            <SF name="magnifyingglass" size={13} />
            <input value={hostFilter} placeholder="Host filter" spellCheck={false} onChange={e => setHostFilter(e.target.value)} />
          </div>
        </div>
        <div className="trace-list" ref={listRef} tabIndex={0} onKeyDown={onKey}>
          {filtered.map(r => (
            <React.Fragment key={r.id}>
              <div data-id={r.id} className={cx('trace-row', r.id === selectedID && 'selected')} onClick={() => setSelectedID(r.id)}>
                <span className="trace-dot" style={{ background: statusColor(r.statusCode) }} />
                <div className="trace-row-main">
                  <div className="trace-row-top">
                    <span className="trace-method">{r.method}</span>
                    <span className="trace-host">{'\u200E' + r.host + '\u200E'}</span>
                    {r.leaks.length > 0 && <span {...tip.bind(`${r.leaks.length} unswapped credential(s)`)} style={{ color: 'var(--orange)', display: 'grid' }}><SF name="exclamationmark.triangle.fill" size={11} /></span>}
                    {r.swaps.length > 0 && <span {...tip.bind(`${r.swaps.length} token(s) swapped`)} style={{ color: 'var(--blue)', display: 'grid' }}><SF name="arrow.left.arrow.right" size={11} /></span>}
                    {r.bodyStored && <span {...tip.bind('Body captured')} style={{ color: 'var(--label-secondary)', display: 'grid' }}><SF name="doc.text" size={11} /></span>}
                  </div>
                  <div className="trace-path">{r.path}</div>
                </div>
                <div className="trace-row-end">
                  <span className="trace-code" style={{ color: statusColor(r.statusCode) }}>{r.statusCode}</span>
                  <span className="trace-latency">{Math.round(r.latencyMs)}ms</span>
                </div>
              </div>
              <div className="trace-divider" />
            </React.Fragment>
          ))}
        </div>
        <div className="trace-footer">
          <span>{filtered.length} records (last {store.recent.length} in memory)</span>
          <span style={{ flex: 1 }} />
          <button className="btn borderless" {...tip.bind('Reload from disk')} onClick={store.reload}><SF name="arrow.clockwise" size={13} /></button>
        </div>
      </div>
      <div className="trace-detail-pane">
        {selected
          ? <Detail key={selected.id} rec={selected} fetchBody={store.fetchBody} profileName={profileName(selected.profileID)} />
          : (
            <div className="trace-empty">
              <SF name="doc.text.magnifyingglass" size={40} weight={300} />
              <div className="trace-empty-title">Pick a request</div>
              <div className="trace-empty-desc">Choose a row on the left to inspect headers, swaps, and (if captured) bodies.</div>
            </div>
          )}
      </div>
      {tip.node}
    </div>
  );
}

function Detail({ rec, fetchBody, profileName }: {
  rec: TraceRecord; profileName: string;
  fetchBody: (r: TraceRecord, k: 'request' | 'response') => Promise<Uint8Array | null>;
}) {
  const [req, setReq] = useState<Uint8Array | null>(null);
  const [res, setRes] = useState<Uint8Array | null>(null);
  const [mode, setMode] = useState<'conversation' | 'raw'>('conversation');
  useEffect(() => {
    let cancelled = false;
    setReq(null); setRes(null);
    if (!rec.bodyStored) return;
    (async () => {
      const a = await fetchBody(rec, 'request');
      const b = await fetchBody(rec, 'response');
      if (!cancelled) { setReq(a); setRes(b); }
    })();
    return () => { cancelled = true; };
  }, [rec.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const conversation = useMemo(() => rec.bodyStored ? parseConversation(rec.host, req, res) : null, [rec, req, res]);
  const available = conversation != null;
  // `.onChange(of: conversationAvailable)`: only a change to unavailable
  // drops to Raw (opening on a record keeps Conversation while its bodies load).
  const wasAvailable = useRef(available);
  useEffect(() => { if (wasAvailable.current && !available) setMode('raw'); wasAvailable.current = available; }, [available]);
  const tip = useTooltip();

  return (
    <div className="trace-detail">
      <div className="trace-header">
        <div className="trace-title-row">
          <span className="trace-title-method">{rec.method}</span>
          <span className="trace-title-url selectable">https://{rec.host}{rec.path}</span>
          <span style={{ flex: 1 }} />
          <span className="trace-title-code" style={{ color: statusColor(rec.statusCode) }}>{rec.statusCode}</span>
        </div>
        <div className="trace-meta-row">
          <Meta k="Workspace" v={profileName} />
          <Meta k="Latency" v={`${Math.round(rec.latencyMs)} ms`} />
          <Meta k="Request" v={bytes(rec.requestBytes)} />
          <Meta k="Response" v={bytes(rec.responseBytes)} />
          <Meta k="Time" v={stamp(rec.timestamp)} />
          <span style={{ flex: 1 }} />
          <div className={cx('trace-mode', !available && 'disabled')}>
            <Segmented value={mode} onChange={m => { if (available || m === 'raw') setMode(m); }}
                       options={[{ value: 'conversation', label: 'Conversation' }, { value: 'raw', label: 'Raw' }]} />
          </div>
        </div>
      </div>
      {mode === 'conversation' && conversation ? <ConversationView c={conversation} /> : (
        <div className="trace-raw">
          {rec.leaks.length > 0 && (
            <Section title="Unswapped credentials (potential leaks)" symbol="exclamationmark.triangle.fill" tint="var(--orange)">
              {rec.leaks.map((l, i) => (
                <div key={i} className="trace-kv">
                  <span style={{ color: 'var(--orange)', display: 'grid' }}><SF name="exclamationmark.shield.fill" size={11} /></span>
                  <b className="mono">{l.header}</b>
                  <span className="mono secondary">{l.valuePreview}</span>
                  <span className="tertiary">·</span>
                  <span className="tertiary small">{l.suspicion}</span>
                </div>
              ))}
            </Section>
          )}
          {rec.swaps.length > 0 && (
            <Section title="Token swaps" symbol="arrow.left.arrow.right" tint="var(--blue)">
              {rec.swaps.map((s, i) => (
                <div key={i} className="trace-kv">
                  <b className="mono">{s.header}</b>
                  <span className="mono">{redactLegacy(s.fakePreview)}</span>
                  <SF name="arrow.right" size={9} />
                  <span className="mono secondary">{redactLegacy(s.realPreview)}</span>
                </div>
              ))}
            </Section>
          )}
          {rec.bodyStored && <>
            <Section title="Request body" symbol="arrow.up.doc" tint="var(--label-secondary)" copy={() => copyable(req)} tip={tip}>
              <BodyView data={req} />
            </Section>
            <Section title="Response body" symbol="arrow.down.doc" tint="var(--label-secondary)" copy={() => copyable(res)} tip={tip}>
              <BodyView data={res} />
            </Section>
          </>}
        </div>
      )}
      {tip.node}
    </div>
  );
}

function copyable(d: Uint8Array | null) {
  if (!d || !d.length) return '';
  return asText(d) ?? Array.from(d, b => b.toString(16).padStart(2, '0')).join('');
}

function Meta({ k, v }: { k: string; v: string }) {
  return <div className="trace-meta"><div className="trace-meta-k">{k}</div><div className="trace-meta-v">{v}</div></div>;
}

function Section({ title, symbol, tint, copy, tip, children }: {
  title: string; symbol: string; tint: string; copy?: () => string; tip?: ReturnType<typeof useTooltip>; children: React.ReactNode;
}) {
  return (
    <div className="trace-section">
      <div className="trace-section-head">
        <span className="trace-section-title" style={{ color: tint }}><SF name={symbol} size={12} />{title}</span>
        <span style={{ flex: 1 }} />
        {copy && (
          <button className="btn borderless" {...(tip?.bind('Copy full content to clipboard') ?? {})}
                  onClick={() => { const s = copy(); if (s) navigator.clipboard?.writeText(s).catch(() => {}); }}>
            <SF name="doc.on.doc" size={12} />
          </button>
        )}
      </div>
      <div className="trace-section-box">{children}</div>
    </div>
  );
}

function BodyView({ data }: { data: Uint8Array | null }) {
  if (!data) return <span className="trace-body-none">(not captured / decryption failed)</span>;
  const s = asText(data);
  if (s == null) return <span className="trace-body-mono tertiary">(binary {data.length} bytes)</span>;
  return <div className="trace-body-mono trace-body-clamp selectable">{s}</div>;
}

// ── ConversationView ─────────────────────────────────────────────────────

const PROVIDER: Record<Conversation['provider'], string> = {
  anthropic: 'Anthropic', openai: 'OpenAI', gemini: 'Google Gemini', cohere: 'Cohere', unknown: 'AI conversation',
};

function ConversationView({ c }: { c: Conversation }) {
  return (
    <div className="trace-conv">
      <div className="trace-conv-header">
        <SF name="sparkles" size={13} style={{ color: 'var(--label-secondary)' }} />
        <span className="trace-conv-provider">{PROVIDER[c.provider]}</span>
        {c.model && <span className="trace-conv-model">{c.model}</span>}
        <span style={{ flex: 1 }} />
        {c.inputTokens != null && <span className="trace-conv-tokens"><SF name="arrow.down" size={9} />{c.inputTokens} in</span>}
        {c.outputTokens != null && <span className="trace-conv-tokens"><SF name="arrow.up" size={9} />{c.outputTokens} out</span>}
      </div>
      <div className="trace-conv-scroll">
        {c.requestEnvelope && <EnvelopeBubble json={c.requestEnvelope} />}
        {c.systemPrompt && (
          <div>
            <div className="trace-bubble-label"><SF name="gear" size={10} />System prompt</div>
            <div className="trace-system selectable">{c.systemPrompt}</div>
          </div>
        )}
        {c.messages.map((m, i) => <MessageBubble key={i} m={m} />)}
      </div>
    </div>
  );
}

function EnvelopeBubble({ json }: { json: string }) {
  const [open, setOpen] = useState(false);
  return (
    <div>
      <div className="trace-bubble-label"><SF name="tray.and.arrow.down" size={10} />Request</div>
      <div className="trace-envelope">
        <div className="trace-disclosure" onClick={() => setOpen(!open)}>
          <SF name={open ? 'chevron.down' : 'chevron.right'} size={10} weight={600} />
          <span>{open ? 'Hide JSON' : 'Show JSON'}</span>
        </div>
        {open && <pre className="trace-envelope-json selectable">{json}</pre>}
      </div>
    </div>
  );
}

const ROLE_LABEL = { user: 'You', assistant: 'Assistant', system: 'System', tool: 'Tool' } as const;

function MessageBubble({ m }: { m: Message }) {
  return (
    <div className={cx('trace-msg', m.role === 'user' && 'user')}>
      <div className="trace-msg-inner">
        <div className="trace-bubble-label">{ROLE_LABEL[m.role]}</div>
        <div className={cx('trace-bubble', 'role-' + m.role)}>
          {m.content.map((b, i) => <BlockView key={i} b={b} />)}
          {!m.content.length && <span className="trace-empty-block">(empty)</span>}
        </div>
      </div>
    </div>
  );
}

function BlockView({ b }: { b: Block }) {
  switch (b.kind) {
    case 'text': return <div className="trace-text selectable">{prettyText(b.text)}</div>;
    case 'thinking': return <div className="trace-text thinking selectable">{prettyText(b.text)}</div>;
    case 'toolUse': return (
      <div className="trace-tool">
        <div className="trace-tool-head" style={{ color: 'var(--purple)' }}><SF name="wrench.and.screwdriver.fill" size={11} /><span className="mono">{b.name}</span></div>
        {b.input && <div className="trace-code-box purple selectable">{b.input}</div>}
      </div>
    );
    case 'toolResult': {
      const tint = b.isError ? 'var(--red)' : 'var(--green)';
      return (
        <div className="trace-tool">
          <div className="trace-tool-head" style={{ color: tint }}>
            <SF name={b.isError ? 'xmark.octagon.fill' : 'checkmark.seal.fill'} size={11} />
            <span>{b.isError ? 'Tool error' : 'Tool result'}</span>
          </div>
          <div className={cx('trace-code-box selectable', b.isError ? 'red' : 'green')}>{b.content}</div>
        </div>
      );
    }
    case 'image': return <div className="trace-image"><SF name="photo" size={12} /><i>{b.mediaType} attachment</i></div>;
  }
}

// ── dev fixture (?traceDemo=1 with the dev relay): the demo server records
// no traffic, so screenshots of the record view need synthetic records. ───

const demoOn = typeof location !== 'undefined' && new URLSearchParams(location.search).get('traceDemo') === '1'
  && new URLSearchParams(location.search).has('devRelay');
const demoRecords: TraceRecord[] | null = demoOn ? (() => {
  const now = Date.now();
  const mk = (i: number, o: Partial<TraceRecord>): TraceRecord => ({
    id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`, sessionID: '', profileID: '478BAA94-0C62-4FF2-8C8E-E171FE1D8E35',
    timestamp: now - i * 37000, host: 'api.anthropic.com', port: 443, method: 'POST', path: '/v1/messages?beta=true', statusCode: 200,
    requestBytes: 48213, responseBytes: 2210, latencyMs: 1830, swaps: [], leaks: [], bodyStored: false, isConversation: false, ...o,
  });
  return [
    mk(1, { swaps: [{ header: 'x-api-key', fakePreview: 'stand-in #3f9a1c2e', realPreview: 'Anthropic key #91be04d7' }], bodyStored: true, isConversation: true }),
    mk(2, { host: 'registry.npmjs.org', method: 'GET', path: '/axios', latencyMs: 212, requestBytes: 412, responseBytes: 128890 }),
    mk(3, { host: 'api.github.com', method: 'GET', path: '/repos/acme/webapp/pulls?state=open', latencyMs: 340,
      swaps: [{ header: 'Authorization', fakePreview: 'stand-in #77a01b3c', realPreview: 'GitHub token #5d2e8f11' }] }),
    mk(4, { host: 'telemetry.example.net', method: 'POST', path: '/v2/collect', statusCode: 403, latencyMs: 12, profileID: 'C804D9CE-5548-44A0-89BA-B319D80DB174',
      leaks: [{ header: 'Authorization', valuePreview: 'Bearer eyJh…', suspicion: 'opaqueToken' }] }),
    mk(5, { host: 'api.stripe.com', method: 'DELETE', path: '/v1/customers/cus_9s8d7f', statusCode: 500, latencyMs: 822, profileID: 'C804D9CE-5548-44A0-89BA-B319D80DB174' }),
    mk(6, { host: 'pypi.org', method: 'GET', path: '/simple/requests/', statusCode: 304, latencyMs: 96, profileID: '7E4A33CB-108D-451A-B524-967334F05FA2' }),
  ];
})() : null;
const demoBodies = demoOn ? (rec: TraceRecord, kind: 'request' | 'response'): Uint8Array | null => {
  if (!rec.id.endsWith('001')) return null;
  const enc = new TextEncoder();
  if (kind === 'request') return enc.encode('POST /v1/messages HTTP/1.1\r\nhost: api.anthropic.com\r\n\r\n' + JSON.stringify({
    model: 'claude-sonnet-4-5', system: 'You are Claude Code, a coding agent.',
    messages: [{ role: 'user', content: 'Add a health check that retries the payments API with a timeout.' }],
  }));
  return enc.encode('HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n' + JSON.stringify({
    content: [{ type: 'text', text: "I'll add axios for timeouts and retries, then run the tests." },
      { type: 'tool_use', id: 'toolu_01', name: 'Bash', input: { command: 'npm install axios' } }],
    usage: { input_tokens: 11842, output_tokens: 96 },
  }));
} : null;
