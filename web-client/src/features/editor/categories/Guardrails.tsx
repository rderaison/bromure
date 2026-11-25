// Guardrails — ProfileViews.swift `guardrailsSection`: per configured
// credential, "Require approval to use" and its service's write policy; the
// exfiltration-alert switch; and the Protections (tell the agent, watchdog,
// strict credentials, transparent interception, insecure bypass, pinned
// upstream certificates). Live consent grants (badges, right-click allow /
// deny) belong to the host's broker and aren't reachable from a remote editor
// — the macOS fat client passes no `consentGrants` either.

import React from 'react';
import { Button, PopUp, Segmented } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { useEditor } from '../ctx';
import { val, type Doc } from '../model';
import { Caption, Field, InfoTip, Toggle } from '../ui';
import { RequireApproval, arr } from './CredentialsEditors';
import {
  MODES, configuredRefs, credentialHosts, credentialTitle, getApproval, manualUsable, modeSlot, refSymbol, setApproval, uuid,
  type CredRef,
} from './CredentialsModel';
import './Credentials.css';

function Setting({ caption, info, children }: { caption: string; info: string; children: React.ReactNode }) {
  return (
    <div className="edg-setting">
      <div className="edc-hrow" style={{ gap: 4 }}>{children}<InfoTip text={info} /></div>
      <Caption md>{caption}</Caption>
    </div>
  );
}

/** Profile.unboundCredentialNames — usable custom tokens with no host filter. */
function unboundNames(doc: Doc): string[] {
  return val<Doc[]>(doc, 'manualTokens')
    .filter(m => manualUsable(m) && !(m.hostFilters ?? []).some((h: string) => h.trim()))
    .map(m => m.name || m.envVarName);
}

const HEX64 = /^[0-9a-f]{64}$/;
function normFingerprint(s: string): string | null {
  let t = s.trim().toLowerCase().replace(/^sha256\s*fingerprint\s*=\s*/, '').replace(/^sha256:/, '');
  t = t.replace(/[:\s]/g, '');
  return HEX64.test(t) ? t : null;
}
function normHost(s: string): string | null {
  let h = s.trim().toLowerCase();
  const i = h.indexOf('://'); if (i >= 0) h = h.slice(i + 3);
  const sl = h.indexOf('/'); if (sl >= 0) h = h.slice(0, sl);
  if (h.startsWith('[')) { const c = h.indexOf(']'); if (c > 0) h = h.slice(1, c); }
  else if ((h.match(/:/g) ?? []).length === 1) h = h.slice(0, h.indexOf(':'));
  if (h.endsWith('.')) h = h.slice(0, -1);
  return h || null;
}

export function GuardrailsPane() {
  const { doc, set, update, credentialRefs, opened, setInvalid } = useEditor();
  const refs = configuredRefs(doc, credentialRefs, opened);
  const g = val<Doc>(doc, 'guardrails');
  const setG = (k: string, v: any) => update(d => { d.guardrails = { ...val<Doc>(d, 'guardrails'), [k]: v }; });
  const strict = val<boolean>(doc, 'strictCredentials');
  const unbound = unboundNames(doc);
  const tellDefault = String(val(doc, 'networkPolicy')).trim() !== '';
  const certs = (g.trustedCertificates ?? []) as Doc[];

  // Strict mode binds every credential to its hosts: can't save until each has one.
  React.useEffect(() => {
    setInvalid('guardrails.strict', strict && unbound.length ? 'Give every custom credential a host filter (strict mode).' : null);
  }, [strict, unbound.length, setInvalid]);

  return (
    <div className="edc-pane" style={{ paddingBottom: 8 }}>
      <div className="edc-hrow" style={{ gap: 4 }}>
        <Caption>How this workspace's credentials may be used.</Caption>
        <InfoTip text={"Guardrails govern how this workspace's configured credentials are used. **Ask before use** pops a host-side confirmation the first time a credential is used in a session. A **write policy** strips or blocks destructive operations on the wire — enforced in the proxy, so a compromised agent can't bypass it. Only credentials you've configured appear here.\n\nA write policy is per service, so two credentials for the same service (e.g. two GitHub tokens) share one policy."} />
      </div>

      {refs.length === 0 ? (
        <div className="edc-empty" style={{ padding: '22px 0' }}>
          <SF name="shield.slash" size={22} color="var(--label-secondary)" />
          <div className="edc-empty-title">No credentials to guard</div>
          <Caption style={{ textAlign: 'center' }}>Add credentials in the Credentials pane.</Caption>
        </div>
      ) : refs.map(r => (
        <React.Fragment key={r.id}>
          <CredentialRow r={r} />
          <div className="ed-divider" />
        </React.Fragment>
      ))}

      <div className="ed-divider" style={{ margin: '4px 0' }} />
      <Setting caption="A leaked credential is still blocked and logged; only the pop-up goes away."
               info="By default, when a session credential is seen heading to a host it wasn't minted for, Bromure pauses the VM and pops up a compromise alert. Turn this on to suppress that modal. The leak is STILL blocked and still recorded in the Security Timeline — only the interruption goes away. Applies live, no restart.">
        <Toggle checked={val(doc, 'disableExfiltrationAlerts')} onChange={v => set('disableExfiltrationAlerts', v)}>Don't alert on credential exfiltration</Toggle>
      </Setting>

      <div className="ed-divider" style={{ margin: '4px 0' }} />
      <div className="ed-headline">Protections</div>
      <div className="edc-vstack" style={{ gap: 10 }}>
        <Setting caption="The agent asks you instead of retrying or finding a way round."
                 info="When the firewall or the sandbox blocks something an agent tried, the agent is told what was blocked and why, and to ask you rather than retry or find another way round. Without it, an agent sees only a failed connection or “permission denied” and may keep trying. Claude Code reads it right after the command that hit the block; other agents get it when their turn ends. Until you choose, it's on while the workspace uses an OpenShell policy.">
          <Toggle checked={(doc.tellAgentOnDeny as boolean | undefined) ?? tellDefault} onChange={v => set('tellAgentOnDeny', v)}>Tell the agent when policy blocks it</Toggle>
        </Setting>
        <Setting caption="Flags a session that behaves suspiciously; Quarantine also cuts its network and pauses it."
                 info="Watches the session as a whole from outside the VM — bursts of blocked requests, credentials that don't belong, tampering, new destinations once the session has settled, and outbound volume far above its own baseline (counted at the network switch, independently of the proxy). Past a threshold within a minute it records a detection finding; in Quarantine it also cuts the VM's network and pauses it in milliseconds, then asks you. Applies live.">
          <span className="ed-body">Agent watchdog</span>
          <span className="edg-seg"><Segmented value={val<string>(doc, 'watchdogMode')} onChange={v => set('watchdogMode', v)}
                     options={[{ value: 'off', label: 'Off' }, { value: 'alert', label: 'Alert' }, { value: 'quarantine', label: 'Quarantine' }]} /></span>
        </Setting>
        <Setting caption="Blocks any credential Bromure didn't put there itself."
                 info="Blocks any request that carries a credential Bromure didn't put there — an API key or token the agent found in a file, an environment dump or a git config, or guessed. Bromure's own credentials still flow to the hosts they're bound to, and tokens a site issues inside the VM (a login, an OAuth flow) can be sent back to that site. A blocked request raises the compromise alert; Allow approves that one credential for the session. Strict mode inspects every HTTP(S) request, so transparent interception stays on and the no-MITM list is ignored. Raw TCP (SSH, databases) can't be inspected: deny it with the firewall. Applies live.">
          <Toggle checked={strict} onChange={v => set('strictCredentials', v)}>Only allow credentials Bromure injects (strict mode)</Toggle>
        </Setting>
        {strict && unbound.length > 0 && (
          <div className="edg-warn"><SF name="exclamationmark.triangle.fill" size={10} />
            <span>Give these credentials a host filter before saving (strict mode doesn't allow credentials usable on any host): {unbound.join(', ')}</span></div>
        )}
        <Setting caption="For clients that break when Bromure intercepts them; proxy-aware tools still go through Bromure."
                 info="Transparent interception (on by default) diverts the VM's HTTP/HTTPS into Bromure at the network layer, so the proxy sees the traffic even when a client doesn't use the proxy env vars. Turn it off and that forced divert stops: raw sockets and cert-pinned clients (Signal and similar) reach the real network — and the real upstream cert — directly. This does NOT disable the proxy itself: HTTP(S)_PROXY stays set, so proxy-aware tools (apt/git/pip/curl/node…) and the agent's own API calls still go through Bromure and keep credential/token swap, tracing, and guardrails. Applies live, no restart. Use for a workspace with a client that breaks under transparent interception.">
          <Toggle checked={val(doc, 'disableTransparentProxy')} disabled={strict} onChange={v => set('disableTransparentProxy', v)}>Disable transparent interception</Toggle>
        </Setting>
        <Setting caption="Lets the agent skip one host's certificate check with a header."
                 info="A lighter escape hatch than full passthrough. When a request to a self-signed / private-CA host fails validation, the agent can retry it with the header `X-bromure-insecure: yes` to skip validating THAT upstream's certificate. Interception, tracing, and the leak guard stay on, and Bromure injects no real credential on such a request (only the guest's fakes go out). Every use is recorded in the Security Timeline. On by default (it only acts when the guest explicitly sends the header); turn it off to forbid the header outright.">
          <Toggle checked={g.allowInsecureBypass ?? true} onChange={v => setG('allowInsecureBypass', v)}>Allow per-request insecure bypass (X-bromure-insecure)</Toggle>
        </Setting>
        <Setting caption="Trusts a self-signed server's exact certificate, so credentials still reach it."
                 info="For an internal server with a self-signed or private-CA certificate that should still get real credentials. Enter its hostname and the SHA-256 fingerprint of the certificate it presents (`openssl s_client -connect host:443 </dev/null | openssl x509 -noout -fingerprint -sha256`, or the fingerprint a browser's certificate viewer shows). When that host presents exactly this certificate, Bromure trusts it like any valid one and swaps and injects credentials as usual. Any other certificate is checked normally. Check the fingerprint against the server itself before pinning it: only you can add a pin, never the agent. Applies live.">
          <span className="ed-body">Trusted upstream certificates</span>
        </Setting>
        <div className="edc-vstack" style={{ gap: 6 }}>
          {certs.map(c => {
            const setC = (k: string, v: string) => update(d => {
              const gg = { ...val<Doc>(d, 'guardrails') };
              gg.trustedCertificates = (gg.trustedCertificates ?? []).map((x: Doc) => x.id === c.id ? { ...x, [k]: v } : x);
              d.guardrails = gg;
            });
            return (
              <div key={c.id} className="edg-certrow">
                <Field value={c.host ?? ''} onChange={v => setC('host', v)} placeholder="internal.example.com" style={{ width: 180, flex: 'none' }} />
                <Field mono value={c.sha256 ?? ''} onChange={v => setC('sha256', v)} placeholder="SHA-256 fingerprint" />
                {(!normHost(c.host ?? '') || !normFingerprint(c.sha256 ?? '')) &&
                  <span title="Needs a hostname and a 64-character SHA-256 fingerprint; ignored until then."><SF name="exclamationmark.triangle.fill" size={13} color="var(--orange)" /></span>}
                <button className="edc-iconbtn" title="Remove" onClick={() => update(d => {
                  const gg = { ...val<Doc>(d, 'guardrails') };
                  gg.trustedCertificates = (gg.trustedCertificates ?? []).filter((x: Doc) => x.id !== c.id);
                  d.guardrails = gg;
                })}><SF name="minus.circle" size={14} /></button>
              </div>
            );
          })}
          <div><Button icon="plus" className="edg-addcert" onClick={() => setG('trustedCertificates', [...certs, { id: uuid(), host: '', sha256: '' }])}>Add certificate</Button></div>
        </div>
      </div>
    </div>
  );
}

function CredentialRow({ r }: { r: CredRef }) {
  const { doc, update } = useEditor();
  const hosts = credentialHosts(doc, r);
  const slot = modeSlot(doc, r);
  const mode = slot == null ? null : 'guardrail' in slot
    ? (val<Doc>(doc, 'guardrails')[slot.guardrail] ?? 'off')
    : (val<Doc[]>(doc, 'httpDatabases').find(x => x.id === slot.db)?.guardrail ?? 'off');
  const setMode = (v: string) => update(d => {
    if (!slot) return;
    if ('guardrail' in slot) d.guardrails = { ...val<Doc>(d, 'guardrails'), [slot.guardrail]: v };
    else { const x = arr(d, 'httpDatabases').find(e => e.id === slot.db); if (x) x.guardrail = v; }
  });
  return (
    <div className="edg-row">
      <div className="edc-hrow" style={{ gap: 8 }}>
        <span className="edc-sym"><SF name={refSymbol(r)} size={14} /></span>
        <div className="edc-vstack grow" style={{ gap: 1 }}>
          <span className="edc-sub500">{credentialTitle(doc, r)}</span>
          {hosts.length > 0 && <Caption>{hosts.join(', ')}</Caption>}
        </div>
        {mode != null && <span className="edg-picker"><PopUp value={mode} onChange={setMode} options={MODES} /></span>}
      </div>
      <div style={{ paddingLeft: 26 }}>
        <RequireApproval checked={getApproval(doc, r)} onChange={v => update(d => setApproval(d, r, v))} />
      </div>
    </div>
  );
}
