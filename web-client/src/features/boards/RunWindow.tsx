// An automation run's window (AutomationRunWindow.swift): the header strip
// (accent bar, automation, status, "fired …") over the run's transcript —
// GET /automation-runs/<id>/transcript — or, without one, the outcome view.
// A run still live in a tab offers its session on the main window's stage.

import React, { useEffect, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import { useRemote } from '../../app/store';
import { useHostCtx } from '../../app/hostContext';
import type { WindowSpec } from '../../app/windows';
import { SF } from '../../ui/icons';
import { Button } from '../../ui/kit';
import { automationsOf, runsOf, workspaceOf, liveRunTab, outcomeGlyph, outcomeTint, dateTime } from './model';
import { parseTranscript, TranscriptView, b64utf8, type Item } from './Transcript';
import { Loading } from './kanban';
import { StatusDot } from './AutomationHub';
import './boards.css';

type WM = { open: (w: WindowSpec) => void };

export function openRunWindow(wm: WM, host: RemoteHost, runID: string) {
  const run = runsOf(host.state).find(r => r.id === runID);
  const a = automationsOf(host.state).find(x => x.id === run?.automationID);
  const name = a ? a.name || 'Untitled automation' : 'Deleted automation';
  wm.open({
    id: 'run:' + runID, title: run ? `${name} — run ${dateTime(run.firedAt)}` : name,
    width: 1120, height: 780, minWidth: 520, minHeight: 360,
    render: () => <RunView host={host} runID={runID} />,
  });
}

function RunView({ host, runID }: { host: RemoteHost; runID: string }) {
  const st = useRemote(host, s => s);
  const ctx = useHostCtx();
  const run = runsOf(st).find(r => r.id === runID);
  const autos = automationsOf(st);
  const a = autos.find(x => x.id === run?.automationID);
  const pid = run?.runProfileID ?? a?.profileID;
  const ws = workspaceOf(st, pid);
  const [items, setItems] = useState<Item[] | null | 'none'>(null);
  const done = !!run?.completedAt;
  useEffect(() => {
    let live = true;
    const load = () => host.request<any>('GET', `/automation-runs/${seg(runID)}/transcript`, undefined, { timeoutMs: 60_000, allowError: true } as any)
      .then(r => { if (!live) return; const raw = r?.transcript ? b64utf8(r.transcript) : ''; const p = raw ? parseTranscript(raw) : []; setItems(p.length ? p : 'none'); })
      .catch(() => live && setItems('none'));
    load();
    return () => { live = false; };
  }, [host, runID, done]);
  if (!run || !st) return <Loading />;
  const tab = liveRunTab(run, autos, st) as any;
  const status: string | undefined = tab?.agentStatus;
  const statusText = status ? (status === 'working' ? 'Agent working…' : status === 'needsInput' ? 'Agent needs your input — answer below' : 'Agent finished')
    : run.completedAt ? `Finished ${dateTime(run.completedAt)}`
    : ({ launched: 'Run ended', skipped: 'Run skipped', failed: 'Run failed', blocked: 'Run blocked' } as Record<string, string>)[run.outcome];
  const explanation = ({
    launched: "The run's session is gone and no transcript was captured — the workspace may have stopped before the agent finished.",
    skipped: 'This fire was skipped — nothing ran.', failed: 'The run never launched.',
    blocked: "The prompt-injection screen refused this item's text — no agent saw it.",
  } as Record<string, string>)[run.outcome];
  const liveTerminal = !!tab && (!run.completedAt || items === 'none');
  return (
    <div className="bx-rw">
      <div className="bx-rw-head">
        <span className="bx-rw-bar" style={{ background: ws?.accentHex ?? '#888' }} />
        <div className="bd-stack" style={{ gap: 2, minWidth: 0, flex: 1 }}>
          <div className="bd-hrow" style={{ gap: 8 }}>
            <span className="bx-rw-title truncate">{a ? a.name || 'Untitled automation' : 'Deleted automation'}</span>
            {ws && <span className="bx-rw-sub">{ws.name}</span>}
          </div>
          <div className="bd-hrow" style={{ gap: 6, minWidth: 0 }}>
            {status ? <StatusDot status={status} /> : <SF name={outcomeGlyph(run.outcome)} size={10} color={outcomeTint(run.outcome)} />}
            <span className="bx-rw-sub" style={status === 'needsInput' ? { color: 'var(--red)' } : undefined}>{statusText}</span>
            {run.detail && run.detail !== run.branchSlug && <span className="bx-rw-sub tertiary truncate">· {run.detail}</span>}
          </div>
        </div>
        <span className="bx-rw-fired">fired {dateTime(run.firedAt)}</span>
      </div>
      {liveTerminal ? (
        <div className="empty-state" style={{ flex: 1 }}>
          <SF name="terminal" size={30} color="var(--label-tertiary)" />
          <span>The run is live in a tab of {ws?.name ?? 'its workspace'}.</span>
          <Button variant="prominent" onClick={() => ctx.select({ kind: 'workspace', workspaceID: pid!, windowIndex: tab.index })}>Open Session</Button>
        </div>
      ) : items === null ? <Loading />
        : items !== 'none' ? <TranscriptView items={items} />
        : (
          <div className="bx-rw-outcome">
            <SF name={outcomeGlyph(run.outcome)} size={30} weight={300} color={outcomeTint(run.outcome)} />
            <div style={{ fontSize: 13, fontWeight: 500, textAlign: 'center' }}>{run.detail || explanation}</div>
            {run.detail && <div className="secondary" style={{ fontSize: 11, textAlign: 'center' }}>{explanation}</div>}
          </div>
        )}
    </div>
  );
}
