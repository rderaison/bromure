// PII Protection — ProfileViews.swift `piiSection` (PIIPolicy).

import React from 'react';
import { useEditor } from '../ctx';
import { openExternal } from '../../../platform';
import { Check, GBox } from './SandboxPolicyKit';

const DEF = { enabled: false, names: true, contact: true, financial: true, governmentIDs: true, addresses: true };
type PII = typeof DEF;

/** PIIPolicy's encoder: only non-defaults are written. */
function encode(p: PII) {
  const o: Record<string, boolean> = {};
  for (const k of Object.keys(DEF) as (keyof PII)[]) if (p[k] !== DEF[k]) o[k] = p[k];
  return o;
}

const CATS: [keyof PII, string][] = [
  ['names', 'People’s names'],
  ['contact', 'Email addresses and phone numbers'],
  ['financial', 'Card, bank account and tax numbers'],
  ['governmentIDs', 'SSNs, passports, driver’s licenses and other IDs'],
  ['addresses', 'Street addresses (city, state and postal code are kept)'],
];

export function PIIPane() {
  const { doc, set } = useEditor();
  const p: PII = { ...DEF, ...(doc.pii ?? {}) };
  const put = (k: keyof PII, v: boolean) => set('pii', encode({ ...p, [k]: v }));
  return (
    <div className="sp-pane">
      <div className="sp-caption">Before the agent&rsquo;s conversation leaves the Mac, Bromure swaps the personal data in it — names, emails, phone numbers, card and ID numbers, street addresses — for realistic stand-ins, and puts the real values back in the replies. The model provider never sees them; the agent and your files keep the real thing. Detection runs on-device with the built-in Rampart model.</div>
      <GBox icon="person.crop.circle.badge.checkmark" title="Protection">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {/* The model lives where the proxy runs (the host): the client just saves the flag. */}
          <Check checked={p.enabled} onChange={v => put('enabled', v)}>Swap personal data for stand-ins before it reaches the model</Check>
          <div className="sp-hdivider" />
          {CATS.map(([k, label]) => (
            <Check key={k} checked={p[k]} disabled={!p.enabled} onChange={v => put(k, v)}>{label}</Check>
          ))}
        </div>
      </GBox>
      <div className="sp-caption">Source code is left to the pattern rules (emails, cards, SSNs) — names in code are almost always identifiers. Each swap is counted in the Security Timeline; the values themselves are never logged.</div>
      <div><a className="sp-link" onClick={() => openExternal('https://huggingface.co/nationaldesignstudio/rampart')}>Rampart — National Design Studio, CC BY 4.0</a></div>
    </div>
  );
}
