// The Automations hub (AutomationHubView.swift): a glass header with the
// Automations / Runs / Code Review tabs over the board backdrop. Runs is the
// run board (AutomationKanbanView.swift); Automations lists them by kind
// (AutomationsHome.swift); Code Review is the repository watches' findings.

import React, { useEffect, useLayoutEffect, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import type { RemoteState } from '../../core/remote/types';
import { useRemote } from '../../app/store';
import { useHostCtx, usePersisted } from '../../app/hostContext';
import { useWindows } from '../../app/windows';
import { SF } from '../../ui/icons';
import { Button, Checkbox, PopUp, Segmented, Sheet, Switch, TextField, cx, useMenu, type MenuItem } from '../../ui/kit';
import {
  type Automation, type Run, type Kind, automationsOf, runsOf, classify, liveRunTab, outcomeGlyph, outcomeTint, scheduleSummary, moment,
  dateTime, relNamed, kindOf, kindTint, kindIcon, kindTitle, kindTagline, kindSteps, describeWhen, describeWhat, workspaceOf, accentOf, toolName,
  tzDiffers, zoneName, WEEKDAYS, isValidRepoSlug, uuid, isoNow,
} from './model';
import { BoardBackdrop, KanbanColumn, Card, MiniSpinner, PrimaryButton, columnWidth, confirm, useTick } from './kanban';
import { Markdown } from './Markdown';
import { openRunWindow } from './RunWindow';
import { openAutomationEditor, confirmDeleteAutomation } from './AutomationEditor';
import { openTaskReview } from './TaskReview';
import { requestResending } from './resend';
import './boards.css';

export type HubTab = 'automations' | 'runs' | 'security';
type SecTab = 'overview' | 'findings' | 'repositories';

export function AutomationHubView({ host, initialTab }: { host: RemoteHost; initialTab?: HubTab }) {
  useTick();
  const st = useRemote(host, s => s) as RemoteState | undefined;
  const wm = useWindows();
  const [tab, setTab] = usePersisted<HubTab>('bromure.automations.tab', initialTab ?? 'runs');
  const [secTab, setSecTab] = useState<SecTab>('overview');
  const [flash, setFlash] = useState<{ text: string; error?: boolean } | null>(null);
  const [chooser, setChooser] = useState(false);
  const [watchEdit, setWatchEdit] = useState<{ draft: any; isNew: boolean } | null>(null);
  const [repoFilter, setRepoFilter] = useState<string | null>(null);
  useEffect(() => { if (initialTab) setTab(initialTab); }, [initialTab]); // eslint-disable-line
  useEffect(() => { if (!flash) return; const t = setTimeout(() => setFlash(null), 8000); return () => clearTimeout(t); }, [flash]);

  const autos = automationsOf(st);
  const watches = (st?.automations?.watches ?? []) as any[];
  const showFlash = (text: string, error?: boolean) => setFlash({ text, error });
  const nameOf = (id: string) => { const n = autos.find(a => a.id === id)?.name ?? ''; return n || 'Untitled automation'; };
  const actions = {
    edit: (id: string) => openAutomationEditor(wm, host, id),
    newAutomation: (trigger?: Automation['trigger']) => openAutomationEditor(wm, host, undefined, trigger),
    runNow: (id: string) => { host.send('POST', `/automations/${seg(id)}/run`); showFlash(`“${nameOf(id)}” is starting — follow it on the Runs tab.`); },
    toggle: (id: string) => host.send('POST', `/automations/${seg(id)}/toggle`),
    delete: (id: string) => confirmDeleteAutomation(host, id),
    openRun: (r: Run) => openRunWindow(wm, host, r.id),
    acknowledge: (id: string) => host.send('POST', `/automation-runs/${seg(id)}/acknowledge`),
    scanNow: (w: any) => {
      host.send('POST', `/watches/${seg(w.id)}/scan`);
      showFlash(w.scheduledScope === 'newCommits'
        ? `Review of the new commits on ${w.repo} requested — it shows under Recent scans once the agent starts (no run if nothing landed since the last review).`
        : `Full scan of ${w.repo} requested — it shows under Recent scans once the agent starts.`);
    },
    baseline: (w: any) => { host.send('POST', `/watches/${seg(w.id)}/baseline`); showFlash(`Full scan of ${w.repo} requested — it shows under Recent scans once the agent starts.`); },
    toggleWatch: (w: any) => host.send('POST', `/watches/${seg(w.id)}/toggle`),
    deleteWatch: (w: any) => confirm({ title: `Stop watching ${w.repo}?`, message: 'Its scan automations are removed. Findings stay.', buttons: [{ label: 'Stop Watching', role: 'destructive', action: () => host.send('DELETE', `/watches/${seg(w.id)}`) }, { label: 'Cancel', role: 'cancel' }] }),
    editWatch: (w: any) => setWatchEdit({ draft: w, isNew: false }),
  };
  const newWatch = () => {
    const ws = st?.workspaces ?? [];
    const first = ws.find(w => (w as any).hasGitHubToken) ?? ws[0];
    if (!first) return;
    setWatchEdit({ isNew: true, draft: {
      id: uuid(), repo: '', profileID: first.id, repoPath: '', tool: first.tool ?? 'claude', enabled: true, scans: ['fullScan', 'commits', 'pullRequests'],
      focus: 'both', fullScanWeekday: 2, fullScanHour: 3, commitBranch: '', instructions: '', automationIDs: {}, createdAt: isoNow(),
      scheduledScope: 'newCommits', firstRunBaseline: true, reviewedThrough: {}, maxParallelScans: 1,
    } });
  };
  const choose = (k: Kind) => { setChooser(false); if (k === 'scheduled') actions.newAutomation('schedule'); else if (k === 'event') actions.newAutomation('githubPullRequest'); else newWatch(); };

  return (
    <BoardBackdrop tints={['var(--blue)', 'var(--purple)', 'var(--teal)']} className="bd-board">
      <div className="bd-header-wrap bx-ah">
        <div className="bd-glass bx-ah-glass">
          <div className="bd-header bx-ah-header" data-drag>
            <span className="bd-hrow" style={{ gap: 8 }}>
              <AutomationGlyph size={16} />
              <span className="bd-title">Automations</span>
            </span>
            <HubTabBar value={tab} onChange={setTab} tabs={[['automations', 'Automations'], ['runs', 'Runs'], ['security', 'Code Review']]} />
            <span className="spacer" />
            <PrimaryButton icon="plus" onClick={() => setChooser(true)}>New Automation</PrimaryButton>
          </div>
          {tab === 'security' && watches.length > 0 && (
            <div className="bx-ah-secbar">
              <Segmented value={secTab} onChange={setSecTab} options={[{ value: 'overview', label: 'Overview' }, { value: 'findings', label: 'Findings' }, { value: 'repositories', label: 'Repositories' }]} />
              <span className="spacer" />
              <ScanNowButton watches={watches} onScan={actions.scanNow} />
              <Button size="small" icon="plus" onClick={newWatch}>Watch a Repository…</Button>
            </div>
          )}
        </div>
      </div>
      {flash && (
        <div className={cx('bx-ah-flash', flash.error && 'error')}>
          <SF name={flash.error ? 'exclamationmark.triangle.fill' : 'checkmark.circle.fill'} size={13} color={flash.error ? 'var(--orange)' : 'var(--green)'} />
          <span style={{ flex: 1 }}>{flash.text}</span>
          <button className="bd-link-btn" onClick={() => setFlash(null)}><SF name="xmark" size={11} /></button>
        </div>
      )}
      <div className="bx-ah-content">
        {!st ? null
          : tab === 'runs' ? <RunsBoard st={st} actions={actions} onNew={() => setChooser(true)} />
          : tab === 'automations' ? <HomeTab st={st} actions={actions} onChoose={choose} onShowRuns={() => setTab('runs')}
                                             onOpenWatch={w => { setRepoFilter(w.repo); setTab('security'); setSecTab('findings'); }} />
          : watches.length === 0 ? <SecurityWelcome onNew={newWatch} />
          : secTab === 'overview' ? <Overview st={st} watches={watches} onFindings={() => setSecTab('findings')} onScan={actions.scanNow} onNew={newWatch} />
          : secTab === 'findings' ? <Findings host={host} st={st} repoFilter={repoFilter} setRepoFilter={setRepoFilter} showFlash={showFlash} onOpenTask={id => openTaskReview(wm, host, id)} />
          : <Repositories st={st} watches={watches} actions={actions} onNew={newWatch} />}
      </div>
      {chooser && (
        <Sheet width={900} onClose={() => setChooser(false)}>
          <div className="bx-ah-chooser">
            <div className="bd-stack" style={{ gap: 4 }}>
              <div className="bx-ah-big">What should run on its own?</div>
              <div className="secondary" style={{ fontSize: 12.5 }}>Every automation runs an agent unattended in one of your workspaces, under its credentials and guardrails.</div>
            </div>
            <KindCards onChoose={choose} />
            <div className="bd-hrow"><span className="spacer" /><Button onClick={() => setChooser(false)}>Cancel</Button></div>
          </div>
        </Sheet>
      )}
      {watchEdit && <WatchEditor host={host} st={st!} draft={watchEdit.draft} isNew={watchEdit.isNew} onCancel={() => setWatchEdit(null)}
                                 onSave={(w, scan) => {
                                   host.send('POST', '/watches', { ...w, scanNow: scan });
                                   setWatchEdit(null);
                                   if (watchEdit.isNew) { setTab('security'); setSecTab('repositories'); showFlash(scan ? `Now watching ${w.repo} — the first review is starting.` : `Now watching ${w.repo}.`); }
                                 }} />}
    </BoardBackdrop>
  );
}

/** bolt.badge.clock.fill — a bolt with a small clock badge (no Lucide twin). */
export function AutomationGlyph({ size = 16, color = 'var(--accent)' }: { size?: number; color?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" style={{ flexShrink: 0 }}>
      <path d="M8.6 1.2 2.8 10.6c-.3.5 0 1 .6 1h4.1l-1.4 6.6c-.1.6.6.9 1 .4l2.9-4.1a5.2 5.2 0 0 1 .3-5.6l-.6.1h-.1l1.3-6.4c.2-.6-.6-1-1-.5Z" fill={color} />
      <circle cx="14.6" cy="14.4" r="4.6" fill={color} />
      <path d="M14.6 11.9v2.6l1.7 1" stroke="var(--control-bg)" strokeWidth="1.3" fill="none" strokeLinecap="round" />
    </svg>
  );
}

function HubTabBar<T extends string>({ value, onChange, tabs }: { value: T; onChange: (v: T) => void; tabs: [T, string][] }) {
  return (
    <div className="bx-ah-tabs">
      {tabs.map(([v, label], i) => (
        <React.Fragment key={v}>
          {i > 0 && <span className="bx-ah-tab-sep" style={{ opacity: value === v || value === tabs[i - 1][0] ? 0 : 1 }} />}
          <button className={cx('bx-ah-tab', value === v && 'on')} onClick={() => onChange(v)}>{label}</button>
        </React.Fragment>
      ))}
    </div>
  );
}

function ScanNowButton({ watches, onScan }: { watches: any[]; onScan: (w: any) => void }) {
  const openMenu = useMenu();
  if (watches.length === 1) return <Button size="small" icon="play.fill" onClick={() => onScan(watches[0])}
    title={watches[0].scheduledScope === 'newCommits' ? `Review the new commits on ${watches[0].repo} now` : `Run a full scan of ${watches[0].repo} now`}>Scan Now</Button>;
  return <Button size="small" icon="play.fill" onClick={e => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), watches.map(w => ({ label: w.repo, action: () => onScan(w) })))}>Scan Now</Button>;
}

// ── Runs board ────────────────────────────────────────────────────────────

type Actions = {
  edit: (id: string) => void; runNow: (id: string) => void; toggle: (id: string) => void; delete: (id: string) => void;
  openRun: (r: Run) => void; acknowledge: (id: string) => void; scanNow: (w: any) => void; baseline: (w: any) => void;
  toggleWatch: (w: any) => void; deleteWatch: (w: any) => void; editWatch: (w: any) => void;
};

function RunsBoard({ st, actions, onNew }: { st: RemoteState; actions: Actions; onNew: () => void }) {
  const autos = automationsOf(st);
  const runs = runsOf(st);
  const tz = st.automations?.timeZone;
  const ref = useRef<HTMLDivElement>(null);
  const [avail, setAvail] = useState(1000);
  const [doneLimit, setDoneLimit] = useState(30);
  const [archived, setArchived] = useState<Run[] | null>(null);
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const ro = new ResizeObserver(() => setAvail(el.clientWidth)); ro.observe(el); setAvail(el.clientWidth);
    return () => ro.disconnect();
  }, [autos.length > 0]);
  if (!autos.length) {
    return (
      <div className="empty-state" style={{ flex: 1 }}>
        <AutomationGlyph size={34} color="var(--label-tertiary)" />
        <h3>No runs yet</h3>
        <span style={{ maxWidth: 420 }}>Each time an automation fires, its run shows up here — scheduled, in progress, then done. Create an automation to get started.</span>
        <Button onClick={onNew}>New Automation…</Button>
      </div>
    );
  }
  const isLive = (r: Run) => !!liveRunTab(r, autos, st);
  const cols = classify(runs, isLive);
  let done = cols.done;
  if (archived) { const seen = new Set(done.map(r => r.id)); done = [...done, ...archived.filter(r => !seen.has(r.id))]; }
  const n = cols.needsAttention.length ? 4 : 3;
  const w = columnWidth(n, avail);
  const accent = (aid: string) => accentOf(st, autos.find(a => a.id === aid)?.profileID);
  const name = (aid: string) => { const a = autos.find(x => x.id === aid); return a ? a.name || 'Untitled automation' : 'Untitled automation'; };
  // Older runs live in the archive on disk — the viewer's own (the native
  // fat client reads its local archive too, which a mirror never fills).
  const loadOlder = () => setArchived([]);
  return (
    <div className="bd-columns" ref={ref}>
      <div className="bd-columns-strip bx-ah-strip">
        <KanbanColumn title="Scheduled" icon="calendar" count={autos.length} width={w}>
          {autos.map(a => {
            const ws = workspaceOf(st, a.profileID);
            const running = cols.inProgress.filter(r => r.automationID === a.id).length;
            const next = st.automations?.nextFires?.[a.id];
            return (
              <Card key={a.id} onClick={() => actions.edit(a.id)} menu={() => [
                { label: 'Run Now', action: () => actions.runNow(a.id) },
                { label: a.enabled ? 'Pause' : 'Resume', action: () => actions.toggle(a.id) },
                { separator: true }, { label: 'Delete…', destructive: true, action: () => actions.delete(a.id) },
              ]}>
                <div className="bd-stack" style={{ gap: 5 }}>
                  <div className="bd-hrow" style={{ gap: 6 }}>
                    <span className="dot" style={{ width: 8, height: 8, background: ws?.accentHex ?? '#888', opacity: a.enabled ? 1 : 0.4 }} />
                    <span className="bd-card-title sm truncate">{a.name || 'Untitled automation'}</span>
                    <span className="spacer" />
                    {running > 0 && <span className="bx-ah-running" title="Runs in progress">{running}</span>}
                  </div>
                  <div className="bd-state truncate">{scheduleSummary(a, tz)}</div>
                  <div className="bd-hrow" style={{ gap: 4 }}>
                    {!a.enabled ? <span className="bx-ah-paused">Paused</span>
                      : next ? <><SF name="clock" size={9} color="var(--label-tertiary)" /><span className="bd-date truncate">next {moment(next, tz)}</span></> : null}
                    <span className="spacer" />
                    {ws && <span className="bd-date truncate">{ws.name}</span>}
                  </div>
                </div>
              </Card>
            );
          })}
        </KanbanColumn>
        <KanbanColumn title="In Progress" icon="play.circle" count={cols.inProgress.length} width={w} emptyText="Nothing running">
          {cols.inProgress.map(r => {
            const tab = liveRunTab(r, autos, st) as any;
            const status = tab?.agentStatus ?? 'working';
            return (
              <Card key={r.id} tint={status === 'needsInput' ? 'var(--red)' : undefined} onClick={() => actions.openRun(r)} title="Open the run's live session">
                <div className="bd-stack" style={{ gap: 5 }}>
                  <div className="bd-hrow" style={{ gap: 6 }}>
                    <StatusDot status={status} />
                    <span className="bd-card-title sm truncate">{name(r.automationID)}</span>
                    <span className="spacer" />
                    <span className="dot" style={{ background: accent(r.automationID) }} />
                  </div>
                  {r.detail !== r.branchSlug && <div className="bd-state l2">{r.detail}</div>}
                  <div className="bd-hrow"><span className="bd-date">started {relNamed(r.firedAt)}</span><span className="spacer" />
                    {status === 'needsInput' && <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--red)' }}>Needs your input</span>}</div>
                </div>
              </Card>
            );
          })}
        </KanbanColumn>
        {cols.needsAttention.length > 0 && (
          <KanbanColumn title="Needs Attention" icon="exclamationmark.triangle.fill" count={cols.needsAttention.length} tint="var(--orange)" width={w}>
            {cols.needsAttention.map(r => (
              <Card key={r.id} tint="var(--orange)" onClick={() => actions.openRun(r)} menu={() => [
                { label: 'Run Again', action: () => actions.runNow(r.automationID) }, { label: 'Dismiss', action: () => actions.acknowledge(r.id) },
              ]}>
                <div className="bd-stack" style={{ gap: 5 }}>
                  <div className="bd-hrow" style={{ gap: 6 }}>
                    <SF name={outcomeGlyph(r.outcome)} size={11} color={outcomeTint(r.outcome)} />
                    <span className="bd-card-title sm truncate">{name(r.automationID)}</span>
                  </div>
                  <div className="bd-state l3">{r.detail}</div>
                  <div className="bd-hrow"><span className="bd-date">{relNamed(r.firedAt)}</span><span className="spacer" />
                    <button className="bx-ah-dismiss" title="Move this run to Done" onClick={() => actions.acknowledge(r.id)}>Dismiss</button></div>
                </div>
              </Card>
            ))}
          </KanbanColumn>
        )}
        <KanbanColumn title="Done" icon="checkmark.circle" count={done.length} width={w} emptyText="No runs yet">
          {done.slice(0, doneLimit).map(r => (
            <Card key={r.id} onClick={() => actions.openRun(r)}>
              <div className="bd-stack" style={{ gap: 4 }}>
                <div className="bd-hrow" style={{ gap: 6 }}>
                  <SF name={outcomeGlyph(r.outcome)} size={10} color={outcomeTint(r.outcome)} />
                  <span className="truncate" style={{ fontSize: 12, fontWeight: 500 }}>{name(r.automationID)}</span>
                  <span className="spacer" />
                  <span className="dot" style={{ width: 6, height: 6, background: accent(r.automationID) }} />
                </div>
                {r.detail !== r.branchSlug && r.detail && <div className="bd-state truncate" style={{ fontSize: 10 }}>{r.detail}</div>}
                <div className="bd-date" style={{ fontSize: 9.5, fontVariantNumeric: 'tabular-nums' }}>{dateTime(r.completedAt ?? r.firedAt)}</div>
              </div>
            </Card>
          ))}
          {done.length > doneLimit && <button className="bx-ah-link" onClick={() => setDoneLimit(doneLimit + 50)}>Show more ({done.length - doneLimit})</button>}
          {archived == null ? <button className="bx-ah-link" title="Runs beyond the recent window are archived on disk — nothing is ever deleted." onClick={loadOlder}>Load older runs…</button>
            : archived.length === 0 ? <div className="bd-date" style={{ fontSize: 10 }}>No archived runs.</div> : null}
        </KanbanColumn>
      </div>
    </div>
  );
}

export function StatusDot({ status }: { status: string }) {
  if (status === 'working') return <span style={{ color: 'var(--orange)', display: 'inline-grid' }}><MiniSpinner size={10} /></span>;
  return <span className="dot" style={{ background: status === 'needsInput' ? 'var(--red)' : 'var(--green)' }} />;
}

// ── Automations tab ───────────────────────────────────────────────────────

function HomeTab({ st, actions, onChoose, onShowRuns, onOpenWatch }: { st: RemoteState; actions: Actions; onChoose: (k: Kind) => void; onShowRuns: () => void; onOpenWatch: (w: any) => void }) {
  const autos = automationsOf(st).filter(a => !a.watchID).sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt));
  const runs = runsOf(st);
  const watches = (st.automations?.watches ?? []) as any[];
  const findings = (st.automations?.findings ?? []) as any[];
  const tz = st.automations?.timeZone;
  const live = (r: Run) => !!liveRunTab(r, automationsOf(st), st);
  const attention = classify(runs, live).needsAttention;
  const scheduled = autos.filter(a => a.trigger === 'schedule'), events = autos.filter(a => a.trigger !== 'schedule');
  const section = (k: Kind, count: number, rows: React.ReactNode) => (
    <div className="bx-ah-section">
      <div className="bd-hrow" style={{ gap: 10 }}>
        <span className="bx-ah-kind-icon" style={{ ['--k' as any]: kindTint(k) }}><SF name={kindIcon(k)} size={12} weight={600} /></span>
        <div className="bd-stack" style={{ gap: 1 }}>
          <div className="bd-hrow" style={{ gap: 6 }}><span className="bx-ah-section-title">{kindTitle(k)}</span>{count > 0 && <span className="bx-ah-count">{count}</span>}</div>
          <div className="secondary" style={{ fontSize: 11.5 }}>{kindTagline(k)}</div>
        </div>
        <span className="spacer" />
        <Button size="small" icon="plus" onClick={() => onChoose(k)}>Add</Button>
      </div>
      {count === 0 ? (
        <button className="bx-ah-empty-add" onClick={() => onChoose(k)}>
          <SF name="plus.circle" size={12} />
          {k === 'scheduled' ? 'No scheduled automations — e.g. a weekday-morning triage of open issues'
            : k === 'event' ? 'No event automations — e.g. review every new pull request' : 'No repository is watched — set up a continuous code review'}
        </button>
      ) : <div className="bd-stack" style={{ gap: 8 }}>{rows}</div>}
    </div>
  );
  return (
    <div className="bx-ah-scroll">
      <div className="bx-ah-home">
        {!scheduled.length && !events.length && !watches.length ? (
          <>
            <div className="bd-stack" style={{ gap: 6 }}>
              <div className="bx-ah-big" style={{ fontSize: 22 }}>Nothing runs on its own yet</div>
              <div className="secondary" style={{ fontSize: 13 }}>Pick what should start an agent. Every automation runs unattended in one of your workspaces, under its credentials and guardrails.</div>
            </div>
            <KindCards onChoose={onChoose} />
          </>
        ) : <>
          {attention.length > 0 && (
            <button className="bx-ah-attn" onClick={onShowRuns}>
              <SF name="exclamationmark.triangle.fill" size={13} color="var(--orange)" />
              <span style={{ fontSize: 12.5, fontWeight: 500 }}>{attention.length} run(s) need your attention</span>
              <span className="spacer" /><span className="secondary" style={{ fontSize: 12 }}>Open Runs</span><SF name="chevron.right" size={11} color="var(--label-secondary)" />
            </button>
          )}
          {section('scheduled', scheduled.length, scheduled.map(a => <AutomationRow key={a.id} a={a} st={st} tz={tz} actions={actions} onShowRuns={onShowRuns} live={live} />))}
          {section('event', events.length, events.map(a => <AutomationRow key={a.id} a={a} st={st} tz={tz} actions={actions} onShowRuns={onShowRuns} live={live} />))}
          {section('security', watches.length, watches.map(w => <WatchRow key={w.id} w={w} st={st} findings={findings.filter(f => f.watchID === w.id)} actions={actions} onOpen={() => onOpenWatch(w)} />))}
        </>}
      </div>
    </div>
  );
}

const triggerIcon = (a: Automation) => ({ schedule: a.frequency === 'interval' ? 'arrow.clockwise' : 'clock', githubPullRequest: 'arrow.triangle.pull', githubIssue: 'exclamationmark.circle',
  githubCommit: 'point.topleft.down.to.point.bottomright.curvepath', linearIssue: 'line.3.horizontal.decrease.circle', afterAutomation: 'link' } as Record<string, string>)[a.trigger];

function AutomationRow({ a, st, tz, actions, onShowRuns, live }: { a: Automation; st: RemoteState; tz?: string; actions: Actions; onShowRuns: () => void; live: (r: Run) => boolean }) {
  const openMenu = useMenu();
  const k = kindOf(a), tint = kindTint(k);
  const ws = workspaceOf(st, a.profileID);
  const runs = runsOf(st).filter(r => r.automationID === a.id).sort((x, y) => Date.parse(y.firedAt) - Date.parse(x.firedAt));
  const running = runs.filter(live).length;
  const last = runs.find(r => r.outcome !== 'skipped' || !r.itemKey);
  const upstream = a.chainedAutomationID ? automationsOf(st).find(x => x.id === a.chainedAutomationID)?.name : undefined;
  const poll = (st.automations as any)?.pollStates?.[a.id];
  const next = st.automations?.nextFires?.[a.id];
  return (
    <div className="bx-ah-row" onClick={e => { if (!(e.target as HTMLElement).closest('button, .switch')) actions.edit(a.id); }}>
      <span className="bx-ah-row-icon" style={{ ['--k' as any]: a.enabled ? tint : 'var(--label-secondary)' }}><SF name={triggerIcon(a)} size={14} weight={600} /></span>
      <div className="bd-stack" style={{ gap: 3, flex: 1, minWidth: 0 }}>
        <div className="bd-hrow" style={{ gap: 7 }}><span className="bx-ah-row-title truncate">{a.name || 'Untitled automation'}</span>{!a.enabled && <span className="bx-ah-paused-pill">Paused</span>}</div>
        <div className="bx-ah-row-when truncate">{describeWhen(a, upstream, tz)}</div>
        <div className="bd-hrow secondary" style={{ gap: 5, fontSize: 11.5 }}>
          {ws && <span className="dot" style={{ width: 6, height: 6, background: ws.accentHex }} />}
          <span className="truncate">{describeWhat(a, ws?.name ?? '?')}</span>
        </div>
      </div>
      <div className="bx-ah-row-status">
        {running > 0 ? <span className="bd-hrow" style={{ gap: 5, color: 'var(--blue)', fontSize: 11.5, fontWeight: 500 }}><MiniSpinner />{running === 1 ? 'Running now' : `${running} running`}</span>
          : poll?.lastError && a.enabled ? <span className="bd-hrow truncate" style={{ gap: 4, color: 'var(--orange)', fontSize: 11 }} title={poll.lastError}><SF name="exclamationmark.triangle.fill" size={11} />{poll.lastError}</span>
          : a.enabled && a.trigger === 'schedule' && next ? <span className="secondary" style={{ fontSize: 11.5 }}>Next {relNamed(next)}</span>
          : a.enabled && a.trigger !== 'schedule' && a.trigger !== 'afterAutomation' ? <span className="secondary" style={{ fontSize: 11.5 }}>{poll?.lastPolledAt ? `Watching · checked ${relNamed(poll.lastPolledAt)}` : 'watching'}</span> : null}
        {last ? <span className="bd-hrow tertiary" style={{ gap: 4, fontSize: 11 }}><SF name={last.completedAt ? 'checkmark.circle.fill' : outcomeGlyph(last.outcome)} size={11} color={last.completedAt ? 'var(--green)' : outcomeTint(last.outcome)} />Last run {relNamed(last.firedAt)}</span>
          : <span className="tertiary" style={{ fontSize: 11 }}>Hasn't run yet</span>}
      </div>
      <div className="bd-hrow" style={{ gap: 4 }}>
        <Button size="small" icon="play.fill" title="Run now" onClick={() => actions.runNow(a.id)} />
        <span title={a.enabled ? 'Pause' : 'Resume'}><Switch checked={a.enabled} onChange={() => actions.toggle(a.id)} /></span>
        <button className="btn icon" style={{ width: 22, height: 22 }} onClick={e => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
          { label: 'Edit…', action: () => actions.edit(a.id) }, { label: 'Run Now', action: () => actions.runNow(a.id) }, { label: 'Show Runs', action: onShowRuns },
          { separator: true }, { label: 'Delete…', destructive: true, action: () => actions.delete(a.id) },
        ])}><SF name="ellipsis" size={14} /></button>
      </div>
    </div>
  );
}

const SEVERITIES = ['critical', 'high', 'medium', 'low', 'info'] as const;
const sevTint = (s: string) => ({ critical: 'var(--red)', high: 'var(--orange)', medium: 'var(--yellow)', low: 'var(--blue)', info: 'var(--gray)' } as Record<string, string>)[s] ?? 'var(--gray)';
const sevName = (s: string) => s ? s[0].toUpperCase() + s.slice(1) : '';
const statusName = (s: string) => ({ new: 'New', triaged: 'Backlog', inProgress: 'In progress', inReview: 'In review', fixed: 'Fixed', duplicate: 'Duplicate', dismissed: 'Dismissed' } as Record<string, string>)[s] ?? s;
const statusTint = (s: string) => ({ new: 'var(--label-secondary)', triaged: 'var(--gray)', inProgress: 'var(--blue)', inReview: 'var(--purple)', fixed: 'var(--green)' } as Record<string, string>)[s] ?? 'var(--label-secondary)';
const isOpen = (s: string) => ['new', 'triaged', 'inProgress', 'inReview'].includes(s);
const focusName = (f: string) => f === 'security' ? 'Security vulnerabilities' : f === 'bugs' ? 'Bugs' : 'Security and bugs';

function scanSummary(w: any, tz?: string) {
  const parts: string[] = [];
  if ((w.scans ?? []).includes('fullScan')) {
    const day = WEEKDAYS[Math.min(Math.max(w.fullScanWeekday ?? 1, 1), 7) - 1].slice(0, 3);
    const zone = tzDiffers(tz) ? ' ' + zoneName(tz!) : '';
    parts.push(`${w.scheduledScope === 'newCommits' ? 'New commits' : 'Full scan'} ${day} ${String(w.fullScanHour ?? 0).padStart(2, '0')}:00${zone}`);
  }
  if ((w.scans ?? []).includes('commits')) parts.push('every commit');
  if ((w.scans ?? []).includes('pullRequests')) parts.push('every pull request');
  return parts.length ? parts.join(' · ') : 'Scan Now only';
}

function SeverityCounts({ findings }: { findings: any[] }) {
  const open = findings.filter(f => isOpen(f.status));
  if (!open.length) return <span className="bd-hrow" style={{ gap: 4, color: 'var(--green)', fontSize: 11.5 }}><SF name="checkmark.shield" size={12} />No open findings</span>;
  return <span className="bd-hrow" style={{ gap: 5 }}>{SEVERITIES.filter(s => open.some(f => f.severity === s)).map(s =>
    <span key={s} className="bx-ah-sev" style={{ ['--sev' as any]: sevTint(s) }}>{open.filter(f => f.severity === s).length} {sevName(s)}</span>)}</span>;
}

function WatchRow({ w, st, findings, actions, onOpen }: { w: any; st: RemoteState; findings: any[]; actions: Actions; onOpen: () => void }) {
  const openMenu = useMenu();
  const ws = workspaceOf(st, w.profileID);
  const tint = kindTint('security');
  return (
    <div className="bx-ah-row" onClick={e => { if (!(e.target as HTMLElement).closest('button, .switch')) onOpen(); }}>
      <span className="bx-ah-row-icon" style={{ ['--k' as any]: w.enabled ? tint : 'var(--label-secondary)' }}><SF name="doc.text.magnifyingglass" size={14} weight={600} /></span>
      <div className="bd-stack" style={{ gap: 3, flex: 1, minWidth: 0 }}>
        <div className="bd-hrow" style={{ gap: 7 }}><span className="bx-ah-row-title truncate">{w.repo}</span>{!w.enabled && <span className="bx-ah-paused-pill">Paused</span>}</div>
        <div className="bx-ah-row-when truncate">{scanSummary(w, st.automations?.timeZone)}</div>
        <div className="bd-hrow secondary truncate" style={{ gap: 5, fontSize: 11.5 }}>
          {ws && <><span className="dot" style={{ width: 6, height: 6, background: ws.accentHex }} />{ws.name}</>}
          <span>· {toolName(w.tool)} · {focusName(w.focus)}</span>
        </div>
      </div>
      <div className="bx-ah-row-status"><SeverityCounts findings={findings} /></div>
      <div className="bd-hrow" style={{ gap: 4 }}>
        <Button size="small" icon="play.fill" title="Scan now" onClick={() => actions.scanNow(w)} />
        <Switch checked={!!w.enabled} onChange={() => actions.toggleWatch(w)} />
        <button className="btn icon" style={{ width: 22, height: 22 }} onClick={e => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
          { label: 'Edit…', action: () => actions.editWatch(w) }, { label: 'Show Findings', action: onOpen },
          ...(w.scheduledScope === 'newCommits' ? [{ label: 'Run Baseline Now', action: () => actions.baseline(w) }] : []),
          { separator: true }, { label: 'Stop Watching…', destructive: true, action: () => actions.deleteWatch(w) },
        ])}><SF name="ellipsis" size={14} /></button>
      </div>
    </div>
  );
}

function KindCards({ onChoose }: { onChoose: (k: Kind) => void }) {
  return (
    <div className="bx-ah-kinds">
      {(['scheduled', 'event', 'security'] as Kind[]).map(k => (
        <button key={k} className="bx-ah-kind" style={{ ['--k' as any]: kindTint(k) }} onClick={() => onChoose(k)}>
          <span className="bx-ah-kind-big"><SF name={kindIcon(k)} size={19} weight={600} /></span>
          <div className="bd-stack" style={{ gap: 4 }}>
            <div style={{ fontSize: 15, fontWeight: 600 }}>{kindTitle(k)}</div>
            <div className="secondary" style={{ fontSize: 12 }}>{kindTagline(k)}</div>
          </div>
          <div className="bx-ah-kind-div" />
          <div className="bx-ah-kind-what">What happens</div>
          <div className="bd-stack" style={{ gap: 9 }}>
            {kindSteps(k).map(([, text], i) => (
              <div key={i} className="bd-hrow" style={{ gap: 9, alignItems: 'flex-start' }}>
                <span className="bx-ah-step">{i + 1}</span><span className="secondary" style={{ fontSize: 12 }}>{text}</span>
              </div>
            ))}
          </div>
          <span className="spacer" />
          <div className="bx-ah-kind-go">Set Up <SF name="arrow.right" size={11} weight={600} /></div>
        </button>
      ))}
    </div>
  );
}

// ── Code Review ───────────────────────────────────────────────────────────

function SecurityWelcome({ onNew }: { onNew: () => void }) {
  return (
    <div className="bx-ah-scroll">
      <div className="bx-ah-welcome">
        <SF name="doc.text.magnifyingglass" size={36} weight={500} color="var(--green)" />
        <div className="bd-stack" style={{ gap: 6, alignItems: 'center' }}>
          <div className="bx-ah-big" style={{ textAlign: 'center' }}>Continuous code review for your GitHub repositories</div>
          <div className="secondary" style={{ fontSize: 13, textAlign: 'center', maxWidth: 560 }}>Scans run as automations in the workspace you choose, with its GitHub token. Nothing is changed in the repository until you start a fix and merge it.</div>
        </div>
        <div className="bx-ah-steps">
          {kindSteps('security').map(([icon, text], i) => (
            <div key={i} className="bx-ah-step-card">
              <SF name={icon} size={15} weight={600} color="var(--green)" />
              <div className="bx-ah-kind-what">Step {i + 1}</div>
              <div style={{ fontSize: 12.5 }}>{text}</div>
            </div>
          ))}
        </div>
        <Button size="large" variant="prominent" icon="plus" onClick={onNew}>Watch a Repository…</Button>
      </div>
    </div>
  );
}

function Overview({ st, watches, onFindings, onScan, onNew }: { st: RemoteState; watches: any[]; onFindings: () => void; onScan: (w: any) => void; onNew: () => void }) {
  const findings = (st.automations?.findings ?? []) as any[];
  const open = findings.filter(f => isOpen(f.status));
  const pipeline = ['new', 'triaged', 'inProgress', 'inReview', 'fixed'];
  return (
    <div className="bx-ah-scroll">
      <div className="bx-ah-home">
        <div className="bx-ah-tiles">
          <div className="bx-ah-tile"><div className="bx-ah-tile-n">{open.length}</div><div className="secondary">Open findings</div></div>
          {SEVERITIES.slice(0, 3).map(s => <div key={s} className="bx-ah-tile" style={{ ['--sev' as any]: sevTint(s) }}><div className="bx-ah-tile-n" style={{ color: sevTint(s) }}>{open.filter(f => f.severity === s).length}</div><div className="secondary">{sevName(s)}</div></div>)}
          <div className="bx-ah-tile"><div className="bx-ah-tile-n" style={{ color: 'var(--green)' }}>{findings.filter(f => f.status === 'fixed').length}</div><div className="secondary">Fixed</div></div>
        </div>
        <div className="bx-ah-card">
          <div className="bx-ah-section-title">Pipeline</div>
          <div className="bx-ah-pipeline">{pipeline.map(s => { const n = findings.filter(f => f.status === s).length; return <div key={s} style={{ flex: Math.max(n, 0.4), background: statusTint(s) }} title={`${statusName(s)}: ${n}`}><span>{statusName(s)} {n}</span></div>; })}</div>
          <Button size="small" onClick={onFindings}>Show Findings</Button>
        </div>
        <div className="bx-ah-card">
          <div className="bd-hrow"><span className="bx-ah-section-title">Repositories</span><span className="spacer" /><Button size="small" icon="plus" onClick={onNew}>Watch a Repository…</Button></div>
          {watches.map(w => (
            <div key={w.id} className="bd-hrow" style={{ gap: 10, padding: '6px 0' }}>
              <SF name="doc.text.magnifyingglass" size={13} color="var(--green)" /><span style={{ fontWeight: 600 }}>{w.repo}</span>
              <span className="secondary truncate" style={{ fontSize: 11.5 }}>{scanSummary(w, st.automations?.timeZone)}</span><span className="spacer" />
              <SeverityCounts findings={findings.filter(f => f.watchID === w.id)} />
              <Button size="small" icon="play.fill" onClick={() => onScan(w)}>Scan Now</Button>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function Findings({ host, st, repoFilter, setRepoFilter, showFlash, onOpenTask }: {
  host: RemoteHost; st: RemoteState; repoFilter: string | null; setRepoFilter: (r: string | null) => void; showFlash: (t: string, e?: boolean) => void; onOpenTask: (id: string) => void;
}) {
  const all = (st.automations?.findings ?? []) as any[];
  const [filter, setFilter] = useState<'open' | 'all'>('open');
  const [sel, setSel] = useState<string | null>(null);
  const openMenu = useMenu();
  const ctx = useHostCtx();
  const list = all.filter(f => (filter === 'all' || isOpen(f.status)) && (!repoFilter || f.repo === repoFilter))
    .sort((a, b) => SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity) || Date.parse(b.lastSeenAt) - Date.parse(a.lastSeenAt));
  const f = all.find(x => x.id === sel) ?? list[0];
  const repos = [...new Set(all.map(x => x.repo))].sort();
  // `resend`: safe to send twice (a fix's task is started once however many
  // times it's asked; a session's hand-over carries a key, and a resend gets
  // the task the first send queued), so a request that got no answer at all is
  // sent once more. A connection that died while idle (sleep, a network
  // change) is only found out by the request riding it; the resend reconnects.
  const handOver = async (path: string, body: any, success: string, failure: (why: string) => string, retry: () => void,
                          resend = false) => {
    try {
      const r = await requestResending(() => host.request<any>('POST', path, body, { allowError: true } as any), resend);
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
    "Fix started — an agent is working on it in its own branch. It moves to In review when it's ready.", w => `Couldn't start the fix: ${w}`, () => fix(id, true), true);
  const route = (id: string, room?: string, confirmed = false) => handOver(`/findings/${seg(id)}/switchboard`, { ...(room ? { room } : {}), ...(confirmed ? { confirmed: true } : {}) },
    'Asked the Switchboard — it will propose a session and wait for your OK.', w => `Couldn't ask the Switchboard: ${w}`, () => route(id, room, true));
  const ask = (id: string, s: { id: string; label: string }, confirmed = false) => handOver(`/findings/${seg(id)}/session`, { session: s.id, confirmed, handOver: crypto.randomUUID() },
    `Sent to ${s.label} — it works on the fix in its own session.`, w => `Couldn't send it to ${s.label}: ${w}`, () => ask(id, s, true), true);
  const setStatus = (id: string, status: string) => host.send('POST', `/findings/${seg(id)}/status`, { status });
  const fixMenu = (e: React.MouseEvent, x: any) => {
    const items: MenuItem[] = [{ label: 'Start a Fix Session', action: () => fix(x.id) }, { separator: true }, { label: 'Ask the Switchboard', action: () => route(x.id) }];
    for (const r of st.agentRooms ?? []) items.push({ label: `Ask #${r.name}'s Switchboard`, action: () => route(x.id, r.id) });
    // Every session, by name: a list cut to the first 20 left the others out of reach.
    const label = (s: any) => s.nickname ? '@' + s.nickname : `“${s.title}”`;
    const sessions = (st.agentSessions ?? []).filter(s => !s.archivedAt && !(s as any).deletedAt && (s as any).role !== 'switchboard')
      .sort((a, b) => label(a).replace(/^[@“]/, '').localeCompare(label(b).replace(/^[@“]/, ''), undefined, { numeric: true, sensitivity: 'base' }));
    if (sessions.length) { items.push({ separator: true }, { header: 'Ask a session' }); for (const s of sessions) items.push({ label: label(s), action: () => ask(x.id, { id: s.id, label: label(s) }) }); }
    openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), items);
  };
  void ctx;
  return (
    <div className="bx-ah-findings">
      <div className="bx-ah-flist">
        <div className="bd-hrow" style={{ gap: 8, padding: '0 4px 8px' }}>
          <Segmented value={filter} onChange={setFilter} options={[{ value: 'open', label: 'Open' }, { value: 'all', label: 'All' }]} />
          <span className="spacer" />
          <PopUp value={repoFilter ?? ''} onChange={v => setRepoFilter(v || null)} options={[{ value: '', label: 'All repositories' }, ...repos.map(r => ({ value: r, label: r }))]} />
        </div>
        {list.length === 0 ? <div className="bx-rv-empty">{filter === 'open' ? 'No open findings.' : 'No findings yet.'}</div>
          : list.map(x => (
            <button key={x.id} className={cx('bx-ah-frow', f?.id === x.id && 'on')} onClick={() => setSel(x.id)}>
              <span className="bx-ah-sev" style={{ ['--sev' as any]: sevTint(x.severity) }}>{sevName(x.severity)}</span>
              <span className="bd-stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
                <span className="truncate" style={{ fontWeight: 600, fontSize: 12.5 }}>{x.title}</span>
                <span className="secondary truncate" style={{ fontSize: 11 }}>{x.repo}{x.file ? ` · ${x.file}${x.line ? ':' + x.line : ''}` : ''}</span>
              </span>
              <span className="bx-ah-fstatus"><span className="dot" style={{ width: 6, height: 6, background: statusTint(x.status) }} />{statusName(x.status)}</span>
            </button>
          ))}
      </div>
      <div className="bx-ah-fdetail">
        {!f ? <div className="bx-rv-empty" style={{ margin: 'auto' }}>Select a finding</div> : (
          <div className="bd-stack selectable" style={{ gap: 12 }}>
            <div className="bd-hrow" style={{ gap: 8 }}>
              <span className="bx-ah-sev" style={{ ['--sev' as any]: sevTint(f.severity) }}>{sevName(f.severity)}</span>
              {f.cwe && <span className="pill">{f.cwe}</span>}
              <span className="bx-ah-fstatus"><span className="dot" style={{ width: 6, height: 6, background: statusTint(f.status) }} />{statusName(f.status)}</span>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600 }}>{f.title}</div>
            <div className="secondary" style={{ fontSize: 11.5 }}>{f.repo}{f.file ? ` · ${f.file}${f.line ? ':' + f.line : ''}` : ''} · first seen {relNamed(f.firstSeenAt)}{f.seenCount > 1 ? ` · seen ${f.seenCount}×` : ''}</div>
            {f.screenWarning && <div className="bx-bm-warn"><SF name="exclamationmark.triangle.fill" size={12} />Flagged by the prompt-injection screen: {f.screenWarning}</div>}
            <Markdown text={f.summary ?? ''} />
            {f.evidence && <><div className="bx-te-label">Evidence</div><pre className="bx-md-pre">{f.evidence}</pre></>}
            {f.recommendation && <><div className="bx-te-label">Recommendation</div><Markdown text={f.recommendation} /></>}
            <div className="bd-hrow" style={{ gap: 8, flexWrap: 'wrap' }}>
              {isOpen(f.status) && (
                <span className="bx-rv-split">
                  <Button variant="prominent" icon="wrench.and.screwdriver" onClick={() => fix(f.id)}>{f.taskID ? 'Retry the Fix' : 'Start a Fix'}</Button>
                  <Button variant="prominent" icon="chevron.down" onClick={e => fixMenu(e, f)} />
                </span>
              )}
              {f.taskID && <Button onClick={() => onOpenTask(f.taskID)}>Open Task</Button>}
              <Button onClick={e => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
                { header: 'Set status' },
                ...['new', 'triaged', 'fixed', 'dismissed'].map(s => ({ label: statusName(s), checked: f.status === s, action: () => setStatus(f.id, s) })),
                { separator: true }, { label: 'Delete Finding', destructive: true, action: () => host.send('DELETE', `/findings/${seg(f.id)}`) },
              ])}>Status</Button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function Repositories({ st, watches, actions, onNew }: { st: RemoteState; watches: any[]; actions: Actions; onNew: () => void }) {
  const findings = (st.automations?.findings ?? []) as any[];
  return (
    <div className="bx-ah-scroll">
      <div className="bx-ah-home">
        {watches.map(w => <WatchRow key={w.id} w={w} st={st} findings={findings.filter(f => f.watchID === w.id)} actions={actions} onOpen={() => actions.editWatch(w)} />)}
        <button className="bx-ah-empty-add" onClick={onNew}><SF name="plus.circle" size={12} />Watch a Repository…</button>
      </div>
    </div>
  );
}

function WatchEditor({ host, st, draft: initial, isNew, onCancel, onSave }: { host: RemoteHost; st: RemoteState; draft: any; isNew: boolean; onCancel: () => void; onSave: (w: any, scan: boolean) => void }) {
  const [d, setD] = useState<any>(initial);
  const [repos, setRepos] = useState<string[] | null>(null);
  const [repoErr, setRepoErr] = useState<string | null>(null);
  const set = (p: any) => setD((x: any) => ({ ...x, ...p }));
  const ws = st.workspaces?.find(w => w.id === d.profileID) as any;
  const tz = st.automations?.timeZone;
  useEffect(() => {
    let live = true; setRepos(null); setRepoErr(null);
    if (!ws?.hasGitHubToken) return;
    host.request<any>('POST', '/automation-sources', { profile: d.profileID, kind: 'repos' }, { timeoutMs: 75_000, allowError: true } as any)
      .then(r => { if (!live) return; if (r?.error) setRepoErr(r.error); else setRepos(r?.items ?? []); })
      .catch(e => live && setRepoErr(String(e?.message ?? e)));
    return () => { live = false; };
  }, [d.profileID]); // eslint-disable-line
  const scans: string[] = d.scans ?? [];
  const toggleScan = (s: string, on: boolean) => set({ scans: on ? [...scans.filter(x => x !== s), s] : scans.filter(x => x !== s) });
  const valid = isValidRepoSlug(d.repo ?? '');
  const tools = (ws?.readyTools ?? []).map((x: any) => x.tool) as string[];
  return (
    <Sheet width={560} onClose={onCancel}>
      <div className="bx-we">
        <div style={{ fontSize: 17, fontWeight: 600 }}>{isNew ? 'Watch a GitHub Repository' : `Watch on ${d.repo}`}</div>
        <div className="form" style={{ padding: 0 }}>
          <div className="form-section-title">Repository</div>
          <div className="form-section">
            <div className="form-row"><div className="form-label">Workspace</div><div className="form-control">
              <PopUp value={d.profileID} onChange={v => set({ profileID: v })} options={(st.workspaces ?? []).map(w => ({ value: w.id, label: w.name }))} /></div></div>
            {!ws?.hasGitHubToken && <div className="form-note" style={{ color: 'var(--orange)' }}>This workspace has no github.com token — scans poll GitHub with it.</div>}
            <div className="form-row"><div className="form-label">Repository</div><div className="form-control">
              {repos && repos.length ? <PopUp value={d.repo} onChange={v => set({ repo: v, repoPath: d.repoPath || '~/' + v.split('/').pop() })} options={[...(repos.includes(d.repo) ? [] : [{ value: d.repo, label: d.repo || 'Choose…' }]), ...repos.map(r => ({ value: r, label: r }))]} />
                : <TextField value={d.repo} placeholder="owner/repo" style={{ width: 240 }} onChange={e => set({ repo: e.target.value })} />}
            </div></div>
            {repoErr && <div className="form-note" style={{ color: 'var(--orange)' }}>{repoErr}</div>}
            <div className="form-row"><div className="form-label">Checkout in the workspace</div><div className="form-control">
              <TextField mono value={d.repoPath} placeholder={'~/' + ((d.repo ?? '').split('/').pop() || 'repo')} style={{ width: 240 }} onChange={e => set({ repoPath: e.target.value })} /></div></div>
            <div className="form-row"><div className="form-label">Agent</div><div className="form-control">
              <PopUp value={d.tool} onChange={v => set({ tool: v })} options={(tools.length ? tools : [d.tool]).map(t => ({ value: t, label: toolName(t) }))} /></div></div>
            <div className="form-row"><div className="form-label">Look for</div><div className="form-control">
              <PopUp value={d.focus} onChange={v => set({ focus: v })} options={['security', 'bugs', 'both'].map(f => ({ value: f, label: focusName(f) }))} /></div></div>
          </div>
          <div className="form-section-title">Scans</div>
          <div className="form-section">
            <div className="form-row"><Checkbox checked={scans.includes('fullScan')} onChange={v => toggleScan('fullScan', v)}>Scheduled review</Checkbox></div>
            {scans.includes('fullScan') && <>
              <div className="form-row"><div className="form-label">Review</div><div className="form-control">
                <PopUp value={d.scheduledScope} onChange={v => set({ scheduledScope: v })} options={[{ value: 'newCommits', label: 'New commits since the last review' }, { value: 'baseline', label: 'The full repository (baseline)' }]} /></div></div>
              <div className="form-row"><div className="form-label">Weekly{tzDiffers(tz) ? ` — ${zoneName(tz!)} (the host's time)` : ''}</div><div className="form-control">
                <PopUp value={d.fullScanWeekday} onChange={v => set({ fullScanWeekday: v })} options={WEEKDAYS.map((n, i) => ({ value: i + 1, label: n }))} />
                <PopUp value={d.fullScanHour} onChange={v => set({ fullScanHour: v })} options={Array.from({ length: 24 }, (_, h) => ({ value: h, label: `${String(h).padStart(2, '0')}:00` }))} /></div></div>
              {d.scheduledScope === 'newCommits' && <div className="form-row"><Checkbox checked={!!d.firstRunBaseline} onChange={v => set({ firstRunBaseline: v })}>Start with a full-repository baseline</Checkbox></div>}
            </>}
            <div className="form-row"><Checkbox checked={scans.includes('commits')} onChange={v => toggleScan('commits', v)}>Every new commit</Checkbox></div>
            <div className="form-row"><Checkbox checked={scans.includes('pullRequests')} onChange={v => toggleScan('pullRequests', v)}>Every new pull request</Checkbox></div>
            <div className="form-row"><div className="form-label">Branch</div><div className="form-control"><TextField value={d.commitBranch} placeholder="default branch" style={{ width: 200 }} onChange={e => set({ commitBranch: e.target.value })} /></div></div>
          </div>
          <div className="form-section-title">Fixes</div>
          <div className="form-section">
            <div className="form-row"><div className="form-label">Start fixes automatically</div><div className="form-control">
              <PopUp value={d.autoFixMinSeverity ?? ''} onChange={v => set({ autoFixMinSeverity: v || undefined })} options={[{ value: '', label: 'Never' }, { value: 'critical', label: 'For critical findings' }, { value: 'high', label: 'For high and critical' }, { value: 'medium', label: 'For medium and above' }]} /></div></div>
          </div>
          <div className="form-section-title">Instructions for the scanning agent</div>
          <textarea className="field" rows={4} value={d.instructions} onChange={e => set({ instructions: e.target.value })} />
        </div>
        <div className="bd-hrow" style={{ gap: 8 }}>
          {!valid && <span style={{ color: 'var(--orange)', fontSize: 11 }}>Pick a repository (owner/name).</span>}
          <span className="spacer" />
          <Button onClick={onCancel}>Cancel</Button>
          {isNew && <Button disabled={!valid} onClick={() => onSave(d, true)}>Watch and Scan Now</Button>}
          <Button variant="prominent" disabled={!valid} onClick={() => onSave(d, false)}>{isNew ? 'Watch' : 'Save'}</Button>
        </div>
      </div>
    </Sheet>
  );
}
