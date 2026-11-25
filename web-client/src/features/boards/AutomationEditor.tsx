// The automation editor (ScheduledAutomationViews.swift AutomationEditorView),
// in an 820×820 window as the fat client opens it: header with the name and
// the Enabled switch, the When → What → Then strip, then "Where it runs",
// "When it runs", "What the agent does", "When it finishes", recent runs and a
// pinned footer (Delete… / Run Now / Save). Saves POST /automations; the
// token-backed pickers ask the host (POST /automation-sources).

import React, { useEffect, useMemo, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import type { RemoteState } from '../../core/remote/types';
import { useRemote } from '../../app/store';
import type { WindowSpec } from '../../app/windows';
import { SF } from '../../ui/icons';
import { Button, Checkbox, PopUp, Segmented, Spinner, Switch, TextField, cx } from '../../ui/kit';
import {
  type Automation, type Trigger, automationsOf, runsOf, newAutomation, kindOf, kindTint, kindIcon, describeWhen, describeWhat, describeAfter,
  toolName, authName, reliableDone, isValidRepoSlug, chainCycles, nextFire, moment, tzDiffers, zoneName, WEEKDAYS, outcomeGlyph, outcomeTint, dateTime,
} from './model';
import { confirm } from './kanban';
import './boards.css';

type WM = { open: (w: WindowSpec) => void; close: (id: string) => void };
const WIN = 'automation-editor';

export function openAutomationEditor(wm: WM, host: RemoteHost, id?: string, trigger?: Trigger) {
  wm.close(WIN);
  // A fresh key re-mounts the editor for another automation, as the native
  // window rebuilds its content.
  const key = (id ?? 'new') + ':' + Date.now();
  setTimeout(() => wm.open({
    id: WIN, title: id ? 'Edit automation' : 'New automation', width: 820, height: 820, minWidth: 560, minHeight: 480,
    render: ctx => <AutomationEditor key={key} host={host} id={id} trigger={trigger} close={ctx.close} />,
  }), 0);
}

export function confirmDeleteAutomation(host: RemoteHost, id: string, then?: () => void) {
  const name = automationsOf(host.state).find(a => a.id === id)?.name || 'this automation';
  confirm({
    title: `Delete “${name}”?`, message: "This removes the automation on the remote. It can't be undone.",
    buttons: [{ label: 'Delete', role: 'destructive', action: () => { host.send('DELETE', `/automations/${seg(id)}`); then?.(); } }, { label: 'Cancel', role: 'cancel' }],
  });
}

function AutomationEditor({ host, id, trigger, close }: { host: RemoteHost; id?: string; trigger?: Trigger; close: () => void }) {
  const st = useRemote(host, s => s) as RemoteState | undefined;
  const [draft, setDraft] = useState<Automation | null>(null);
  const [isNew] = useState(!id);
  const [filtersOpen, setFiltersOpen] = useState(false);
  useEffect(() => {
    if (draft || !st) return;
    const existing = id ? automationsOf(st).find(a => a.id === id) : undefined;
    if (existing) {
      setDraft(JSON.parse(JSON.stringify(existing)));
      const f = existing.filters ?? ({} as any);
      setFiltersOpen(!!(f.labels?.length || f.titleContains || !f.excludeDrafts || f.ignoreBots || f.baseBranch || f.commitBranch || f.commitSubfolder || f.linearProjectID || f.linearMinPriority));
    } else {
      const ws = st.workspaces?.[0];
      const fresh = newAutomation(ws);
      if (trigger && ws) {
        const gh = !!(ws as any).hasGitHubToken, lin = !!(ws as any).hasLinearToken;
        const isGH = trigger.startsWith('github');
        fresh.trigger = trigger === 'schedule' || trigger === 'afterAutomation' || (isGH && gh) || (trigger === 'linearIssue' && lin) ? trigger
          : gh ? 'githubPullRequest' : lin ? 'linearIssue' : 'schedule';
      }
      setDraft(fresh);
    }
  }, [st, id]); // eslint-disable-line

  if (!st || !draft) return <div className="bx-ae" />;
  const ws = st.workspaces ?? [];
  if (!ws.length) {
    return <div className="empty-state" style={{ flex: 1 }}><SF name="clock" size={30} color="var(--label-tertiary)" /><h3>No workspaces yet</h3><span>Automations run inside a workspace. Create one first.</span></div>;
  }
  return <EditorBody host={host} st={st} draft={draft} setDraft={setDraft} isNew={isNew} filtersOpen={filtersOpen} setFiltersOpen={setFiltersOpen} close={close} />;
}

function EditorBody({ host, st, draft, setDraft, isNew, filtersOpen, setFiltersOpen, close }: {
  host: RemoteHost; st: RemoteState; draft: Automation; setDraft: React.Dispatch<React.SetStateAction<Automation | null>>; isNew: boolean;
  filtersOpen: boolean; setFiltersOpen: (v: boolean) => void; close: () => void;
}) {
  const set = (p: Partial<Automation>) => setDraft(d => d && ({ ...d, ...p }));
  const setF = (p: Partial<Automation['filters']>) => setDraft(d => d && ({ ...d, filters: { ...d.filters, ...p } }));
  const autos = automationsOf(st);
  const tz = st.automations?.timeZone;
  const profile = st.workspaces?.find(w => w.id === draft.profileID) as any;
  const hasGH = !!profile?.hasGitHubToken, hasLin = !!profile?.hasLinearToken;
  const tools: { tool: string; authMode: string }[] = profile?.readyTools?.length ? profile.readyTools : [{ tool: profile?.tool ?? 'claude', authMode: profile?.authMode ?? 'token' }];
  const spec = tools.find(t => t.tool === draft.tool);
  const k = kindOf(draft), tint = kindTint(k);
  const askLabels: string[] = profile?.askBeforeUseLabels ?? [];
  const available = (t: Trigger) => t === 'schedule' || t === 'afterAutomation' ? true : t === 'linearIssue' ? hasLin : hasGH;
  const chainLoop = useMemo(() => chainCycles(draft.id, [...autos.filter(a => a.id !== draft.id), draft]), [autos, draft]);

  // Token-backed lists from the host.
  const [repos, setRepos] = useState<string[] | null>(null);
  const [repoErr, setRepoErr] = useState<string | null>(null);
  const [teams, setTeams] = useState<{ key: string; name: string }[] | null>(null);
  const [teamErr, setTeamErr] = useState<string | null>(null);
  const [projects, setProjects] = useState<{ id: string; name: string }[] | null>(null);
  const [branches, setBranches] = useState<string[] | null>(null);
  const [dirs, setDirs] = useState<string[] | null>(null);
  const sources = (body: any) => host.request<any>('POST', '/automation-sources', { profile: draft.profileID, ...body }, { timeoutMs: 75_000, allowError: true } as any)
    .then(r => { if (r?.error) throw new Error(r.error); return r; });
  useEffect(() => {
    let live = true;
    setRepos(null); setRepoErr(null); setTeams(null); setTeamErr(null); setProjects(null);
    if (hasGH) sources({ kind: 'repos' }).then(r => live && setRepos(r.items ?? [])).catch(e => live && setRepoErr(e.message));
    if (hasLin) {
      sources({ kind: 'teams' }).then(r => live && setTeams((r.items ?? []).filter((x: any) => x.key && x.name))).catch(e => live && setTeamErr(e.message));
      sources({ kind: 'projects' }).then(r => live && setProjects((r.items ?? []).filter((x: any) => x.id && x.name))).catch(() => {});
    }
    return () => { live = false; };
  }, [draft.profileID, hasGH, hasLin]); // eslint-disable-line
  useEffect(() => {
    let live = true; setBranches(null); setDirs(null);
    if (!draft.trigger.startsWith('github') || !isValidRepoSlug(draft.githubRepo) || !hasGH) return;
    sources({ kind: 'branches', repo: draft.githubRepo }).then(r => live && setBranches(r.items ?? [])).catch(() => live && setBranches([]));
    if (draft.trigger === 'githubCommit') sources({ kind: 'dirs', repo: draft.githubRepo, branch: draft.filters.commitBranch })
      .then(r => live && setDirs(r.truncated ? [] : r.items ?? [])).catch(() => live && setDirs([]));
    return () => { live = false; };
  }, [draft.githubRepo, draft.filters.commitBranch, draft.trigger]); // eslint-disable-line

  const blockers: string[] = [];
  if (!draft.name.trim()) blockers.push('give it a name');
  if (!draft.prompt.trim()) blockers.push('write a prompt');
  if (!profile) blockers.push('pick a workspace');
  if (draft.trigger.startsWith('github')) {
    if (!isValidRepoSlug(draft.githubRepo)) blockers.push('set the repository as owner/name');
    if (!hasGH) blockers.push('add a GitHub token to the workspace');
  } else if (draft.trigger === 'linearIssue' && !hasLin) blockers.push('add a Linear API key to the workspace');
  else if (draft.trigger === 'afterAutomation') {
    if (draft.chainedAutomationID && autos.some(a => a.id === draft.chainedAutomationID)) { if (chainLoop) blockers.push('break the automation loop'); }
    else blockers.push('pick the automation this one follows');
  }
  const canSave = blockers.length === 0;
  const save = () => { host.send('POST', '/automations', draft); close(); };
  const runNow = () => { host.request('POST', '/automations', draft).then(() => host.send('POST', `/automations/${seg(draft.id)}/run`)).catch(() => {}); close(); };

  const upstream = draft.chainedAutomationID ? autos.find(a => a.id === draft.chainedAutomationID)?.name : undefined;
  const triggerSub = ({ schedule: 'on a schedule', githubPullRequest: 'on new pull requests', githubIssue: 'on new issues', githubCommit: 'on new commits', linearIssue: 'on new Linear issues', afterAutomation: 'after another automation' } as Record<string, string>)[draft.trigger];
  const hint = (t: string) => <div className="bx-ae-hint">{t}</div>;
  const card = (title: string, icon: string, sub: string | null, body: React.ReactNode) => (
    <div className="bx-ae-card" style={{ ['--k' as any]: tint }}>
      <div className="bd-hrow" style={{ gap: 8 }}>
        <span className="bx-ae-card-icon"><SF name={icon} size={11} weight={600} /></span>
        <div className="bd-stack"><div className="bx-ae-card-title">{title}</div>{sub && <div className="secondary" style={{ fontSize: 11 }}>{sub}</div>}</div>
      </div>
      {body}
    </div>
  );
  const captioned = (title: string, body: React.ReactNode) => <div className="bd-stack" style={{ gap: 2 }}><div className="bx-ae-caption">{title}</div>{body}</div>;
  const branchField = (caption: string, value: string, onChange: (v: string) => void, anyLabel: string) => captioned(caption,
    branches && branches.length ? <PopUp bordered value={value} onChange={onChange} options={[{ value: '', label: anyLabel }, ...(value && !branches.includes(value) ? [{ value, label: value }] : []), ...branches.map(b => ({ value: b, label: b }))]} />
      : <TextField value={value} placeholder="main" onChange={e => onChange(e.target.value)} />);
  const repoPicker = (
    <>
      {repos && repos.length ? (
        <div className="bx-ae-line"><span>Repository</span><PopUp bordered value={draft.githubRepo} onChange={v => set({ githubRepo: v })}
          options={[...(repos.includes(draft.githubRepo) ? [] : [{ value: draft.githubRepo, label: draft.githubRepo || 'Choose…' }]), ...repos.map(r => ({ value: r, label: r }))]} /></div>
      ) : !repoErr && hasGH ? <div className="bd-hrow" style={{ gap: 6 }}><Spinner size={12} /><span className="bx-ae-hint">Checking the GitHub token and loading repositories…</span></div> : null}
      {(repoErr || (repos && !repos.length) || !hasGH) && <>
        {repoErr && <div className="bx-ae-warn"><SF name="exclamationmark.triangle" size={11} />{repoErr}</div>}
        {captioned('Repository', <TextField value={draft.githubRepo} placeholder="owner/repo" onChange={e => set({ githubRepo: e.target.value })} />)}
      </>}
    </>
  );
  const backlog = (
    <>
      <Checkbox checked={draft.ignoreBacklog} onChange={v => set({ ignoreBacklog: v })}>Ignore backlog</Checkbox>
      {hint(draft.ignoreBacklog ? 'Only items appearing after you save fire. The existing open items are skipped.' : 'The existing open backlog is processed once, too, then new items as they appear.')}
      <div className="bx-ae-line"><span>Runs at a time</span>
        <PopUp bordered value={draft.maxParallelRuns} onChange={v => set({ maxParallelRuns: v })} options={[1, 2, 3, 5, 10, 0].map(n => ({ value: n, label: n === 0 ? 'No limit' : String(n) }))} /></div>
      {hint('A burst of events waits its turn, oldest first: the next one starts when a run finishes.')}
    </>
  );
  const filters = (isPR: boolean, isLinear: boolean) => (
    <div className="bx-ae-filters">
      <button className="bx-ae-disclosure" onClick={() => setFiltersOpen(!filtersOpen)}><SF name={filtersOpen ? 'chevron.down' : 'chevron.right'} size={10} weight={600} />Filters</button>
      {filtersOpen && (
        <div className="bd-stack" style={{ gap: 8, paddingTop: 6 }}>
          {isLinear && <>
            {projects && projects.length > 0 && <div className="bx-ae-line"><span>Project</span><PopUp bordered value={draft.filters.linearProjectID} onChange={v => setF({ linearProjectID: v, linearProjectName: projects.find(p => p.id === v)?.name ?? '' })} options={[{ value: '', label: 'All projects' }, ...projects.map(p => ({ value: p.id, label: p.name }))]} /></div>}
            <div className="bx-ae-line"><span>Priority</span><PopUp bordered value={draft.filters.linearMinPriority} onChange={v => setF({ linearMinPriority: v })} options={[{ value: 0, label: 'Any' }, { value: 1, label: 'Urgent only' }, { value: 2, label: 'High or higher' }, { value: 3, label: 'Normal or higher' }]} /></div>
          </>}
          {captioned('Labels — fire only if the item has any of these (comma-separated)', <TextField value={draft.filters.labels.join(', ')} placeholder={isLinear ? 'Bug, Agent' : 'bug, agent-ok'}
            onChange={e => setF({ labels: e.target.value.split(',').map(s => s.trim()).filter(Boolean) })} />)}
          {isPR && <>
            {branchField('Base branch — fire only for PRs targeting this branch', draft.filters.baseBranch, v => setF({ baseBranch: v }), 'Any branch')}
            <Checkbox checked={draft.filters.excludeDrafts} onChange={v => setF({ excludeDrafts: v })}>Ignore draft PRs</Checkbox>
          </>}
          {!isLinear && <Checkbox checked={draft.filters.ignoreBots} onChange={v => setF({ ignoreBots: v })}>Ignore bot authors (dependabot, renovate, …)</Checkbox>}
          {captioned('Title contains — fire only if the title includes this text', <TextField value={draft.filters.titleContains} placeholder="security" onChange={e => setF({ titleContains: e.target.value })} />)}
        </div>
      )}
    </div>
  );
  const pollLine = !isNew ? <div className="bx-ae-hint bd-hrow" style={{ gap: 5 }}><SF name="antenna.radiowaves.left.and.right" size={11} />First check runs within 30 seconds of saving.</div> : null;

  let triggerBody: React.ReactNode;
  switch (draft.trigger) {
    case 'schedule': {
      const nf = nextFire(draft, tz);
      triggerBody = <>
        <Segmented value={draft.frequency} onChange={v => set({ frequency: v })} options={[{ value: 'interval', label: 'Every…' }, { value: 'daily', label: 'Daily' }, { value: 'weekdays', label: 'Weekdays' }, { value: 'weekly', label: 'Weekly' }]} />
        {draft.frequency === 'interval' ? (
          <div className="bx-ae-line"><span>Every</span><PopUp bordered value={draft.intervalMinutes} onChange={v => set({ intervalMinutes: v })}
            options={[...[[5, '5 minutes'], [15, '15 minutes'], [30, '30 minutes'], [60, 'Hour'], [120, '2 hours'], [240, '4 hours'], [720, '12 hours']].map(([v, l]) => ({ value: v as number, label: l as string })),
              ...([5, 15, 30, 60, 120, 240, 720].includes(draft.intervalMinutes) ? [] : [{ value: draft.intervalMinutes, label: draft.intervalMinutes % 60 === 0 ? `${draft.intervalMinutes / 60} hours` : `${draft.intervalMinutes} minutes` }])]} /></div>
        ) : <>
          {draft.frequency === 'weekly' && <div className="bx-ae-line"><span>On</span><PopUp bordered value={draft.weekday} onChange={v => set({ weekday: v })} options={WEEKDAYS.map((d, i) => ({ value: i + 1, label: d }))} /></div>}
          <div className="bx-ae-line"><span>At</span>
            <input className="field" type="time" style={{ width: 110 }} value={`${String(draft.hour).padStart(2, '0')}:${String(draft.minute).padStart(2, '0')}`}
                   onChange={e => { const [h, m] = e.target.value.split(':').map(Number); if (!isNaN(h)) set({ hour: h, minute: m || 0 }); }} />
            {tzDiffers(tz) && <span className="bx-ae-hint">{zoneName(tz!)} (the host's time)</span>}
          </div>
        </>}
        {captioned('If the Mac is asleep at fire time', <PopUp bordered value={draft.missedRunPolicy} onChange={v => set({ missedRunPolicy: v })} options={[{ value: 'skip', label: 'Skip the run' }, { value: 'runOnWake', label: 'Run when the Mac wakes' }]} />)}
        {nf && <div className="bx-ae-hint bd-hrow" style={{ gap: 5 }}><SF name="clock" size={11} />Next run: {moment(nf, tz)}</div>}
        {hint('Skipped runs stay visible in the run history — nothing fails silently.')}
      </>;
      break;
    }
    case 'githubPullRequest': case 'githubIssue': {
      const issue = draft.trigger === 'githubIssue', ns = issue ? 'issue' : 'pr';
      triggerBody = <>
        {repoPicker}
        {issue && <Segmented value={draft.assignmentFilter} onChange={v => set({ assignmentFilter: v })} options={[{ value: 'unassigned', label: 'Unassigned' }, { value: 'assignedToMe', label: 'Assigned to me' }]} />}
        {filters(!issue, false)}
        {backlog}
        {issue && hint("The issue's comments are included in the agent's context automatically (and screened for prompt injection).")}
        {hint(`Each event runs once, checked every 3 minutes with the workspace's GitHub token — no webhooks. The prompt can use {{${ns}.number}}, {{${ns}.title}}, {{${ns}.body}}, {{${ns}.author}}, {{${ns}.url}}; without them the details are appended automatically.`)}
        {pollLine}
      </>;
      break;
    }
    case 'githubCommit':
      triggerBody = <>
        {repoPicker}
        {branchField('Branch to watch', draft.filters.commitBranch, v => setF({ commitBranch: v }), 'Default branch')}
        {captioned('Subfolder — fire only for commits that touch this folder', dirs && dirs.length
          ? <PopUp bordered value={draft.filters.commitSubfolder} onChange={v => setF({ commitSubfolder: v })} options={[{ value: '', label: 'Whole repository' }, ...dirs.map(d => ({ value: d, label: d }))]} />
          : <TextField value={draft.filters.commitSubfolder} placeholder="services/api" onChange={e => setF({ commitSubfolder: e.target.value })} />)}
        {backlog}
        {hint("Fires for each commit on the branch touching the subfolder (whole repo if blank), once each, checked every 3 minutes. The prompt can use {{commit.title}}, {{commit.body}}, {{commit.author}}, {{commit.url}}, {{commit.key}} (short SHA); without them the commit's details are appended automatically.")}
        {hint('A merged branch fires once, for its merge commit — not for each of its commits. Diff a commit against its first parent to see what it brought: git diff {{commit.key}}^1 {{commit.key}}.')}
        {pollLine}
      </>;
      break;
    case 'linearIssue':
      triggerBody = <>
        <Segmented value={draft.assignmentFilter} onChange={v => set({ assignmentFilter: v })} options={[{ value: 'unassigned', label: 'Unassigned' }, { value: 'assignedToMe', label: 'Assigned to me' }]} />
        {teams && teams.length ? <div className="bx-ae-line"><span>Team</span><PopUp bordered value={draft.linearTeam} onChange={v => set({ linearTeam: v })} options={[{ value: '', label: 'All teams' }, ...teams.map(t => ({ value: t.key, label: `${t.name} (${t.key})` }))]} /></div>
          : !teamErr && hasLin ? <div className="bd-hrow" style={{ gap: 6 }}><Spinner size={12} /><span className="bx-ae-hint">Checking the Linear key and loading teams…</span></div> : null}
        {(teamErr || (teams && !teams.length)) && <>
          {teamErr && <div className="bx-ae-warn"><SF name="exclamationmark.triangle" size={11} />{teamErr}</div>}
          {captioned('Team key (optional)', <TextField value={draft.linearTeam} placeholder="ENG" onChange={e => set({ linearTeam: e.target.value })} />)}
        </>}
        {filters(false, true)}
        {backlog}
        {hint("Each issue runs once, checked every 3 minutes with the workspace's Linear API key — no webhooks.")}
        {hint("The prompt can use {{issue.key}}, {{issue.title}}, {{issue.body}}, {{issue.branch}}, {{issue.author}}, {{issue.url}}. Without them, the issue's details are appended automatically.")}
        {pollLine}
      </>;
      break;
    case 'afterAutomation': {
      const others = autos.filter(a => a.id !== draft.id);
      const up = autos.find(a => a.id === draft.chainedAutomationID);
      triggerBody = others.length === 0 ? hint('No other automations yet — create the one this should follow first.') : <>
        <div className="bx-ae-line"><span>Runs after</span><PopUp bordered value={draft.chainedAutomationID ?? ''} onChange={v => set({ chainedAutomationID: v || undefined })}
          options={[{ value: '', label: 'Choose…' }, ...others.map(o => ({ value: o.id, label: o.name || 'Untitled automation' }))]} /></div>
        {up && (chainLoop ? <div className="bx-ae-warn"><SF name="exclamationmark.triangle" size={11} />This choice closes a loop — the chain would fire itself forever.</div>
          : !reliableDone(up.tool) ? <div className="bx-ae-warn"><SF name="exclamationmark.triangle" size={11} />“{up.name}” runs {toolName(up.tool)}, which doesn't report finishing, so this chain will never fire.</div> : null)}
        {hint("Fires when the chosen automation's run reports done, in this automation's own workspace and repository path. The prompt can use {{chain.automation}} and {{chain.branch}} (the upstream run's worktree branch — its work, if both automations share a repository); without them that context is appended automatically.")}
      </>;
    }
  }
  const tiles: [Trigger, string, string, string][] = [
    ['schedule', 'Schedule', 'clock', 'At set times'], ['githubPullRequest', 'Pull request', 'arrow.triangle.pull', 'Opened on GitHub'],
    ['githubIssue', 'Issue', 'exclamationmark.circle', 'Opened on GitHub'], ['githubCommit', 'Commit', 'point.topleft.down.to.point.bottomright.curvepath', 'Pushed to a branch'],
    ['linearIssue', 'Linear', 'line.3.horizontal.decrease.circle', 'New issue'], ['afterAutomation', 'After automation', 'link', 'Another one finishes'],
  ];
  const nsFields = draft.trigger === 'schedule' || draft.trigger === 'afterAutomation' ? null
    : ({ githubPullRequest: ['pr', ['number', 'title', 'body', 'author', 'url', 'branch']], githubIssue: ['issue', ['number', 'title', 'body', 'author', 'url']],
      githubCommit: ['commit', ['key', 'title', 'body', 'author', 'url']], linearIssue: ['issue', ['key', 'title', 'body', 'author', 'url', 'branch']] } as Record<string, [string, string[]]>)[draft.trigger];
  const promptVars = nsFields ? nsFields[1].map(f => `{{${nsFields[0]}.${f}}}`) : draft.trigger === 'afterAutomation' ? ['{{chain.automation}}', '{{chain.branch}}'] : [];
  const recent = runsOf(st).filter(r => r.automationID === draft.id && !r.isBacklogSeed).sort((a, b) => Date.parse(b.firedAt) - Date.parse(a.firedAt)).slice(0, 8);

  return (
    <div className="bx-ae">
      <div className="bx-ae-scroll">
        <div className="bx-ae-col">
          <div className="bd-hrow" style={{ gap: 14 }}>
            <span className="bx-ae-head-icon" style={{ ['--k' as any]: tint }}><SF name={kindIcon(k)} size={20} weight={600} /></span>
            <div className="bd-stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
              <input className="bx-ae-name" value={draft.name} placeholder="Name this automation" onChange={e => set({ name: e.target.value })} autoFocus={isNew} />
              <div className="secondary truncate" style={{ fontSize: 12 }}>Runs in {profile?.name ?? 'no workspace'} · {triggerSub}</div>
            </div>
            <label className="bx-ae-enabled"><Switch checked={draft.enabled} onChange={v => set({ enabled: v })} /><span>{draft.enabled ? 'Enabled' : 'Paused'}</span></label>
          </div>
          {draft.watchID && <div className="bx-ae-hint bd-hrow" style={{ gap: 5 }}><SF name="eye" size={11} />A repository watch manages this automation — edit the watch in the Automations hub's Repositories tab. Changes made here are replaced the next time the watch is saved.</div>}
          <div className="bx-ae-strip" style={{ ['--k' as any]: tint }}>
            {([['bolt.fill', 'When', describeWhen(draft, upstream, tz)], ['terminal.fill', 'What', describeWhat(draft, profile?.name ?? '?')], ['tray.full.fill', 'Then', describeAfter(draft)]] as const).map(([icon, label, text], i) => (
              <React.Fragment key={label}>
                {i > 0 && <SF name="chevron.right" size={11} weight={600} color="var(--label-tertiary)" style={{ marginTop: 22 }} />}
                <div className="bx-ae-step"><div className="bx-ae-step-label"><SF name={icon} size={10.5} weight={600} />{label}</div><div style={{ fontSize: 12.5 }}>{text}</div></div>
              </React.Fragment>
            ))}
          </div>
          {card('Where it runs', 'macwindow', 'The workspace\'s credentials and guardrails apply to every run.', <div className="bd-stack" style={{ gap: 8 }}>
            <div><PopUp bordered value={draft.profileID} onChange={v => {
              const w = st.workspaces?.find(x => x.id === v) as any;
              const ok = (w?.readyTools ?? [{ tool: w?.tool }]).some((x: any) => x.tool === draft.tool);
              const trig = draft.trigger === 'schedule' || draft.trigger === 'afterAutomation' || (draft.trigger === 'linearIssue' ? w?.hasLinearToken : w?.hasGitHubToken) ? draft.trigger : 'schedule';
              set({ profileID: v, ...(ok ? {} : { tool: w?.tool ?? 'claude' }), trigger: trig });
            }} options={(st.workspaces ?? []).map(w => ({ value: w.id, label: w.name }))} /></div>
            {hint("The workspace's credentials decide which triggers are available, and its agents run the task.")}
            <Checkbox checked={draft.startWorkspaceIfNeeded} onChange={v => set({ startWorkspaceIfNeeded: v })}>Start the workspace if needed</Checkbox>
            {hint(draft.startWorkspaceIfNeeded ? 'A fire while the workspace is off or suspended boots it first.' : "A fire while the workspace isn't running is recorded as skipped.")}
            <Checkbox checked={draft.cloneWorkspaceFirst} disabled={!reliableDone(draft.tool)} onChange={v => set({ cloneWorkspaceFirst: v })}>Run in a disposable clone of the workspace</Checkbox>
            {hint(!reliableDone(draft.tool) ? 'Clone runs need an agent that reports completion (Claude Code, Codex, Grok or Kimi Code) — that signal is what tears the clone down.'
              : draft.cloneWorkspaceFirst ? 'Each run copies this workspace (settings, credentials, home), boots the copy, and deletes it when the run finishes — have the prompt push results to a remote. With “Close the tab…” off, the clone is kept for inspection instead.'
              : 'The run executes in this workspace itself, as a worktree tab.')}
          </div>)}
          {card('When it runs', 'bolt.fill', 'A schedule, or something happening on GitHub or Linear.', <div className="bd-stack" style={{ gap: 13 }}>
            <div className="bd-stack" style={{ gap: 6 }}>
              <div className="bx-ae-tiles">
                {tiles.map(([t, title, icon, sub]) => {
                  const ok = available(t);
                  return (
                    <button key={t} className={cx('bx-ae-tile', draft.trigger === t && 'on')} disabled={!ok} title={`${title} — ${ok ? sub : 'Needs a token'}`} onClick={() => set({ trigger: t })}>
                      <SF name={icon} size={14} weight={600} />
                      <span className="bx-ae-tile-title">{title}</span>
                      <span className="bx-ae-tile-sub" style={ok ? undefined : { color: 'var(--orange)' }}>{ok ? sub : 'Needs a token'}</span>
                    </button>
                  );
                })}
              </div>
              {(!hasGH || !hasLin) && (
                <div className="bd-hrow" style={{ gap: 6 }}>
                  <span className="bx-ae-hint">{!hasGH && !hasLin ? 'GitHub triggers need a GitHub token; Linear triggers need a Linear API key.' : !hasGH ? 'GitHub triggers need a GitHub token in this workspace.' : 'Linear triggers need a Linear API key in this workspace.'}</span>
                  <button className="bx-ah-link" onClick={() => window.dispatchEvent(new CustomEvent('bromure:open', { detail: { what: 'workspace-settings', id: draft.profileID } }))}>Add one…</button>
                </div>
              )}
            </div>
            <div className="bx-ae-div" />
            {triggerBody}
          </div>)}
          {card('What the agent does', 'terminal.fill', 'Each run starts this agent with your prompt, on a fresh branch.', <div className="bd-stack" style={{ gap: 13 }}>
            <div className="bx-ae-line"><span>Agent</span><PopUp bordered value={draft.tool} onChange={v => set({ tool: v })} options={tools.map(t => ({ value: t.tool, label: `${toolName(t.tool)} — ${authName(t.authMode)}` }))} /></div>
            {spec?.authMode === 'subscription' && <div className="bx-ae-warn"><SF name="exclamationmark.triangle" size={11} />This agent signs in interactively — an expired login can stall an unattended run.</div>}
            {captioned('Start the agent in — a folder inside the workspace ("~" is home)', <TextField value={draft.repoPath} placeholder="~/my-repo" onChange={e => set({ repoPath: e.target.value })} />)}
            {draft.trigger.startsWith('github') && hint(draft.githubRepo ? `Each run starts here, on a fresh branch: pick the workspace's clone of ${draft.githubRepo}.` : "Each run starts here, on a fresh branch: pick the workspace's clone of the repository the trigger watches.")}
            <div className="bd-stack" style={{ gap: 4 }}>
              <div className="bx-ae-caption">Prompt</div>
              <textarea className="bx-ae-prompt" value={draft.prompt} onChange={e => set({ prompt: e.target.value })} />
              {promptVars.length > 0 && (
                <div className="bd-hrow" style={{ gap: 5, flexWrap: 'wrap' }}>
                  <span className="bx-ae-hint">Insert:</span>
                  {promptVars.map(v => <button key={v} className="bx-ae-var" onClick={() => set({ prompt: draft.prompt + (!draft.prompt || /[ \n]$/.test(draft.prompt) ? '' : ' ') + v })}>{v}</button>)}
                </div>
              )}
              {hint('Each run starts the agent with this prompt — in a fresh worktree when the path is a git repo, in a plain tab at that path otherwise.')}
            </div>
          </div>)}
          {card('When it finishes', 'checkmark.circle.fill', null, <div className="bd-stack" style={{ gap: 8 }}>
            <Checkbox checked={draft.closeWhenDone} disabled={!reliableDone(draft.tool)} onChange={v => set({ closeWhenDone: v })}>Close the tab when the agent finishes</Checkbox>
            {hint(reliableDone(draft.tool) ? "The transcript is saved first — readable any time from the run's card on the automation board. Turn off to leave the session up for inspection."
              : "Only agents that report completion through a hook (Claude Code, Codex, Grok, Kimi Code) can close their tab; other agents' tabs stay open.")}
          </div>)}
          {askLabels.length > 0 && (
            <div className="bx-ae-unattended">
              <SF name="exclamationmark.triangle.fill" size={13} color="var(--orange)" />
              <div className="bd-stack" style={{ gap: 4 }}>
                <div style={{ fontSize: 12, fontWeight: 600 }}>Won't run fully unattended</div>
                <div className="bx-ae-hint">{askLabels.join(', ')} {askLabels.length === 1 ? 'is' : 'are'} set to Ask before use. A run that needs {askLabels.length === 1 ? 'it' : 'them'} will pause in the consent dialog until you approve it on this Mac.</div>
                <div><Button size="small" onClick={() => window.dispatchEvent(new CustomEvent('bromure:open', { detail: { what: 'workspace-settings', id: draft.profileID } }))}>Open Workspace Settings…</Button></div>
              </div>
            </div>
          )}
          {!isNew && card('Recent runs', 'clock.arrow.circlepath', null, <div className="bd-stack" style={{ gap: 7 }}>
            {recent.length === 0 && hint('No runs yet.')}
            {recent.map(r => (
              <div key={r.id} className="bd-hrow" style={{ gap: 8 }}>
                <span style={{ width: 14, display: 'grid', placeItems: 'center' }}><SF name={outcomeGlyph(r.outcome)} size={11} color={outcomeTint(r.outcome)} /></span>
                <span className="secondary" style={{ fontSize: 11, fontVariantNumeric: 'tabular-nums' }}>{dateTime(r.firedAt)}</span>
                <span className="truncate" style={{ fontSize: 11 }}>{r.detail}</span>
              </div>
            ))}
          </div>)}
        </div>
      </div>
      <div className="bx-ae-footer">
        {!isNew && <Button size="large" destructive onClick={() => confirmDeleteAutomation(host, draft.id, close)}>Delete…</Button>}
        {!canSave && <span className="bx-ae-blockers"><SF name="exclamationmark.circle" size={12} />To save: {blockers.join(', ')}</span>}
        <span className="spacer" />
        <Button size="large" disabled={!canSave} onClick={runNow} title="Saves, then fires immediately — the schedule is untouched.">Run Now</Button>
        <Button size="large" variant="prominent" disabled={!canSave} onClick={save}>Save</Button>
      </div>
    </div>
  );
}
