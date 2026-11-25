// MCP — ProfileViews.swift `mcpSection` + MCPServerRow.
//
// OAuth authorization runs a localhost callback listener + browser dance on
// the machine that injects the token (MCPOAuthBroker, host-side): like the
// iOS editor, a remote client offers a static token and shows an existing
// authorization (re-authorize/revoke).

import React, { useState } from 'react';
import { Segmented, Switch } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { useEditor } from '../ctx';
import { val } from '../model';
import { Caption, Disclosure } from '../ui';
import { BorderlessButton, RemoveButton, RowCard, relativeAge } from './FoldersKit';
import { isValidEnvName } from './Environment';

interface MCPServer {
  id: string; name: string; transport: 'http' | 'stdio'; command: string; arguments: string[]; url: string;
  environment: { id: string; name: string; value: string }[]; bearerTokenEnvVar: string; bearerToken: string;
  enabled: boolean; rawJSON: string; startupTimeoutSec?: number; toolTimeoutSec?: number;
  oauthState?: { expiresAt?: string; [k: string]: unknown } | null;
}

const newServer = (): MCPServer => ({
  id: crypto.randomUUID().toUpperCase(), name: '', transport: 'http', command: '', arguments: [], url: '',
  environment: [], bearerTokenEnvVar: '', bearerToken: '', enabled: true, rawJSON: '',
});

export function MCPPane() {
  const { doc, set } = useEditor();
  const servers = val<MCPServer[]>(doc, 'mcpServers');
  return (
    <div className="edm-pane" style={{ gap: 8 }}>
      <Caption>MCP servers give your agent access to external tools and context. Configs are translated into the right format for each agent (Claude Code, Codex, Grok, Kimi and omp) and injected into the VM at boot.</Caption>
      {servers.length === 0 ? (
        <div className="edm-empty-small">No MCP servers configured.</div>
      ) : servers.map((s, i) => (
        <MCPServerRow key={s.id ?? i} server={s}
                      onChange={next => set('mcpServers', servers.map((x, j) => j === i ? next : x))}
                      onRemove={() => set('mcpServers', servers.filter((_, j) => j !== i))} />
      ))}
      <div className="edm-trailing">
        <BorderlessButton symbol="plus" onClick={() => set('mcpServers', [...servers, newServer()])}>Add server</BorderlessButton>
      </div>
    </div>
  );
}

function MCPServerRow({ server, onChange, onRemove }: { server: MCPServer; onChange: (s: MCPServer) => void; onRemove: () => void }) {
  const [showJSON, setShowJSON] = useState(() => !!server.rawJSON);
  const patch = (p: Partial<MCPServer>) => onChange({ ...server, ...p });
  const jsonValid = (() => { if (!server.rawJSON) return true; try { JSON.parse(server.rawJSON); return true; } catch { return false; } })();
  return (
    <RowCard style={{ opacity: server.enabled ? 1 : 0.6 }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        <div className="edm-row">
          <input className="field ed-field" style={{ maxWidth: 180 }} spellCheck={false} aria-label="Name" placeholder="my-server"
                 value={server.name} onChange={e => patch({ name: e.target.value })} />
          {!showJSON && (
            <span style={{ width: 120, flexShrink: 0, display: 'flex' }}>
              <Segmented value={server.transport} onChange={t => patch({ transport: t })}
                         options={[{ value: 'http', label: 'HTTP' }, { value: 'stdio', label: 'STDIO' }]} />
            </span>
          )}
          <Switch checked={server.enabled} onChange={v => patch({ enabled: v })} title={server.enabled ? 'Enabled' : 'Disabled'} />
          <div style={{ flex: 1 }} />
          <BorderlessButton symbol={showJSON ? 'slider.horizontal.3' : 'curlybraces'} help={showJSON ? 'Switch to form' : 'Edit as JSON'}
                            onClick={() => {
                              if (!showJSON && !server.rawJSON) patch({ rawJSON: generateJSON(server) });
                              else if (showJSON) patch({ rawJSON: '' });
                              setShowJSON(!showJSON);
                            }} />
          <RemoveButton help="Remove this server" onClick={onRemove} />
        </div>
        {showJSON ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <div className="edm-caption2 secondary">Raw JSON config — passed directly to the agent's MCP config file.</div>
            <textarea className={'edm-json' + (jsonValid ? '' : ' invalid')} spellCheck={false} rows={5} value={server.rawJSON}
                      onChange={e => patch({ rawJSON: e.target.value })} />
            {!jsonValid && <div className="edm-caption2" style={{ color: 'var(--red)' }}>Invalid JSON</div>}
          </div>
        ) : server.transport === 'stdio' ? (
          <div className="edm-row">
            <input className="field ed-field" style={{ maxWidth: 140 }} spellCheck={false} aria-label="Command" placeholder="npx"
                   value={server.command} onChange={e => patch({ command: e.target.value })} />
            <ArgsField args={server.arguments} onChange={a => patch({ arguments: a })} />
          </div>
        ) : (
          <>
            <input className="field ed-field" spellCheck={false} aria-label="URL" placeholder="https://mcp.example.com/mcp"
                   value={server.url} onChange={e => patch({ url: e.target.value })} />
            <div className="edm-mcp-auth" style={{ fontSize: 10 }}>
              <Disclosure label={<span className="ed-caption" style={{ color: 'var(--label)' }}>Authentication</span>}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6, paddingTop: 2 }}>
                  {server.url !== '' && (
                    <>
                      <div className="edm-row" style={{ gap: 8 }}>
                        {server.oauthState ? (
                          <>
                            <SF name="checkmark.circle.fill" size={13} color="var(--green)" />
                            <span className="ed-caption" style={{ color: 'var(--label)' }}>Authorized</span>
                            {server.oauthState.expiresAt && (
                              <span className="edm-caption2 secondary">expires {relativeAge(new Date(server.oauthState.expiresAt))}</span>
                            )}
                            <div style={{ flex: 1 }} />
                            <button className="btn small" disabled title="Authorize OAuth from the desktop app; a static token works from here.">Re-authorize</button>
                            <button className="btn small" style={{ color: 'var(--red)' }}
                                    onClick={() => patch({ oauthState: null, bearerToken: '' })}>Revoke</button>
                          </>
                        ) : (
                          <span className="edm-caption2 secondary">Authorize OAuth from the desktop app; a static token works from here.</span>
                        )}
                      </div>
                      <div className="ed-divider" />
                      <div className="edm-caption2 secondary">Or enter a static token:</div>
                    </>
                  )}
                  <div className="edm-row">
                    <span className="ed-caption" style={{ width: 80, textAlign: 'right', flexShrink: 0 }}>Env var name</span>
                    <input className="field ed-field" spellCheck={false} placeholder="e.g. FIGMA_OAUTH_TOKEN" disabled={!!server.oauthState}
                           value={server.bearerTokenEnvVar} onChange={e => patch({ bearerTokenEnvVar: e.target.value })} />
                  </div>
                  {server.bearerTokenEnvVar !== '' && (
                    <div className="edm-row">
                      <span className="ed-caption" style={{ width: 80, textAlign: 'right', flexShrink: 0 }}>Token</span>
                      {server.oauthState
                        ? <span className="edm-caption2 secondary">Managed by OAuth</span>
                        : <input className="field ed-field" type="password" spellCheck={false} autoComplete="off"
                                 placeholder="Never sent to VM — swapped by proxy" value={server.bearerToken}
                                 onChange={e => patch({ bearerToken: e.target.value })} />}
                    </div>
                  )}
                </div>
              </Disclosure>
            </div>
          </>
        )}
      </div>
    </RowCard>
  );
}

/** Arguments typed as one space-separated line; kept as typed while focused. */
function ArgsField({ args, onChange }: { args: string[]; onChange: (a: string[]) => void }) {
  const [text, setText] = useState<string | null>(null);
  return <input className="field ed-field" spellCheck={false} aria-label="Arguments" placeholder="-y @upstash/context7-mcp"
                value={text ?? args.join(' ')} onFocus={() => setText(args.join(' '))} onBlur={() => setText(null)}
                onChange={e => { setText(e.target.value); onChange(e.target.value.split(' ').filter(Boolean)); }} />;
}

function generateJSON(s: MCPServer): string {
  const obj: Record<string, unknown> = {};
  if (s.transport === 'stdio') {
    obj.command = s.command;
    if (s.arguments.length) obj.args = s.arguments;
  } else {
    obj.type = 'http';
    obj.url = s.url;
    if (s.bearerTokenEnvVar) obj.bearerTokenEnvVar = s.bearerTokenEnvVar;
  }
  const env = (s.environment ?? []).filter(e => e.name.trim() && isValidEnvName(e.name.trim()));
  if (env.length) obj.env = Object.fromEntries(env.map(e => [e.name, e.value]));
  // JSONSerialization .prettyPrinted + .sortedKeys
  const sort = (v: any): any => Array.isArray(v) ? v.map(sort) : v && typeof v === 'object'
    ? Object.fromEntries(Object.keys(v).sort().map(k => [k, sort(v[k])])) : v;
  return JSON.stringify(sort(obj), null, 2);
}
