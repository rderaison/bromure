// DockerDashboard.swift: containers / images / volumes in a running
// workspace, from the mirrored /state (vms[].docker*); verbs ride
// POST /vms/<id>/docker. Opening turns on the guest's gated stats polling.

import React, { useEffect, useMemo, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import type { VMInfo, Workspace } from '../../core/remote/types';
import { Button, Checkbox, Sheet, TextField, useMenu, cx } from '../../ui/kit';
import { StatCard, CPUStatCard, useHistory, EmptyState, SegPicker, SmallSearch, Confirm, Pill, SF } from './parts';
import { actions } from './actions';

const DOCKER_BLUE = '#2496ED';

interface Container { id: string; name: string; image: string; status: string; state: string; ports: string; runningFor: string; mounts: string; cpuPerc: string; memUsage: string; arch: string }
interface Image { id: string; repository: string; tag: string; size: string; created: string }
interface Volume { name: string; driver: string; mountpoint: string; createdAt: string; size: string }

const dname = (c: Container) => c.name || c.id.slice(0, 12);
const cpuValue = (c: Container) => { const v = parseFloat(c.cpuPerc.replace('%', '')); return Number.isFinite(v) ? v : null; };
const mountList = (c: Container) => c.mounts.split(',').map(s => s.trim()).filter(Boolean);

function publishedPorts(raw: string): string[] {
  const seen = new Set<string>(), out: string[] = [];
  for (const seg of raw.split(',')) {
    const s = seg.trim();
    const i = s.indexOf('->');
    if (i < 0) continue;
    const host = s.slice(0, i).split(':').pop() ?? s.slice(0, i);
    let cont = s.slice(i + 2);
    const sl = cont.indexOf('/'); if (sl >= 0) cont = cont.slice(0, sl);
    const label = `${host}→${cont}`;
    if (!seen.has(label)) { seen.add(label); out.push(label); }
  }
  return out;
}
const humanStarted = (s: string) => s.replace(/ ago$/, '');
function usedMemoryBytes(s: string): number | null {
  const used = (s.split('/')[0] ?? s).trim();
  const units: [string, number][] = [['GiB', 1073741824], ['MiB', 1048576], ['KiB', 1024], ['GB', 1e9], ['MB', 1e6], ['kB', 1e3], ['B', 1]];
  for (const [suf, mult] of units) if (used.endsWith(suf)) { const v = parseFloat(used.slice(0, -suf.length)); if (Number.isFinite(v)) return v * mult; }
  return null;
}
function formatBytes(b: number) { if (b <= 0) return '0 MB'; if (b >= 1e9) return `${(b / 1e9).toFixed(1)} GB`; if (b >= 1e6) return `${(b / 1e6).toFixed(0)} MB`; return `${(b / 1e3).toFixed(0)} KB`; }
const friendlyArch = (q: string) => ({ x86_64: 'amd64', i386: '386', aarch64: 'arm64' } as Record<string, string>)[q] ?? q;
const archIsEmulated = (a: string) => { const base = a.split('/')[0] || a; return !!base && base !== 'arm64' && base !== 'aarch64'; };
const stateColor = (s: string) => s === 'running' ? 'var(--green)' : s === 'paused' ? 'var(--orange)' : s === 'created' ? 'var(--blue)' : 'var(--label-tertiary)';
function humanVolumeCreated(iso: string) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const s = Math.round((Date.now() - d.getTime()) / 1000);
  const [n, u] = s < 60 ? [s, 'second'] : s < 3600 ? [Math.round(s / 60), 'minute'] : s < 86400 ? [Math.round(s / 3600), 'hour'] : s < 2592000 ? [Math.round(s / 86400), 'day'] : [Math.round(s / 2592000), 'month'];
  return `${n} ${u}${n === 1 ? '' : 's'} ago`;
}

type Pane = 'containers' | 'images' | 'volumes';

export function DockerDashboard({ host, ws, vm, initialContainer }: { host: RemoteHost; ws: Workspace; vm: VMInfo; initialContainer?: string }) {
  const a = actions(host);
  const id = ws.id;
  const containers: Container[] = useMemo(() => ((vm.dockerContainers as any[]) ?? []).map(d => ({
    id: d.id ?? '', name: d.name ?? '', image: d.image ?? '', status: d.status ?? '', state: d.state ?? '', ports: d.ports ?? '',
    runningFor: d.runningFor ?? '', mounts: d.mounts ?? '', cpuPerc: d.cpuPerc ?? '', memUsage: d.memUsage ?? '', arch: d.arch ?? '',
  })), [vm.dockerContainers]);
  const images: Image[] = useMemo(() => ((vm.dockerImages as any[]) ?? []).map(d => ({
    id: d.id ?? '', repository: d.repository ?? '<none>', tag: d.tag ?? '<none>', size: d.size ?? '', created: d.created ?? '' })), [vm.dockerImages]);
  const volumes: Volume[] = useMemo(() => ((vm.dockerVolumes as any[]) ?? []).map(d => ({
    name: d.name ?? '', driver: d.driver ?? '', mountpoint: d.mountpoint ?? '', createdAt: d.createdAt ?? '', size: d.size ?? '' })), [vm.dockerVolumes]);
  const arches: string[] = (vm.dockerBinfmt as string[]) ?? [];

  const [pane, setPane] = useState<Pane>('containers');
  const [query, setQuery] = useState('');
  const [showNew, setShowNew] = useState<string | null>(null);   // prefill image
  const [showNewVolume, setShowNewVolume] = useState(false);
  const [detailID, setDetailID] = useState<string | null>(initialContainer ?? null);
  const [deleteTarget, setDeleteTarget] = useState<Container | null>(null);
  const [deleteVolume, setDeleteVolume] = useState<Volume | null>(null);
  useEffect(() => { a.dockerWatch(id, true); return () => a.dockerWatch(id, false); }, [host, id]); // eslint-disable-line

  const runningList = containers.filter(c => c.state === 'running');
  const cpuTotal = runningList.reduce((s, c) => s + (cpuValue(c) ?? 0), 0);
  const memTotal = runningList.reduce((s, c) => s + (usedMemoryBytes(c.memUsage) ?? 0), 0);
  const cpuHist = useHistory(() => cpuTotal, 2000, pane);

  const q = query.trim().toLowerCase();
  const fContainers = !q ? containers : containers.filter(c => dname(c).toLowerCase().includes(q) || c.image.toLowerCase().includes(q) || c.id.slice(0, 12).includes(q));
  const fImages = !q ? images : images.filter(i => i.repository.toLowerCase().includes(q) || i.tag.toLowerCase().includes(q));
  const fVolumes = !q ? volumes : volumes.filter(v => v.name.toLowerCase().includes(q) || v.driver.toLowerCase().includes(q));
  const inUse = new Set(containers.map(c => c.image));
  const volumeUsers = useMemo(() => {
    const m = new Map<string, string[]>();
    for (const c of containers) for (const v of mountList(c)) m.set(v, [...(m.get(v) ?? []), dname(c)]);
    return m;
  }, [containers]);

  const detail = detailID ? containers.find(c => c.id === detailID) : undefined;

  return (
    <div className="mc-stage window">
      <div className="mc-dhead" style={{ flexDirection: 'row', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <div className="mc-badge" style={{ background: `color-mix(in srgb, ${DOCKER_BLUE} 15%, transparent)` }}><SF name="shippingbox" size={18} weight={600} color={DOCKER_BLUE} /></div>
        <div className="mc-col" style={{ gap: 1 }}>
          <span style={{ fontSize: 18, fontWeight: 600 }}>Docker</span>
          <span className="mc-secondary" style={{ fontSize: 11 }}>{runningList.length} running · {containers.length} total</span>
        </div>
        <span className="mc-spacer" />
        <EmulationControl arches={arches} probed={arches.length > 0}
                          onInstall={() => a.docker(id, { action: 'binfmt' })} onUninstall={() => a.docker(id, { action: 'binfmt-off' })} />
        <SmallSearch value={query} onChange={setQuery} width={200}
                     placeholder={pane === 'containers' ? 'Search containers' : pane === 'images' ? 'Search images' : 'Search volumes'} />
        <SegPicker value={pane} onChange={p => { setPane(p); setDetailID(null); }}
                   options={[{ value: 'containers', label: 'Containers' }, { value: 'images', label: 'Images' }, { value: 'volumes', label: 'Volumes' }]} />
        {pane === 'volumes'
          ? <Button variant="prominent" icon="plus" title="Create a named volume" onClick={() => setShowNewVolume(true)}>New Volume</Button>
          : <Button variant="prominent" icon="plus" title="Run a new container" onClick={() => setShowNew('')}>Run</Button>}
      </div>
      <div className="mc-divider" />

      {pane === 'containers' && (detail
        ? <ContainerDetail c={detail} onBack={() => setDetailID(null)}
                           onStart={() => a.docker(id, { action: 'start', container: detail.id })}
                           onStop={() => a.docker(id, { action: 'stop', container: detail.id })}
                           onDelete={() => setDeleteTarget(detail)}
                           onAttach={shell => a.docker(id, { action: 'attach', container: detail.id, shell })}
                           onLogs={() => a.docker(id, { action: 'logs', container: detail.id })} />
        : containers.length === 0
          ? <EmptyState icon="shippingbox" title="No containers yet" subtitle="Run one to get started — it lives only inside this disposable workspace."
                        action={{ label: 'Run a container', onClick: () => setShowNew('') }} />
          : <div className="mc-scroll"><div className="mc-pad">
              <div className="mc-stats">
                <StatCard title="Running" value={`${runningList.length}`} caption={`of ${containers.length}`} icon="play.circle.fill" tint="var(--green)" />
                <CPUStatCard value={cpuTotal} history={cpuHist} tint={DOCKER_BLUE} />
                <StatCard title="Memory" value={formatBytes(memTotal)} caption="in use" icon="memorychip" tint="var(--purple)" />
                <StatCard title="Images" value={`${images.length}`} caption="local" icon="square.stack.3d.up.fill" tint="var(--orange)" />
              </div>
              <div className="mc-card mc-table">
                <div className="mc-th">
                  <span style={{ width: 16 }} />
                  <span style={{ flex: 1, minWidth: 130 }}>Name</span><span style={{ flex: 1, minWidth: 120 }}>Image</span>
                  <span style={{ width: 96 }}>Status</span><span style={{ width: 130 }}>Ports</span>
                  <span style={{ width: 96 }}>Started</span><span style={{ width: 96 }}>CPU</span><span style={{ width: 104 }} />
                </div>
                {fContainers.map((c, i) => (
                  <React.Fragment key={c.id}>
                    {i > 0 && <div className="mc-row-sep" />}
                    <div className="mc-tr" onClick={() => setDetailID(c.id)}>
                      <span style={{ width: 16, display: 'grid', placeItems: 'center' }}><span className="dot" style={{ width: 8, height: 8, background: c.state === 'running' ? 'var(--green)' : 'var(--label-tertiary)' }} /></span>
                      <span className="mc-col" style={{ flex: 1, minWidth: 130, gap: 1 }}>
                        <span className="mc-ellipsis" style={{ fontSize: 13, fontWeight: 500 }}>{dname(c)}</span>
                        <span className="mc-row" style={{ gap: 5 }}>
                          <span className="mc-tertiary" style={{ fontFamily: 'var(--font-mono)', fontSize: 10 }}>{c.id.slice(0, 12)}</span>
                          {c.arch && <ArchBadge arch={c.arch} />}
                        </span>
                      </span>
                      <span className="mc-secondary mc-ellipsis" style={{ flex: 1, minWidth: 120, fontSize: 12 }}>{c.image}</span>
                      <span style={{ width: 96 }}><StatusPill c={c} /></span>
                      <span style={{ width: 130 }}><PortsCell ports={c.ports} /></span>
                      <span className="mc-secondary mc-ellipsis" style={{ width: 96, fontSize: 12 }}>{c.state === 'running' ? humanStarted(c.runningFor) : '—'}</span>
                      <span style={{ width: 96 }}><CPUCell c={c} /></span>
                      <span className="mc-row mc-row-actions" style={{ width: 104, justifyContent: 'flex-end', gap: 12 }} onClick={e => e.stopPropagation()}>
                        {c.state === 'running'
                          ? <button className="mc-icon-btn" title="Stop" style={{ color: 'var(--orange)' }} onClick={() => a.docker(id, { action: 'stop', container: c.id })}><SF name="stop.fill" size={12} /></button>
                          : <button className="mc-icon-btn" title="Start" style={{ color: 'var(--green)' }} onClick={() => a.docker(id, { action: 'start', container: c.id })}><SF name="play.fill" size={12} /></button>}
                        <button className="mc-icon-btn" title="View logs" onClick={() => a.docker(id, { action: 'logs', container: c.id })}><SF name="doc.plaintext" size={12} /></button>
                        <button className="mc-icon-btn" title="Delete" onClick={() => setDeleteTarget(c)}><SF name="trash" size={12} /></button>
                      </span>
                    </div>
                  </React.Fragment>
                ))}
              </div>
            </div></div>)}

      {pane === 'images' && (images.length === 0
        ? <EmptyState icon="square.stack.3d.up" title="No local images" subtitle="Images appear here after you run one. Any reference is pulled on first use." />
        : <div className="mc-scroll"><div className="mc-pad"><div className="mc-card mc-table">
            <div className="mc-th">
              <span style={{ flex: 1, minWidth: 150 }}>Repository</span><span style={{ width: 120 }}>Tag</span><span style={{ width: 110 }}>Image ID</span>
              <span style={{ width: 120 }}>Created</span><span style={{ width: 80, textAlign: 'right' }}>Size</span><span style={{ width: 44 }} />
            </div>
            {fImages.map((im, i) => {
              const ref = `${im.repository}:${im.tag}`;
              return (
                <React.Fragment key={im.id + i}>
                  {i > 0 && <div className="mc-row-sep" />}
                  <div className="mc-tr">
                    <span className="mc-row" style={{ flex: 1, minWidth: 150, gap: 6 }}>
                      <span className="mc-ellipsis" style={{ fontSize: 13, fontWeight: 500 }}>{im.repository}</span>
                      {(inUse.has(ref) || inUse.has(im.repository)) && <span className="mc-tag" style={{ color: 'var(--green)', background: 'color-mix(in srgb, var(--green) 16%, transparent)' }}>in use</span>}
                    </span>
                    <span className="mc-secondary mc-ellipsis" style={{ width: 120, fontSize: 12 }}>{im.tag}</span>
                    <span className="mc-tertiary" style={{ width: 110, fontSize: 11, fontFamily: 'var(--font-mono)' }}>{im.id.replace('sha256:', '').slice(0, 12)}</span>
                    <span className="mc-secondary mc-ellipsis" style={{ width: 120, fontSize: 12 }}>{im.created}</span>
                    <span className="mc-secondary mc-num" style={{ width: 80, fontSize: 12, textAlign: 'right' }}>{im.size}</span>
                    <span style={{ width: 44, textAlign: 'right' }}>
                      <button className="mc-icon-btn mc-row-actions" title="Run a container from this image" onClick={() => setShowNew(ref)}><SF name="play.fill" size={12} /></button>
                    </span>
                  </div>
                </React.Fragment>
              );
            })}
          </div></div></div>)}

      {pane === 'volumes' && (volumes.length === 0
        ? <EmptyState icon="externaldrive" title="No volumes yet" subtitle="Named volumes hold data that outlives any single container — databases, caches, build artifacts."
                      action={{ label: 'New volume', onClick: () => setShowNewVolume(true) }} />
        : <div className="mc-scroll"><div className="mc-pad"><div className="mc-card mc-table">
            <div className="mc-th">
              <span style={{ flex: 1, minWidth: 150 }}>Name</span><span style={{ width: 70 }}>Driver</span><span style={{ width: 110 }}>Created</span>
              <span style={{ width: 80, textAlign: 'right' }}>Size</span><span style={{ width: 44 }} />
            </div>
            {fVolumes.map((v, i) => {
              const users = volumeUsers.get(v.name) ?? [];
              return (
                <React.Fragment key={v.name}>
                  {i > 0 && <div className="mc-row-sep" />}
                  <div className="mc-tr">
                    <span className="mc-col" style={{ flex: 1, minWidth: 150, gap: 1 }}>
                      <span className="mc-row" style={{ gap: 6 }}>
                        <span className="mc-ellipsis" style={{ fontSize: 13, fontWeight: 500 }}>{v.name}</span>
                        {users.length > 0 && <span className="mc-tag" title={`Mounted by ${users.join(', ')}`} style={{ color: 'var(--green)', background: 'color-mix(in srgb, var(--green) 16%, transparent)' }}>in use</span>}
                      </span>
                      <span className="mc-tertiary mc-ellipsis" title={v.mountpoint} style={{ fontSize: 10, fontFamily: 'var(--font-mono)' }}>{v.mountpoint}</span>
                    </span>
                    <span className="mc-secondary" style={{ width: 70, fontSize: 12 }}>{v.driver || '—'}</span>
                    <span className="mc-secondary mc-ellipsis" style={{ width: 110, fontSize: 12 }}>{humanVolumeCreated(v.createdAt)}</span>
                    <span className="mc-secondary mc-num" style={{ width: 80, fontSize: 12, textAlign: 'right' }}>{!v.size || v.size === 'N/A' ? '—' : v.size}</span>
                    <span style={{ width: 44, textAlign: 'right' }}>
                      <button className="mc-icon-btn mc-row-actions" title="Delete volume" onClick={() => setDeleteVolume(v)}><SF name="trash" size={12} /></button>
                    </span>
                  </div>
                </React.Fragment>
              );
            })}
          </div></div></div>)}

      {showNew !== null && <NewContainerSheet images={images} prefill={showNew} onCancel={() => setShowNew(null)}
                                              onRun={spec => { a.docker(id, { action: 'run', ...spec }); setShowNew(null); }} />}
      {showNewVolume && <NewVolumeSheet onCancel={() => setShowNewVolume(false)}
                                        onCreate={name => { a.docker(id, { action: 'volume-create', volume: name }); setShowNewVolume(false); }} />}
      {deleteTarget && <Confirm title="Delete container?" message="This force-removes the container (docker rm -f). This can't be undone."
                                confirm={`Delete ${dname(deleteTarget)}`} destructive
                                onConfirm={() => { a.docker(id, { action: 'remove', container: deleteTarget.id }); if (detailID === deleteTarget.id) setDetailID(null); setDeleteTarget(null); }}
                                onCancel={() => setDeleteTarget(null)} />}
      {deleteVolume && <Confirm title="Delete volume?" destructive confirm={`Delete ${deleteVolume.name}`}
                                message={(volumeUsers.get(deleteVolume.name) ?? []).length
                                  ? `This volume is mounted by ${(volumeUsers.get(deleteVolume.name) ?? []).join(', ')} — docker will refuse to delete it until those containers are removed.`
                                  : 'This permanently deletes the volume and its data (docker volume rm). This can\'t be undone.'}
                                onConfirm={() => { a.docker(id, { action: 'volume-remove', volume: deleteVolume.name }); setDeleteVolume(null); }}
                                onCancel={() => setDeleteVolume(null)} />}
    </div>
  );
}

function StatusPill({ c }: { c: Container }) {
  const label = c.state ? c.state[0].toUpperCase() + c.state.slice(1) : '—';
  return <Pill color={stateColor(c.state)} title={c.status} style={{ padding: '2px 8px' }}>{label}</Pill>;
}
function PortsCell({ ports }: { ports: string }) {
  const m = publishedPorts(ports);
  if (!m.length) return <span className="mc-tertiary">—</span>;
  return (
    <span className="mc-row" style={{ gap: 4 }} title={m.join(', ')}>
      {m.slice(0, 2).map(p => <span key={p} className="mc-secondary" style={{ fontFamily: 'var(--font-mono)', fontSize: 10, padding: '1px 5px', borderRadius: 4, background: 'rgba(var(--mc-ink-rgb), 0.07)' }}>{p}</span>)}
      {m.length > 2 && <span className="mc-tertiary" style={{ fontSize: 10 }}>+{m.length - 2}</span>}
    </span>
  );
}
function CPUCell({ c }: { c: Container }) {
  if (c.state !== 'running') return <span className="mc-tertiary">—</span>;
  const v = cpuValue(c);
  if (v == null) return <span className="mc-tertiary">…</span>;
  return (
    <span className="mc-col" style={{ gap: 2 }}>
      <span className="mc-secondary" style={{ fontFamily: 'var(--font-mono)', fontSize: 11 }}>{c.cpuPerc}</span>
      <span style={{ width: 64, height: 4, borderRadius: 2, background: 'rgba(var(--mc-ink-rgb), 0.1)', overflow: 'hidden' }}>
        <span style={{ display: 'block', height: '100%', width: `${Math.min(100, Math.max(0, v))}%`, background: v > 80 ? 'var(--red)' : v > 40 ? 'var(--orange)' : 'var(--green)' }} />
      </span>
    </span>
  );
}
function ArchBadge({ arch }: { arch: string }) {
  const em = archIsEmulated(arch);
  const color = em ? 'var(--purple)' : 'var(--label-secondary)';
  return <span title={em ? 'Running under emulation' : 'Native architecture'}
               style={{ fontFamily: 'var(--font-mono)', fontSize: 9, fontWeight: 500, padding: '0 4px', borderRadius: 3, color, background: `color-mix(in srgb, ${em ? 'var(--purple)' : 'var(--gray)'} 16%, transparent)` }}>{arch}</span>;
}

function EmulationControl({ probed, arches, onInstall, onUninstall }: { probed: boolean; arches: string[]; onInstall: () => void; onUninstall: () => void }) {
  const [busy, setBusy] = useState(false);
  const menu = useMenu();
  useEffect(() => setBusy(false), [arches.length === 0]);
  if (!probed) return null;
  if (!arches.length) return (
    <Button className="mc-btn-bordered" icon="cpu" disabled={busy} title="Install QEMU binfmt handlers so this workspace can run other-arch images (amd64, etc.)"
            onClick={() => { setBusy(true); onInstall(); }}>{busy ? 'Enabling…' : 'Enable emulation'}</Button>
  );
  return (
    <button className="mc-pill" style={{ border: 'none', color: 'var(--green)', background: 'color-mix(in srgb, var(--green) 16%, transparent)', padding: '4px 9px', fontSize: 11 }}
            title={`Cross-arch emulation enabled: ${arches.map(friendlyArch).sort().join(', ')}`}
            onClick={e => menu(e.currentTarget.getBoundingClientRect(), [{ label: 'Disable emulation', destructive: true, action: () => { setBusy(true); onUninstall(); } }])}>
      <SF name="cpu" size={11} />{busy ? 'Disabling…' : 'Emulation'}<SF name="chevron.down" size={8} />
    </button>
  );
}

function ContainerDetail({ c, onBack, onStart, onStop, onDelete, onAttach, onLogs }: {
  c: Container; onBack: () => void; onStart: () => void; onStop: () => void; onDelete: () => void; onAttach: (shell: string) => void; onLogs: () => void;
}) {
  const [shell, setShell] = useState('sh');
  const color = stateColor(c.state);
  const ports = publishedPorts(c.ports);
  const rows: [string, string, boolean?][] = [
    ['Container ID', c.id, true], ['Image', c.image, true],
    ...(c.arch ? [['Architecture', c.arch + (archIsEmulated(c.arch) ? '  (emulated)' : ''), true] as [string, string, boolean]] : []),
    ['State', c.state ? c.state[0].toUpperCase() + c.state.slice(1) : ''], ['Status', c.status],
    ['Ports', ports.length ? ports.join(', ') : '—', true], ['Mounts', mountList(c).length ? mountList(c).join('\n') : '—', true],
    ...(c.state === 'running' ? [['Started', humanStarted(c.runningFor)], ['CPU', c.cpuPerc || '…', true], ['Memory', c.memUsage || '…', true]] as [string, string, boolean?][] : []),
  ];
  return (
    <div className="mc-col" style={{ flex: 1, minHeight: 0 }}>
      <div className="mc-row" style={{ padding: '12px 18px', gap: 12 }}>
        <Button variant="borderless" icon="chevron.left" style={{ color: 'var(--accent)' }} onClick={onBack}>Containers</Button>
        <span className="mc-spacer" />
        {c.state === 'running'
          ? <Button variant="borderless" icon="stop.fill" style={{ color: 'var(--orange)' }} onClick={onStop}>Stop</Button>
          : <Button variant="borderless" icon="play.fill" style={{ color: 'var(--green)' }} onClick={onStart}>Start</Button>}
        <Button variant="borderless" icon="trash" style={{ color: 'var(--red)' }} onClick={onDelete}>Delete</Button>
      </div>
      <div className="mc-divider" />
      <div className="mc-scroll">
        <div className="mc-col" style={{ padding: 24, gap: 24, maxWidth: 560, margin: '0 auto', alignItems: 'center' }}>
          <div className="mc-col" style={{ gap: 8, alignItems: 'center', paddingTop: 8 }}>
            <div style={{ width: 64, height: 64, borderRadius: 16, display: 'grid', placeItems: 'center', background: `color-mix(in srgb, ${color} 14%, transparent)` }}><SF name="shippingbox" size={30} color={color} /></div>
            <div style={{ fontSize: 22, fontWeight: 600 }}>{dname(c)}</div>
            <div className="mc-secondary" style={{ fontFamily: 'var(--font-mono)', fontSize: 12 }}>{c.image}</div>
            <Pill color={color} size={12} style={{ padding: '3px 10px' }}>{c.status}</Pill>
          </div>
          <div className="mc-col" style={{ gap: 10, alignItems: 'center' }}>
            {c.state === 'running' ? <>
              <div className="mc-row" style={{ gap: 8 }}>
                <span className="mc-secondary" style={{ fontSize: 12 }}>Shell</span>
                <TextField mono value={shell} placeholder="sh" style={{ width: 160 }} onChange={e => setShell(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') onAttach(shell); }} />
              </div>
              <Button variant="prominent" size="large" icon="terminal" style={{ minWidth: 182, justifyContent: 'center' }} onClick={() => onAttach(shell)}>Attach</Button>
            </> : <Button variant="prominent" size="large" icon="play.fill" style={{ minWidth: 182, justifyContent: 'center' }} onClick={onStart}>Start container</Button>}
            <Button size="large" className="mc-btn-bordered" icon="doc.plaintext" style={{ minWidth: 182, justifyContent: 'center' }} onClick={onLogs}>Logs</Button>
          </div>
          <div className="mc-card" style={{ width: '100%' }}>
            {rows.map(([k, v, mono], i) => (
              <React.Fragment key={k}>
                {i > 0 && <div className="mc-divider faint" />}
                <div className="mc-row" style={{ alignItems: 'flex-start', gap: 12, padding: '10px 14px', fontSize: 12 }}>
                  <span className="mc-secondary" style={{ width: 110, flexShrink: 0 }}>{k}</span>
                  <span className="selectable" style={{ flex: 1, minWidth: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-all', fontFamily: mono ? 'var(--font-mono)' : undefined }}>{v}</span>
                </div>
              </React.Fragment>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

interface KV { a: string; b: string }
function NewContainerSheet({ images, prefill, onRun, onCancel }: {
  images: Image[]; prefill: string; onRun: (spec: Record<string, unknown>) => void; onCancel: () => void;
}) {
  const [image, setImage] = useState(prefill);
  const [name, setName] = useState('');
  const [ports, setPorts] = useState<KV[]>([]);
  const [envs, setEnvs] = useState<KV[]>([]);
  const [vols, setVols] = useState<KV[]>([]);
  const [inheritEnv, setInheritEnv] = useState(true);
  const [inheritProxy, setInheritProxy] = useState(true);
  const [interactive, setInteractive] = useState(false);
  const [advanced, setAdvanced] = useState(false);
  const refs = [...new Set(images.map(i => `${i.repository}:${i.tag}`))].sort();
  const canRun = !!image.trim();
  const join = (rows: KV[], sep: string) => rows.map(r => [r.a.trim(), r.b.trim()] as const).filter(([x]) => x).map(([x, y]) => (y ? `${x}${sep}${y}` : x));
  const run = () => canRun && onRun({ image: image.trim(), name: name.trim(), ports: join(ports, ':'), env: join(envs, '='), volumes: join(vols, ':'), inheritEnv, inheritProxy, interactive });
  const label = (t: string) => <div className="mc-secondary" style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: 0.5 }}>{t}</div>;
  const kv = (title: string, rows: KV[], set: (r: KV[]) => void, ap: string, bp: string, sep: string, add: string) => (
    <div className="mc-col" style={{ gap: 6 }}>
      <div style={{ fontSize: 12, fontWeight: 500 }}>{title}</div>
      {rows.map((r, i) => (
        <div key={i} className="mc-row" style={{ gap: 6 }}>
          <TextField mono placeholder={ap} value={r.a} onChange={e => set(rows.map((x, j) => (j === i ? { ...x, a: e.target.value } : x)))} style={{ flex: 1 }} />
          <span className="mc-tertiary">{sep}</span>
          <TextField mono placeholder={bp} value={r.b} onChange={e => set(rows.map((x, j) => (j === i ? { ...x, b: e.target.value } : x)))} style={{ flex: 1 }} />
          <button className="mc-icon-btn mc-tertiary" onClick={() => set(rows.filter((_, j) => j !== i))}><SF name="minus.circle" size={13} /></button>
        </div>
      ))}
      <Button variant="borderless" size="small" icon="plus.circle" style={{ color: 'var(--accent)', alignSelf: 'flex-start' }} onClick={() => set([...rows, { a: '', b: '' }])}>{add}</Button>
    </div>
  );
  return (
    <Sheet width={480} height={460} onClose={onCancel}>
      <div className="mc-sheet" style={{ height: '100%' }}>
        <div className="mc-row" style={{ gap: 10, padding: '18px 20px 12px' }}>
          <SF name="shippingbox.fill" size={15} color={DOCKER_BLUE} /><span style={{ fontSize: 15, fontWeight: 600 }}>Run a new container</span>
        </div>
        <div className="mc-divider" />
        <div className="mc-scroll"><div className="mc-col" style={{ padding: 20, gap: 18 }}>
          <div className="mc-col" style={{ gap: 8 }}>
            {label('Image')}
            <TextField autoFocus placeholder="Search or paste an image reference" value={image} onChange={e => setImage(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') run(); }} />
            {refs.length > 0 && <div className="mc-row" style={{ gap: 6, overflowX: 'auto', padding: '1px 0' }}>
              {refs.map(r => <button key={r} onClick={() => setImage(r)} style={{ border: 'none', fontFamily: 'var(--font-mono)', fontSize: 11, padding: '4px 8px', borderRadius: 999, whiteSpace: 'nowrap',
                color: image === r ? DOCKER_BLUE : 'var(--label-secondary)', background: image === r ? `color-mix(in srgb, ${DOCKER_BLUE} 18%, transparent)` : 'rgba(var(--mc-ink-rgb), 0.06)' }}>{r}</button>)}
            </div>}
          </div>
          <div className="mc-col" style={{ gap: 8 }}>
            {label('Name')}
            <TextField placeholder="Leave blank to auto-generate" value={name} onChange={e => setName(e.target.value)} />
          </div>
          <div className="mc-col" style={{ gap: 8 }}>
            {label('Environment')}
            <Checkbox checked={inheritEnv} onChange={setInheritEnv}><span className="mc-col"><span>Inherit workspace environment</span><span className="mc-secondary" style={{ fontSize: 11 }}>Pass the workspace's variables (API tokens, etc.) into the container.</span></span></Checkbox>
            <Checkbox checked={inheritProxy} onChange={setInheritProxy}><span className="mc-col"><span>Inherit HTTP proxy settings</span><span className="mc-secondary" style={{ fontSize: 11 }}>http_proxy / https_proxy / no_proxy.</span></span></Checkbox>
            <Checkbox checked={interactive} onChange={setInteractive}><span className="mc-col"><span>Run interactively</span><span className="mc-secondary" style={{ fontSize: 11 }}>Allocate a TTY (-it) and open it in a new tab — for images that drop into a shell/REPL (e.g. gdb).</span></span></Checkbox>
          </div>
          <div className="mc-col" style={{ gap: 8 }}>
            <span className="mc-row mc-secondary" style={{ gap: 6, fontSize: 12, fontWeight: 500 }} onClick={() => setAdvanced(v => !v)}>
              <SF name={advanced ? 'chevron.down' : 'chevron.right'} size={9} weight={700} />Advanced options
            </span>
            {advanced && <div className="mc-col" style={{ gap: 16, paddingTop: 8 }}>
              {kv('Port mappings', ports, setPorts, 'host', 'container', '→', 'Add port')}
              {kv('Environment variables', envs, setEnvs, 'KEY', 'value', '=', 'Add variable')}
              {kv('Volumes', vols, setVols, 'volume or host path', 'container path', '→', 'Add volume')}
            </div>}
          </div>
        </div></div>
        <div className="mc-divider" />
        <div className="mc-row" style={{ gap: 8, padding: '14px 20px', justifyContent: 'flex-end' }}>
          <Button onClick={onCancel}>Cancel</Button>
          <Button variant="prominent" disabled={!canRun} onClick={run}>Run</Button>
        </div>
      </div>
    </Sheet>
  );
}

function NewVolumeSheet({ onCreate, onCancel }: { onCreate: (name: string) => void; onCancel: () => void }) {
  const [name, setName] = useState('');
  const t = name.trim();
  const ok = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(t);
  return (
    <Sheet width={380} onClose={onCancel}>
      <div className="mc-sheet">
        <div className="mc-row" style={{ gap: 10, padding: '18px 20px 12px' }}>
          <SF name="externaldrive.fill.badge.plus" size={15} color={DOCKER_BLUE} /><span style={{ fontSize: 15, fontWeight: 600 }}>New volume</span>
        </div>
        <div className="mc-divider" />
        <div className="mc-col" style={{ padding: 20, gap: 8 }}>
          <div className="mc-secondary" style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: 0.5 }}>Name</div>
          <TextField mono autoFocus placeholder="e.g. pgdata" value={name} onChange={e => setName(e.target.value)} onKeyDown={e => { if (e.key === 'Enter' && ok) onCreate(t); }} />
          <div className="mc-secondary" style={{ fontSize: 11 }}>Letters and digits, then _ . - too. Mount it in a container as name → path.</div>
        </div>
        <div className="mc-divider" />
        <div className={cx('mc-row')} style={{ gap: 8, padding: '14px 20px', justifyContent: 'flex-end' }}>
          <Button onClick={onCancel}>Cancel</Button>
          <Button variant="prominent" disabled={!ok} onClick={() => onCreate(t)}>Create</Button>
        </div>
      </div>
    </Sheet>
  );
}
