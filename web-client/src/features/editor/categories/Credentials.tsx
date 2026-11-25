// Credentials — ProfileViews.swift `credentialsSection`: git identity, the
// imported config files, the configured credentials grouped by category (the
// host's `configuredCredentialRefs`, since secrets arrive blanked), the
// "Add credential" type picker + per-type editor sheets, Import env file…,
// and (OpenShell policy) the provider profiles.

import React, { useState } from 'react';
import { Button, Sheet, useMenu } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { useEditor } from '../ctx';
import { val, type Doc } from '../model';
import { Caption, Field, InfoTip, Toggle } from '../ui';
import { CredentialEditorBody, arr } from './CredentialsEditors';
import { EnvImportReview, applyEnvImport, importEnvText, type EnvImport } from './CredentialsEnvImport';
import {
  EDITOR_TYPES, configuredRefs, credentialHosts, credentialTitle, editorType, groupByCategory, markRemoved,
  refEditorType, refSymbol, type CredRef, type EditorType,
} from './CredentialsModel';
import './Credentials.css';

type CredSheet = { kind: 'picker' } | { kind: 'editor'; type: EditorType } | null;

export function CredentialsPane() {
  const ctx = useEditor();
  const { doc, set, update, credentialRefs, opened, select } = ctx;
  const [sheet, setSheet] = useState<CredSheet>(null);
  const [envImport, setEnvImport] = useState<EnvImport | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [, bump] = useState(0);
  const menu = useMenu();
  const groups = groupByCategory(configuredRefs(doc, credentialRefs, opened));
  const files = val<Doc[]>(doc, 'importedConfigFiles');

  const openEditor = (r: CredRef) => {
    // Agent API keys live in the model settings: a remote editor switches its own pane.
    if (refEditorType(r) === 'agents') select('localModels');
    else setSheet({ kind: 'editor', type: refEditorType(r) });
  };
  const remove = (r: CredRef) => {
    update(d => {
      const drop = (key: string) => { d[key] = arr(d, key).filter(x => String(x.id).toUpperCase() !== String(r.arg).toUpperCase()); };
      switch (r.kind) {
        case 'git': drop('gitHTTPSCredentials'); break;
        case 'manual': drop('manualTokens'); break;
        case 'docker': drop('dockerRegistries'); break;
        case 'db': drop('httpDatabases'); break;
        case 'kube': drop('kubeconfigs'); break;
        case 'ssh': drop('importedSSHKeys'); break;
        case 'aws': d.awsCredentials = {}; break;
        case 'do': d.digitalOceanToken = ''; break;
        case 'linear': d.linearToken = ''; break;
        case 'twilio': d.twilioCredential = {}; break;
        case 'ssh-managed': delete d.sshPublicKey; break;
      }
    });
    if (r.kind === 'do' || r.kind === 'linear') { markRemoved(opened, r.kind, true); bump(n => n + 1); }
    if (r.kind === 'ssh-managed') ctx.setGenerateSSH(false);
  };

  const pickEnvFile = () => {
    const input = document.createElement('input');
    input.type = 'file';
    input.onchange = async () => {
      const f = input.files?.[0]; if (!f) return;
      let text: string;
      try { text = await f.text(); } catch { setImportError(`Couldn't read ${f.name} as text.`); return; }
      const r = importEnvText(ctx, text, f.name);
      if (typeof r === 'string') setImportError(r); else { setImportError(null); setEnvImport(r); }
    };
    input.click();
  };

  return (
    <div className="edc-pane">
      <div className="edc-vstack" style={{ gap: 6 }}>
        <div className="ed-headline">Git Identity</div>
        <Field className="edc-bigfield" value={val(doc, 'gitUserName')} onChange={v => set('gitUserName', v)} placeholder="Your Name" />
        <Field className="edc-bigfield" value={val(doc, 'gitUserEmail')} onChange={v => set('gitUserEmail', v)} placeholder="you@example.com" />
        <Caption>Written to ~/.gitconfig in the VM. Leave both blank to keep git's defaults.</Caption>
      </div>

      {files.length > 0 && (
        <>
          <div className="ed-divider" />
          <div className="edc-vstack" style={{ gap: 6 }}>
            <div className="ed-headline">Imported Config Files</div>
            {files.map(f => (
              <div key={f.path} className="edc-card row top">
                <SF name="doc.text" size={14} color="var(--label-secondary)" />
                <div className="edc-vstack grow" style={{ gap: 1 }}>
                  <span className="mono" style={{ fontSize: 12 }}>~/{f.path}</span>
                  <Caption>{importedFileSubtitle(f)}</Caption>
                </div>
                <button className="edc-iconbtn" title="Remove this file from the workspace"
                        onClick={() => update(d => { d.importedConfigFiles = arr(d, 'importedConfigFiles').filter(x => x.path !== f.path); })}>
                  <SF name="minus.circle" size={14} />
                </button>
              </div>
            ))}
            <Caption>Copied into the VM as-is. Secrets were left out — those come in as credentials above, so the VM only ever sees a fake.</Caption>
          </div>
        </>
      )}

      <div className="ed-divider" />

      {groups.length === 0 ? (
        <div className="edc-empty">
          <SF name="key.slash" size={22} color="var(--label-secondary)" />
          <div className="edc-empty-title">No credentials yet</div>
          <Caption style={{ textAlign: 'center' }}>Add an API key, token, or SSH key — or import an env file. Real values stay on your Mac; the VM only ever holds a fake.</Caption>
        </div>
      ) : groups.map(([cat, refs]) => (
        <div key={cat} className="edc-vstack" style={{ gap: 4 }}>
          <div className="edc-sectitle">{cat.toUpperCase()}</div>
          {refs.map(r => {
            const hosts = credentialHosts(doc, r);
            const agents = refEditorType(r) === 'agents';
            return (
              <div key={r.id} className="edc-credrow" onClick={() => openEditor(r)}>
                <span className="edc-sym"><SF name={refSymbol(r)} size={14} /></span>
                <div className="edc-vstack grow" style={{ gap: 1 }}>
                  <span className="edc-sub">{credentialTitle(doc, r)}</span>
                  {hosts.length > 0 && <Caption>{hosts.join(', ')}</Caption>}
                </div>
                <button className="edc-iconbtn" aria-label="More"
                        onClick={e => { e.stopPropagation(); menu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
                          { label: agents ? 'Edit in Models…' : 'Edit…', action: () => openEditor(r) },
                          ...(agents ? [] : [{ label: 'Remove', destructive: true, action: () => remove(r) }]),
                        ]); }}>
                  <SF name="ellipsis" size={14} />
                </button>
              </div>
            );
          })}
        </div>
      ))}

      <div className="edc-hrow" style={{ paddingTop: 2, gap: 8 }}>
        <Button size="small" className="edc-bordered" icon="plus" onClick={() => setSheet({ kind: 'picker' })}>Add credential</Button>
        <Button size="small" className="edc-bordered" icon="square.and.arrow.down" onClick={pickEnvFile}>Import env file…</Button>
      </div>
      {importError && <div className="ed-caption" style={{ color: 'var(--red)' }}>{importError}</div>}

      {String(val(doc, 'networkPolicy')).trim() !== '' && (
        <>
          <div className="ed-divider" />
          <OpenShellCredentials />
        </>
      )}

      {sheet?.kind === 'picker' && (
        <Sheet width={460} height={520} onClose={() => setSheet(null)}>
          <div className="edc-sheet">
            <div className="edc-sheet-head">
              <span className="ed-headline">Add credential</span>
              <div style={{ flex: 1 }} />
              <Button onClick={() => setSheet(null)}>Cancel</Button>
            </div>
            <div className="edc-picker">
              {EDITOR_TYPES.filter(t => t.id !== 'agents').map(t => (
                <div key={t.id} className="edc-pickrow" onClick={() => setSheet({ kind: 'editor', type: t.id })}>
                  <span className="edc-picksym"><SF name={t.symbol} size={16} /></span>
                  <div className="edc-vstack grow" style={{ gap: 1 }}>
                    <span className="edc-sub500">{t.title}</span>
                    <Caption>{t.subtitle}</Caption>
                  </div>
                  <SF name="chevron.right" size={9} color="var(--label-tertiary)" />
                </div>
              ))}
            </div>
            <div className="ed-caption" style={{ padding: 10 }}>Agent API keys (Anthropic, OpenAI, xAI, …) are configured in Preferences › Models.</div>
          </div>
        </Sheet>
      )}
      {sheet?.kind === 'editor' && (
        <Sheet width={560} height={560} onClose={() => setSheet(null)}>
          <div className="edc-sheet">
            <div className="edc-sheet-head">
              <SF name={editorType(sheet.type).symbol} size={15} color="var(--accent)" />
              <span className="ed-headline">{editorType(sheet.type).title}</span>
              <div style={{ flex: 1 }} />
              <Button variant="prominent" onClick={() => setSheet(null)}>Done</Button>
            </div>
            <div className="edc-sheet-body" style={{ gap: 12 }}>
              <CredentialEditorBody type={sheet.type} />
            </div>
          </div>
        </Sheet>
      )}
      {envImport && (
        <EnvImportReview state={envImport} setState={setEnvImport} onCancel={() => setEnvImport(null)}
                         onImport={() => { applyEnvImport(ctx, envImport); setEnvImport(null); }} />
      )}
    </div>
  );
}

function importedFileSubtitle(f: Doc): string {
  const count = String(f.contents ?? '').split('\n').filter(l => { const t = l.trim(); return t && !t.startsWith('#') && !t.startsWith(';') && !t.startsWith('['); }).length;
  const bits = [`${count} setting(s)`];
  if (f.strippedSecrets > 0) bits.push(`${f.strippedSecrets} secret(s) left out`);
  if ((f.disabled ?? []).length) bits.push(`${f.disabled.join(', ')} disabled`);
  return bits.join(' · ');
}

/** OpenShellCredentialsSection: attached provider profiles + placeholders. */
function OpenShellCredentials() {
  const { doc, set, update } = useEditor();
  const providers = val<Doc[]>(doc, 'openShellProviders');
  return (
    <div className="edc-vstack" style={{ gap: 6 }}>
      <div className="edc-hrow" style={{ gap: 4 }}>
        <span className="ed-headline">OpenShell provider profiles</span>
        <InfoTip text="Import an OpenShell provider profile to add its credentials to this workspace. Bromure keeps the real values on the Mac, gives the VM stand-ins, and only swaps them in on the profile's endpoints (hosts and paths); the profile's endpoints are added as a rule." />
      </div>
      {providers.map(a => (
        <div key={a.id} className="edc-hrow">
          <SF name="key.horizontal" size={14} />
          <div className="edc-vstack grow" style={{ gap: 1 }}>
            <span className="ed-callout">{a.instanceName} · {providerName(a.profileYAML)}</span>
          </div>
          <button className="edc-iconbtn" title="Detach" onClick={() => update(d => {
            const ids = new Set((a.tokenIDs ?? []).map(String));
            d.manualTokens = arr(d, 'manualTokens').filter(t => !ids.has(String(t.id)));
            d.openShellProviders = arr(d, 'openShellProviders').filter(x => x.id !== a.id);
          })}><SF name="trash" size={13} color="var(--red)" /></button>
        </div>
      ))}
      <Button variant="borderless" icon="plus" disabled
              title="Attaching a provider profile parses its YAML on the Mac editor; not available in this client yet.">Attach provider profile…</Button>
      <div className="ed-divider" style={{ margin: '2px 0' }} />
      <div className="edc-vstack" style={{ gap: 2 }}>
        <div className="edc-hrow" style={{ gap: 4 }}>
          <Toggle checked={val(doc, 'openShellCredentialPlaceholders')} onChange={v => set('openShellCredentialPlaceholders', v)}>Use OpenShell credential placeholders</Toggle>
          <InfoTip text="The agent sees `openshell:resolve:env:NAME` in its environment instead of Bromure's look-alike tokens, for the credentials this workspace passes as environment variables. The proxy swaps in the real value in request headers, and in request bodies or WebSocket messages only where an endpoint sets `request_body_credential_rewrite` or `websocket_credential_rewrite`. Each credential still works only on its own hosts. Some tools check a token's format and may reject a placeholder. Takes effect at the next VM start." />
        </div>
        <Caption>Takes effect at the next VM start.</Caption>
      </div>
    </div>
  );
}

/** The provider profile's display name (`name:` / `display_name:` in its YAML). */
function providerName(yaml: string): string {
  const m = /^\s*(?:display_name|displayName|name)\s*:\s*["']?([^"'\n]+)["']?\s*$/m.exec(String(yaml ?? ''));
  return m?.[1]?.trim() || 'unknown profile';
}
