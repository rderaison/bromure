// Squelch — ProfileViews.swift `squelchSection` + SquelchViews.swift
// (SquelchTallyRow, SquelchDaysChart). The savings come from the host's
// ledger (GET /squelch), not this client's.

import React, { useEffect, useState } from 'react';
import { SF } from '../../../ui/icons';
import { openExternal } from '../../../platform';
import { useEditor } from '../ctx';
import { val } from '../model';
import { Check } from './ModelsShared';

interface Tally { outputs?: number; trimmed?: number; rawBytes?: number; keptBytes?: number }
interface Summary { total?: Tally; commands?: { name: string; tally: Tally }[]; days?: { name: string; tally: Tally }[] }

const saved = (t?: Tally) => Math.floor(Math.max(0, (t?.rawBytes ?? 0) - (t?.keptBytes ?? 0)) / 4);
const raw = (t?: Tally) => Math.floor((t?.rawBytes ?? 0) / 4);
const frac = (t?: Tally) => (t?.rawBytes ?? 0) > 0 ? Math.max(0, (t!.rawBytes! - (t!.keptBytes ?? 0))) / t!.rawBytes! : 0;
/** SquelchFormat.tokens / percent */
export function fmtTokens(n: number) {
  if (n < 1000) return `${n}`;
  if (n < 10_000) return `${(n / 1000).toFixed(1)}K`;
  if (n < 1_000_000) return `${(n / 1000).toFixed(0)}K`;
  return `${(n / 1e6).toFixed(1)}M`;
}
const pct = (f: number) => `${Math.round(f * 100)}%`;

export function SquelchPane() {
  const { doc, update, isTemplate, host, workspaceID, opened } = useEditor();
  const [summary, setSummary] = useState<Summary | null>(null);
  useEffect(() => {
    if (isTemplate || !workspaceID) return;
    host.request<any>('GET', '/squelch').then(r => {
      const s = r?.workspaces?.[workspaceID] ?? r?.workspaces?.[workspaceID.toLowerCase()];
      if (s) setSummary(s);
    }).catch(() => {});
  }, [host, workspaceID, isTemplate]);
  const on = !!val<any>(doc, 'squelch')?.enabled;
  return (
    <div className="sq-pane">
      <div className="sq-gb-label"><SquelchGlyph />Squelch</div>
      <div className="sq-gb">
        <Check checked={on} onChange={v => update(d => { if (v) d.squelch = { enabled: true }; else if (opened.squelch == null) delete d.squelch; else d.squelch = {}; })}>
          Trim the noise out of command output before the model reads it
        </Check>
      </div>
      {summary?.total && (
        <>
          <div className="sq-gb-label"><SF name="chart.bar.fill" size={13} />Saved so far</div>
          <div className="sq-gb sq-saved">
            <TallyRow title={doc.name} t={summary.total} />
            {!!summary.commands?.length && (
              <div className="sq-grid">
                {summary.commands.map(e => (
                  <React.Fragment key={e.name}>
                    <span className="mono sq-cmd">{e.name}</span>
                    <span className="sq-num">{fmtTokens(saved(e.tally))} tokens</span>
                    <span className="sq-num secondary">{pct(frac(e.tally))}</span>
                  </React.Fragment>
                ))}
              </div>
            )}
            {!!summary.days?.length && <DaysChart days={summary.days} />}
          </div>
        </>
      )}
      <div className="mdl-caption">Tokens are estimated as characters ÷ 4.</div>
      <div className="mdl-caption sq-credit">Inspired by <a href="https://github.com/rtk-ai/rtk" onClick={e => { e.preventDefault(); openExternal('https://github.com/rtk-ai/rtk'); }}>rtk — Rust Token Killer (rtk-ai), Apache-2.0</a></div>
    </div>
  );
}

function TallyRow({ title, t }: { title: string; t: Tally }) {
  return (
    <div className="sq-tally">
      <div className="sq-tally-title">{title}</div>
      <div className="sq-tally-big">~{fmtTokens(saved(t))} tokens saved</div>
      <div className="sq-tally-sub">{pct(frac(t))} of {fmtTokens(raw(t))} tokens of command output · {t.outputs ?? 0} outputs, {t.trimmed ?? 0} trimmed</div>
    </div>
  );
}

function DaysChart({ days }: { days: { name: string; tally: Tally }[] }) {
  const top = Math.max(1, ...days.map(d => saved(d.tally)));
  return (
    <div className="sq-days">
      <div className="sq-tally-title">Last two weeks</div>
      <div className="sq-bars">
        {days.map(d => (
          <div key={d.name} className="sq-bar" title={`${d.name}: ${fmtTokens(saved(d.tally))} tokens saved`}
               style={{ height: Math.max(2, 36 * saved(d.tally) / top), background: saved(d.tally) > 0 ? 'var(--accent)' : 'var(--fill)' }} />
        ))}
      </div>
    </div>
  );
}

/** line.3.horizontal.decrease.circle.fill — a filled disc with the lines knocked out. */
function SquelchGlyph() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" aria-hidden>
      <mask id="sqg"><rect width="24" height="24" fill="#fff" /><g fill="#000"><rect x="6.5" y="7.6" width="11" height="2" rx="1" /><rect x="8" y="11" width="8" height="2" rx="1" /><rect x="9.8" y="14.4" width="4.4" height="2" rx="1" /></g></mask>
      <circle cx="12" cy="12" r="11" fill="currentColor" mask="url(#sqg)" />
    </svg>
  );
}
