// VMDashboard.swift: a workspace machine's dashboard — identity + run-state
// pill, lifecycle actions, vitals (CPU sparkline / memory / vCPUs / disk /
// uptime), configuration, listening ports (running only), and the notes
// card edited in place.

import React, { useEffect, useMemo, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import type { VMInfo, Workspace } from '../../core/remote/types';
import { Button, useTooltip } from '../../ui/kit';
import { StatCard, CPUStatCard, useHistory, CardTitle, Pill, Confirm, SF } from './parts';
import { Markdown } from './markdown';
import { accentOf, copyText, gbBytes, gbKB, isUp, type RunState } from './util';
import { actions } from './actions';

const TOOL_NAMES: Record<string, string> = {
  claude: 'Claude Code', codex: 'Codex', grok: 'Grok Build', kimi: 'Kimi Code', omp: 'Oh My Pi', hermes: 'Hermes Agent',
};
const AUTH_NAMES: Record<string, string> = {
  token: 'API token', subscription: 'Subscription (interactive login)', bedrock: 'Bedrock (AWS)', local: 'Local model',
};
const GUARD_NAMES: Record<string, string> = {
  off: 'Off', promptOnWrite: 'Prompt before write', destructive: 'Block destructive', readOnly: 'Read-only',
};

const STATE_LABEL: Record<RunState, string> = { running: 'Running', booting: 'Booting', suspended: 'Suspended', off: 'Off' };
const STATE_COLOR: Record<RunState, string> = { running: 'var(--green)', booting: 'var(--orange)', suspended: 'var(--blue)', off: 'var(--label-tertiary)' };

interface ListeningPort { proto: string; addr: string; port: number; process: string }

export function VMDashboard({ host, ws, vm, state }: { host: RemoteHost; ws: Workspace; vm?: VMInfo; state: RunState }) {
  const running = isUp(state);
  const accent = accentOf(ws);
  const tip = useTooltip();
  const [confirm, setConfirm] = useState<null | { force: boolean }>(null);

  // The full document carries what /state leaves out (guardrails, folders,
  // prompt-injection) — read once per workspace, refreshed on save.
  const [full, setFull] = useState<any>(null);
  useEffect(() => {
    let live = true;
    setFull(null);
    host.request('GET', `/profiles/${seg(ws.id)}?full=1`, undefined, { allowError: true })
      .then(d => { if (live && d && !d.error) setFull(d); }).catch(() => {});
    return () => { live = false; };
  }, [host, ws.id]);

  const cpuHist = useHistory(() => (running ? (vm?.cpu as number) ?? 0 : 0), 1500, ws.id + state);
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 1500); return () => clearInterval(t); }, []);

  const vCPUs = (vm?.cpuCount as number) ?? ws.cpuCount ?? 0;
  const memGB = ws.memoryGB ?? (vm?.memoryGB as number) ?? 0;
  const diskAlloc = (ws.diskAllocatedBytes as number) ?? (vm?.diskAllocatedBytes as number) ?? 0;
  const diskCap = (ws.diskCapacityBytes as number) ?? 0;
  const bootedAt = vm?.bootedAt as number | undefined;   // seconds since 1970
  const uptimeText = (() => {
    const secs = bootedAt ? Math.max(0, Math.floor(now / 1000 - bootedAt)) : vm?.uptimeSeconds;
    if (secs == null) return '—';
    const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60);
    return h > 0 ? `${h}h ${m}m` : m > 0 ? `${m}m` : `${secs}s`;
  })();
  const stateCaption = state;

  // ── config rows (one per configured tool, then guardrails / PI / folders)
  const configRows = useMemo(() => {
    const specs: { tool: string; authMode: string; localModelID?: string }[] = [
      { tool: ws.tool, authMode: (ws.authMode as string) ?? 'subscription', localModelID: ws.localModelID as string | undefined },
      ...(((ws.additionalTools as any[]) ?? []).map(t => ({ tool: t.tool, authMode: t.authMode ?? 'subscription', localModelID: t.localModelID }))),
    ];
    const rows = specs.map(s => ({
      icon: s.authMode === 'local' ? 'cpu' : 'cloud',
      label: TOOL_NAMES[s.tool] ?? s.tool,
      value: s.authMode === 'local' ? `On-device · ${s.localModelID ?? 'local model'}` : `Cloud · ${AUTH_NAMES[s.authMode] ?? s.authMode}`,
    }));
    const g = full?.guardrails ?? {};
    const modes = ['kubernetes', 'aws', 'digitalOcean', 'docker', 'github', 'gitlab', 'bitbucket'].map(k => g[k] ?? 'promptOnWrite');
    const active = modes.filter(m => m !== 'off');
    const names = new Set(active.map(m => GUARD_NAMES[m] ?? m));
    rows.push({ icon: 'shield.lefthalf.filled', label: 'Guardrails',
      value: active.length === 0 ? 'Off' : names.size === 1 ? [...names][0] : `Custom (${active.length} domains)` });
    const pi = full?.promptInjection ?? {};
    rows.push({ icon: 'lock.shield', label: 'Prompt-injection scan', value: pi.detectSourceInjection || pi.detectRulesInjection ? 'On' : 'Off' });
    const folders: string[] = full?.folderPaths ?? [];
    rows.push({ icon: 'folder.fill', label: 'Shared folders', value: folders.length ? folders.map(p => p.replace(/\/+$/, '').split('/').pop()).join(', ') : 'None' });
    return rows;
  }, [ws, full]);

  // ── listening ports: externally reachable, deduped across v4/v6
  const ports = useMemo(() => {
    const by = new Map<string, ListeningPort>();
    for (const p of ((vm?.listeningPorts as ListeningPort[]) ?? [])) {
      if (isLoopback(p.addr)) continue;
      const key = `${p.port}/${p.proto}`;
      const ex = by.get(key);
      if (ex && ex.process) continue;
      by.set(key, p);
    }
    return [...by.values()].sort((a, b) => a.port - b.port || a.proto.localeCompare(b.proto));
  }, [vm?.listeningPorts]);
  const endpoint = (p: ListeningPort) => `${p.addr === '0.0.0.0' || p.addr === '[::]' || p.addr === '::' ? (vm?.ip ?? p.addr) : p.addr}:${p.port}`;
  const [copied, setCopied] = useState<string | null>(null);
  const copy = (t: string) => { copyText(t); setCopied(t); setTimeout(() => setCopied(c => (c === t ? null : c)), 1200); };

  const a = actions(host);
  return (
    <div className="mc-stage">
      <div className="mc-scroll">
        <div className="mc-pad">
          {/* header */}
          <div className="mc-vm-head">
            <div className="mc-vm-badge" style={{ background: `linear-gradient(135deg, ${accent}, color-mix(in srgb, ${accent} 60%, transparent))`, boxShadow: `0 2px 5px color-mix(in srgb, ${accent} 35%, transparent)` }}>
              <SF name="server.rack" size={19} weight={500} color="#fff" />
            </div>
            <div className="mc-col" style={{ gap: 3, minWidth: 0 }}>
              <div className="mc-vm-name">{ws.name}</div>
              <div className="mc-row" style={{ gap: 8 }}>
                <Pill color={STATE_COLOR[state]} dot={7}>{STATE_LABEL[state]}</Pill>
                {vm?.ip && running && (
                  <span className="mc-row mc-secondary" style={{ gap: 4, fontFamily: 'var(--font-mono)', fontSize: 11 }}>
                    <SF name="network" size={11} />{vm.ip}
                  </span>
                )}
              </div>
            </div>
            <span className="mc-spacer" style={{ flex: '1 0 0' }} />
            <div className="mc-actions">
              {running ? <>
                <Button variant="prominent" icon="plus" onClick={() => a.newTab(ws.id)}>New Terminal</Button>
                <span {...tip.bind('Save the VM\'s state to disk')}>
                  <Button className="mc-btn-bordered" icon="pause.fill" onClick={() => a.suspend(ws.id)}>Suspend</Button>
                </span>
                <Button className="mc-btn-bordered" icon="arrow.clockwise" onClick={e => setConfirm({ force: e.altKey })}>Reboot</Button>
                <Button className="mc-btn-bordered mc-destructive-btn" icon="power" onClick={() => a.shutdown(ws.id)}>Shut Down</Button>
              </> : (
                <Button variant="prominent" icon="play.fill" onClick={() => a.start(ws.id)}>{state === 'suspended' ? 'Resume' : 'Start'}</Button>
              )}
            </div>
          </div>

          {/* vitals */}
          <div className="mc-stats">
            {running
              ? <CPUStatCard value={(vm?.cpu as number) ?? 0} history={cpuHist} tint={accent} />
              : <StatCard title="CPU" value="—" caption={stateCaption} icon="cpu" tint={accent} />}
            {running
              ? <StatCard title="Memory" value={gbKB((vm?.memUsedKB as number) ?? 0)} caption={`of ${memGB} GB`} icon="memorychip" tint="var(--purple)" />
              : <StatCard title="Memory" value={`${memGB} GB`} caption="allocated" icon="memorychip" tint="var(--purple)" />}
            <StatCard title="vCPUs" value={`${vCPUs}`} caption={running ? `load ${((vm?.load as number) ?? 0).toFixed(2)}` : 'cores'} icon="cpu" tint="var(--blue)" />
            {running && vm && (vm.diskTotalKB ?? 0) > 0
              ? <StatCard title="Disk" value={gbKB(vm.diskUsedKB ?? 0)} caption={`of ${gbKB(vm.diskTotalKB ?? 0)}`} icon="internaldrive" tint="var(--teal)" />
              : <StatCard title="Disk" value={gbBytes(diskAlloc)} caption={`of ${gbBytes(diskCap)} (host)`} icon="internaldrive" tint="var(--teal)" />}
            <StatCard title="Uptime" value={running ? uptimeText : '—'} caption={running ? 'since boot' : stateCaption} icon="clock" tint="var(--orange)" />
          </div>

          {/* configuration */}
          <div className="mc-card">
            <CardTitle>Configuration</CardTitle>
            {configRows.map((r, i) => (
              <React.Fragment key={i}>
                {i > 0 && <div className="mc-row-sep" />}
                <div className="mc-cfg-row">
                  <span style={{ width: 18, display: 'grid', placeItems: 'center' }} className="mc-secondary"><SF name={r.icon} size={12} /></span>
                  <span className="mc-secondary">{r.label}</span>
                  <span className="mc-spacer" />
                  <span className="mc-ellipsis" style={{ fontWeight: 500 }}>{r.value}</span>
                </div>
              </React.Fragment>
            ))}
          </div>

          {/* listening ports */}
          {running && ports.length > 0 && (
            <div className="mc-card">
              <CardTitle>Listening Ports</CardTitle>
              {ports.map((p, i) => {
                const ep = endpoint(p);
                return (
                  <React.Fragment key={ep + p.proto}>
                    {i > 0 && <div className="mc-row-sep" />}
                    <div className="mc-port">
                      <span className="selectable" style={{ fontFamily: 'var(--font-mono)', fontSize: 12, fontWeight: 500 }}>{ep}</span>
                      <button className="mc-icon-btn" title={`Copy ${ep}`} onClick={() => copy(ep)}>
                        <SF name={copied === ep ? 'checkmark' : 'doc.on.doc'} size={10} color={copied === ep ? 'var(--green)' : undefined} />
                      </button>
                      {p.proto === 'udp' && <span className="mc-tag mc-secondary" style={{ background: 'color-mix(in srgb, var(--gray) 15%, transparent)' }}>udp</span>}
                      <span className="mc-spacer" style={{ minWidth: 12 }} />
                      <span className="mc-secondary mc-ellipsis" style={{ fontSize: 12 }}>{p.process || '—'}</span>
                    </div>
                  </React.Fragment>
                );
              })}
            </div>
          )}

          <NotesCard host={host} ws={ws} onSaved={d => setFull((f: any) => (f ? { ...f, comments: d } : f))} />
        </div>
      </div>
      {confirm && (
        <Confirm
          title={confirm.force ? `Force reboot “${ws.name}”?` : `Reboot “${ws.name}”?`}
          message={confirm.force
            ? 'Cuts the machine\'s power at once and boots it fresh, like pulling the plug: anything unsaved inside it is lost. For a machine that doesn\'t respond.'
            : 'Shuts the machine down cleanly and boots it fresh. Everything running inside it stops. (Hold ⌥ while choosing Reboot to force it.)'}
          confirm={confirm.force ? 'Force Reboot' : 'Reboot'}
          onConfirm={() => { a.reboot(ws.id, confirm.force); setConfirm(null); }}
          onCancel={() => setConfirm(null)} />
      )}
      {tip.node}
    </div>
  );
}

function isLoopback(addr: string) {
  return addr.startsWith('127.') || addr === '::1' || addr === '[::1]' || addr === 'localhost';
}

/** The notes, edited in place as markdown: Return saves, Shift-Return adds
 *  a line, Esc cancels; focus leaving saves (only while still the stored
 *  notes — `_commentsIfStill`). */
function NotesCard({ host, ws, onSaved }: { host: RemoteHost; ws: Workspace; onSaved: (t: string) => void }) {
  const stored = (ws.comments as string) ?? '';
  const [draft, setDraft] = useState<string | null>(null);
  const [base, setBase] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const ta = useRef<HTMLTextAreaElement>(null);
  const text = saved ?? stored;
  useEffect(() => { setSaved(null); if (draft !== null && draft === base) { setDraft(stored); setBase(stored); } }, [stored]); // eslint-disable-line
  useEffect(() => { if (draft !== null && ta.current) { ta.current.style.height = '0'; ta.current.style.height = ta.current.scrollHeight + 'px'; } }, [draft]);

  const begin = () => { setDraft(text); setBase(text); setTimeout(() => ta.current?.focus(), 0); };
  const commit = (implicit = false) => {
    if (draft === null) return;
    let t = draft;
    setDraft(null);
    if (implicit && base !== text) return;
    t = t.replace(/\s+$/, '');
    if (t === text) return;
    setSaved(t);
    const doc: any = { comments: t };
    if (implicit && base !== null) doc._commentsIfStill = base;
    host.request('PUT', `/profiles/${seg(ws.id)}`, doc, { allowError: true }).then(r => {
      if (r?.commentsSuperseded) { setSaved(r.comments ?? null); return; }
      if (r?.ok) { onSaved(t); host.refreshSoon(); return; }
      setSaved(null); setDraft(t); setBase(text);
    }).catch(() => { setSaved(null); setDraft(t); setBase(text); });
  };
  const editing = draft !== null;
  return (
    <div className="mc-card mc-notes">
      <div className="mc-row">
        <span style={{ fontSize: 12, fontWeight: 600, textTransform: 'uppercase', letterSpacing: 0.6 }} className="mc-secondary">Notes</span>
        <span className="mc-spacer" />
        <Button variant="borderless" size="small" icon={editing ? 'checkmark' : 'pencil'}
                title={editing ? 'Save the notes (Return)' : 'Edit the notes as markdown'}
                onMouseDown={e => e.preventDefault()}
                onClick={() => (editing ? commit() : begin())}>{editing ? 'Save' : 'Edit'}</Button>
      </div>
      {editing ? <>
        <textarea ref={ta} value={draft!} placeholder="Add a note about this workspace" rows={1}
                  onChange={e => setDraft(e.target.value)}
                  onBlur={() => commit(true)}
                  onKeyDown={e => {
                    if (e.key === 'Escape') { e.preventDefault(); setDraft(null); }
                    else if (e.key === 'Enter' && !e.shiftKey && !e.altKey) { e.preventDefault(); commit(); }
                  }} />
        <div className="mc-tertiary" style={{ fontSize: 10 }}>Return saves · Shift-Return adds a line · Esc cancels</div>
      </> : text.trim()
        ? <Markdown text={text} />
        : <div className="mc-tertiary" style={{ fontSize: 13 }}>(empty)</div>}
    </div>
  );
}
