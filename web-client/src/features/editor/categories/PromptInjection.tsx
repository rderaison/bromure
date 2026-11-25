// Prompt Injection — ProfileViews.swift `promptInjectionSection` (PromptInjectionPolicy).

import React from 'react';
import { useEditor } from '../ctx';
import { Check, GBox, RadioGroup } from './SandboxPolicyKit';

const DEF = { detectSourceInjection: false, detectRulesInjection: false, onDetection: 'log' as 'log' | 'ask' | 'block' };
type PI = typeof DEF;

function encode(p: PI) {
  const o: Record<string, any> = {};
  if (p.detectSourceInjection) o.detectSourceInjection = true;
  if (p.detectRulesInjection) o.detectRulesInjection = true;
  if (p.onDetection !== 'log') o.onDetection = p.onDetection;
  return o;
}

export function PromptInjectionPane() {
  const { doc, set } = useEditor();
  const p: PI = { ...DEF, ...(doc.promptInjection ?? {}) };
  const put = (patch: Partial<PI>) => set('promptInjection', encode({ ...p, ...patch }));
  const active = p.detectSourceInjection || p.detectRulesInjection;
  return (
    <div className="sp-pane">
      <div className="sp-caption">Bromure scans the agent&rsquo;s AI traffic on-device for injected instructions — nothing leaves the Mac. Each detector uses a local model, downloaded from bromure.io the first time you enable it.</div>
      <GBox icon="brain" title="Detectors">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {/* The detector model lives on the machine that runs the proxy; a
              remote client just saves the flag and the host downloads on demand. */}
          <Check checked={p.detectSourceInjection} onChange={v => put({ detectSourceInjection: v })}>Detect prompt injection in source code</Check>
          <div className="sp-caption">Scores the file contents, web pages, and tool output the agent reads (Prompt Guard). Catches &ldquo;ignore previous instructions / exfiltrate secrets&rdquo; hidden in a rogue repository. Downloads ~272 MB on first enable.</div>
          <div className="sp-hdivider" />
          <Check checked={p.detectRulesInjection} onChange={v => put({ detectRulesInjection: v })}>Detect rogue instructions in CLAUDE.md files and similar</Check>
          <div className="sp-caption">Scores the instruction / settings files every agent loads as authority: CLAUDE.md (Claude Code), AGENTS.md (Codex, Kimi and omp) and GROK.md (Grok), plus their nested and global variants. Downloads ~571 MB on first enable.</div>
        </div>
      </GBox>
      <GBox icon="exclamationmark.triangle" title="When an injection is detected">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <RadioGroup value={p.onDetection} disabled={!active} onChange={v => put({ onDetection: v })}
                      options={[{ value: 'log', label: 'Log but continue' }, { value: 'ask', label: 'Ask me what to do' }, { value: 'block', label: 'Block unilaterally' }]} />
          <div className="sp-caption">&ldquo;Log but continue&rdquo; records detections to the Security Timeline. &ldquo;Ask me what to do&rdquo; pauses the request and shows the flagged text. &ldquo;Block&rdquo; fails the request outright.</div>
        </div>
      </GBox>
    </div>
  );
}
