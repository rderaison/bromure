// Environment — ProfileViews.swift `environmentSection` + AgentEnvironmentEditor.swift
// (Preferences only: the host's global "Describe your environment", saved
// into its model settings) + EnvironmentVariableRow.

import React from 'react';
import { useEditor } from '../ctx';
import { val } from '../model';
import { Caption, CaptionTertiary, Divider, Headline, MD } from '../ui';
import { BorderlessButton, RemoveButton, RowCard } from './FoldersKit';

const EXAMPLE = `Organization: Acme Corp — software development
staging.acme.dev is our staging server: deploys and changes there are fully authorized
prod.acme.com is production: never change anything there without asking me first
Source control: github.com/acme — pushing to any branch is fine
Trusted internal domains: *.acme.internal, api.acme.dev`;

interface EnvVar { id: string; name: string; value: string }

/** EnvironmentVariable.isValidName: [A-Za-z_][A-Za-z0-9_]* (letters/digits in the Unicode sense). */
export const isValidEnvName = (s: string) => /^[\p{L}_][\p{L}\p{N}_]*$/u.test(s);

export function EnvironmentPane() {
  const { doc, set, setGlobalModels, globalModels } = useEditor();
  const vars = val<EnvVar[]>(doc, 'environmentVariables');
  const update = (i: number, patch: Partial<EnvVar>) => set('environmentVariables', vars.map((v, j) => j === i ? { ...v, ...patch } : v));
  return (
    <div className="edm-pane" style={{ gap: 18 }}>
      {setGlobalModels && (
        <>
          <AgentEnvironmentEditor text={String(globalModels.agentEnvironment ?? '')}
                                  onChange={t => setGlobalModels(m => { m.agentEnvironment = t; })} />
          <Divider />
        </>
      )}
      <div className="edm-pane" style={{ gap: 8 }}>
        <Headline>Variables</Headline>
        <Caption md>{'Plain `KEY=VALUE` pairs exported into every shell in the VM via `proxy.env` (sourced from `.bashrc`). No proxy substitution — values land on the VM verbatim, so don\'t put secrets here. Good for log levels, feature flags, build toggles.'}</Caption>
        {vars.length === 0 ? (
          <div className="edm-empty-small">No environment variables configured.</div>
        ) : vars.map((v, i) => {
          const t = v.name.trim();
          const invalid = t !== '' && !isValidEnvName(t);
          return (
            <RowCard key={v.id ?? i}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                <div className="edm-row">
                  <input className="field ed-field" style={{ maxWidth: 220 }} spellCheck={false} aria-label="Name"
                         placeholder="MY_ENV_VAR" value={v.name} onChange={e => update(i, { name: e.target.value })} />
                  <span className="tertiary">=</span>
                  <input className="field ed-field" spellCheck={false} aria-label="Value" placeholder="1"
                         value={v.value} onChange={e => update(i, { value: e.target.value })} />
                  <RemoveButton help="Remove this variable" onClick={() => set('environmentVariables', vars.filter((_, j) => j !== i))} />
                </div>
                {invalid && (
                  <div className="edm-caption2" style={{ color: 'var(--orange)' }}>
                    <MD>{'Name must match `[A-Za-z_][A-Za-z0-9_]*` to be exported.'}</MD>
                  </div>
                )}
              </div>
            </RowCard>
          );
        })}
        <div className="edm-trailing">
          <BorderlessButton symbol="plus" onClick={() => set('environmentVariables', [...vars, { id: crypto.randomUUID().toUpperCase(), name: '', value: '' }])}>
            Add variable
          </BorderlessButton>
        </div>
      </div>
    </div>
  );
}

/** "Describe your environment" — the host's global agent environment. */
function AgentEnvironmentEditor({ text, onChange }: { text: string; onChange: (t: string) => void }) {
  return (
    <div className="edm-pane" style={{ gap: 8 }}>
      <Headline>Describe your environment</Headline>
      <Caption>What your agents' safety checks should know about your world: your organization, your servers and what they're for, the repositories and domains you trust, what's safe to change. One fact per line. Claude's auto mode reads them to tell routine work from risky actions.</Caption>
      <textarea className="edm-texteditor" spellCheck={false} rows={6} value={text} placeholder={EXAMPLE}
                aria-label="Describe your environment" onChange={e => onChange(e.target.value)} />
      <CaptionTertiary>Applies to every workspace from its next launch.</CaptionTertiary>
    </div>
  );
}
