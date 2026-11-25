// Sandbox Policy — ProfileViews.swift `firewallSection` → FirewallEditor
// (OpenShellPolicyEditor.swift): the engine card, then either the Bromure
// Firewall's outbound-rule table (EgressRulesEditor.swift, committed live via
// POST /profiles/<id>/firewall and put back on Cancel) or the OpenShell
// policy editor (YAML + kernel sentry + sandbox + advisor + governance).

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useEditor } from '../ctx';
import { seg } from '../../../core/remote/host';
import { saveFile } from '../../../platform';
import { SF } from '../../../ui/icons';
import { Disclosure, InfoTip } from '../ui';
import { val } from '../model';
import {
  Check, Confirm, IconMenu, MenuPicker, PlainButton, PolicyCard, PolicyIcon, PolicyRow, PolicyStatus, Segmented,
  SmallButton, StatusLabel,
} from './SandboxPolicyKit';
import { isActive, newRow, parseRules, pfText, remaining, validationError, type EditRow } from './SandboxPolicyEgress';
import { checkOpenShell, YamlError } from './SandboxPolicyYaml';

type Sentry = 'off' | 'best_effort' | 'hard';

/** OpenShellPolicyEditor.starterPolicy */
export const STARTER_POLICY = `version: 1

# OpenShell sandbox policy — https://github.com/NVIDIA/OpenShell
# Everything not listed is denied. Bromure also allows the workspace's
# agents and every host it injects a credential for (_provider_* rules).
# \`binaries\`: the programs a rule is for (or that they started). With
# the strict sandbox they're enforced, and a rule without any allows
# nothing; otherwise they're advisory.
network_policies:
  github:
    endpoints:
      - { host: github.com, port: 443 }
      - { host: api.github.com, port: 443 }
      - { host: "**.githubusercontent.com", port: 443 }
    binaries:
      - { path: /usr/bin/git }
      - { path: /usr/bin/gh }
      - { path: /usr/bin/curl }

  npm:
    endpoints:
      - host: registry.npmjs.org
        port: 443
        protocol: rest
        enforcement: enforce
        access: read-only          # installs work; publish is blocked
        allow_encoded_slash: true  # scoped packages (@types%2Fnode)
    binaries:
      - { path: /usr/bin/node }    # npm, npx, pnpm and yarn run on it
      - { path: /opt/bun/bin/bun }

  pypi:
    endpoints:
      - { host: pypi.org, port: 443, protocol: rest, enforcement: enforce, access: read-only }
      - { host: files.pythonhosted.org, port: 443, protocol: rest, enforcement: enforce, access: read-only }
    binaries:
      - { path: "/usr/bin/python3*" }   # pip runs on it

  ubuntu_apt:
    endpoints:
      - { host: ports.ubuntu.com, ports: [80, 443] }
      - { host: security.ubuntu.com, ports: [80, 443] }
    binaries:
      - { path: "/usr/lib/apt/methods/*" }
`;

const usesOpenShell = (policy: string) => policy.trim().length > 0;

export function SandboxPolicyPane() {
  const { doc, set, update } = useEditor();
  const policy = val<string>(doc, 'networkPolicy');
  const [engine, setEngine] = useState<'firewall' | 'openShell'>(() => usesOpenShell(policy) ? 'openShell' : 'firewall');
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const sentry = val<Sentry>(doc, 'kernelSentry');

  const switchEngine = (e: 'firewall' | 'openShell') => {
    if (e === engine) return;
    if (e === 'openShell') {
      update(d => {
        if (!usesOpenShell(val<string>(d, 'networkPolicy'))) d.networkPolicy = STARTER_POLICY;
        if (val<Sentry>(d, 'kernelSentry') === 'off') d.kernelSentry = 'best_effort';
      });
      setEngine('openShell');
    } else if (usesOpenShell(policy)) setConfirmDiscard(true);
    else { set('kernelSentry', 'off'); setEngine('firewall'); }
  };

  return (
    <div className="sp-pane" style={{ gap: 16, paddingBottom: 8 }}>
      <PolicyCard>
        <div className="sp-engine">
          <PolicyIcon symbol={engine === 'openShell' ? 'cube.transparent.fill' : 'flame.fill'} tint={engine === 'openShell' ? 'teal' : 'red'} size={36} />
          <div className="sp-engine-text">
            <div className="sp-engine-title">Sandbox engine</div>
            <div className="sp-engine-sub">{engine === 'openShell'
              ? 'An NVIDIA OpenShell policy, enforced in the VM and watched by the kernel sentry.'
              : 'Allow or deny the VM’s connections by host, address, protocol and port.'}</div>
          </div>
          <MenuPicker value={engine} onChange={switchEngine} ariaLabel="Sandbox engine"
                      options={[{ value: 'firewall', label: 'Bromure Firewall' }, { value: 'openShell', label: 'OpenShell + Sentry' }]} />
        </div>
      </PolicyCard>

      {engine === 'firewall' ? (
        <>
          <PolicyCard title="Outbound rules" icon="list.bullet.rectangle" tint="red">
            <EgressRulesEditor />
          </PolicyCard>
          {/* Left on from before the sentry came with the OpenShell engine.
              (The organization's minimum is the host's; a remote can't read it.) */}
          {sentry !== 'off' && (
            <PolicyCard>
              <PolicyRow title="Kernel sentry is still on" caption="It belongs to the OpenShell engine now.">
                <button className="btn" onClick={() => set('kernelSentry', 'off')}>Turn off</button>
              </PolicyRow>
            </PolicyCard>
          )}
        </>
      ) : <OpenShellPolicyEditor />}

      {confirmDiscard && (
        <Confirm title="Switch to the Bromure Firewall?"
                 message="The workspace's OpenShell policy will be removed and the kernel sentry turned off. Export the policy first if you want to keep it."
                 confirm="Discard OpenShell policy"
                 onCancel={() => setConfirmDiscard(false)}
                 onConfirm={() => { update(d => { d.networkPolicy = ''; d.kernelSentry = 'off'; }); setEngine('firewall'); setConfirmDiscard(false); }} />
      )}
    </div>
  );
}

// ── Bromure Firewall ─────────────────────────────────────────────────────

const COL = { toggle: 18, action: 70, proto: 62, hostMin: 140, ports: 56, methods: 92, timer: 64, buttons: 58 };

function EgressRulesEditor() {
  const { doc, set, firewallEdited, mode } = useEditor();
  const text = val<string>(doc, 'egressRules');
  const live = mode === 'workspace';
  const [state, setState] = useState(() => {
    try { return parseRules(text); } catch { return { defaultAllow: true, rows: [] as EditRow[] }; }
  });
  const [showPF, setShowPF] = useState(false);
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => { const t = setInterval(() => setNow(Date.now() / 1000), 15000); return () => clearInterval(t); }, []);

  /** A user edit: the table is the truth; the text follows and goes live. */
  const commit = (rows: EditRow[], defaultAllow = state.defaultAllow) => {
    setState({ rows, defaultAllow });
    const t = pfText(rows, defaultAllow);
    set('egressRules', t);
    firewallEdited(t);
  };
  const edit = (id: string, patch: Partial<EditRow>) => commit(state.rows.map(r => r.id === id ? { ...r, ...patch } : r));
  const move = (id: string, d: number) => {
    const i = state.rows.findIndex(r => r.id === id), j = i + d;
    if (i < 0 || j < 0 || j >= state.rows.length) return;
    const rows = [...state.rows]; [rows[i], rows[j]] = [rows[j], rows[i]];
    commit(rows);
  };
  const expired = (r: EditRow) => r.expiresAt != null && now >= r.expiresAt;
  const showMethods = state.rows.some(r => r.proto === 'web');
  const err = validationError(text);
  const logAllowed = doc.logAllowedConnections as boolean | null | undefined;

  return (
    <div className="sp-fw">
      <div className="sp-row" style={{ gap: 4 }}>
        <span className="sp-caption">{live ? 'Rules apply as you edit them; Cancel puts them back.' : 'Rules apply when you save, without a restart.'}</span>
        <InfoTip text={live
          ? 'Changes apply to a running workspace as you make them — no restart, no Save needed; Cancel puts back the rules as they were. Untick a rule to switch it off without deleting it, or use its clock menu to turn it on for a limited time.'
          : 'Changes apply to a running workspace as soon as you save — no restart. Untick a rule to switch it off without deleting it, or use its clock menu to turn it on for a limited time.'} />
      </div>

      <div className="sp-fw-unmatched">
        <span>Unmatched traffic</span>
        <Segmented value={state.defaultAllow ? 'allow' : 'deny'} ariaLabel="Unmatched traffic"
                   options={[{ value: 'allow', label: 'Allow' }, { value: 'deny', label: 'Deny' }]}
                   onChange={v => commit(state.rows, v === 'allow')} />
      </div>

      <div className="sp-row" style={{ gap: 4 }}>
        <Check checked={logAllowed ?? isActive(text)} onChange={v => set('logAllowedConnections', v)}
               title="List allowed connections in the Security Timeline too">Log allowed connections</Check>
        <InfoTip text="Lists the connections the firewall lets through in the Security Timeline too — one row per destination, repeats folded in — so you can block a host from there. Off: only blocked connections are listed. Until you choose, it's on while the workspace has rules." />
      </div>

      {state.rows.length > 0 && (
        <div className="sp-fw-head">
          <span style={{ width: COL.toggle, flexShrink: 0 }} />
          <span style={{ width: COL.action, flexShrink: 0 }}>Action</span>
          <span style={{ width: COL.proto, flexShrink: 0 }}>Proto</span>
          <span style={{ flex: 1, minWidth: COL.hostMin }}>Host / CIDR</span>
          <span style={{ width: COL.ports, flexShrink: 0 }}>Ports</span>
          {showMethods && <span style={{ width: COL.methods, flexShrink: 0 }}>Methods</span>}
          <span style={{ width: COL.timer, flexShrink: 0 }}>Time limit</span>
          <span style={{ width: COL.buttons, flexShrink: 0 }} />
        </div>
      )}

      {state.rows.map(r => {
        const on = r.enabled && !expired(r);
        const temporary = r.enabled && (r.untilStop || r.expiresAt != null);
        return (
          <div key={r.id} className={'sp-fw-row' + (r.enabled ? '' : ' off')}>
            <span style={{ width: COL.toggle, flexShrink: 0, display: 'grid' }}>
              <Check checked={on} title={r.enabled ? 'On — untick to switch this rule off without deleting it' : 'Off — this rule is ignored until you tick it'}
                     onChange={v => edit(r.id, (!v || expired(r)) ? { enabled: v, expiresAt: null, untilStop: false } : { enabled: v })} />
            </span>
            <MenuPicker className="small sp-fw-dim" width={COL.action} value={r.action} ariaLabel="Action"
                        options={[{ value: 'allow', label: 'allow' }, { value: 'deny', label: 'deny' }]} onChange={v => edit(r.id, { action: v })} />
            <MenuPicker className="small sp-fw-dim" width={COL.proto} value={r.proto} ariaLabel="Proto"
                        options={['tcp', 'udp', 'web', 'any'].map(v => ({ value: v, label: v }))} onChange={v => edit(r.id, { proto: v })} />
            <input className="field sp-fw-dim" style={{ flex: 1, minWidth: COL.hostMin }} spellCheck={false} value={r.host} title={r.host}
                   placeholder="any / example.com / 10.0.0.0/8" aria-label="Host / CIDR" onChange={e => edit(r.id, { host: e.target.value })} />
            <input className="field sp-fw-dim" style={{ width: COL.ports, flexShrink: 0 }} spellCheck={false} value={r.ports} placeholder="any"
                   aria-label="Ports" onChange={e => edit(r.id, { ports: e.target.value })} />
            {showMethods && (
              <input className="field sp-fw-dim" style={{ width: COL.methods, flexShrink: 0 }} spellCheck={false} value={r.methods}
                     disabled={r.proto !== 'web'} title={r.methods} aria-label="Methods"
                     placeholder={r.proto !== 'web' ? '—' : r.action === 'deny' ? 'PUT,DELETE' : 'GET,POST'}
                     onChange={e => edit(r.id, { methods: e.target.value })} />
            )}
            <span className="sp-fw-timer" style={{ width: COL.timer }} title={limitHelp(r)}>
              <IconMenu icon={temporary ? 'clock.fill' : 'clock'} color={temporary ? 'var(--orange)' : undefined} title="Time limit" items={[
                { label: 'On for 15 minutes', action: () => edit(r.id, { enabled: true, untilStop: false, expiresAt: Date.now() / 1000 + 15 * 60 }) },
                { label: 'On for 1 hour', action: () => edit(r.id, { enabled: true, untilStop: false, expiresAt: Date.now() / 1000 + 3600 }) },
                { label: 'On until the workspace stops', action: () => edit(r.id, { enabled: true, expiresAt: null, untilStop: true }) },
                ...(r.expiresAt != null || r.untilStop ? ['divider' as const, { label: 'Make permanent', action: () => edit(r.id, { expiresAt: null, untilStop: false }) }] : []),
              ]} />
              {temporary && (r.untilStop
                ? <span style={{ color: 'var(--orange)' }}>until stop</span>
                : expired(r) ? <span className="secondary">expired</span>
                : <span style={{ color: 'var(--orange)', fontVariantNumeric: 'tabular-nums' }}>{remaining(r.expiresAt! - now)}</span>)}
            </span>
            <span className="sp-fw-btns">
              <button onClick={() => move(r.id, -1)} aria-label="Move rule up"><SF name="chevron.up" size={13} /></button>
              <button onClick={() => move(r.id, 1)} aria-label="Move rule down"><SF name="chevron.down" size={13} /></button>
              <button onClick={() => commit(state.rows.filter(x => x.id !== r.id))} aria-label="Delete rule"><SF name="trash" size={13} /></button>
            </span>
          </div>
        );
      })}

      <div><PlainButton icon="plus" onClick={() => commit([...state.rows, newRow()])}>Add rule</PlainButton></div>

      {err && <StatusLabel icon="exclamationmark.triangle.fill" color="var(--orange)" text={err} />}

      <Disclosure open={showPF} onToggle={setShowPF} label={<span style={{ fontSize: 10 }}>pf format</span>}>
        <div className="sp-pf">{text.trim() ? text : 'default allow'}</div>
      </Disclosure>
    </div>
  );
}

function limitHelp(r: EditRow) {
  if (r.enabled && r.untilStop) return 'On until this workspace stops, then switched off automatically';
  if (r.enabled && r.expiresAt != null) return `Switches off automatically at ${new Date(r.expiresAt * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`;
  return 'Turn this rule on for a limited time';
}

// ── OpenShell ────────────────────────────────────────────────────────────

const FILESYSTEM_TEMPLATE = `
# Filesystem sandbox (OpenShell): the paths OpenShell's own example
# policies use, with the workload home (/sandbox there) at
# /home/ubuntu, plus /opt, where the Bromure image installs tools
# (grok, bun for omp, gcloud). The agent may read the system and
# write only its home, its project folders (include_workdir), /tmp,
# and /dev/shm (Python's multiprocessing and anything parallel on it).
filesystem_policy:
  include_workdir: true
  read_only: [/bin, /usr, /lib, /opt, /proc, /dev/urandom, /dev/random, /dev/zero, /etc, /var/log]
  read_write: [/home/ubuntu, /tmp, /dev/null, /dev/shm]
landlock:
  compatibility: best_effort

`;

function OpenShellPolicyEditor() {
  const { doc, set, setInvalid } = useEditor();
  const policy = val<string>(doc, 'networkPolicy');
  const strict = val<boolean>(doc, 'strictSandbox');
  const hasProcess = policy.split('\n').some(l => l.startsWith('process:') && !l.startsWith('process: null') && !l.startsWith('process: ~'));
  const effectiveStrict = strict || hasProcess;
  const parsed = useMemo(() => {
    try { return { ok: checkOpenShell(policy), err: null }; }
    catch (e) { return { ok: null, err: e instanceof YamlError ? e.toString() : `invalid YAML: ${e}` }; }
  }, [policy]);

  // A broken policy fails closed: it can't be saved (isValid).
  useEffect(() => {
    setInvalid('openshell', parsed.err ? `Invalid OpenShell policy: ${parsed.err}` : null);
  }, [parsed, setInvalid]);
  useEffect(() => () => setInvalid('openshell', null), [setInvalid]);

  const fileRef = useRef<HTMLInputElement>(null);
  const exportPolicy = () => saveFile(`${(String(doc.name ?? '').trim() || 'workspace')}-policy.yaml`, policy, 'application/yaml');
  const confined = !!parsed.ok?.confinesGuest;
  const unbound = parsed.ok?.rules.filter(r => !r.binaries.length).map(r => r.key) ?? [];

  return (
    <>
      <PolicyCard title="Policy" icon="doc.text.fill" tint="teal"
                  info="An [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox policy, schema version 1. Everything is denied unless a `network_policies` rule allows it; endpoints with a `protocol` are inspected request by request (`enforce` blocks, `audit` only records). Enforced host-side at the network switch and the proxy, and every decision is recorded in the Security Timeline. Applies live, no restart."
                  accessory={
                    <span className="sp-headicons">
                      <button title="Import…" aria-label="Import…" onClick={() => fileRef.current?.click()}><SF name="square.and.arrow.down" size={15} /></button>
                      <button title="Export…" aria-label="Export…" onClick={exportPolicy}><SF name="square.and.arrow.up" size={15} /></button>
                      <button title="Reset to starter policy" aria-label="Reset to starter policy" onClick={() => set('networkPolicy', STARTER_POLICY)}><SF name="arrow.counterclockwise" size={15} /></button>
                    </span>
                  }>
        <input ref={fileRef} type="file" accept=".yaml,.yml,text/plain" style={{ display: 'none' }}
               onChange={async e => { const f = e.target.files?.[0]; e.target.value = ''; if (f) set('networkPolicy', await f.text()); }} />
        <div className="sp-engine-sub">Everything is denied unless a rule allows it. Applies live.</div>
        <AutoGrowEditor value={policy} onChange={v => set('networkPolicy', v)} />
        {parsed.err ? (
          <StatusLabel icon="xmark.octagon.fill" color="var(--red)" text={parsed.err} />
        ) : parsed.ok && (
          <>
            <PolicyStatus tone="ok" text={`Valid policy · ${parsed.ok.rules.length} network rule${parsed.ok.rules.length === 1 ? '' : 's'}`} />
            {effectiveStrict && unbound.length > 0 && (
              <PolicyStatus tone="warn" text={'Binary identity is enforced, so rules without binaries allow nothing: ' + unbound.join(', ')} />
            )}
            {parsed.ok.warnings.filter(w => !(effectiveStrict && w.startsWith('binaries:'))).map(w => <PolicyStatus key={w} text={w} />)}
          </>
        )}
      </PolicyCard>

      <PolicyCard title="Kernel sentry" icon="waveform.path.ecg" tint="indigo"
                  info="Streams security events (process launches, privilege changes, module and BPF loads, sandbox denials) from the VM's kernel to Bromure, outside anything the agent can stop; after it starts, the kernel is locked so not even root in the VM can load code to interfere. Silence or a gap in the stream is treated as tampering by the watchdog. “Required” won't start agent sessions without it. Takes effect at the next VM start.">
        <KernelSentrySection />
      </PolicyCard>

      <PolicyCard title="Sandbox" icon="cube.transparent.fill" tint="teal">
        <PolicyRow title="Enforce binaries"
                   caption={hasProcess ? 'Required by the policy’s process section.' : 'Rules apply only to the programs they list; the agent loses sudo and Docker.'}
                   info="Rules then apply only to the executables they list (or to processes those start), as reported for every connection by a root-owned attestor in the VM. To make that report trustworthy, agents get no path to root: no sudo, no Docker, and all traffic goes through transparent interception (the proxy environment variables are removed). Each executable's hash is pinned on first use; a changed binary is refused. Takes effect at the next VM start.">
          <SwitchControl checked={effectiveStrict} disabled={hasProcess} onChange={v => set('strictSandbox', v)} label="Enforce binaries" />
        </PolicyRow>
        <div className="sp-hdivider" />
        <PolicyRow title="Filesystem & process"
                   caption={confined ? 'The agent can only reach the paths the policy lists.' : 'Not confined: the policy has no filesystem_policy or process section.'}
                   info="Enforced inside the VM with Landlock, as OpenShell does: the agent can only read and write the paths the policy lists, and can't lift that, even as root. Only the few paths Bromure's own plumbing needs are added, and they're listed once the VM reports in. Takes effect at the next VM start.">
          {!confined && (
            <button className="btn" title="Insert an OpenShell filesystem template"
                    onClick={() => set('networkPolicy', (policy.endsWith('\n') ? policy : policy + '\n') + FILESYSTEM_TEMPLATE)}>Insert template</button>
          )}
        </PolicyRow>
        {confined && !effectiveStrict && (
          <PolicyStatus tone="warn" text="The agent keeps sudo, so it could stop Bromure's processes in the VM. Turn on Enforce binaries to prevent that." />
        )}
        <div className="sp-hdivider" />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <PolicyRow title="Packages in the home folder" caption="pip installs into ~/.local; npm already uses ~/.npm-global."
                     info="The sandbox has no root, so system-wide installs can't work. With this on, pip installs into the home folder by default (PIP_USER), and npm installs globally into ~/.npm-global as on every workspace. Bromure's own processes outside the sandbox ignore packages in the home folder. Takes effect in new terminals.">
            <SwitchControl checked={val<boolean>(doc, 'sandboxHomePackages')} onChange={v => set('sandboxHomePackages', v)} label="Packages in the home folder" />
          </PolicyRow>
          <PolicyRow title="System packages on request" caption="apt-get install asks you first; the agent never gets root."
                     info="When the agent runs apt-get install (with or without sudo), the request waits in the Sandbox drawer. Approve it and the VM's root supervisor installs those packages — by exact name, from Ubuntu's mirrors, which Bromure allows for this. Reject it and the agent is told not to retry. Takes effect at the next VM start.">
            <SwitchControl checked={val<boolean>(doc, 'sandboxSystemPackages')} onChange={v => set('sandboxSystemPackages', v)} label="System packages on request" />
          </PolicyRow>
        </div>
      </PolicyCard>

      <PolicyCard title="Policy advisor" icon="wand.and.stars" tint="purple"
                  info="When a request is blocked, the agent can propose the narrow rule it needs at http://policy.local (OpenShell's advisor API) and wait for your decision. Blocked connections are also drafted as proposals here. A proposal that reaches a host with a workspace credential, adds a method there, or uses a wildcard, private address, database or high port always waits for you; “Approve if risk-free” approves the rest. Approved rules are added to the policy above and apply live.">
        <AdvisorSection />
      </PolicyCard>

      <PolicyCard title="Governance" icon="building.columns.fill" tint="gray">
        <PolicyRow title="Organization boundary" caption="Checked by the host when you save."
                   info="A boundary is the most any workspace's policy may allow; it's checked with NVIDIA's openshell-prover when installed, otherwise with Bromure's built-in check." />
        <div className="sp-hdivider" />
        <HistorySection />
        <div className="sp-hdivider" />
        <Disclosure label="Rules Bromure adds automatically">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <div className="sp-caption">Like OpenShell&rsquo;s provider rules, these keep the workspace&rsquo;s agents and every credential it configures reachable. They&rsquo;re not part of the exported policy.</div>
            {providerGroups(doc).filter(g => g.endpoints.length).map(g => (
              <div key={g.name} className="sp-mono-small">{`_provider_${g.name}: ` + g.endpoints.join(', ')}</div>
            ))}
          </div>
        </Disclosure>
      </PolicyCard>
    </>
  );
}

function SwitchControl({ checked, onChange, disabled, label }: { checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; label: string }) {
  return (
    <span className="switch" title={label}>
      <input type="checkbox" role="switch" aria-label={label} checked={checked} disabled={disabled} onChange={e => onChange(e.target.checked)} />
      <span className="track" /><span className="thumb" />
    </span>
  );
}

/** TextEditor that grows with its text (min 240pt), wrapping like the native one. */
function AutoGrowEditor({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const ref = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    const el = ref.current; if (!el) return;
    el.style.height = 'auto';
    el.style.height = Math.max(240, el.scrollHeight + 2) + 'px';
  }, [value]);
  return <textarea ref={ref} className="sp-yaml" spellCheck={false} autoCorrect="off" autoCapitalize="off" value={value}
                   aria-label="OpenShell policy" onChange={e => onChange(e.target.value)} />;
}

function KernelSentrySection() {
  const { doc, set } = useEditor();
  const sentry = val<Sentry>(doc, 'kernelSentry');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      {sentry === 'off' ? (
        <PolicyRow title="Off for this workspace" caption="Turn it on to see sandbox denials and which process made each connection.">
          <button className="btn" onClick={() => set('kernelSentry', 'best_effort')}>Turn on</button>
        </PolicyRow>
      ) : (
        <PolicyRow title="Mode" caption="Reports which process made each connection, and why, from where the agent can't stop it.">
          <Segmented value={sentry === 'hard' ? 'hard' : 'best_effort'} ariaLabel="Kernel sentry"
                     options={[{ value: 'best_effort', label: 'Best effort' }, { value: 'hard', label: 'Required' }]}
                     onChange={v => set('kernelSentry', v)} />
        </PolicyRow>
      )}
    </div>
  );
}

interface Proposal {
  id: string; status: string; source: string; intent: string; host: string; port: number; rule_name: string;
  binaries?: string[]; findings?: string[]; auto?: boolean; rejection_reason?: string;
}

/** Agent proposals: the mode is a profile field; the proposals live on the
 *  host (GET /profiles/<id>/proposals, POST …/<p>/approve|reject). */
function AdvisorSection() {
  const { doc, set, host, workspaceID, mode } = useEditor();
  const [proposals, setProposals] = useState<Proposal[]>([]);
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const load = () => {
    if (mode !== 'workspace' || !workspaceID) return;
    host.request<{ proposals?: Proposal[] }>('GET', `/profiles/${seg(workspaceID)}/proposals`)
      .then(r => setProposals(r.proposals ?? [])).catch(() => {});
  };
  useEffect(() => { load(); const t = setInterval(load, 5000); return () => clearInterval(t); }, [workspaceID]); // eslint-disable-line react-hooks/exhaustive-deps
  const decide = (p: Proposal, verb: 'approve' | 'reject') =>
    host.request('POST', `/profiles/${seg(workspaceID!)}/proposals/${seg(p.id)}/${verb}`, verb === 'reject' ? { reason: reasons[p.id] ?? '' } : {}, { allowError: true })
      .catch(() => {}).finally(load);
  const pending = proposals.filter(p => p.status === 'pending');
  const decided = proposals.filter(p => p.status !== 'pending').slice(-5).reverse();
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <PolicyRow title="Agent proposals" caption="When something is blocked, the agent can ask for the rule it needs.">
        <MenuPicker value={val<string>(doc, 'openShellAdvisorMode')} onChange={v => set('openShellAdvisorMode', v)} ariaLabel="Agent proposals"
                    options={[{ value: 'off', label: 'Off' }, { value: 'review', label: 'Ask me' }, { value: 'auto', label: 'Approve if risk-free' }]} />
      </PolicyRow>
      {pending.length === 0 && <PolicyStatus text="No pending proposals." />}
      {pending.map(p => (
        <div key={p.id} className="sp-proposal">
          <div className="sp-row">
            <SF name={p.source === 'mechanistic' ? 'wand.and.stars' : 'person.crop.circle.badge.questionmark'} size={13} />
            <span style={{ fontSize: 12, fontWeight: 500 }}>{`${p.rule_name} — ${p.host}:${p.port}`}</span>
            <span style={{ flex: 1 }} />
            <span className="sp-caption">{p.source === 'mechanistic' ? 'drafted from a block' : 'proposed by the agent'}</span>
          </div>
          {p.intent && <div style={{ fontSize: 10 }}>{p.intent}</div>}
          {!!p.binaries?.length && <div className="sp-mono-small">{p.binaries.join(', ')}</div>}
          {!!p.findings?.length && <StatusLabel icon="exclamationmark.shield" color="var(--orange)" text={p.findings.join(', ')} />}
          <div className="sp-row">
            <input className="field sp-field" style={{ flex: 1, fontSize: 10 }} placeholder="Reason (sent to the agent on reject)"
                   value={reasons[p.id] ?? ''} onChange={e => setReasons(r => ({ ...r, [p.id]: e.target.value }))} />
            <SmallButton onClick={() => decide(p, 'reject')}>Reject</SmallButton>
            <SmallButton prominent onClick={() => decide(p, 'approve')}>Approve</SmallButton>
          </div>
        </div>
      ))}
      {decided.length > 0 && (
        <>
          <div style={{ fontSize: 10, fontWeight: 500, paddingTop: 2 }}>Recent decisions</div>
          {decided.map(p => (
            <div key={p.id} className="sp-caption">
              {`${p.status === 'approved' ? '✓' : '✗'} ${p.rule_name} (${p.host}:${p.port})` + (p.auto ? ' — auto' : '') + (p.rejection_reason ? ` — ${p.rejection_reason}` : '')}
            </div>
          ))}
        </>
      )}
    </div>
  );
}

interface Revision { version: number; hash: string; saved_at: string; source: string }

/** Saved versions of this policy (GET /profiles/<id>/policy/revisions[/<n>]). */
function HistorySection() {
  const { host, workspaceID, mode, doc, set } = useEditor();
  const [open, setOpen] = useState(false);
  const [revs, setRevs] = useState<Revision[]>([]);
  const [policies, setPolicies] = useState<Record<number, string>>({});
  useEffect(() => {
    if (mode !== 'workspace' || !workspaceID) return;
    host.request<{ revisions?: Revision[] }>('GET', `/profiles/${seg(workspaceID)}/policy/revisions`)
      .then(r => setRevs(r.revisions ?? [])).catch(() => {});
  }, [host, workspaceID, mode]);
  // Opened: fetch each version's text so "current" can be told apart.
  useEffect(() => {
    if (!open || !workspaceID) return;
    for (const r of revs.slice(0, 20)) {
      if (policies[r.version] != null) continue;
      host.request<{ policy?: string }>('GET', `/profiles/${seg(workspaceID)}/policy/revisions/${r.version}`)
        .then(x => setPolicies(p => ({ ...p, [r.version]: x.policy ?? '' }))).catch(() => {});
    }
  }, [open, revs]); // eslint-disable-line react-hooks/exhaustive-deps
  const policy = val<string>(doc, 'networkPolicy');
  return (
    <Disclosure open={open} onToggle={setOpen} label={'Revision history' + (revs[0] ? ` · v${revs[0].version}` : '')}>
      {revs.length === 0 ? (
        <div className="sp-caption" style={{ fontSize: 10 }}>No saved versions yet. Each save that changes the policy is kept here.</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          {revs.map(r => (
            <div key={r.version} className="sp-row" style={{ gap: 8, fontSize: 10 }}>
              <span style={{ fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>v{r.version}</span>
              <span>{new Date(r.saved_at).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })}</span>
              <span className="secondary">{r.source}</span>
              <span className="secondary mono">{r.hash.slice(0, 12)}</span>
              <span style={{ flex: 1 }} />
              {policies[r.version] === policy ? <span className="secondary" style={{ fontWeight: 500 }}>current</span>
                : <PlainButton disabled={policies[r.version] == null} onClick={() => set('networkPolicy', policies[r.version])}>
                    <span style={{ fontSize: 11, color: 'var(--link)' }}>Restore</span>
                  </PlainButton>}
            </div>
          ))}
        </div>
      )}
    </Disclosure>
  );
}

/** Profile.openShellProviderGroups, as far as the redacted document tells:
 *  the agents' services, Kubernetes API servers, system packages and Local
 *  Models. (Credential hosts and AWS come from the host's token plan.) */
function providerGroups(doc: Record<string, any>) {
  const dom = (d: string) => d.split('.').length >= 2 ? [d, `**.${d}`] : [d];
  const tools = [{ tool: doc.tool, authMode: doc.authMode }, ...((doc.additionalTools as any[]) ?? [])];
  const DOMAINS: Record<string, string[]> = {
    claude: ['anthropic.com', 'claude.ai', 'claude.com'], codex: ['openai.com', 'chatgpt.com'], grok: ['x.ai'],
    kimi: ['kimi.ai', 'kimi.com', 'moonshot.ai', 'moonshot.cn'], omp: [], hermes: ['nousresearch.com'],
  };
  const groups: { name: string; endpoints: string[] }[] = [];
  for (const t of tools) if (t?.tool && t.authMode !== 'local') groups.push({ name: t.tool, endpoints: (DOMAINS[t.tool] ?? []).flatMap(dom) });
  const kube = ((doc.kubeconfigs as any[]) ?? []).flatMap(k => {
    try { const u = new URL(k.serverURL); return [(u.port || '443') === '443' ? u.hostname : `${u.hostname}:${u.port}`]; } catch { return []; }
  });
  groups.push({ name: 'kubernetes', endpoints: kube });
  if (val<boolean>(doc, 'sandboxSystemPackages') && usesOpenShell(val<string>(doc, 'networkPolicy')))
    groups.push({ name: 'system_packages', endpoints: ['ports.ubuntu.com:80,443', 'archive.ubuntu.com:80,443', 'security.ubuntu.com:80,443'] });
  groups.push({ name: 'local_models', endpoints: ['bromure.llm'] });
  return groups;
}
