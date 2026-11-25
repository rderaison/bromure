// The Credentials pane's per-type editors (ProfileViews.swift
// `credentialEditorBody` and its subsections + the row views
// HTTPSCredentialRow, ManualTokenRow, KubeconfigRow, DockerRegistryRow,
// DatabaseEndpointRow). Secrets arrive blanked from the host: blank = keep
// the stored value, type one to replace it.

import React, { useState } from 'react';
import { Button, Segmented, cx, useMenu } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { openExternal } from '../../../platform';
import { useEditor } from '../ctx';
import { val, type Doc } from '../model';
import { Caption, CaptionTertiary, Field, HostListField, MD, TextArea, Toggle } from '../ui';
import {
  DB_ENGINES, isBitbucket, isGitHub, isGitLab, opReference, uuid, type DBEngine, type EditorType,
} from './CredentialsModel';

/** A mutable array field on the (cloned) draft — never the shared default. */
export function arr(d: Doc, key: string): Doc[] {
  if (!Array.isArray(d[key])) d[key] = [];
  return d[key];
}
const byId = (list: Doc[], id: string) => list.find(x => x.id === id);

const Label = ({ children }: { children: React.ReactNode }) => <div className="edc-flabel">{children}</div>;
const Hint = ({ children }: { children: string }) => <div className="edc-fhint"><MD>{children}</MD></div>;
const IconBtn = ({ symbol, help, onClick, disabled }: { symbol: string; help?: string; onClick?: () => void; disabled?: boolean }) =>
  <button className="edc-iconbtn" title={help} aria-label={help} onClick={onClick} disabled={disabled}><SF name={symbol} size={14} /></button>;

function SecretField({ value, onChange, placeholder, revealPlaceholder, help }: {
  value: string; onChange: (v: string) => void; placeholder: string; revealPlaceholder?: string; help: [string, string];
}) {
  const [reveal, setReveal] = useState(false);
  return (
    <div className="edc-hrow">
      <Field value={value} onChange={onChange} secure={!reveal} placeholder={reveal ? (revealPlaceholder ?? placeholder) : placeholder} />
      <IconBtn symbol={reveal ? 'eye.slash' : 'eye'} help={reveal ? help[1] : help[0]} onClick={() => setReveal(!reveal)} />
    </div>
  );
}

/** requireApprovalToggle — compact checkbox. */
export function RequireApproval({ checked, onChange }: { checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className="edc-approval">
      <Toggle checked={checked} onChange={onChange} help="Pop a confirmation dialog the first time this credential is used in a session. Off by default.">
        <span className="edc-small">Require approval to use</span>
      </Toggle>
    </div>
  );
}

export function CredentialEditorBody({ type }: { type: EditorType }) {
  switch (type) {
    case 'agents': return null;
    case 'git': return (
      <div className="edc-vstack" style={{ gap: 16 }}>
        <GitProvider name="GitHub" host="github.com" filter={isGitHub} />
        <GitProvider name="GitLab" host="gitlab.com" filter={isGitLab} />
        <GitProvider name="Bitbucket" host="bitbucket.org" filter={isBitbucket} />
      </div>
    );
    case 'ssh': return <SSHEditor />;
    case 'aws': return <AWSEditor />;
    case 'digitalOcean': return <SingleToken field="digitalOceanToken" placeholder="dop_v1_…" url="https://cloud.digitalocean.com/account/api/tokens"
      help="Open DigitalOcean token page in your browser"
      blurb="Personal access token from cloud.digitalocean.com → API → Generate New Token. Injected into the VM as `DIGITALOCEAN_ACCESS_TOKEN` env + `~/.config/doctl/config.yaml` — `doctl auth init` is unnecessary, you're already logged in." />;
    case 'linear': return <SingleToken field="linearToken" placeholder="lin_api_…" url="https://linear.app/settings/api"
      help="Open Linear API settings in your browser"
      blurb="Personal API key from linear.app → Settings → API. Injected into the VM as `LINEAR_API_KEY` env — the Linear SDK, MCP servers and CLI tools pick it up automatically. Swapped fake→real only on requests to linear.app." />;
    case 'twilio': return <TwilioEditor />;
    case 'kubernetes': return <KubeEditor />;
    case 'docker': return <DockerEditor />;
    case 'database': return (
      <div className="edc-vstack" style={{ gap: 18 }}>
        {(['mongoDataAPI', 'clickHouse', 'elasticsearch'] as DBEngine[]).map(e => (
          <div key={e} className="edc-vstack" style={{ gap: 6 }}>
            <div className="edc-subhead">{DB_ENGINES[e].name}</div>
            <DatabaseSection engine={e} />
          </div>
        ))}
      </div>
    );
    case 'manual': return <ManualTokens />;
  }
}

// ── Git ──────────────────────────────────────────────────────────────────

function tokenPage(host: string): string | null {
  if (isGitHub(host)) return 'https://github.com/settings/tokens';
  if (isGitLab(host)) return 'https://gitlab.com/-/user_settings/personal_access_tokens';
  if (isBitbucket(host)) return 'https://bitbucket.org/account/settings/app-passwords/';
  return null;
}

function GitProvider({ name, host, filter }: { name: string; host: string; filter: (h: string) => boolean }) {
  const { doc, update } = useEditor();
  const entries = val<Doc[]>(doc, 'gitHTTPSCredentials').filter(c => filter(String(c.host ?? '')));
  const suggestion = () => { const n = String(doc.gitUserName ?? '').trim(); return n && !n.includes(' ') ? n : ''; };
  return (
    <div className="edc-vstack" style={{ gap: 6 }}>
      <div className="edc-subhead">{name}</div>
      <Caption md>Personal access tokens for git over HTTPS. Stored encrypted on the host; the proxy swaps them onto outbound requests so the VM only ever holds the fake. `gh` and `glab` pick up GH_TOKEN / GITLAB_TOKEN env automatically.</Caption>
      {entries.length === 0
        ? <CaptionTertiary className="edc-emptyline">No {name} tokens configured.</CaptionTertiary>
        : entries.map(c => <GitRow key={c.id} id={c.id} />)}
      <div className="edc-hrow end">
        <Button variant="borderless" icon="plus" onClick={() => update(d => { arr(d, 'gitHTTPSCredentials').push({ id: uuid(), host, username: suggestion(), token: '' }); })}>Add token</Button>
      </div>
    </div>
  );
}

function GitRow({ id }: { id: string }) {
  const { doc, update } = useEditor();
  const c = byId(val(doc, 'gitHTTPSCredentials'), id) ?? {};
  const set = (k: string, v: any) => update(d => { const x = byId(arr(d, 'gitHTTPSCredentials'), id); if (x) x[k] = v; });
  const h = String(c.host ?? '').toLowerCase();
  const symbol = isGitHub(h) ? 'cat.fill' : isGitLab(h) ? 'fox.fill' : 'globe';
  const page = tokenPage(h);
  return (
    <div className="edc-card" style={{ gap: 10 }}>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>Host</Label>
        <div className="edc-hrow">
          <span className="edc-sym"><SF name={symbol} size={14} /></span>
          <Field value={c.host ?? ''} onChange={v => set('host', v)} placeholder="github.com" />
          <IconBtn symbol="arrow.up.right.square" help="Open this host's token-creation page in your browser" disabled={!page} onClick={() => page && openExternal(page)} />
          <IconBtn symbol="minus.circle" help="Remove this credential" onClick={() => update(d => { d.gitHTTPSCredentials = arr(d, 'gitHTTPSCredentials').filter(x => x.id !== id); })} />
        </div>
        <Hint>The git host these credentials sign in to. Works with self-hosted GitLab / Gitea too.</Hint>
      </div>
      <div className="edc-hrow top" style={{ gap: 8 }}>
        <div className="edc-vstack grow" style={{ gap: 3 }}>
          <Label>Username</Label>
          <Field value={c.username ?? ''} onChange={v => set('username', v)} placeholder="octocat" />
        </div>
        <div className="edc-vstack grow" style={{ gap: 3 }}>
          <Label>Personal access token</Label>
          <SecretField value={c.token ?? ''} onChange={v => set('token', v)} placeholder="ghp_…" help={['Show token', 'Hide token']} />
        </div>
      </div>
    </div>
  );
}

// ── SSH ──────────────────────────────────────────────────────────────────

function SSHEditor() {
  const { doc, update, isNew, generateSSH, setGenerateSSH } = useEditor();
  const pub = doc.sshPublicKey as string | undefined;
  const keys = val<Doc[]>(doc, 'importedSSHKeys');
  return (
    <div className="edc-vstack" style={{ gap: 12 }}>
      <div className="edc-vstack" style={{ gap: 6 }}>
        <div className="edc-subhead">Bromure-generated keypair</div>
        {isNew ? (
          <>
            <Toggle checked={generateSSH} onChange={setGenerateSSH}>Generate an ed25519 keypair</Toggle>
            <Caption>The public key will be displayed below after the workspace is saved.</Caption>
          </>
        ) : pub ? (
          <>
            <div className="edc-hrow">
              <span className="secondary">ed25519 keypair on file.</span>
              <div style={{ flex: 1 }} />
              <Toggle checked={generateSSH} onChange={setGenerateSSH}>Regenerate</Toggle>
            </div>
            <Caption>Public key (paste into github.com/settings/keys):</Caption>
            <div className="edc-pubkey selectable">{pub}</div>
            <div className="edc-hrow">
              <Button onClick={() => navigator.clipboard?.writeText(pub).catch(() => {})}>Copy</Button>
              <Button onClick={() => openExternal('https://github.com/settings/keys')}>Open GitHub keys page</Button>
            </div>
          </>
        ) : (
          <Toggle checked={generateSSH} onChange={setGenerateSSH}>Generate an ed25519 keypair</Toggle>
        )}
      </div>
      <div className="ed-divider" />
      <div className="edc-vstack" style={{ gap: 6 }}>
        <div className="edc-hrow">
          <div className="ed-headline">Imported SSH keys</div>
          <div style={{ flex: 1 }} />
          {/* The key file and the host's ssh-agent live on the server Mac: no
              route reaches them from a client (the macOS fat client disables these too). */}
          <Button variant="borderless" icon="plus" disabled title="Import a key file on the server Mac (not available from a remote client)">Import…</Button>
          <Button variant="borderless" icon="key.radiowaves.forward" disabled title="Pick keys from the server Mac's ssh-agent (not available from a remote client)">From host agent…</Button>
        </div>
        <Caption>Point bromure at any existing SSH private key (RSA, ed25519, ecdsa) — encrypted ones included. The key is loaded into the per-workspace bromure ssh-agent at every session launch; passphrases are stored in the macOS Keychain.</Caption>
        <Caption>A key that can't be copied — on a YubiKey, in gpg-agent, Secretive or 1Password — can be picked from that ssh-agent instead. The VM sees only the keys you pick, and their signatures are made by the agent on your Mac.</Caption>
        {keys.length === 0
          ? <CaptionTertiary className="edc-emptyline" style={{ padding: '10px 0' }}>No imported keys.</CaptionTertiary>
          : keys.map(k => {
            const parts = String(k.publicKeyText ?? '').split(' ');
            const line = k.publicKeyText ? `${parts[0]} ${parts.length > 1 ? parts[parts.length - 1] : ''}` : k.filename;
            return (
              <div key={k.id} className="edc-card row">
                <SF name={k.hostAgentSocket != null ? 'key.radiowaves.forward.fill' : 'key.horizontal.fill'} size={14} color="var(--label-secondary)" />
                <div className="edc-vstack grow" style={{ gap: 1 }}>
                  <div className="edc-hrow" style={{ gap: 6 }}>
                    <span className="ed-callout">{k.label}</span>
                    {k.hostAgentSocket != null && <span className="edc-tiny tertiary" title="Signed by the ssh-agent on your Mac; never copied.">{socketName(k.hostAgentSocket)}</span>}
                    {k.hasPassphrase && <span className="tertiary" title="Passphrase is in your macOS Keychain."><SF name="lock.fill" size={10} /></span>}
                  </div>
                  <div className="edc-tiny mono tertiary truncate">{line}</div>
                </div>
                <IconBtn symbol="minus.circle" help="Remove" onClick={() => update(d => { d.importedSSHKeys = arr(d, 'importedSSHKeys').filter(x => x.id !== k.id); })} />
              </div>
            );
          })}
      </div>
    </div>
  );
}

function socketName(s: string) {
  if (!s) return 'SSH_AUTH_SOCK';
  const l = s.toLowerCase();
  if (l.includes('secretive')) return 'Secretive';
  if (l.includes('1password') || l.includes('2bua8c4s2c')) return '1Password';
  if (l.includes('gnupg') || l.includes('gpg')) return 'gpg-agent';
  return s.split('/').pop() ?? s;
}

// ── AWS ──────────────────────────────────────────────────────────────────

function AWSEditor() {
  const { doc, update } = useEditor();
  const a = val<Doc>(doc, 'awsCredentials');
  const mode = a.authMode ?? 'staticKeys';
  const set = (k: string, v: any) => update(d => { d.awsCredentials = { ...val<Doc>(d, 'awsCredentials'), [k]: v }; });
  const row = (label: string, el: React.ReactNode) => <div className="edc-labeled"><span>{label}</span>{el}</div>;
  return (
    <div className="edc-vstack" style={{ gap: 6 }}>
      <div className="edc-hrow" style={{ paddingBottom: 4 }}>
        <span>Auth method</span>
        <Segmented value={mode} onChange={v => set('authMode', v)}
                   options={[{ value: 'staticKeys', label: 'Static keys' }, { value: 'ssoProfile', label: 'SSO / Identity Center' }]} />
      </div>
      {mode === 'staticKeys' ? (
        <>
          <Caption md>Access key + secret from IAM → Users → Security credentials. The real secret never reaches the VM at all — `~/.aws/config` points at a `credential_process` helper that vends the real access key with a *fake* secret, so the SDK signs a doomed request. The host's MITM proxy strips that signature and re-signs with the real material before the request leaves your Mac. `aws`, terraform, boto3 etc. work out of the box; if anything bypasses the proxy, AWS rejects with InvalidSignatureException — fail-closed.</Caption>
          {row('Access key ID', <Field value={a.accessKeyID ?? ''} onChange={v => set('accessKeyID', v)} placeholder="AKIA…" />)}
          {row('Secret access key', <Field secure value={a.secretAccessKey ?? ''} onChange={v => set('secretAccessKey', v)} placeholder="•••• ••••" />)}
          {row('Session token', <Field secure value={a.sessionToken ?? ''} onChange={v => set('sessionToken', v)} placeholder="Optional — STS only" />)}
          {row('Default region', <Field value={a.region ?? ''} onChange={v => set('region', v)} placeholder="us-east-1" />)}
          <div className="edc-hrow end">
            <Button variant="borderless" icon="arrow.up.right.square" className="edc-small"
                    onClick={() => openExternal('https://console.aws.amazon.com/iam/home#/security_credentials')}>Open IAM credentials page</Button>
          </div>
        </>
      ) : (
        <>
          {/* SSO discovery reads ~/.aws on the machine that RUNS the workspaces;
              a remote client can't browse it — typed in, as on iOS. */}
          <Caption>Authenticate via AWS IAM Identity Center (SSO). Enter the SSO profile name as it appears in the server's ~/.aws/config; the server resolves it at session start.</Caption>
          {row('SSO profile', <Field value={a.ssoProfileName ?? ''} onChange={v => set('ssoProfileName', v)} placeholder="my-sso-profile" />)}
          {row('Default region', <Field value={a.region ?? ''} onChange={v => set('region', v)} placeholder="us-east-1" />)}
        </>
      )}
    </div>
  );
}

// ── DigitalOcean / Linear / Twilio ───────────────────────────────────────

function SingleToken({ field, placeholder, url, help, blurb }: { field: string; placeholder: string; url: string; help: string; blurb: string }) {
  const { doc, set } = useEditor();
  return (
    <div className="edc-vstack" style={{ gap: 6 }}>
      <Caption md>{blurb}</Caption>
      <div className="edc-hrow">
        <Field secure value={val<string>(doc, field)} onChange={v => set(field, v)} placeholder={placeholder} />
        <IconBtn symbol="arrow.up.right.square" help={help} onClick={() => openExternal(url)} />
      </div>
    </div>
  );
}

function TwilioEditor() {
  const { doc, update } = useEditor();
  const t = val<Doc>(doc, 'twilioCredential');
  const set = (k: string, v: any) => update(d => { d.twilioCredential = { ...val<Doc>(d, 'twilioCredential'), [k]: v }; });
  return (
    <div className="edc-vstack" style={{ gap: 6 }}>
      <Caption md>Account SID + Auth Token from console.twilio.com (or an API Key SID `SK…` + its secret). Injected into the VM as `TWILIO_ACCOUNT_SID` + `TWILIO_AUTH_TOKEN` env with a FAKE secret; the proxy swaps it to the real value on requests to twilio.com. The SID is identity (it rides in the request URL), so it isn't secret; the token is.</Caption>
      <Field value={t.sid ?? ''} onChange={v => set('sid', v)} placeholder="Account SID (AC…) or API Key SID (SK…)" />
      <div className="edc-hrow">
        <Field secure value={t.secret ?? ''} onChange={v => set('secret', v)} placeholder="Auth Token / API Key secret" />
        <IconBtn symbol="arrow.up.right.square" help="Open the Twilio Console in your browser" onClick={() => openExternal('https://console.twilio.com/')} />
      </div>
      <RequireApproval checked={!!t.requireApproval} onChange={v => set('requireApproval', v)} />
    </div>
  );
}

// ── Kubernetes ───────────────────────────────────────────────────────────

function KubeEditor() {
  const { doc, update } = useEditor();
  const list = val<Doc[]>(doc, 'kubeconfigs');
  return (
    <div className="edc-vstack" style={{ gap: 8 }}>
      <Caption>Each context produces a synthetic ~/.kube/config in the VM with throwaway client certs / placeholder bearer tokens. Real credentials live on the host; the proxy substitutes them on the wire when the VM talks to the API server. Exec-plugin contexts are polled on the host so kubectl always sees a fresh token.</Caption>
      {list.length === 0
        ? <CaptionTertiary className="edc-emptyline">No Kubernetes contexts configured.</CaptionTertiary>
        : list.map(k => <KubeRow key={k.id} id={k.id} />)}
      <div className="edc-hrow end">
        <Button variant="borderless" icon="plus" onClick={() => update(d => {
          const l = arr(d, 'kubeconfigs');
          l.push({ id: uuid(), name: `context-${l.length + 1}`, serverURL: '', caCertPEM: '', namespace: '', auth: { kind: 'bearerToken', token: '' } });
        })}>Add context</Button>
      </div>
    </div>
  );
}

function KubeRow({ id }: { id: string }) {
  const { doc, update } = useEditor();
  const [open, setOpen] = useState(false);
  const k = byId(val(doc, 'kubeconfigs'), id) ?? {};
  const set = (key: string, v: any) => update(d => { const x = byId(arr(d, 'kubeconfigs'), id); if (x) x[key] = v; });
  const auth: Doc = k.auth ?? { kind: 'bearerToken', token: '' };
  const kind = auth.kind === 'clientCert' ? 'cert' : auth.kind === 'execPlugin' ? 'exec' : 'token';
  const setAuth = (a: Doc) => set('auth', a);
  const lab = (t: string) => <span className="edc-klabel">{t}</span>;
  const badge = { token: ['token', 'var(--blue)'], cert: ['cert', 'var(--green)'], exec: ['exec', 'var(--purple)'] }[kind];
  const secs = Number(auth.refreshSeconds ?? 600);
  return (
    <div className="edc-card">
      <div className="edc-hrow">
        <span className={cx('ed-disclosure-chev', open && 'open')} onClick={() => setOpen(!open)}><SF name="chevron.right" size={10} weight={600} /></span>
        <SF name="shippingbox.fill" size={14} color="var(--label-secondary)" />
        <input className="edc-plain edc-kname" value={k.name ?? ''} placeholder="context-name" spellCheck={false} onChange={e => set('name', e.target.value)} />
        {k.serverURL && <span className="edc-tiny mono tertiary truncate" style={{ minWidth: 0 }}>{k.serverURL}</span>}
        <div style={{ flex: 1 }} />
        <span className="edc-badge" style={{ background: badge[1] }}>{badge[0]}</span>
        <IconBtn symbol="minus.circle" help="Remove" onClick={() => update(d => { d.kubeconfigs = arr(d, 'kubeconfigs').filter(x => x.id !== id); })} />
      </div>
      {open && (
        <div className="edc-vstack" style={{ gap: 8, paddingTop: 6 }}>
          <div className="edc-hrow">{lab('Server')}<Field value={k.serverURL ?? ''} onChange={v => set('serverURL', v)} placeholder="https://k8s.example.com:6443" /></div>
          <div className="edc-hrow top">{lab('CA cert')}
            <div className="edc-vstack grow" style={{ gap: 2 }}>
              <TextArea mono rows={4} value={k.caCertPEM ?? ''} onChange={v => set('caCertPEM', v)} />
              <div className="edc-fhint">Optional. Leave blank to trust the Bromure CA only (the proxy still validates the upstream).</div>
            </div>
          </div>
          <div className="edc-hrow">{lab('Namespace')}<Field value={k.namespace ?? ''} onChange={v => set('namespace', v)} placeholder="default" /></div>
          <div className="ed-divider" />
          <div className="edc-hrow">{lab('Auth')}
            <Segmented value={kind} onChange={v => setAuth(v === 'token' ? { kind: 'bearerToken', token: '' } : v === 'cert' ? { kind: 'clientCert', cert: '', key: '' } : { kind: 'execPlugin', command: '', args: [], refreshSeconds: 600 })}
                       options={[{ value: 'token', label: 'Bearer token' }, { value: 'cert', label: 'Client certificate' }, { value: 'exec', label: 'Exec plugin' }]} />
          </div>
          {kind === 'token' && <div className="edc-hrow">{lab('Token')}<Field secure value={auth.token ?? ''} onChange={v => setAuth({ kind: 'bearerToken', token: v })} placeholder="eyJ… or sa-…" /></div>}
          {kind === 'cert' && <>
            <div className="edc-hrow top">{lab('Cert PEM')}<TextArea mono rows={4} value={auth.cert ?? ''} onChange={v => setAuth({ ...auth, cert: v })} /></div>
            <div className="edc-hrow top">{lab('Key PEM')}<TextArea mono rows={4} value={auth.key ?? ''} onChange={v => setAuth({ ...auth, key: v })} /></div>
          </>}
          {kind === 'exec' && <>
            <div className="edc-hrow">{lab('Command')}<Field value={auth.command ?? ''} onChange={v => setAuth({ ...auth, command: v })} placeholder="/usr/local/bin/aws" /></div>
            <div className="edc-hrow">{lab('Args')}<Field value={(auth.args ?? []).join(' ')} onChange={v => setAuth({ ...auth, args: v.split(' ').filter(Boolean) })} placeholder="eks get-token --cluster-name foo (space-separated)" /></div>
            <div className="edc-hrow">{lab('Refresh')}
              <span className="edc-stepper">
                <button onClick={() => setAuth({ ...auth, refreshSeconds: Math.max(60, secs - 60) })}>−</button>
                <button onClick={() => setAuth({ ...auth, refreshSeconds: Math.min(3600, secs + 60) })}>+</button>
              </span>
              <span className="edc-small mono">{Math.round(secs / 60)} min</span>
            </div>
            <div className="edc-fhint">Bromure runs this command on the host every refresh interval, parses the kubectl ExecCredential JSON, and feeds the resulting token into the proxy's swap map. The VM's kubectl never executes the plugin.</div>
          </>}
        </div>
      )}
    </div>
  );
}

// ── Container registries ─────────────────────────────────────────────────

function DockerEditor() {
  const { doc, update } = useEditor();
  const menu = useMenu();
  const list = val<Doc[]>(doc, 'dockerRegistries');
  const add = (host: string) => update(d => { arr(d, 'dockerRegistries').push({ id: uuid(), host, username: '', password: '' }); });
  return (
    <div className="edc-vstack" style={{ gap: 6 }}>
      <Caption md>{'Per-registry HTTP Basic auth for `docker pull` / `docker push`. The real password is never written into the VM — bromure puts a fake `base64("<user>:<derived>")` in `~/.docker/config.json`, and the proxy substitutes the real value on the wire when the request hits the matching registry host.'}</Caption>
      {list.length === 0
        ? <CaptionTertiary style={{ padding: '4px 0' }}>No registries configured.</CaptionTertiary>
        : list.map(c => <React.Fragment key={c.id}><DockerRow id={c.id} /><div className="ed-divider" /></React.Fragment>)}
      <div className="edc-hrow">
        <Button variant="borderless" icon="plus" onClick={e => menu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
          { label: 'Docker Hub (docker.io)', action: () => add('docker.io') },
          { label: 'GitHub Container Registry (ghcr.io)', action: () => add('ghcr.io') },
          { label: 'GitLab Container Registry (registry.gitlab.com)', action: () => add('registry.gitlab.com') },
          { label: 'Quay (quay.io)', action: () => add('quay.io') },
          { separator: true },
          { label: 'Other host…', action: () => add('') },
        ])}>Add</Button>
        <DockerConfigImport />
      </div>
    </div>
  );
}

/** Import config.json… — the file is read here in the browser (it's the
 *  user's own ~/.docker/config.json), entries with a credsStore / credHelpers
 *  are skipped as on macOS. */
function DockerConfigImport() {
  const { update } = useEditor();
  const [msg, setMsg] = useState<string | null>(null);
  const pick = () => {
    const input = document.createElement('input');
    input.type = 'file'; input.accept = '.json,application/json';
    input.onchange = async () => {
      const f = input.files?.[0]; if (!f) return;
      try {
        const j = JSON.parse(await f.text());
        const auths = (j?.auths ?? {}) as Record<string, Doc>;
        const entries: { host: string; username: string; password: string }[] = [];
        let skipped = 0;
        for (const [key, v] of Object.entries(auths)) {
          let host = key.replace(/^https?:\/\//, '').replace(/\/.*$/, '');
          if (host === 'index.docker.io') host = 'docker.io';
          let user = v.username ?? '', pass = v.password ?? '';
          if (v.auth) { try { const s = atob(v.auth); const i = s.indexOf(':'); if (i > 0) { user = s.slice(0, i); pass = s.slice(i + 1); } } catch { /* bad base64 */ } }
          if (!user || !pass) { skipped++; continue; }
          entries.push({ host, username: user, password: pass });
        }
        let added = 0;
        update(d => {
          const l = arr(d, 'dockerRegistries');
          for (const e of entries) {
            if (l.some(x => String(x.host).toLowerCase() === e.host.toLowerCase() && x.username === e.username)) continue;
            l.push({ id: uuid(), ...e }); added++;
          }
        });
        setTimeout(() => setMsg((added === 1 ? 'Imported 1 registry' : `Imported ${added} registries`)
          + (skipped ? ` — skipped ${skipped} entr${skipped === 1 ? 'y' : 'ies'} stored in credsStore / credHelpers.` : added ? '' : ' — no usable auth entries found.')), 0);
      } catch (e: any) { setMsg(`Couldn't import config.json: ${e?.message ?? e}`); }
    };
    input.click();
  };
  return (
    <>
      <Button variant="borderless" icon="square.and.arrow.down" onClick={pick}
              title="Pull entries from an existing ~/.docker/config.json. Entries that delegate to credsStore / credHelpers are skipped — those passwords live in the OS keychain, not in the file.">Import config.json…</Button>
      {msg && <span className="edc-small secondary">{msg}</span>}
    </>
  );
}

function DockerRow({ id }: { id: string }) {
  const { doc, update } = useEditor();
  const c = byId(val(doc, 'dockerRegistries'), id) ?? {};
  const set = (k: string, v: any) => update(d => { const x = byId(arr(d, 'dockerRegistries'), id); if (x) x[k] = v; });
  const h = String(c.host ?? '').toLowerCase();
  const symbol = h === 'ghcr.io' ? 'cat.fill' : h.includes('gitlab') ? 'fox.fill' : (h === 'docker.io' || h === 'index.docker.io') ? 'cube.box.fill' : 'shippingbox.fill';
  return (
    <div className="edc-card" style={{ gap: 10 }}>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>Registry host</Label>
        <div className="edc-hrow">
          <span className="edc-sym"><SF name={symbol} size={14} /></span>
          <Field value={c.host ?? ''} onChange={v => set('host', v)} placeholder="ghcr.io" />
          <IconBtn symbol="minus.circle" help="Remove this registry" onClick={() => update(d => { d.dockerRegistries = arr(d, 'dockerRegistries').filter(x => x.id !== id); })} />
        </div>
        <Hint>The registry you docker pull / push to, e.g. ghcr.io or a private registry host.</Hint>
      </div>
      <div className="edc-hrow top" style={{ gap: 8 }}>
        <div className="edc-vstack grow" style={{ gap: 3 }}>
          <Label>Username</Label>
          <Field value={c.username ?? ''} onChange={v => set('username', v)} placeholder="octocat" />
        </div>
        <div className="edc-vstack grow" style={{ gap: 3 }}>
          <Label>Password or token</Label>
          <SecretField value={c.password ?? ''} onChange={v => set('password', v)} placeholder="•••• ••••" revealPlaceholder="ghp_…" help={['Show password', 'Hide password']} />
        </div>
      </div>
    </div>
  );
}

// ── HTTPS databases ──────────────────────────────────────────────────────

const DB_BLURB: Record<DBEngine, string> = {
  mongoDataAPI: 'MongoDB Atlas Data API endpoints. The real API key never enters the VM — bromure injects a fake under your env var(s) and swaps it for the real key on requests to the endpoint host. Set the Guardrails mode under the Guardrails panel: deleteOne/deleteMany are destructive, insert/update are writes, find/aggregate are reads.',
  clickHouse: 'ClickHouse HTTP-interface endpoints (self-hosted or Cloud). The real credential stays on the host; a fake rides in the VM. Guardrails classify the SQL: DROP/TRUNCATE/DELETE (and ALTER…DELETE) are destructive, INSERT/CREATE are writes, SELECT/SHOW are reads.',
  elasticsearch: 'Elasticsearch endpoints. The real credential stays on the host. Guardrails classify by method + path: DELETE and _delete_by_query are destructive, _search/_count/_msearch are reads, _bulk/index/_update are writes.',
};

function DatabaseSection({ engine }: { engine: DBEngine }) {
  const { doc, update } = useEditor();
  const matching = val<Doc[]>(doc, 'httpDatabases').filter(d => d.engine === engine);
  return (
    <div className="edc-vstack" style={{ gap: 6 }}>
      <Caption>{DB_BLURB[engine]}</Caption>
      {matching.length === 0
        ? <CaptionTertiary style={{ padding: '4px 0' }}>No endpoints configured.</CaptionTertiary>
        : matching.map(db => <React.Fragment key={db.id}><DatabaseRow id={db.id} /><div className="ed-divider" /></React.Fragment>)}
      <div className="edc-hrow">
        <Button variant="borderless" icon="plus" onClick={() => update(d => {
          arr(d, 'httpDatabases').push({ id: uuid(), name: '', engine, host: '', auth: engine === 'mongoDataAPI' ? 'apiKey' : 'basic', username: '', secret: '', envVars: [], guardrail: 'off' });
        })}>Add</Button>
      </div>
    </div>
  );
}

function DatabaseRow({ id }: { id: string }) {
  const { doc, update } = useEditor();
  const e = byId(val(doc, 'httpDatabases'), id) ?? {};
  const set = (k: string, v: any) => update(d => { const x = byId(arr(d, 'httpDatabases'), id); if (x) x[k] = v; });
  const engine = e.engine as DBEngine;
  const hostPrompt = { mongoDataAPI: 'data.mongodb-api.com', clickHouse: 'myhost.clickhouse.cloud:8443 or self-hosted host', elasticsearch: 'my-deployment.es.io' }[engine] ?? '';
  const envPrompt = { mongoDataAPI: 'MONGODB_API_KEY', clickHouse: 'CLICKHOUSE_PASSWORD', elasticsearch: 'ELASTIC_PASSWORD' }[engine] ?? '';
  const secretPrompt = { basic: 'password', apiKey: 'API key', bearer: 'bearer token' }[e.auth as string] ?? 'password';
  return (
    <div className="edc-card" style={{ gap: 10 }}>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <div className="edc-hrow"><Label>Name (optional)</Label><div style={{ flex: 1 }} />
          <IconBtn symbol="minus.circle" help="Remove this endpoint" onClick={() => update(d => { d.httpDatabases = arr(d, 'httpDatabases').filter(x => x.id !== id); })} /></div>
        <Field value={e.name ?? ''} onChange={v => set('name', v)} placeholder="e.g. Production cluster" />
        <Hint>A name for you to recognise this endpoint. Shown here only.</Hint>
      </div>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>Host</Label>
        <Field value={e.host ?? ''} onChange={v => set('host', v)} placeholder={hostPrompt} />
        <Hint>The hostname the agent connects to — no https:// or path. Both the credential swap and Guardrails scope to this host, so self-hosted instances work.</Hint>
      </div>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>Authentication</Label>
        <Segmented value={e.auth ?? 'basic'} onChange={v => set('auth', v)}
                   options={[{ value: 'basic', label: 'Username + password' }, { value: 'apiKey', label: 'API key' }, { value: 'bearer', label: 'Bearer token' }]} />
      </div>
      {(e.auth ?? 'basic') === 'basic' && (
        <div className="edc-vstack" style={{ gap: 3 }}>
          <Label>Username</Label>
          <Field value={e.username ?? ''} onChange={v => set('username', v)} placeholder="default" />
        </div>
      )}
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>Secret</Label>
        <SecretField value={e.secret ?? ''} onChange={v => set('secret', v)} placeholder="•••• ••••" revealPlaceholder={secretPrompt} help={['Show secret', 'Hide secret']} />
        <Hint>Your real secret. Stays on macOS — the VM only ever sees a fake stand-in.</Hint>
      </div>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>Environment variable(s)</Label>
        <HostListField hosts={e.envVars ?? []} onChange={v => set('envVars', v)} placeholder={envPrompt} />
        <Hint>Variable(s) the fake secret is exported under in the VM — comma-separated for more than one. Reference these from your code / connection string.</Hint>
      </div>
    </div>
  );
}

// ── Other API keys (manual tokens) ───────────────────────────────────────

const HERMES_PRESETS: { name: string; envVarName: string; hosts: string[] }[] = [
  { name: 'Firecrawl (web search & extract)', envVarName: 'FIRECRAWL_API_KEY', hosts: ['firecrawl.dev'] },
  { name: 'Exa (web search)', envVarName: 'EXA_API_KEY', hosts: ['exa.ai'] },
  { name: 'Tavily (web search)', envVarName: 'TAVILY_API_KEY', hosts: ['tavily.com'] },
  { name: 'Parallel (web search)', envVarName: 'PARALLEL_API_KEY', hosts: ['parallel.ai'] },
  { name: 'Perplexity (web search)', envVarName: 'PERPLEXITY_API_KEY', hosts: ['perplexity.ai'] },
  { name: 'Brave Search', envVarName: 'BRAVE_SEARCH_API_KEY', hosts: ['search.brave.com'] },
  { name: 'Browserbase (cloud browser)', envVarName: 'BROWSERBASE_API_KEY', hosts: ['browserbase.com'] },
  { name: 'Browser Use (cloud browser)', envVarName: 'BROWSER_USE_API_KEY', hosts: ['browser-use.com'] },
  { name: 'FAL (image generation)', envVarName: 'FAL_KEY', hosts: ['fal.run', 'fal.ai', 'fal.media'] },
  { name: 'Krea (image generation)', envVarName: 'KREA_API_KEY', hosts: ['krea.ai'] },
  { name: 'ElevenLabs (text to speech)', envVarName: 'ELEVENLABS_API_KEY', hosts: ['elevenlabs.io'] },
  { name: 'Groq (speech to text)', envVarName: 'GROQ_API_KEY', hosts: ['groq.com'] },
  { name: 'Honcho (memory)', envVarName: 'HONCHO_API_KEY', hosts: ['honcho.dev'] },
  { name: 'Mem0 (memory)', envVarName: 'MEM0_API_KEY', hosts: ['mem0.ai'] },
];

export const newManualToken = (t: Partial<Doc> = {}): Doc =>
  ({ id: uuid(), name: '', realValue: '', envVarName: '', hostFilters: [], ...t });

function ManualTokens() {
  const { doc, update } = useEditor();
  const menu = useMenu();
  const list = val<Doc[]>(doc, 'manualTokens');
  return (
    <div className="edc-vstack" style={{ gap: 6 }}>
      <Caption md>Add credentials for any API that Bromure doesn't handle automatically (Anthropic, OpenAI, GitHub, GitLab, DigitalOcean and Kubernetes already are). The agent inside the VM only ever sees a fake token (`brm_…`); when a request leaves the VM, Bromure swaps the fake back to your real key on the way out — so your real secret never enters the sandbox.</Caption>
      {list.length === 0
        ? <CaptionTertiary className="edc-emptyline">No extra credentials yet.</CaptionTertiary>
        : list.map(t => <ManualRow key={t.id} id={t.id} />)}
      <div className="edc-hrow end">
        <Button variant="borderless" icon="paperplane"
                title="Add the API key of a service Hermes Agent's tools use (web search, cloud browser, images, voice, memory). Hermes only ever sees a stand-in."
                onClick={e => menu((e.currentTarget as HTMLElement).getBoundingClientRect(), HERMES_PRESETS.map(p => ({
                  label: p.name, disabled: list.some(t => t.envVarName === p.envVarName),
                  action: () => update(d => { arr(d, 'manualTokens').push(newManualToken({ name: p.name, envVarName: p.envVarName, hostFilters: p.hosts })); }),
                })))}>Hermes integration <SF name="chevron.down" size={9} weight={600} /></Button>
        <Button variant="borderless" icon="plus" onClick={() => update(d => { arr(d, 'manualTokens').push(newManualToken()); })}>Add credential</Button>
      </div>
    </div>
  );
}

function ManualRow({ id }: { id: string }) {
  const { doc, update } = useEditor();
  const [reveal, setReveal] = useState(false);
  const t = byId(val(doc, 'manualTokens'), id) ?? {};
  const set = (k: string, v: any) => update(d => { const x = byId(arr(d, 'manualTokens'), id); if (x) x[k] = v; });
  const isOp = !!opReference(t.realValue ?? '');
  return (
    <div className="edc-card pad10" style={{ gap: 12 }}>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <div className="edc-hrow"><Label>Name</Label><div style={{ flex: 1 }} />
          <IconBtn symbol="minus.circle" help="Remove this credential" onClick={() => update(d => { d.manualTokens = arr(d, 'manualTokens').filter(x => x.id !== id); })} /></div>
        <Field value={t.name ?? ''} onChange={v => set('name', v)} placeholder="e.g. Stripe (sandbox)" />
        <Hint>A name for you to recognise this entry. Shown here only — never sent anywhere.</Hint>
      </div>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>{isOp ? '1Password reference' : 'Real secret'}</Label>
        <div className="edc-hrow">
          <Field value={t.realValue ?? ''} onChange={v => set('realValue', v)} secure={!isOp && !reveal}
                 placeholder={isOp ? 'op://vault/item/field' : 'sk_live_…'} />
          {!isOp && <IconBtn symbol={reveal ? 'eye.slash' : 'eye'} help={reveal ? 'Hide value' : 'Show value'} onClick={() => setReveal(!reveal)} />}
        </div>
        {isOp
          ? <Hint>A 1Password secret reference (op://…). Only this path is stored — Bromure resolves the secret with the op CLI at launch and refreshes it every 2 minutes; the VM only ever sees a fake.</Hint>
          : <Hint>Your real API key. Stays on macOS — the VM only ever sees a fake stand-in. You can also paste a 1Password reference (op://vault/item/field).</Hint>}
      </div>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>Environment variable</Label>
        <Field value={t.envVarName ?? ''} onChange={v => set('envVarName', v)} placeholder="STRIPE_API_KEY" />
        <Hint>The agent reads the fake token from this variable inside the VM. Leave blank to inject nothing and copy it in yourself.</Hint>
      </div>
      <div className="edc-vstack" style={{ gap: 3 }}>
        <Label>API host(s) (optional)</Label>
        <HostListField hosts={t.hostFilters ?? []} onChange={v => set('hostFilters', v)} placeholder="api.stripe.com, api.example.com" />
        <Hint>Hostnames only, comma-separated, no https:// or path. The real key is substituted only on requests to these hosts and their subdomains. Leave blank to allow any host.</Hint>
      </div>
    </div>
  );
}

