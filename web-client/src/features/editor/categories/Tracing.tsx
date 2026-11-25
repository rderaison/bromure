// Tracing — ProfileViews.swift `tracingSection`: the proxy's session trace
// level, Private mode (only where the host streams to bromure.io), and the
// subscription-token-swap resets.

import React from 'react';
import { Button, PopUp, Switch } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { useEditor } from '../ctx';
import { val } from '../model';
import { Caption } from '../ui';
import './Credentials.css';

const LEVELS = [
  { value: 'off', label: 'Off' },
  { value: 'activity', label: 'Activity only' },
  { value: 'aiDetails', label: 'AI request details' },
  { value: 'all', label: 'Everything' },
];

export function TracingPane() {
  const { doc, set, host } = useEditor();
  // Private mode means something only on a host enrolled with bromure.io
  // (BACEnrollmentStore on the Mac that runs the workspace); the snapshot says
  // so when the server is new enough. A setting already on stays visible.
  const st = host.state as any;
  const enrolled = !!(st?.enrolled ?? st?.cloudEnrolled ?? st?.enrollment) || val<boolean>(doc, 'privateMode');
  const swap = val<string>(doc, 'subscriptionTokenSwap'), cswap = val<string>(doc, 'codexTokenSwap');
  return (
    <div className="edc-pane">
      <div className="edc-vstack" style={{ gap: 4 }}>
        <div className="edc-hrow">
          <span className="edt-label"><SF name="doc.text.magnifyingglass" size={14} />Session trace</span>
          <div style={{ flex: 1 }} />
          <span className="edt-levelbox"><PopUp bordered className="edt-level" value={val<string>(doc, 'traceLevel')} onChange={v => set('traceLevel', v)} options={LEVELS} /></span>
        </div>
        <Caption>Off → nothing recorded. Activity → metadata only (host, status, latency, swap report, leak warnings). AI request details → also captures bodies for known LLM hosts (Anthropic, OpenAI, Google, Cohere, Mistral, Perplexity, x.ai, Groq, Replicate, HuggingFace). Everything → bodies for every host. Bodies are AES-GCM encrypted with the same keychain key as workspace secrets. View it in Window › Trace Inspector… (⇧⌘I).</Caption>
      </div>

      {enrolled && (
        <div className="edc-vstack" style={{ gap: 4 }}>
          <div className="edc-hrow">
            <span className="edt-label"><SF name="eye.slash" size={14} />Private mode</span>
            <div style={{ flex: 1 }} />
            <Switch checked={val(doc, 'privateMode')} onChange={v => set('privateMode', v)} />
          </div>
          <Caption>Sessions running under this workspace normally stream metadata (tools, files, commands, token usage) to your workspace. Turn this on to keep this workspace's activity local — neither the title-bar indicator nor the admin's session list will see anything from this workspace. The local trace inspector is unaffected.</Caption>
        </div>
      )}

      {swap !== 'unset' && <SwapRow title="Claude subscription token swap" state={swap} host="anthropic.com" onReset={() => set('subscriptionTokenSwap', 'unset')} />}
      {cswap !== 'unset' && <SwapRow title="Codex subscription token swap" state={cswap} host="chatgpt.com" onReset={() => set('codexTokenSwap', 'unset')} />}
    </div>
  );
}

function SwapRow({ title, state, host, onReset }: { title: string; state: string; host: string; onReset: () => void }) {
  const accepted = state === 'accepted';
  return (
    <div className="edc-vstack" style={{ gap: 4 }}>
      <div className="edc-hrow">
        <span className="edt-label"><SF name="key.viewfinder" size={14} />{title}</span>
        <div style={{ flex: 1 }} />
        <Caption>{accepted ? 'Active' : 'Declined'}</Caption>
      </div>
      <Caption>{accepted
        ? 'The proxy is keeping the real OAuth tokens on this Mac and serving fakes inside the VM.'
        : `You said “Never” on the swap prompt for this workspace. Reset to be asked again next time the VM sends a real token to ${host}.`}</Caption>
      <div><Button size="small" onClick={onReset}>{accepted ? 'Forget swap (re-prompt next session)' : 'Re-enable prompt'}</Button></div>
    </div>
  );
}
