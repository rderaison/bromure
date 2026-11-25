// The Machines overview: every machine on the host at a glance — workspace
// VMs (run state, vitals, start / open), Kubernetes clusters and container
// registries, plus native Macs waiting to join the fleet. Stands in for the
// native Grid stage (live terminal tiles) when no grid surface is mounted.

import React from 'react';
import { useHostCtx } from '../../app/hostContext';
import { useRemote } from '../../app/store';
import { Button } from '../../ui/kit';
import { Pill, SF } from './parts';
import { actions } from './actions';
import { PhasePill, KUBE_BLUE, REGISTRY_TINT, useKube } from './KubeDashboard';
import { accentOf, gbKB, isUp, runState, vmFor, type RunState } from './util';
import { openMachinesSurface } from './events';

const STATE_LABEL: Record<RunState, string> = { running: 'Running', booting: 'Booting', suspended: 'Suspended', off: 'Off' };
const STATE_COLOR: Record<RunState, string> = { running: 'var(--green)', booting: 'var(--orange)', suspended: 'var(--blue)', off: 'var(--label-tertiary)' };

export function MachinesOverview() {
  const { host, select } = useHostCtx();
  const state = useRemote(host, s => s) ?? null;
  const workspaces = state?.workspaces ?? [];
  const kube = useKube(state);
  const pending = ((state?.pendingMachines as any[]) ?? []).filter(m => m?.id);
  const a = actions(host);
  return (
    <div className="mc-stage">
      <div className="mc-scroll"><div className="mc-pad">
        <div className="mc-row" style={{ gap: 12 }}>
          <div className="mc-col" style={{ gap: 2 }}>
            <span style={{ fontSize: 20, fontWeight: 600 }}>Machines</span>
            <span className="mc-secondary" style={{ fontSize: 11 }}>
              {workspaces.filter(w => isUp(runState(w, vmFor(state, w.id)))).length} running · {workspaces.length + kube.clusters.length + kube.registries.length} total
            </span>
          </div>
          <span className="mc-spacer" />
          <Button className="mc-btn-bordered" icon="plus" onClick={() => openMachinesSurface('new-registry')}>Registry</Button>
          <Button className="mc-btn-bordered" icon="plus" onClick={() => openMachinesSurface('new-cluster')}>Cluster</Button>
          <Button variant="prominent" icon="plus" onClick={() => openMachinesSurface('new-machine')}>New Machine</Button>
        </div>

        {pending.map(m => (
          <div key={m.id} className="mc-card mc-row" style={{ padding: '12px 14px', gap: 12, background: 'color-mix(in srgb, var(--orange) 8%, transparent)' }}>
            <SF name="laptopcomputer" size={18} color="var(--orange)" />
            <span className="mc-col" style={{ gap: 2, flex: 1, minWidth: 0 }}>
              <span style={{ fontWeight: 600 }}>“{m.name ?? 'Mac'}” wants to join the fleet</span>
              <span className="mc-secondary" style={{ fontSize: 11 }}>A Mac running Bromure Sidecar: its agents run natively — not in a sandbox — as that Mac's user. Only allow a Mac you trust.</span>
            </span>
            <Button onClick={() => a.machineAdmit(m.id, false)}>Block</Button>
            <Button variant="prominent" onClick={() => a.machineAdmit(m.id, true)}>Allow</Button>
          </div>
        ))}

        <div className="mc-section-h">Workspaces</div>
        <div className="mc-tiles">
          {workspaces.map(w => {
            const vm = vmFor(state, w.id);
            const rs = runState(w, vm);
            const accent = accentOf(w);
            return (
              <div key={w.id} className="mc-card mc-tile" onClick={() => select({ kind: 'workspace', workspaceID: w.id })}>
                <div className="mc-row" style={{ gap: 10 }}>
                  <span className="mc-badge" style={{ width: 32, height: 32, borderRadius: 8, background: `linear-gradient(135deg, ${accent}, color-mix(in srgb, ${accent} 60%, transparent))` }}>
                    <SF name="server.rack" size={14} color="#fff" />
                  </span>
                  <span className="mc-col" style={{ gap: 2, minWidth: 0 }}>
                    <span className="mc-ellipsis" style={{ fontWeight: 600 }}>{w.name}</span>
                    <Pill color={STATE_COLOR[rs]} dot={6} size={10.5} style={{ alignSelf: 'flex-start', padding: '1px 7px' }}>{STATE_LABEL[rs]}</Pill>
                  </span>
                  <span className="mc-spacer" />
                  {isUp(rs)
                    ? <Button size="small" className="mc-btn-bordered" icon="terminal" onClick={e => { e.stopPropagation(); select({ kind: 'workspace', workspaceID: w.id, windowIndex: (vm?.tabs?.find(t => t.active) ?? vm?.tabs?.[0])?.index ?? 0 }); }}>Open</Button>
                    : <Button size="small" variant="prominent" icon="play.fill" onClick={e => { e.stopPropagation(); a.start(w.id); }}>{rs === 'suspended' ? 'Resume' : 'Start'}</Button>}
                </div>
                <div className="mc-row mc-secondary" style={{ gap: 14, fontSize: 11 }}>
                  <span><SF name="cpu" size={11} /> {isUp(rs) && vm ? `${((vm.cpu as number) ?? 0).toFixed(1)}%` : `${w.cpuCount ?? '—'} vCPU`}</span>
                  <span><SF name="memorychip" size={11} /> {isUp(rs) && vm?.memUsedKB ? gbKB(vm.memUsedKB) : `${w.memoryGB ?? '—'} GB`}</span>
                  {isUp(rs) && vm?.ip && <span style={{ fontFamily: 'var(--font-mono)' }}>{vm.ip}</span>}
                  {isUp(rs) && (vm?.tabs?.length ?? 0) > 0 && <span>{vm!.tabs!.length} tab{vm!.tabs!.length === 1 ? '' : 's'}</span>}
                </div>
              </div>
            );
          })}
        </div>

        {(kube.clusters.length > 0 || kube.registries.length > 0) && <>
          <div className="mc-section-h">Kubernetes</div>
          <div className="mc-tiles">
            {kube.clusters.map(c => (
              <div key={c.id} className="mc-card mc-tile" onClick={() => select({ kind: 'cluster', clusterID: c.id })}>
                <div className="mc-row" style={{ gap: 10 }}>
                  <span className="mc-badge" style={{ width: 32, height: 32, borderRadius: 8, background: `color-mix(in srgb, ${KUBE_BLUE} 15%, transparent)` }}><SF name="helm" size={15} color={KUBE_BLUE} /></span>
                  <span className="mc-col" style={{ gap: 2, minWidth: 0 }}>
                    <span className="mc-ellipsis" style={{ fontWeight: 600 }}>{c.name}</span>
                    <PhasePill phase={kube.status[c.id]?.phase ?? 'stopped'} />
                  </span>
                </div>
                <div className="mc-secondary" style={{ fontSize: 11 }}>{c.spec?.nodeCount ?? 1} node(s) · {c.spec?.cpusPerNode ?? 2} vCPU · {c.spec?.memoryGBPerNode ?? 4} GB each</div>
              </div>
            ))}
            {kube.registries.map(r => (
              <div key={r.id} className="mc-card mc-tile" onClick={() => select({ kind: 'registry', registryID: r.id })}>
                <div className="mc-row" style={{ gap: 10 }}>
                  <span className="mc-badge" style={{ width: 32, height: 32, borderRadius: 8, background: `color-mix(in srgb, ${REGISTRY_TINT} 15%, transparent)` }}><SF name="shippingbox.and.arrow.backward" size={15} color={REGISTRY_TINT} /></span>
                  <span className="mc-col" style={{ gap: 2, minWidth: 0 }}>
                    <span className="mc-ellipsis" style={{ fontWeight: 600 }}>{r.name}</span>
                    <PhasePill phase={kube.status[r.id]?.phase ?? 'stopped'} />
                  </span>
                </div>
                <div className="mc-secondary" style={{ fontSize: 11 }}>{kube.status[r.id]?.address ?? `${r.memoryGB ?? 1} GB RAM · ${r.diskGB ?? 40} GB disk`}</div>
              </div>
            ))}
          </div>
        </>}
      </div></div>
    </div>
  );
}
