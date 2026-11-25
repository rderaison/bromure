// The Security window (SecurityTimelineView.swift): an Overview of what the
// engines decided and each workspace's protections, and the Timeline — one
// table of every decision, newest first, colour-coded by outcome — for the
// mirrored host.

import React, { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { Button, PopUp, Segmented, cx, useMenu, type MenuItem } from '../../ui/kit';
import { SF } from '../../ui/icons';
import { saveFile } from '../../platform';
import { openSurface } from '../palette/events';
import {
  securityStore, rangeTitle, RANGE_CHOICES, DEFAULT_RANGE_HOURS, historyHours, searchKey, repeats,
  occurrences, totalsOf, type SecEvent, type Decision, type Totals,
} from './model';
import { usePostures, type Posture } from './posture';
import { ocsfMenuItems, useOCSF } from './ocsf';
import { NetworkLineageSheet } from './lineage/NetworkLineage';
import './security.css';

export interface SecurityRequest {
  gen: number;
  tab?: 'overview' | 'timeline';
  /** Open the Timeline on one workspace's events. */
  workspace?: string;
  /** Open the Timeline with this row's lineage sheet (its stable id). */
  lineage?: string;
}

interface Filter { engine?: string; outcome?: Decision; workspace?: string; query?: string; block?: string }

const ENGINE_ICONS: Record<string, string> = {
  'PII protection': 'person.crop.circle.badge.checkmark',
  'Credential brokering': 'arrow.left.arrow.right',
  'Credential used': 'key.fill',
  'Guardrails': 'hand.raised',
  'Firewall': 'network',
  'Supply chain': 'shippingbox',
  'Prompt injection': 'exclamationmark.shield',
  'Agent delegation': 'arrow.triangle.branch',
  'Network': 'point.3.connected.trianglepath.dotted',
  'Agent reasoning': 'brain.head.profile',
  'Kernel sentry': 'cpu',
  'Guest sandbox': 'square.dashed.inset.filled',
};
const engineIcon = (e: string) => ENGINE_ICONS[e] ?? 'shield';
const kindColor = (k: Decision) => k === 'allowed' ? 'var(--green)' : k === 'blocked' ? 'var(--red)' : 'var(--blue)';

function useStore(host: RemoteHost) {
  const store = securityStore(host);
  useSyncExternalStore(store.subscribe, () => store.version);
  return store;
}

/** `SecurityOverview.blockKey`: engine + condition without what changes. */
const blockKey = (e: SecEvent) => e.engine + '|' + searchKey(e);

export function SecurityWindow({ host, request }: { host: RemoteHost; request: SecurityRequest }) {
  const store = useStore(host);
  const all = store.events;
  const [tab, setTab] = useState<'overview' | 'timeline'>(request.tab ?? 'overview');
  const [query, setQuery] = useState('');
  const [engineFilter, setEngineFilter] = useState<string | undefined>();
  const [workspaceFilter, setWorkspaceFilter] = useState<string | undefined>();
  const [rangeHours, setRangeHours] = useState(DEFAULT_RANGE_HOURS);
  const [outcomeFilter, setOutcomeFilter] = useState<Decision | undefined>();
  const [blockFilter, setBlockFilter] = useState<{ key: string; query: string } | undefined>();
  const [lineage, setLineage] = useState<SecEvent | undefined>();
  const [postureTick, setPostureTick] = useState(0);
  const postures = usePostures(host, postureTick);

  // Opened / reopened: the tab asked for, freshly fetched.
  useEffect(() => {
    if (request.tab) setTab(request.tab);
    if (request.workspace) { setWorkspaceFilter(request.workspace); setTab('timeline'); }
    setPostureTick(t => t + 1);
    store.fetchHistory(historyHours(rangeHours, DEFAULT_RANGE_HOURS));
  }, [request.gen]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { store.fetchHistory(historyHours(rangeHours, DEFAULT_RANGE_HOURS)); }, [rangeHours]); // eslint-disable-line react-hooks/exhaustive-deps
  // A lineage asked for by row id: open it once the row is here.
  const pendingLineage = useRef<string | undefined>(undefined);
  useEffect(() => { pendingLineage.current = request.lineage; }, [request.gen, request.lineage]);
  useEffect(() => {
    const id = pendingLineage.current;
    if (!id) return;
    const e = all.find(x => (x.rowID ?? x.id) === id);
    if (e) { pendingLineage.current = undefined; if (e.detail) setLineage(e); }
  }, [all, request.gen]);

  const open = (f: Filter) => {
    setEngineFilter(f.engine);
    setOutcomeFilter(f.outcome);
    setWorkspaceFilter(f.workspace);
    setQuery(f.query ?? '');
    setBlockFilter(f.block ? { key: f.block, query: f.query ?? '' } : undefined);
    setTab('timeline');
  };

  const engines = useMemo(() => [...new Set(all.map(e => e.engine))].sort(), [all]);
  const workspaces = useMemo(() => {
    const names = new Map<string, string | undefined>();
    for (const e of all) names.set(e.profileID, e.workspace ?? names.get(e.profileID));
    for (const p of postures) names.set(p.id, p.name);
    return [...names].map(([id, name]) => ({ id, name: name ?? '—' }))
      .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
  }, [all, postures]);

  const rows = useMemo(() => {
    let e = all;
    if (rangeHours > 0) { const since = Date.now() - rangeHours * 3600_000; e = e.filter(x => x.time >= since); }
    if (workspaceFilter) e = e.filter(x => x.profileID === workspaceFilter);
    if (engineFilter) e = e.filter(x => x.engine === engineFilter);
    if (outcomeFilter) e = e.filter(x => x.kind === outcomeFilter);
    if (blockFilter && blockFilter.query === query) e = e.filter(x => blockKey(x) === blockFilter.key);
    else if (query) {
      const q = query.toLowerCase();
      e = e.filter(x => x.engine.toLowerCase().includes(q) || x.condition.toLowerCase().includes(q)
        || x.decision.toLowerCase().includes(q) || (x.workspace ?? '').toLowerCase().includes(q));
    }
    return [...e].reverse();   // newest first
  }, [all, rangeHours, workspaceFilter, engineFilter, outcomeFilter, blockFilter, query]);

  const exportCSV = () => {
    const field = (s: string) => '"' + s.replace(/"/g, '""') + '"';
    let out = 'time,machine,workspace,engine,condition,decision,outcome\n';
    const exported = tab === 'timeline' ? [...rows].reverse() : shown(all, DEFAULT_RANGE_HOURS);
    for (const e of exported) {
      out += [new Date(e.time).toISOString().replace(/\.\d{3}Z$/, 'Z'), host.target.name, e.workspace ?? '', e.engine,
              e.condition, e.decision, e.kind].map(field).join(',') + '\n';
    }
    const d = new Date();
    const day = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    saveFile(`bromure-security-${day}.csv`, out, 'text/csv');
  };

  const tabPicker = (
    <span className="sec-tabs">
      <Segmented value={tab} onChange={setTab}
                 options={[{ value: 'overview', label: 'Overview' }, { value: 'timeline', label: 'Timeline' }]} />
    </span>
  );
  const actions = (
    <>
      {tab === 'timeline' && <span className="sec-count">{rows.length} events</span>}
      <Button size="small" icon="square.and.arrow.up" className="sec-tb-btn" disabled={!all.length} onClick={exportCSV}
              title="Save the events (with any filter applied) as a CSV file">Export…</Button>
      <OCSFButton events={tab === 'timeline' ? [...rows].reverse() : shown(all, DEFAULT_RANGE_HOURS)} hostName={host.target.name} />
      {tab === 'timeline' && <Button size="small" className="sec-tb-btn" disabled={!all.length} onClick={() => store.clear()}>Clear</Button>}
    </>
  );
  const filters = tab === 'timeline' ? (
    <div className="sec-filters">
      <label className="sec-search">
        <SF name="magnifyingglass" size={12} />
        <input value={query} placeholder="Filter events…" spellCheck={false} onChange={e => setQuery(e.target.value)} />
      </label>
      <PopUp<string> bordered className="sec-pop" value={workspaceFilter ?? ''} onChange={v => setWorkspaceFilter(v || undefined)}
                     options={[{ value: '', label: 'All workspaces' }, ...workspaces.map(w => ({ value: w.id, label: w.name }))]} />
      <PopUp<number> bordered className="sec-pop" value={rangeHours} onChange={setRangeHours}
                     options={RANGE_CHOICES.map(h => ({ value: h, label: rangeTitle(h) }))} />
      <PopUp<string> bordered className="sec-pop" value={engineFilter ?? ''} onChange={v => setEngineFilter(v || undefined)}
                     options={[{ value: '', label: 'All engines' }, ...engines.map(e => ({ value: e, label: e }))]} />
      <PopUp<string> bordered className="sec-pop" value={outcomeFilter ?? ''} onChange={v => setOutcomeFilter((v || undefined) as Decision | undefined)}
                     options={[{ value: '', label: 'All outcomes' }, { value: 'blocked', label: 'Blocked' }, { value: 'allowed', label: 'Allowed' }]} />
    </div>
  ) : null;

  return (
    <div className="sec-window">
      <Toolbar tabPicker={tabPicker} filters={filters} actions={actions} />
      {tab === 'overview' ? (
        <Overview events={all} postures={postures} rangeHours={DEFAULT_RANGE_HOURS} remoteTotals={store.remoteTotals}
                  showTimeline={f => { open(f); setRangeHours(DEFAULT_RANGE_HOURS); }} />
      ) : rows.length === 0 ? (
        <div className="sec-empty">
          <SF name="shield.lefthalf.filled" size={36} color="var(--label-secondary)" />
          <div className="sec-empty-title">{all.length ? 'No matching events' : 'No security events yet'}</div>
          <div className="sec-empty-desc">Credential swaps, firewall verdicts, package checks, prompt-injection scans, and credential use appear here as your workspaces run.</div>
        </div>
      ) : (
        <TimelineTable rows={rows} onLineage={setLineage} />
      )}
      {lineage && <NetworkLineageSheet events={all} focus={lineage} onClose={() => setLineage(undefined)} />}
    </div>
  );
}

/** What the Overview counts (and exports): the range (0 = all). */
function shown(all: SecEvent[], rangeHours: number) {
  if (rangeHours <= 0) return all;
  const since = Date.now() - rangeHours * 3600_000;
  return all.filter(e => e.time >= since);
}

/** One row when it fits; on a narrower window the filters take a row of
 *  their own under the tabs and actions (ViewThatFits). */
function Toolbar({ tabPicker, filters, actions }: { tabPicker: React.ReactNode; filters: React.ReactNode; actions: React.ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const measure = useRef<HTMLDivElement>(null);
  const [wide, setWide] = useState(true);
  useLayoutEffect(() => {
    const el = ref.current, m = measure.current;
    if (!el || !m) return;
    const check = () => setWide(m.scrollWidth <= el.clientWidth - 24);
    check();
    const ro = new ResizeObserver(check);
    ro.observe(el);
    return () => ro.disconnect();
  });
  return (
    <div ref={ref} className="sec-toolbar">
      <div ref={measure} className="sec-tb-row sec-tb-measure" aria-hidden>{tabPicker}{filters}{actions}</div>
      {wide ? (
        <div className="sec-tb-row">{tabPicker}{filters}<span className="spacer" />{actions}</div>
      ) : (
        <>
          <div className="sec-tb-row">{tabPicker}<span className="spacer" />{actions}</div>
          {filters && <div className="sec-tb-row">{filters}</div>}
        </>
      )}
    </div>
  );
}

function OCSFButton({ events, hostName }: { events: SecEvent[]; hostName: string }) {
  const menu = useMenu();
  const ocsf = useOCSF();
  return (
    <button className="btn small sec-tb-btn sec-ocsf" title="Stream every security event as OCSF JSON (one file per day) for a SIEM"
            onClick={e => menu(e.currentTarget.getBoundingClientRect(), ocsfMenuItems(ocsf, events, hostName))}>
      <SF name={ocsf.enabled ? 'dot.radiowaves.left.and.right' : 'doc.badge.gearshape'} size={12} />
      <span>OCSF</span>
      <SF name="chevron.down" size={9} weight={700} />
    </button>
  );
}

// ── Overview ─────────────────────────────────────────────────────────────

function Overview({ events, postures, rangeHours, remoteTotals, showTimeline }: {
  events: SecEvent[]; postures: Posture[]; rangeHours: number; remoteTotals: Record<number, Totals> | null;
  showTimeline: (f: Filter) => void;
}) {
  const recent = shown(events, rangeHours);
  // A host that counts for itself is shown as it counts.
  const totals = remoteTotals?.[rangeHours] ?? totalsOf(recent);
  const groups = blockGroups(recent);
  const showSandbox = postures.some(p => p.sandbox) || totals.sandboxSeen;
  return (
    <div className="sec-overview">
      <div className="sec-ov-inner">
        <div className="sec-ov-head">
          <div className="sec-ov-title">{rangeTitle(rangeHours)}</div>
          <div className="sec-ov-sub">What Bromure's security engines decided for your agents.</div>
        </div>
        <div className="sec-tiles">
          <Tile title="Blocked" n={totals.blocked} icon="hand.raised" tint="var(--red)" onClick={() => showTimeline({ outcome: 'blocked' })} />
          <Tile title="Allowed" n={totals.allowed} icon="checkmark.seal.fill" tint="var(--green)" onClick={() => showTimeline({ outcome: 'allowed' })} />
          <Tile title="Credential brokering" n={totals.credential} icon="arrow.left.arrow.right" tint="var(--blue)" onClick={() => showTimeline({ engine: 'Credential brokering' })} />
          <Tile title="Supply chain" n={totals.supplyChain} icon="shippingbox" tint="var(--orange)" onClick={() => showTimeline({ engine: 'Supply chain' })} />
          <Tile title="PII protection" n={totals.pii} icon="person.crop.circle.badge.checkmark" tint="var(--purple)" onClick={() => showTimeline({ engine: 'PII protection' })} />
          {showSandbox && <Tile title="Guest sandbox" n={totals.sandbox} icon="square.dashed.inset.filled" tint="var(--teal)" onClick={() => showTimeline({ engine: 'Guest sandbox', outcome: 'blocked' })} />}
        </div>

        {postures.length > 0 && (
          <div className="sec-section">
            <div className="sec-section-head">
              <div className="sec-section-title">Protections</div>
              <div className="sec-section-sub">Click a workspace to see its events, or a protection that's off to turn it on.</div>
            </div>
            <div className="sec-card sec-postures">
              <div className="sec-posture-row sec-posture-header">
                <span className="sec-posture-name">Workspace</span>
                {COLUMNS.map(c => <span key={c} className="sec-posture-col">{c}</span>)}
              </div>
              {postures.map(p => (
                <div key={p.id} className="sec-posture-row">
                  <WorkspaceName p={p} onClick={() => showTimeline({ workspace: p.id })} />
                  {[p.firewall, p.supplyChain, p.guardrails, p.promptInjection, p.pii, true, p.sandbox].map((on, i) => (
                    <PostureCell key={i} on={on} workspace={p.name} column={COLUMNS[i]}
                                 onClick={() => openSurface('settings', { profileID: p.id, category: COLUMN_CATEGORIES[i] })} />
                  ))}
                </div>
              ))}
            </div>
          </div>
        )}

        {groups.length > 0 && (
          <div className="sec-section">
            <div className="sec-section-head">
              <div className="sec-section-title">Latest blocks</div>
              <div className="sec-section-sub">Click one to find every time it happened, in every workspace.</div>
            </div>
            <div className="sec-blocks">
              {groups.map(g => (
                <BlockRow key={g.key} g={g} onClick={() => showTimeline({ outcome: 'blocked', query: searchKey(g.latest), block: blockKey(g.latest) })} />
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

const COLUMNS = ['Firewall', 'Supply chain', 'Guardrails', 'Prompt injection', 'PII protection', 'Credential brokering', 'Sandbox'];
const COLUMN_CATEGORIES = ['firewall', 'supplyChain', 'guardrails', 'promptInjection', 'pii', 'credentials', 'firewall'];

function Tile({ title, n, icon, tint, onClick }: { title: string; n: number; icon: string; tint: string; onClick: () => void }) {
  return (
    <button className="sec-tile" onClick={onClick} title="Show these in the timeline">
      <div className="sec-tile-top">
        <span className="sec-tile-icon" style={{ color: tint, background: `color-mix(in srgb, ${tint} 14%, transparent)` }}>
          {icon === 'checkmark.seal.fill'
            ? <span className="sec-glyph sec-seal" style={{ background: tint }}><SF name="checkmark" size={9} weight={700} color="#fff" /></span>
            : <SF name={icon} size={14} weight={600} />}
        </span>
        <span className="spacer" />
        <SF name="arrow.up.right" size={11} weight={700} color="var(--label-tertiary)" />
      </div>
      <div className="sec-tile-n">{n}</div>
      <div className="sec-tile-title">{title}</div>
    </button>
  );
}

function WorkspaceName({ p, onClick }: { p: Posture; onClick: () => void }) {
  return (
    <button className="sec-posture-name sec-ws-link" onClick={onClick} title={`Show ${p.name}'s events in the timeline`}>
      <span className="sec-ws-swatch" style={{ background: `linear-gradient(${p.colorHex}, color-mix(in srgb, ${p.colorHex} 82%, black))` }} />
      <span className="sec-ws-label truncate">{p.name}</span>
      <span className="sec-ws-arrow"><SF name="arrow.up.right" size={9} weight={700} /></span>
    </button>
  );
}

function PostureCell({ on, workspace, column, onClick }: { on: boolean; workspace: string; column: string; onClick: () => void }) {
  return (
    <button className={cx('sec-posture-col sec-cell', on ? 'on' : 'off')} onClick={onClick}
            title={on ? `${column} is on for ${workspace}. Click to change it.` : `${column} is off for ${workspace}. Click to turn it on.`}>
      {on ? <FilledGlyph icon="checkmark" color="var(--green)" />
          : <>
              <SF name="minus.circle" size={14} color="var(--label-tertiary)" className="sec-minus" />
              <span className="sec-turn-on">Turn on…</span>
            </>}
    </button>
  );
}

/** An SF `*.circle.fill` glyph: a tinted disc with a white mark. */
function FilledGlyph({ icon, color }: { icon: string; color: string }) {
  return <span className="sec-glyph" style={{ background: color }}><SF name={icon} size={9} weight={700} color="#fff" /></span>;
}

interface BlockGroup { key: string; latest: SecEvent; count: number; workspaces: Set<string> }

function blockGroups(events: SecEvent[], limit = 8): BlockGroup[] {
  const groups = new Map<string, BlockGroup>();
  for (const e of events) {
    if (e.kind !== 'blocked') continue;
    const key = blockKey(e);
    const n = occurrences(e);
    const g = groups.get(key);
    if (g) {
      g.count += n; g.workspaces.add(e.profileID);
      if (e.time > g.latest.time) g.latest = e;
    } else groups.set(key, { key, latest: e, count: n, workspaces: new Set([e.profileID]) });
  }
  return [...groups.values()].sort((a, b) => b.latest.time - a.latest.time).slice(0, limit);
}

/** `.relative(presentation: .named, unitsStyle: .abbreviated)`. */
function relative(t: number): string {
  const s = Math.round((Date.now() - t) / 1000);
  if (s < 1) return 'now';
  if (s < 60) return `${s} sec. ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min. ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} hr. ago`;
  const d = Math.round(h / 24);
  if (d === 1) return 'yesterday';
  if (d < 7) return `${d} days ago`;
  const w = Math.round(d / 7);
  if (w < 5) return w === 1 ? 'last wk.' : `${w} wk. ago`;
  const mo = Math.round(d / 30);
  return mo < 12 ? (mo === 1 ? 'last mo.' : `${mo} mo. ago`) : `${Math.round(d / 365)} yr. ago`;
}

function BlockRow({ g, onClick }: { g: BlockGroup; onClick: () => void }) {
  const e = g.latest;
  const sub = [e.engine, e.decision, g.workspaces.size > 1 ? `${g.workspaces.size} workspaces` : (e.workspace ?? '')].filter(Boolean).join(' · ');
  return (
    <button className="sec-block" onClick={onClick} title="Find every instance in the timeline">
      <FilledGlyph icon="xmark" color="var(--red)" />
      <span className="sec-block-text">
        <span className="sec-block-cond truncate">{e.condition}</span>
        <span className="sec-block-sub truncate">{sub}</span>
      </span>
      <span className="spacer" />
      {g.count > 1 && <span className="sec-block-count" title={`Blocked ${g.count} times; the last one is shown`}>{g.count > 999 ? '999+' : g.count}</span>}
      <span className="sec-block-time">{relative(e.time)}</span>
      <span className="sec-block-search"><SF name="magnifyingglass" size={10} weight={600} /></span>
    </button>
  );
}

// ── Timeline table ───────────────────────────────────────────────────────

const timeFmt = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: '2-digit', day: '2-digit', hour: 'numeric', minute: '2-digit', second: '2-digit' });

const COLS: { key: string; title: string; width: number; min: number }[] = [
  { key: 'time', title: 'Time', width: 190, min: 150 },
  { key: 'workspace', title: 'Workspace', width: 146, min: 90 },
  { key: 'engine', title: 'Engine', width: 177, min: 140 },
  { key: 'condition', title: 'Condition', width: 257, min: 140 },
  { key: 'decision', title: 'Decision', width: 260, min: 140 },
  { key: 'action', title: '', width: 80, min: 64 },
];

/** A firewall row the quick actions could work on (`isActionable`). */
function fwActionable(e: SecEvent) {
  const fw = e.firewall;
  if (!fw || !fw.byPolicy || (fw.proto !== 'tcp' && fw.proto !== 'udp')) return false;
  const isIP = (s?: string) => !!s && /^\d{1,3}(\.\d{1,3}){3}$/.test(s);
  return (!!fw.host && !isIP(fw.host)) || isIP(fw.ip ?? fw.host);
}
const REMOTE_FW_HELP = 'Change this workspace\'s firewall rules in its settings on the Mac that runs it.';

function conditionHelp(e: SecEvent) {
  const base = e.firewall?.aliases.length ? `${e.condition}\nAlso seen as: ${e.firewall.aliases.join(', ')}` : e.condition;
  return e.detail ? base + '\nDouble-click to see the whole chain' : base;
}

function TimelineTable({ rows, onLineage }: { rows: SecEvent[]; onLineage: (e: SecEvent) => void }) {
  const [widths, setWidths] = useState(() => COLS.map(c => c.width));
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const anchor = useRef<number | null>(null);
  const menu = useMenu();

  const startResize = (i: number) => (ev: React.MouseEvent) => {
    ev.preventDefault(); ev.stopPropagation();
    const sx = ev.clientX, sw = widths[i];
    const mm = (m: MouseEvent) => setWidths(w => w.map((x, j) => j === i ? Math.max(COLS[i].min, sw + m.clientX - sx) : x));
    const mu = () => { window.removeEventListener('mousemove', mm); window.removeEventListener('mouseup', mu); };
    window.addEventListener('mousemove', mm); window.addEventListener('mouseup', mu);
  };

  const click = (ev: React.MouseEvent, i: number) => {
    const id = rows[i].id;
    if (ev.shiftKey && anchor.current != null) {
      const [a, b] = [Math.min(anchor.current, i), Math.max(anchor.current, i)];
      setSelection(new Set(rows.slice(a, b + 1).map(r => r.id)));
      return;
    }
    if (ev.metaKey || ev.ctrlKey) {
      setSelection(s => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
    } else setSelection(new Set([id]));
    anchor.current = i;
  };

  const contextMenu = (ev: React.MouseEvent, e: SecEvent) => {
    ev.preventDefault();
    if (!selection.has(e.id)) setSelection(new Set([e.id]));
    const items: MenuItem[] = [];
    if (e.detail) items.push({ label: 'Show the Whole Chain', action: () => onLineage(e) });
    if (fwActionable(e)) items.push({ label: REMOTE_FW_HELP, disabled: true });
    if (items.length) menu(ev, items);
  };

  // ↑/↓ move the selection; Return opens a flow's lineage.
  const onKey = (ev: React.KeyboardEvent) => {
    const i = rows.findIndex(r => selection.has(r.id));
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
      ev.preventDefault();
      const n = Math.max(0, Math.min(rows.length - 1, i + (ev.key === 'ArrowDown' ? 1 : -1)));
      if (rows[n]) { setSelection(new Set([rows[n].id])); anchor.current = n; }
    } else if (ev.key === 'Enter' && i >= 0 && rows[i].detail) onLineage(rows[i]);
  };

  const total = widths.reduce((a, b) => a + b, 0);
  return (
    <div className="sec-table-scroll" tabIndex={0} onKeyDown={onKey}>
      <div className="sec-table" style={{ minWidth: total }}>
        <div className="sec-thead">
          {COLS.map((c, i) => (
            <div key={c.key} className="sec-th" style={{ width: i === COLS.length - 1 ? undefined : widths[i], flex: i === COLS.length - 1 ? 1 : undefined, minWidth: i === COLS.length - 1 ? widths[i] : undefined }}>
              <span className="truncate">{c.title}</span>
              {i < COLS.length - 1 && <span className="sec-th-resize" onMouseDown={startResize(i)} />}
            </div>
          ))}
        </div>
        <div className="sec-tbody">
          {rows.map((e, i) => {
            const sel = selection.has(e.id);
            const n = repeats(e);
            const color = kindColor(e.kind);
            return (
              <div key={e.id} className={cx('sec-tr', sel && 'selected')}
                   onMouseDown={ev => { if (ev.button === 0) click(ev, i); }}
                   onDoubleClick={() => { if (e.detail) onLineage(e); }}
                   onContextMenu={ev => contextMenu(ev, e)}>
                <div className="sec-td sec-time" style={{ width: widths[0] }}>{timeFmt.format(e.time)}</div>
                <div className="sec-td sec-secondary" style={{ width: widths[1] }} title={e.workspace ?? ''}><span className="truncate">{e.workspace ?? '—'}</span></div>
                <div className="sec-td" style={{ width: widths[2] }}>
                  <SF name={engineIcon(e.engine)} size={14} color={sel ? undefined : color} className="sec-engine-icon" />
                  <span className="truncate">{e.engine}</span>
                </div>
                <div className="sec-td sec-cond" style={{ width: widths[3] }} title={conditionHelp(e)}>
                  <MiddleTruncate text={e.condition} />
                  {e.detail && <SF name="point.3.connected.trianglepath.dotted" size={10} color={sel ? undefined : 'var(--label-tertiary)'} className="sec-chain" />}
                </div>
                <div className="sec-td sec-decision" style={{ width: widths[4] }}
                     title={n ? `${e.decision} (${n} times, last one shown)` : e.decision}>
                  <span className="sec-dot" style={{ background: sel ? '#fff' : color }} />
                  <span className="truncate" style={{ color: sel ? undefined : color }}>{e.decision}</span>
                  {n && <span className="sec-repeat">×{n}</span>}
                </div>
                <div className="sec-td sec-action" style={{ flex: 1, minWidth: widths[5] }}>
                  <RowAction e={e} />
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/** The inline quick action of a firewall / blocked-package row. A mirrored
 *  host's rows show it disabled, with why in the tooltip. */
function RowAction({ e }: { e: SecEvent }) {
  if (e.package) {
    return <span className="sec-row-action" title="Change this workspace's trusted packages in its settings on the Mac that runs it.">Allow…</span>;
  }
  if (!fwActionable(e)) return null;
  const fw = e.firewall!;
  const title = fw.denied ? 'Allow…' : fw.rule != null ? 'Rule…' : 'Block…';
  return <span className="sec-row-action" title={REMOTE_FW_HELP}>{title}</span>;
}

/** `.truncationMode(.middle)` for one line of text. */
function MiddleTruncate({ text }: { text: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const [shown, setShown] = useState(text);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const fit = () => {
      const par = el.parentElement!;
      const cs = getComputedStyle(par);
      const avail = par.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) - (el.nextElementSibling ? 16 : 0) - 1;
      el.textContent = text;
      if (el.offsetWidth <= avail) { setShown(text); return; }
      let lo = 0, hi = text.length;
      while (lo < hi) {
        const mid = Math.ceil((lo + hi) / 2);
        const head = Math.ceil(mid / 2), tail = Math.floor(mid / 2);
        el.textContent = text.slice(0, head) + '…' + text.slice(text.length - tail);
        if (el.offsetWidth <= avail) lo = mid; else hi = mid - 1;
      }
      const head = Math.ceil(lo / 2), tail = Math.floor(lo / 2);
      const s = text.slice(0, head) + '…' + text.slice(text.length - tail);
      el.textContent = s;
      setShown(s);
    };
    fit();
    const ro = new ResizeObserver(fit);
    if (el.parentElement) ro.observe(el.parentElement);
    return () => ro.disconnect();
  }, [text]);
  return <span ref={ref} className="sec-mid selectable">{shown}</span>;
}
