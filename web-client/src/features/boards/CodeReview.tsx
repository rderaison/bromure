// The Automations hub's Code Review tab — Overview and Findings — ported
// from AutomationHubView.swift (HubOverviewTab, HubPipelineCard +
// PipelineBand, HubFindingsTab + HubFindingsFlow, FindingsList,
// FindingDetailPanel). Same sections, same charts, same verbs.

import React, { useLayoutEffect, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import type { RemoteState } from '../../core/remote/types';
import { SF } from '../../ui/icons';
import { Button, PopUp, SearchField, cx, useMenu, type MenuItem } from '../../ui/kit';
import { type Run, automationsOf, runsOf, classify, liveRunTab, outcomeGlyph, outcomeTint, relNamed, dateTime, tasksOf, type CodingTask } from './model';
import { MiniSpinner, confirm } from './kanban';
import { Markdown } from './Markdown';

// ── Vocabulary (RepoFinding.Severity / .Status) ──────────────────────────

export const SEVERITIES = ['critical', 'high', 'medium', 'low', 'info'] as const;
export const STATUSES = ['new', 'triaged', 'inProgress', 'inReview', 'fixed', 'duplicate', 'dismissed'] as const;
export const PIPELINE = ['new', 'triaged', 'inProgress', 'inReview', 'fixed'] as const;
export const sevTint = (s: string) => ({ critical: 'var(--red)', high: 'var(--orange)', medium: 'var(--yellow)', low: 'var(--blue)', info: 'var(--gray)' } as Record<string, string>)[s] ?? 'var(--gray)';
export const sevName = (s: string) => s ? s[0].toUpperCase() + s.slice(1) : '';
export const statusName = (s: string) => ({ new: 'New', triaged: 'Backlog', inProgress: 'In progress', inReview: 'In review', fixed: 'Fixed', duplicate: 'Duplicate', dismissed: 'Dismissed' } as Record<string, string>)[s] ?? s;
export const statusTint = (s: string) => ({ new: 'var(--label-secondary)', triaged: 'var(--gray)', inProgress: 'var(--blue)', inReview: 'var(--purple)', fixed: 'var(--green)' } as Record<string, string>)[s] ?? 'var(--label-secondary)';
export const isOpen = (s: string) => ['new', 'triaged', 'inProgress', 'inReview'].includes(s);
/** RepoFinding.Status.bandColor: [color, opacity]. */
const band = (s: string): [string, number] => ({ new: ['var(--gray)', 0.45], triaged: ['var(--gray)', 0.7], inProgress: ['var(--blue)', 0.75], inReview: ['var(--indigo)', 0.75], fixed: ['var(--green)', 0.75] } as Record<string, [string, number]>)[s] ?? ['var(--gray)', 0.3];
const bandCSS = (s: string) => { const [c, a] = band(s); return `color-mix(in srgb, ${c} ${a * 100}%, transparent)`; };
const categoryName = (c?: string) => ({ security: 'Security', bug: 'Bug', dependency: 'Dependency', quality: 'Quality', other: 'Other' } as Record<string, string>)[c ?? ''] ?? sevName(c ?? '');
const ms = (d?: string) => d ? Date.parse(d) || 0 : 0;

export function location(f: any): string {
  if (!f.file) return '';
  if (f.line == null) return f.file;
  return f.endLine > f.line ? `${f.file}:${f.line}-${f.endLine}` : `${f.file}:${f.line}`;
}
/** Most severe first, then most recently seen. */
export const sortedForTriage = (fs: any[]) => [...fs].sort((a, b) =>
  SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity) || ms(b.lastSeenAt) - ms(a.lastSeenAt));

function stats(findings: any[], now = Date.now()) {
  const byStatus: Record<string, number> = {}, openBySeverity: Record<string, number> = {};
  let open = 0, fixedRecently = 0;
  const cutoff = now - 30 * 86_400_000;
  for (const f of findings) {
    byStatus[f.status] = (byStatus[f.status] ?? 0) + 1;
    if (isOpen(f.status)) { open++; openBySeverity[f.severity] = (openBySeverity[f.severity] ?? 0) + 1; }
    if (f.status === 'fixed' && ms(f.statusChangedAt ?? f.lastSeenAt) >= cutoff) fixedRecently++;
  }
  return { byStatus, openBySeverity, open, fixedRecently, count: (s: string) => byStatus[s] ?? 0 };
}

function useWidth<T extends HTMLElement>(): [React.RefObject<T | null>, number] {
  const ref = useRef<T>(null);
  const [w, setW] = useState(0);
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const ro = new ResizeObserver(() => setW(el.clientWidth)); ro.observe(el); setW(el.clientWidth);
    return () => ro.disconnect();
  }, []);
  return [ref, w];
}

// ── Shared pieces ────────────────────────────────────────────────────────

export function SeverityBadge({ severity, compact }: { severity: string; compact?: boolean }) {
  return <span className={cx('bx-cr-sev', compact && 'compact', severity === 'medium' && 'medium')} style={{ ['--sev' as any]: sevTint(severity) }}>{sevName(severity)}</span>;
}
export function StatusPill({ status }: { status: string }) {
  return <span className="bx-cr-pill"><span className="dot" style={{ background: statusTint(status) }} />{statusName(status)}</span>;
}
function HubCard({ title, trailing, children }: { title?: string; trailing?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div className="bx-cr-card">
      {(title || trailing) && <div className="bd-hrow"><span className="bx-cr-card-title">{title}</span><span className="spacer" />{trailing}</div>}
      {children}
    </div>
  );
}

/** Hands a finding over to an agent (fix / Switchboard / a session), with
 *  the flagged-text confirmation — the hub's `fix` / `routeToSwitchboard` /
 *  `askSession` actions. */
export function useFindingActions(host: RemoteHost, st: RemoteState, showFlash: (t: string, e?: boolean) => void) {
  const openMenu = useMenu();
  const handOver = async (path: string, body: any, success: string, failure: (why: string) => string, retry: () => void) => {
    try {
      const r = await host.request<any>('POST', path, body, { allowError: true } as any);
      host.refreshSoon();
      if (r?.flagged) {
        confirm({ title: "This finding's text was flagged",
          message: `The prompt-injection screen flagged it (${r.warning ?? r.error ?? ''}). It came from an agent reading repository content, and the agent you hand it to would read it too. Check it before handing it over.`,
          buttons: [{ label: 'Hand It Over Anyway', role: 'destructive', action: retry }, { label: 'Cancel', role: 'cancel' }] });
      } else if (r?.error) showFlash(failure(r.error === 'not found' ? 'the server runs an older Bromure — update it to hand findings to a session' : r.error), true);
      else showFlash(success);
    } catch { showFlash(failure("the server didn't answer"), true); }
  };
  const fix = (id: string, confirmed = false) => handOver(`/findings/${seg(id)}/fix`, confirmed ? { confirmed: true } : {},
    "Fix started — an agent is working on it in its own branch. It moves to In review when it's ready.", w => `Couldn't start the fix: ${w}`, () => fix(id, true));
  const route = (id: string, room?: string, confirmed = false) => handOver(`/findings/${seg(id)}/switchboard`, { ...(room ? { room } : {}), ...(confirmed ? { confirmed: true } : {}) },
    'Asked the Switchboard — it will propose a session and wait for your OK.', w => `Couldn't ask the Switchboard: ${w}`, () => route(id, room, true));
  const ask = (id: string, s: { id: string; label: string }, confirmed = false) => handOver(`/findings/${seg(id)}/session`, { session: s.id, confirmed },
    `Sent to ${s.label} — it works on the fix in its own session.`, w => `Couldn't send it to ${s.label}: ${w}`, () => ask(id, s, true));
  const setStatus = (id: string, status: string, note?: string) => host.send('POST', `/findings/${seg(id)}/status`, note ? { status, note } : { status });
  const markDuplicate = (id: string, of: string) => host.send('POST', `/findings/${seg(id)}/duplicate`, { of });
  const deleteFinding = (id: string) => host.send('DELETE', `/findings/${seg(id)}`);
  /** SwitchboardRouteItems: the global Switchboard, each room's, then sessions. */
  const routeItems = (x: any): MenuItem[] => {
    const items: MenuItem[] = [{ label: 'Ask the Switchboard Who Should Fix It', icon: 'person.2.wave.2', action: () => route(x.id) }];
    for (const r of st.agentRooms ?? []) items.push({ label: `Ask #${r.name}'s Switchboard`, icon: 'square.grid.2x2', action: () => route(x.id, r.id) });
    const sessions = (st.agentSessions ?? []).filter(s => !s.archivedAt && (s as any).role !== 'switchboard').slice(0, 20);
    if (sessions.length) {
      items.push({ separator: true }, { header: 'Ask a session to fix it' });
      for (const s of sessions) { const label = s.nickname ? '@' + s.nickname : `“${s.title}”`; items.push({ label, action: () => ask(x.id, { id: s.id, label }) }); }
    }
    return items;
  };
  const fixMenu = (e: React.MouseEvent, x: any) => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(),
    [{ label: 'Start a Fix Session', icon: 'wrench.and.screwdriver', action: () => fix(x.id) }, { separator: true }, ...routeItems(x)]);
  /** FindingTriageItems. */
  const triageItems = (x: any, onOpen?: () => void): MenuItem[] => {
    const items: MenuItem[] = [];
    if (onOpen) items.push({ label: 'Show Details', action: onOpen }, { separator: true });
    if (isOpen(x.status) && !x.taskID) items.push(...routeItems(x), { separator: true });
    if (isOpen(x.status)) {
      if (x.status === 'new') items.push({ label: 'Move to Backlog', action: () => setStatus(x.id, 'triaged') });
      else if (x.status === 'triaged') items.push({ label: 'Mark as New', action: () => setStatus(x.id, 'new') });
      items.push({ label: 'Mark as Fixed', action: () => setStatus(x.id, 'fixed', 'Marked fixed by hand') },
                 { label: 'Dismiss (Not an Issue)', action: () => setStatus(x.id, 'dismissed', 'Dismissed') });
    } else items.push({ label: 'Reopen', action: () => setStatus(x.id, 'new') });
    return items;
  };
  const rowMenu = (e: React.MouseEvent, x: any, onOpen?: () => void) => {
    e.stopPropagation();
    if ('clientX' in e && e.type === 'contextmenu') { e.preventDefault(); openMenu(e, triageItems(x, onOpen)); }
    else openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), triageItems(x));
  };
  return { fix, route, ask, setStatus, markDuplicate, deleteFinding, routeItems, fixMenu, triageItems, rowMenu, openMenu };
}
export type FindingActions = ReturnType<typeof useFindingActions>;

/** FixButton: a split "Fix ⌄" on rows; nothing (a spacer) once a fix runs. */
function FixButton({ f, fa }: { f: any; fa: FindingActions }) {
  if (!(isOpen(f.status) && (!f.taskID || f.status === 'triaged'))) return <span style={{ width: 78, flexShrink: 0 }} />;
  if (f.taskID) return <span className="bx-cr-fixcell"><Button size="small" icon="arrow.clockwise" onClick={e => { e.stopPropagation(); fa.fix(f.id); }}>Retry</Button></span>;
  return (
    <span className="bx-cr-fixcell">
      <span className="bx-cr-split" onClick={e => e.stopPropagation()}>
        <button onClick={() => fa.fix(f.id)}><SF name="wrench.and.screwdriver" size={12} />Fix</button>
        <button className="chev" onClick={e => fa.fixMenu(e, f)}><SF name="chevron.down" size={9} weight={600} /></button>
      </span>
    </span>
  );
}
function RowMenuButton({ f, fa }: { f: any; fa: FindingActions }) {
  return <button className="bx-cr-more" title="Backlog, dismiss, mark fixed…" onClick={e => fa.rowMenu(e, f)}><SF name="ellipsis" size={14} /></button>;
}

// ── Overview ─────────────────────────────────────────────────────────────

export interface FindingsQuery { status: string; severity: string; search: string; selected: string | null }

function StatTile({ value, label, icon, tint, detail, detailTint, chips, onClick }: {
  value: number; label: string; icon: string; tint: string; detail?: string; detailTint?: string; chips?: [string, number][]; onClick: () => void;
}) {
  return (
    <button className="bx-cr-tile" onClick={onClick}>
      <div className="bd-hrow" style={{ alignItems: 'flex-start' }}>
        <span className="bx-cr-tile-n">{value}</span><span className="spacer" />
        <span className="bx-cr-tile-icon" style={{ ['--t' as any]: tint }}><SF name={icon} size={13} weight={600} /></span>
      </div>
      <div className="bx-cr-tile-label">{label}</div>
      <div className="bd-hrow" style={{ gap: 6, minHeight: 18 }}>
        {(chips ?? []).map(([s, n]) => <span key={s} className="bx-cr-chip" style={{ ['--sev' as any]: sevTint(s) }}>{n} {sevName(s)}</span>)}
        {detail && <span style={{ fontSize: 11, color: detailTint ?? 'var(--label-secondary)' }}>{detail}</span>}
      </div>
    </button>
  );
}

/** The remediation pipeline as a band: its height at each stage the
 *  number of findings there (square root, so one finding still shows). */
export function PipelineBand({ counts, colors }: { counts: number[]; colors: string[] }) {
  const id = useRef('pb' + Math.random().toString(36).slice(2)).current;
  const W = 1000, H = 54, n = counts.length;
  if (!n) return null;
  const max = Math.max(...counts, 1), colW = W / n, mid = H / 2;
  const h = (c: number) => c === 0 ? 2 : 6 + (H - 6) * Math.sqrt(c / max);
  const cx_ = counts.map((_, i) => (i + 0.5) * colW), hs = counts.map(h);
  let d = `M0 ${mid - hs[0] / 2} L${cx_[0]} ${mid - hs[0] / 2}`;
  for (let i = 1; i < n; i++) { const m = (cx_[i - 1] + cx_[i]) / 2; d += ` C${m} ${mid - hs[i - 1] / 2} ${m} ${mid - hs[i] / 2} ${cx_[i]} ${mid - hs[i] / 2}`; }
  d += ` L${W} ${mid - hs[n - 1] / 2} L${W} ${mid + hs[n - 1] / 2} L${cx_[n - 1]} ${mid + hs[n - 1] / 2}`;
  for (let i = n - 1; i > 0; i--) { const m = (cx_[i] + cx_[i - 1]) / 2; d += ` C${m} ${mid + hs[i] / 2} ${m} ${mid + hs[i - 1] / 2} ${cx_[i - 1]} ${mid + hs[i - 1] / 2}`; }
  d += ` L0 ${mid + hs[0] / 2} Z`;
  return (
    <svg className="bx-cr-band" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label="Findings pipeline">
      <defs>{counts.map((_, i) => <clipPath key={i} id={`${id}-${i}`}><rect x={i * colW} y={0} width={colW} height={H} /></clipPath>)}</defs>
      {counts.map((_, i) => <path key={i} d={d} clipPath={`url(#${id}-${i})`} style={{ fill: colors[i] }} />)}
      {counts.map((_, i) => i > 0 && <line key={'s' + i} x1={i * colW} x2={i * colW} y1={0} y2={H} vectorEffect="non-scaling-stroke" style={{ stroke: 'var(--label)', strokeOpacity: 0.08, strokeWidth: 1 }} />)}
    </svg>
  );
}

function PipelineCard({ findings, repos, repo, setRepo }: { findings: any[]; repos: string[]; repo: string | null; setRepo: (r: string | null) => void }) {
  const s = stats(repo ? findings.filter(f => f.repo === repo) : findings);
  const counts = PIPELINE.map(p => s.count(p));
  return (
    <HubCard title="Pipeline" trailing={repos.length > 1 &&
      <PopUp value={repo ?? ''} onChange={v => setRepo(v || null)} options={[{ value: '', label: 'All repositories' }, ...repos.map(r => ({ value: r, label: r }))]} />}>
      <div className="bd-stack" style={{ gap: 6 }}>
        <div className="bx-cr-stages">{PIPELINE.map((p, i) => <div key={p}><span>{statusName(p)}</span><b>{counts[i]}</b></div>)}</div>
        <PipelineBand counts={counts} colors={PIPELINE.map(bandCSS)} />
        <div className="bx-cr-branches">
          <span><SF name="square.on.square" size={11} />{s.count('duplicate')} duplicate</span>
          <span><SF name="xmark.circle" size={11} />{s.count('dismissed')} dismissed</span>
        </div>
      </div>
    </HubCard>
  );
}

function FindingRow({ f, fa, onOpen }: { f: any; fa: FindingActions; onOpen: () => void }) {
  return (
    <div className="bx-cr-arow" onClick={onOpen} onContextMenu={e => fa.rowMenu(e, f, onOpen)}>
      <span style={{ width: 64, flexShrink: 0 }}><SeverityBadge severity={f.severity} compact /></span>
      <span className="bd-stack" style={{ gap: 2, minWidth: 0 }}>
        <span className="bx-cr-title truncate">{f.title}</span>
        <span className="bx-cr-loc truncate">{[f.repo, location(f)].filter(Boolean).join(' · ')}</span>
      </span>
      <span className="spacer" style={{ minWidth: 8 }} />
      <StatusPill status={f.status} />
      <span className="bx-cr-when" style={{ width: 90 }}>{relNamed(f.lastSeenAt)}</span>
      <FixButton f={f} fa={fa} />
      <RowMenuButton f={f} fa={fa} />
    </div>
  );
}

export function CodeReviewOverview({ st, watches, fa, repo, setRepo, showFindings, showRepositories, showRuns, openRun, acknowledge }: {
  st: RemoteState; watches: any[]; fa: FindingActions; repo: string | null; setRepo: (r: string | null) => void;
  showFindings: (q: Partial<FindingsQuery>, repo?: string | null) => void; showRepositories: () => void; showRuns: () => void;
  openRun: (r: Run) => void; acknowledge: (id: string) => void;
}) {
  const findings = (st.automations?.findings ?? []) as any[];
  const autos = automationsOf(st), runs = runsOf(st);
  const repos = watches.map(w => w.repo as string);
  const picked = repo && repos.includes(repo) ? repo : null;
  const isLive = (r: Run) => !!liveRunTab(r, autos, st);
  const cols = classify(runs, isLive);
  const s = stats(findings);
  const continuous = watches.filter(w => w.enabled && ((w.scans ?? []).includes('commits') || (w.scans ?? []).includes('pullRequests'))).length;
  const idsOf = (ws: any[]) => new Set(ws.flatMap(w => Object.values(w.automationIDs ?? {}) as string[]));
  const pickedIDs = picked ? idsOf(watches.filter(w => w.repo === picked)) : null;
  const inRepo = (rs: Run[]) => pickedIDs ? rs.filter(r => pickedIDs.has(r.automationID)) : rs;
  const open = sortedForTriage((picked ? findings.filter(f => f.repo === picked) : findings).filter(f => f.status === 'new' || f.status === 'triaged'));
  const failed = inRepo(cols.needsAttention);
  const watchIDs = idsOf(watches);
  const scans = inRepo(runs.filter(r => watchIDs.has(r.automationID) && r.outcome !== 'skipped'))
    .sort((a, b) => ms(b.firedAt) - ms(a.firedAt)).slice(0, 8);
  const nameOf = (id: string) => autos.find(a => a.id === id)?.name ?? '';
  return (
    <div className="bx-ah-scroll">
      <div className="bx-cr-overview">
        <div className="bx-cr-tiles">
          <StatTile value={watches.length} label="Watched repositories" icon="eye" tint="var(--accent)" detail={`${continuous} scanning continuously`} onClick={showRepositories} />
          <StatTile value={s.open} label="Open findings" icon="exclamationmark.shield" tint={(s.openBySeverity.critical ?? 0) > 0 ? 'var(--red)' : 'var(--orange)'}
                    chips={(['critical', 'high'] as const).filter(x => (s.openBySeverity[x] ?? 0) > 0).map(x => [x, s.openBySeverity[x]] as [string, number])}
                    onClick={() => showFindings({ status: 'open', severity: '' })} />
          <StatTile value={s.fixedRecently} label="Fixed in the last 30 days" icon="checkmark.shield" tint="var(--green)" onClick={() => showFindings({ status: 'fixed' })} />
          <StatTile value={cols.inProgress.length} label="Runs in progress" icon="play.circle" tint="var(--blue)"
                    detail={cols.needsAttention.length ? `${cols.needsAttention.length} need${cols.needsAttention.length === 1 ? 's' : ''} attention` : undefined} detailTint="var(--orange)" onClick={showRuns} />
        </div>
        <PipelineCard findings={findings} repos={repos} repo={picked} setRepo={setRepo} />
        <HubCard title="Needs attention" trailing={open.length > 8 && <button className="bd-link-btn" onClick={() => showFindings({ status: 'open' }, picked)}>All {open.length}</button>}>
          {!open.length && !failed.length ? <div className="bx-cr-none">Nothing needs you right now.</div> : (
            <div className="bx-cr-rows">
              {open.slice(0, 8).map(f => <FindingRow key={f.id} f={f} fa={fa} onOpen={() => showFindings({ selected: f.id, status: 'open', severity: '', search: '' }, null)} />)}
              {failed.slice(0, 5).map(r => (
                <div key={r.id} className="bx-cr-arow" onClick={() => openRun(r)}>
                  <span style={{ width: 64, flexShrink: 0 }}><SF name={outcomeGlyph(r.outcome)} size={14} color={outcomeTint(r.outcome)} /></span>
                  <span className="bd-stack" style={{ gap: 2, minWidth: 0 }}>
                    <span className="bx-cr-title truncate">{nameOf(r.automationID) || 'Deleted automation'}</span>
                    <span className="secondary" style={{ fontSize: 11 }}>{r.detail}</span>
                  </span>
                  <span className="spacer" style={{ minWidth: 8 }} />
                  <span className="bx-cr-when">{relNamed(r.firedAt)}</span>
                  <Button size="small" onClick={e => { e.stopPropagation(); acknowledge(r.id); }}>Dismiss</Button>
                </div>
              ))}
            </div>
          )}
        </HubCard>
        <HubCard title="Recent scans">
          {!scans.length ? <div className="bx-cr-none">No scans yet — they appear here as the watches run.</div> : (
            <div className="bx-cr-rows">
              {scans.map(r => {
                const live = isLive(r);
                const fresh = findings.filter(f => (f.runIDs ?? []).at(-1) === r.id).length;
                return (
                  <div key={r.id} className="bx-cr-arow scan" onClick={() => openRun(r)}>
                    <span style={{ width: 20, flexShrink: 0, display: 'grid', placeItems: 'center' }}>
                      {live ? <MiniSpinner /> : <SF name={r.completedAt ? 'checkmark.circle.fill' : outcomeGlyph(r.outcome)} size={15} color={r.completedAt ? 'var(--green)' : outcomeTint(r.outcome)} />}
                    </span>
                    <span className="bd-stack" style={{ gap: 2, minWidth: 0 }}>
                      <span className="bx-cr-title truncate">{nameOf(r.automationID)}</span>
                      <span className="secondary truncate" style={{ fontSize: 11 }}>{r.detail}</span>
                    </span>
                    <span className="spacer" style={{ minWidth: 8 }} />
                    {fresh > 0 && <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--orange)' }}>{fresh} new</span>}
                    <span className="bx-cr-when" style={{ width: 110 }}>{relNamed(r.firedAt)}</span>
                  </div>
                );
              })}
            </div>
          )}
        </HubCard>
      </div>
    </div>
  );
}

// ── Findings ─────────────────────────────────────────────────────────────

/** Findings by severity flowing into their status: two columns of bars
 *  joined by ribbons sized by count (HubFindingsFlow). */
export function FindingsFlow({ findings }: { findings: any[] }) {
  const [ref, W] = useWidth<HTMLDivElement>();
  const H = 150;
  const id = useRef('ff' + Math.random().toString(36).slice(2)).current;
  let body: React.ReactNode = null;
  if (!findings.length) body = <text x={W / 2} y={H / 2} textAnchor="middle" dominantBaseline="middle" className="bx-cr-flow-empty">No findings yet</text>;
  else if (W > 0) {
    const sevs = SEVERITIES.filter(s => findings.some(f => f.severity === s));
    const sts = STATUSES.filter(s => findings.some(f => f.status === s));
    const sevCount: Record<string, number> = {}, stCount: Record<string, number> = {}, pair: Record<string, number> = {};
    for (const f of findings) { sevCount[f.severity] = (sevCount[f.severity] ?? 0) + 1; stCount[f.status] = (stCount[f.status] ?? 0) + 1; pair[f.severity + '|' + f.status] = (pair[f.severity + '|' + f.status] ?? 0) + 1; }
    const layout = (keys: readonly string[], counts: Record<string, number>) => {
      const gap = 6, floor = 12, n = keys.length, total = keys.reduce((a, k) => a + (counts[k] ?? 0), 0);
      const spare = Math.max(H - gap * Math.max(n - 1, 0) - floor * n, 0);
      const out: Record<string, { y: number; h: number }> = {}; let y = 0;
      for (const k of keys) { const h = floor + (total > 0 ? spare * (counts[k] ?? 0) / total : 0); out[k] = { y, h }; y += h + gap; }
      return out;
    };
    const left = layout(sevs, sevCount), right = layout(sts, stCount);
    const barW = 5, x0 = 104, x1 = W - 130, mx = (x0 + x1) / 2;
    const lc: Record<string, number> = {}, rc: Record<string, number> = {};
    for (const s of sevs) lc[s] = left[s].y; for (const s of sts) rc[s] = right[s].y;
    const ribbons: React.ReactNode[] = [], grads: React.ReactNode[] = [];
    for (const sv of sevs) for (const sx of sts) {
      const n = pair[sv + '|' + sx] ?? 0; if (!n) continue;
      const l = lc[sv], r = rc[sx];
      const hl = left[sv].h * n / sevCount[sv], hr = right[sx].h * n / stCount[sx];
      const faded = !isOpen(sx), gid = `${id}-${sv}-${sx}`, [bc, ba] = band(sx);
      grads.push(<linearGradient key={gid} id={gid} gradientUnits="userSpaceOnUse" x1={x0} x2={x1} y1={0} y2={0}>
        <stop offset="0" style={{ stopColor: sevTint(sv), stopOpacity: faded ? 0.12 : 0.28 }} />
        <stop offset="1" style={{ stopColor: bc, stopOpacity: ba * (faded ? 0.12 : 0.30) }} />
      </linearGradient>);
      ribbons.push(<path key={gid} fill={`url(#${gid})`} d={`M${x0} ${l} C${mx} ${l} ${mx} ${r} ${x1} ${r} L${x1} ${r + hr} C${mx} ${r + hr} ${mx} ${l + hl} ${x0} ${l + hl} Z`} />);
      lc[sv] = l + hl; rc[sx] = r + hr;
    }
    body = <>
      <defs>{grads}</defs>
      {ribbons}
      {sevs.map(s => <g key={s}>
        <rect x={x0 - barW} y={left[s].y} width={barW} height={left[s].h} rx={2} style={{ fill: sevTint(s) }} />
        <text x={x0 - barW - 8} y={left[s].y + left[s].h / 2} textAnchor="end" dominantBaseline="central" className="bx-cr-flow-label">{sevName(s)}<tspan className="n" dx={6}>{sevCount[s]}</tspan></text>
      </g>)}
      {sts.map(s => { const [c, a] = band(s); return <g key={s}>
        <rect x={x1} y={right[s].y} width={barW} height={right[s].h} rx={2} style={{ fill: c, fillOpacity: a }} />
        <text x={x1 + barW + 8} y={right[s].y + right[s].h / 2} dominantBaseline="central" className="bx-cr-flow-label">{statusName(s)}<tspan className="n" dx={6}>{stCount[s]}</tspan></text>
      </g>; })}
    </>;
  }
  return <div ref={ref} className="bx-cr-flow"><svg width={W} height={H} role="img" aria-label="Findings by severity and status">{body}</svg></div>;
}

function FindingDetail({ f, st, fa, others, onClose, onOpenTask, openRun }: {
  f: any; st: RemoteState; fa: FindingActions; others: any[]; onClose: () => void; onOpenTask: (id: string) => void; openRun: (r: Run) => void;
}) {
  const task = f.taskID ? tasksOf(st).find(t => t.id === f.taskID) : undefined;
  const runs = ((f.runIDs ?? []) as string[]).map(id => runsOf(st).find(r => r.id === id)).filter(Boolean) as Run[];
  const autos = automationsOf(st);
  const loc = location(f);
  const src = f.file ? `https://github.com/${f.repo}/blob/${f.commit ?? 'HEAD'}/${f.file}${f.line != null ? `#L${f.line}${f.endLine > f.line ? `-L${f.endLine}` : ''}` : ''}` : null;
  const dismiss = () => confirm({ title: 'Dismiss this finding?', message: "Later scans that see it again won't reopen it.",
    buttons: [{ label: 'Dismiss', action: () => fa.setStatus(f.id, 'dismissed', 'Dismissed') }, { label: 'Cancel', role: 'cancel' }] });
  const statusMenu = (e: React.MouseEvent) => fa.openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
    ...(['new', 'triaged', 'fixed'] as const).map(s => ({ label: `Mark as ${statusName(s)}`, disabled: f.status === s, action: () => fa.setStatus(f.id, s) })),
    { label: 'Dismiss…', disabled: f.status === 'dismissed', action: dismiss },
    ...(others.length ? [{ separator: true }, { header: 'Duplicate of' }, ...sortedForTriage(others).slice(0, 40).map(o => ({ label: o.title, action: () => fa.markDuplicate(f.id, o.id) }))] : []),
    { separator: true }, { label: 'Delete Finding', destructive: true, action: () => { fa.deleteFinding(f.id); onClose(); } },
  ]);
  const stageText = (t: CodingTask) => t.stage === 'backlog' ? ((t as any).lastError ?? 'Fix not started') : t.stage === 'planning' ? 'Planning'
    : t.stage === 'inProgress' ? 'Agent working on the fix' : t.stage === 'testing' ? 'Ready for review'
    : (t as any).merged ? 'Merged' : (t as any).prOpened ? 'Pull request opened' : 'Closed';
  const canFix = isOpen(f.status) && (!f.taskID || f.status === 'triaged');
  return (
    <div className="bx-cr-detail">
      <div className="bx-cr-detail-head">
        <SeverityBadge severity={f.severity} />
        <span className="secondary" style={{ fontSize: 11 }}>{categoryName(f.category)}{f.cwe ? ' · ' + f.cwe : ''}</span>
        <span className="spacer" />
        <button className="bx-cr-more" onClick={onClose} title="Close"><SF name="xmark" size={12} /></button>
      </div>
      <div className="bx-cr-detail-body selectable">
        <div style={{ fontSize: 15, fontWeight: 600 }}>{f.title}</div>
        <div className="bd-hrow" style={{ gap: 8 }}>
          <button className="btn small bx-cr-statusbtn" onClick={statusMenu} title="Change the status">
            <span className="dot" style={{ background: statusTint(f.status) }} />{statusName(f.status)}<SF name="chevron.down" size={9} weight={600} />
          </button>
          <span className="spacer" />
          {f.status === 'new' && <Button size="small" onClick={() => fa.setStatus(f.id, 'triaged')}>Move to Backlog</Button>}
          {isOpen(f.status) ? <Button size="small" onClick={dismiss}>Dismiss…</Button> : <Button size="small" onClick={() => fa.setStatus(f.id, 'new')}>Reopen</Button>}
        </div>
        {f.statusNote && <div className="secondary" style={{ fontSize: 11 }}>{f.statusNote}</div>}
        {f.screenWarning && <div className="bd-hrow" style={{ gap: 5, fontSize: 11, color: 'var(--orange)' }}><SF name="exclamationmark.shield.fill" size={12} />Flagged by the prompt-injection screen: {f.screenWarning}</div>}
        {task && task.stage === 'backlog' && (task as any).lastError ? (
          <div className="bx-cr-fixbox error">
            <div className="bd-hrow" style={{ gap: 5, alignItems: 'flex-start', color: 'var(--red)', fontSize: 11.5 }}><SF name="exclamationmark.triangle.fill" size={12} />The fix couldn't start: {(task as any).lastError}</div>
            <div className="bd-hrow" style={{ gap: 8 }}>
              <Button size="large" variant="prominent" icon="arrow.clockwise" style={{ flex: 1 }} onClick={() => fa.fix(f.id)}>Retry the Fix</Button>
              <Button size="large" onClick={() => onOpenTask(task.id)}>Open Task</Button>
            </div>
          </div>
        ) : task ? (
          <div className="bx-cr-fixbox">
            <SF name="wrench.and.screwdriver" size={13} color="var(--blue)" />
            <span className="bd-stack" style={{ gap: 1, flex: 1, minWidth: 0 }}>
              <span className="truncate" style={{ fontSize: 12, fontWeight: 500 }}>{task.title}</span>
              <span className="secondary" style={{ fontSize: 11 }}>{stageText(task)}</span>
            </span>
            <Button size="small" onClick={() => onOpenTask(task.id)}>Open</Button>
          </div>
        ) : canFix ? (
          <div className="bd-stack" style={{ gap: 6 }}>
            <Button size="large" variant="prominent" icon="wrench.and.screwdriver" className="bx-cr-wide" onClick={() => fa.fix(f.id)}>Start a Fix</Button>
            <Button size="large" icon="person.2.wave.2" className="bx-cr-wide" onClick={e => fa.openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), fa.routeItems(f))}>Ask a Session or the Switchboard…</Button>
            <div className="secondary" style={{ fontSize: 11 }}>An agent fixes it on a branch of its own — or the Switchboard proposes which of your running sessions should. You review the change before anything merges.</div>
          </div>
        ) : null}
        <div className="bx-cr-meta">
          <span>Repository</span><a href={`https://github.com/${f.repo}`} target="_blank" rel="noreferrer">{f.repo}</a>
          {loc && <><span>Location</span>{src ? <a className="mono" href={src} target="_blank" rel="noreferrer">{loc}</a> : <span className="mono">{loc}</span>}</>}
          {f.commit && <><span>Commit</span><span className="mono">{String(f.commit).slice(0, 10)}</span></>}
          <span>First seen</span><span>{dateTime(f.firstSeenAt)}</span>
          <span>Last seen</span><span>{dateTime(f.lastSeenAt)}{f.seenCount > 1 ? ` · reported ${f.seenCount} times` : ''}</span>
        </div>
        <div className="bx-cr-section"><div className="bx-cr-section-title">What's wrong</div><Markdown text={f.summary ?? ''} /></div>
        {f.evidence && <div className="bx-cr-section"><div className="bx-cr-section-title">Evidence</div><pre className="bx-cr-evidence">{f.evidence}</pre></div>}
        {f.recommendation && <div className="bx-cr-section"><div className="bx-cr-section-title">Recommendation</div><Markdown text={f.recommendation} /></div>}
        {runs.length > 0 && (
          <div className="bx-cr-section"><div className="bx-cr-section-title">Reported by</div>
            {runs.map(r => <button key={r.id} className="bx-cr-runlink" onClick={() => openRun(r)}><span className="truncate">{autos.find(a => a.id === r.automationID)?.name ?? ''}</span><span className="spacer" /><span className="secondary">{dateTime(r.firedAt)}</span></button>)}
          </div>
        )}
      </div>
    </div>
  );
}

export function CodeReviewFindings({ st, fa, q, setQ, repoFilter, setRepoFilter, onOpenTask, openRun }: {
  st: RemoteState; fa: FindingActions; q: FindingsQuery; setQ: (p: Partial<FindingsQuery>) => void;
  repoFilter: string | null; setRepoFilter: (r: string | null) => void; onOpenTask: (id: string) => void; openRun: (r: Run) => void;
}) {
  const all = (st.automations?.findings ?? []) as any[];
  const watched = ((st.automations?.watches ?? []) as any[]).map(w => w.repo);
  const repos = [...new Set(all.map(x => x.repo as string))].sort();
  const repo = repoFilter && (watched.includes(repoFilter) || repos.includes(repoFilter)) ? repoFilter : null;
  const needle = q.search.trim().toLowerCase();
  const rows = sortedForTriage(all.filter(f =>
    (q.status === 'all' || (q.status === 'open' ? isOpen(f.status) : f.status === q.status))
    && (!q.severity || f.severity === q.severity) && (!repo || f.repo === repo)
    && (!needle || [f.title, f.file ?? '', f.summary ?? '', f.cwe ?? '', f.repo].join(' ').toLowerCase().includes(needle))));
  const sel = q.selected ? all.find(x => x.id === q.selected) : undefined;
  const compact = !!sel;
  const listRef = useRef<HTMLDivElement>(null);
  const move = (d: number) => {
    if (!rows.length) return;
    const i = rows.findIndex(r => r.id === q.selected);
    const next = rows[i < 0 ? 0 : Math.min(Math.max(i + d, 0), rows.length - 1)];
    setQ({ selected: next.id });
    listRef.current?.querySelector(`[data-id="${next.id}"]`)?.scrollIntoView({ block: 'nearest' });
  };
  return (
    <div className="bx-cr-findings">
      <FindingsFlow findings={repo ? all.filter(f => f.repo === repo) : all} />
      <div className="bx-cr-filters">
        <SearchField value={q.search} onChange={v => setQ({ search: v })} placeholder="Search findings" style={{ flex: 1 }} />
        <span className="bx-cr-flabel">Status</span>
        <PopUp value={q.status} onChange={v => setQ({ status: v })} options={[{ value: 'open', label: 'Open' }, { value: 'all', label: 'All' }, { value: '-', label: '', divider: true }, ...STATUSES.map(s => ({ value: s as string, label: statusName(s) }))]} />
        <span className="bx-cr-flabel">Severity</span>
        <PopUp value={q.severity} onChange={v => setQ({ severity: v })} options={[{ value: '', label: 'Any severity' }, ...SEVERITIES.map(s => ({ value: s as string, label: sevName(s) }))]} />
        {repos.length > 1 && <><span className="bx-cr-flabel">Repository</span>
          <PopUp value={repo ?? ''} onChange={v => setRepoFilter(v || null)} options={[{ value: '', label: 'All repositories' }, ...repos.map(r => ({ value: r, label: r }))]} /></>}
        <span className="secondary" style={{ fontSize: 11, whiteSpace: 'nowrap' }}>{rows.length} finding{rows.length === 1 ? '' : 's'}</span>
      </div>
      <div className="bx-cr-split-pane">
        <div className="bx-cr-table" tabIndex={0} onKeyDown={e => { if (e.key === 'ArrowDown') { e.preventDefault(); move(1); } else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); } }}>
          {!all.length ? (
            <div className="empty-state" style={{ flex: 1 }}><SF name="checkmark.shield" size={30} color="var(--label-tertiary)" /><h3>No findings yet</h3>
              <span>Findings appear here as the repository watches scan. Watch a repository from the Repositories tab.</span></div>
          ) : !rows.length ? (
            <div className="empty-state" style={{ flex: 1 }}><SF name="line.3.horizontal.decrease.circle" size={30} color="var(--label-tertiary)" /><h3>No matching findings</h3>
              <span>Nothing matches these filters.</span>
              <Button onClick={() => { setQ({ search: '', severity: '', status: 'all' }); setRepoFilter(null); }}>Clear Filters</Button></div>
          ) : <>
            <div className="bx-cr-thead">
              <span style={{ width: 72 }}>Severity</span><span style={{ flex: 1 }}>Finding</span>
              {!compact && <span style={{ width: 160 }}>Repository</span>}
              <span style={{ width: 104 }}>Status</span>
              {!compact && <span style={{ width: 120 }}>Seen</span>}
              <span style={{ width: 78 + 22 + 12 }} />
            </div>
            <div className="bx-cr-tbody" ref={listRef}>
              {rows.map(f => (
                <div key={f.id} data-id={f.id} className={cx('bx-cr-trow', q.selected === f.id && 'on')}
                     onClick={() => setQ({ selected: q.selected === f.id ? null : f.id })}
                     onContextMenu={e => fa.rowMenu(e, f, () => setQ({ selected: f.id }))}>
                  <span style={{ width: 72, flexShrink: 0 }}><SeverityBadge severity={f.severity} compact /></span>
                  <span className="bd-stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
                    <span className="bd-hrow" style={{ gap: 5, minWidth: 0 }}>
                      {f.screenWarning && <span title="Flagged by the prompt-injection screen"><SF name="exclamationmark.shield.fill" size={12} color="var(--orange)" /></span>}
                      <span className="bx-cr-title truncate">{f.title}</span>
                    </span>
                    <span className="bx-cr-loc truncate">{compact ? [f.repo, location(f)].filter(Boolean).join(' · ') : (location(f) || categoryName(f.category))}</span>
                  </span>
                  {!compact && <span className="secondary truncate" style={{ width: 160, flexShrink: 0, fontSize: 12 }}>{f.repo}</span>}
                  <span style={{ width: 104, flexShrink: 0 }}><StatusPill status={f.status} /></span>
                  {!compact && <span className="secondary truncate" style={{ width: 120, flexShrink: 0, fontSize: 11.5 }}>{relNamed(f.lastSeenAt)}{f.seenCount > 1 ? ` · ×${f.seenCount}` : ''}</span>}
                  <FixButton f={f} fa={fa} />
                  <RowMenuButton f={f} fa={fa} />
                </div>
              ))}
            </div>
          </>}
        </div>
        {sel && <FindingDetail f={sel} st={st} fa={fa} onClose={() => setQ({ selected: null })} onOpenTask={onOpenTask} openRun={openRun}
                               others={all.filter(o => o.repo === sel.repo && o.profileID === sel.profileID && o.id !== sel.id && o.status !== 'duplicate')} />}
      </div>
    </div>
  );
}
