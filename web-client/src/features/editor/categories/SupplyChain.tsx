// Supply Chain — ProfileViews.swift `supplyChainSection` (SupplyChainPolicy).
// The reputation allowlist also grows from the host's override prompt
// ("Always allow", SupplyChainOverrides.swift) while the editor is open.

import React from 'react';
import { useEditor } from '../ctx';
import { openExternal } from '../../../platform';
import { SF } from '../../../ui/icons';
import { Allowlist, Check, GBox, MenuPicker, RadioGroup, Stepper, StatusLabel } from './SandboxPolicyKit';

type Severity = 'low' | 'medium' | 'high' | 'critical';
type Filter = 'none' | 'socketdev' | 'delpi';
interface SC {
  ageGateEnabled: boolean; ageGateDays: number; ageGateAllowlist: string[];
  osvEnabled: boolean; osvSeverity: Severity;
  packageFilter: Filter; socketAPIKey: string; socketBlockCompromised: boolean; socketBlockCVE: boolean; socketCVESeverity: Severity;
  delpiAPIKey: string; stripInstallScripts: boolean; stripAllowlist: string[]; lockfilePrompt: boolean; reputationAllowlist: string[];
}
const DEF: Omit<SC, 'packageFilter'> = {
  ageGateEnabled: true, ageGateDays: 2, ageGateAllowlist: [], osvEnabled: false, osvSeverity: 'high',
  socketAPIKey: '', socketBlockCompromised: false, socketBlockCVE: false, socketCVESeverity: 'high',
  delpiAPIKey: '', stripInstallScripts: false, stripAllowlist: [], lockfilePrompt: false, reputationAllowlist: [],
};

function decode(raw: Record<string, any> | undefined): SC {
  const r = raw ?? {};
  const base = { ...DEF, ...r } as any;
  // Legacy profiles predate the provider radio: a stored socket.dev key meant
  // socket.dev. Unknown values degrade to the same inference.
  const f = ['none', 'socketdev', 'delpi'].includes(r.packageFilter) ? r.packageFilter : (base.socketAPIKey ? 'socketdev' : 'none');
  return { ...base, packageFilter: f };
}

/** SupplyChainPolicy's encoder: only non-defaults. The redacted document
 *  blanks the API keys, so a chosen provider is always written explicitly —
 *  the decoder's "a key means socket.dev" inference can't hold there. */
function encode(p: SC) {
  const o: Record<string, any> = {};
  for (const k of Object.keys(DEF) as (keyof typeof DEF)[]) {
    const v = p[k], d = DEF[k];
    if (Array.isArray(v) ? v.length > 0 : v !== d) o[k] = v;
  }
  if (p.packageFilter !== 'none' || o.socketAPIKey) o.packageFilter = p.packageFilter;
  return o;
}

const SEVERITIES: { value: Severity; label: string }[] = [
  { value: 'low', label: 'Low and above' }, { value: 'medium', label: 'Medium and above' },
  { value: 'high', label: 'High and above' }, { value: 'critical', label: 'Critical only' },
];

function KeyRow({ value, onChange, href, stored }: { value: string; onChange: (v: string) => void; href: string; stored: boolean }) {
  return (
    <div className="sp-row">
      <span className="sp-body" style={{ whiteSpace: 'nowrap' }}>API key:</span>
      <input className="field sp-field" type="password" autoComplete="off" spellCheck={false} value={value}
             placeholder={stored ? 'Saved on the host — type to replace' : ''} onChange={e => onChange(e.target.value)} style={{ flex: 1 }} />
      <a className="sp-link" style={{ display: 'inline-flex', alignItems: 'center', gap: 2, whiteSpace: 'nowrap' }} onClick={() => openExternal(href)}>
        Get an API key <SF name="arrow.up.forward.square" size={10} />
      </a>
    </div>
  );
}

export function SupplyChainPane() {
  const { doc, opened, set } = useEditor();
  const p = decode(doc.supplyChain);
  const put = (patch: Partial<SC>) => set('supplyChain', encode({ ...p, ...patch }));
  // The redacted document blanks the API keys: a provider the OPENED document
  // names explicitly is taken to have its key stored on the host, so the
  // controls it gates stay usable with the field left blank (= keep it).
  const was = opened._secretsRedacted ? opened.supplyChain?.packageFilter : undefined;
  const socketKey = !!p.socketAPIKey || was === 'socketdev';
  const delpiKey = !!p.delpiAPIKey || was === 'delpi';
  const col = (gap: number): React.CSSProperties => ({ display: 'flex', flexDirection: 'column', gap });
  return (
    <div className="sp-pane padded">
      <div className="sp-caption">{'Bromure scans every package fetch (npm, PyPI, Cargo, RubyGems, Maven, NuGet, Go modules, Packagist) through the host MITM and applies these policies before the agent sees the response. The in-VM `.npmrc` / `pip.conf` can only further restrict these settings — they cannot loosen them. Use the per-package allowlists for surgical overrides.'}</div>

      <GBox icon="calendar" title="Age gate">
        <div style={col(8)}>
          <Check checked={p.ageGateEnabled} onChange={v => put({ ageGateEnabled: v })}>Refuse packages younger than the cutoff</Check>
          <div className="sp-row" style={{ gap: 8 }}>
            <span className="sp-body">Minimum age:</span>
            <Stepper value={p.ageGateDays} min={0} max={90} disabled={!p.ageGateEnabled} onChange={v => put({ ageGateDays: v })}>
              {`${p.ageGateDays} days`}
            </Stepper>
          </div>
          <div className="sp-caption">{'Floating refs (`latest`, semver ranges) silently resolve to the newest version older than the cutoff. Pinned references to too-fresh versions get a 451 with a clear Bromure error.'}</div>
          <Allowlist title="Exempt packages (format: `npm:axios` or just `axios`)" list={p.ageGateAllowlist}
                     onChange={l => put({ ageGateAllowlist: l })} />
        </div>
      </GBox>

      <GBox icon="ladybug" title="OSV vulnerability check">
        <div style={col(6)}>
          <Check checked={p.osvEnabled} onChange={v => put({ osvEnabled: v })}>Look up packages on api.osv.dev (free, no key required)</Check>
          <div className="sp-row" style={{ maxWidth: 280, paddingLeft: 3 }}>
            <span className="sp-body" style={{ whiteSpace: 'nowrap' }}>Block at severity:</span>
            <MenuPicker value={p.osvSeverity} options={SEVERITIES} disabled={!p.osvEnabled} onChange={v => put({ osvSeverity: v })}
                        className="sp-flexmenu" ariaLabel="Block at severity:" />
          </div>
          <div className="sp-caption">Aggregates GitHub Advisory Database + PyPI advisories + Go&rsquo;s database + RubySec etc. Off by default — a low-severity CVE in a transitive subpackage shouldn&rsquo;t interrupt a workflow.</div>
        </div>
      </GBox>

      <GBox icon="checkmark.shield" title="Package filtering">
        <div style={col(8)}>
          <RadioGroup value={p.packageFilter} onChange={v => put({ packageFilter: v })}
                      options={[{ value: 'none', label: 'None' }, { value: 'socketdev', label: 'socket.dev' }, { value: 'delpi', label: 'Depi' }]} />
          <div className="sp-caption">One provider at a time: socket.dev vets each package against its reputation database before Bromure lets the fetch through; Depi replaces the npm registry outright — every npm fetch is re-routed to its filtering registry.</div>
          {p.packageFilter === 'socketdev' && (
            <>
              <div className="sp-hdivider" style={{ margin: '4px 0' }} />
              <KeyRow value={p.socketAPIKey} stored={socketKey && !p.socketAPIKey} onChange={v => put({ socketAPIKey: v })} href="https://socket.dev/dashboard/settings/api-tokens" />
              <div className="sp-caption">The key is stored host-side only — Bromure never exports it into the VM. Calls go directly to api.socket.dev from the host&rsquo;s MITM proxy.</div>
              <Check checked={p.socketBlockCompromised} disabled={!socketKey} onChange={v => put({ socketBlockCompromised: v })}>
                Block compromised packages (rogue install scripts, malware-flagged, typosquats, suspicious telemetry)
              </Check>
              <Check checked={p.socketBlockCVE} disabled={!socketKey} onChange={v => put({ socketBlockCVE: v })}>Block packages with known CVEs</Check>
              <div className="sp-row" style={{ maxWidth: 280 }}>
                <span className="sp-body" style={{ whiteSpace: 'nowrap' }}>CVE block threshold:</span>
                <MenuPicker value={p.socketCVESeverity} options={SEVERITIES} onChange={v => put({ socketCVESeverity: v })}
                            disabled={!p.socketBlockCVE || !socketKey} className="sp-flexmenu" />
              </div>
            </>
          )}
          {p.packageFilter === 'delpi' && (
            <>
              <div className="sp-hdivider" style={{ margin: '4px 0' }} />
              <KeyRow value={p.delpiAPIKey} stored={delpiKey && !p.delpiAPIKey} onChange={v => put({ delpiAPIKey: v })} href="https://www.landh.tech/" />
              <div className="sp-caption">Every npm registry request from the VM is re-routed to Depi&rsquo;s secure registry (depi-npm-proxy.landh.tech), authenticated host-side with this key — Bromure never exports it into the VM. If Depi rejects the key, the install fails with a clear error and Bromure alerts you.</div>
              {!delpiKey && <StatusLabel icon="exclamationmark.triangle.fill" color="var(--orange)" text="Enter an API key — Depi stays off without one." />}
            </>
          )}
        </div>
      </GBox>

      <GBox icon="scroll" title="Install scripts">
        <div style={col(6)}>
          <Check checked={p.stripInstallScripts} onChange={v => put({ stripInstallScripts: v })}>Strip preinstall / install / postinstall / prepare from npm tarballs on the fly</Check>
          <div className="sp-caption">{'Bromure rewrites the tarball, removes the script keys from `package.json`, and updates the registry metadata hash so npm’s verification still passes for unpinned installs. Some packages (binding compilers — better-sqlite3, node-canvas, …) legitimately need install scripts; add them to the allowlist below.'}</div>
          <Allowlist title="Allow install scripts for (format: `npm:better-sqlite3`)" list={p.stripAllowlist} onChange={l => put({ stripAllowlist: l })} />
        </div>
      </GBox>

      <GBox icon="lock.fill" title="Lockfile-pinned installs">
        <div style={col(6)}>
          <Check checked={p.lockfilePrompt} onChange={v => put({ lockfilePrompt: v })}>
            {'Prompt before passing lockfile-pinned tarballs through unmodified (`npm ci`, `pip --require-hashes`)'}
          </Check>
          <div className="sp-caption">These installs use cryptographic integrity hashes baked into a lockfile — Bromure can&rsquo;t rewrite them without breaking verification. When this is on, the first lockfile-pinned fetch in a batch pops a host dialog (Allow once / 15 min / for the session / Don&rsquo;t allow); the entire batch follows the decision.</div>
        </div>
      </GBox>

      <GBox icon="checkmark.shield" title="Trusted packages">
        <div style={col(6)}>
          <div className="sp-caption">When OSV or socket.dev blocks a package, Bromure asks whether to install it anyway (for this session, or always). Packages you always allow are listed here; their downloads skip those checks. A socket.dev malware verdict is never overridden.</div>
          <Allowlist title="Install despite reputation warnings (format: `npm:workerd`)" list={p.reputationAllowlist} onChange={l => put({ reputationAllowlist: l })} />
        </div>
      </GBox>
    </div>
  );
}
