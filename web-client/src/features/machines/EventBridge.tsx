// Mounted once per host window: routes `bromure:open` events for this
// surface, shows the Infrastructure sheets and the Rewind sheet, and the
// fleet-admission prompt (FleetAdmissionPrompter) for native Macs asking to
// join the server's fleet.
//
//   machines                         the Machines overview
//   machine      { profileID }       a machine's dashboard
//   branches     { profileID }       Branches window
//   docker { profileID, containerID? } / cluster { id } / registry { id }   their dashboards
//   review / review-branch { sessionID, files?, since? }   Review window
//   new-machine                      → the editor's new-workspace
//   new-cluster / new-registry       Infrastructure creation sheets
//   rewind / rewind-home { profileID } Rewind home sheet
//   kube-action  { kind, id, action } start / stop / restart / access / delete
//   toggle-files { open? }           the Files pane (⌃⌘E)
//
// `bare: true` on a sheet event renders it alone at the window's top-left
// (scripted screenshots against the native reference renders).

import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { useHostCtx } from '../../app/hostContext';
import { useWindows } from '../../app/windows';
import { useRemote } from '../../app/store';
import { Sheet } from '../../ui/kit';
import { actions } from './actions';
import { NewKubeClusterSheet, NewRegistrySheet } from './KubeSheets';
import { RewindSheet } from './RewindSheet';
import { Confirm } from './parts';
import { openBranchesWindow } from './Branches';
import { openSessionReviewWindow } from './Review';
import { MachineStage } from './MachineStage';
import { isUp, runState, vmFor, workspaceFor } from './util';
import { openMachinesSurface } from './events';
import './machines.css';

type Modal =
  | { kind: 'new-cluster'; bare?: boolean } | { kind: 'new-registry'; bare?: boolean }
  | { kind: 'rewind'; id: string; bare?: boolean }
  | { kind: 'kube-delete'; what: 'cluster' | 'registry'; id: string; name: string };

const idOf = (d: any): string | undefined => d.profileID ?? d.workspaceID ?? d.id;

export function MachinesEventBridge() {
  const { host, select, selection, filePaneOpen, setFilePaneOpen } = useHostCtx();
  const wm = useWindows();
  const [modal, setModal] = useState<Modal | null>(null);
  const [stageOverlay, setStageOverlay] = useState(false);
  const workspaces = useRemote(host, s => s.workspaces) ?? [];
  const kube = useRemote(host, s => s.kubeClusters);
  const pending = ((useRemote(host, s => s.pendingMachines) as any[]) ?? []).filter(m => m?.id);
  const [deferred, setDeferred] = useState<Set<string>>(new Set());
  const a = actions(host);
  const refs = workspaces.map(w => ({ id: w.id, name: w.name }));

  const handler = useRef<(d: any) => void>(() => {});
  handler.current = (d: any) => {
    switch (d.what) {
      case 'machines': select({ kind: 'machines' }); break;
      case 'machine': { const id = idOf(d); if (id) select({ kind: 'workspace', workspaceID: id }); break; }
      case 'docker': { const id = idOf(d); if (id) select({ kind: 'docker', workspaceID: id, containerID: d.containerID }); break; }
      case 'cluster': if (d.id) select({ kind: 'cluster', clusterID: d.id }); break;
      case 'registry': if (d.id) select({ kind: 'registry', registryID: d.id }); break;
      case 'branches': { const id = idOf(d); if (id) openBranchesWindow(wm, host, id); break; }
      case 'review': case 'review-branch':
        if (d.sessionID) openSessionReviewWindow(wm, host, d.sessionID, { files: d.files, since: d.since ? new Date(d.since) : undefined });
        break;
      case 'new-machine': openMachinesSurface('new-workspace'); break;
      case 'new-cluster': setModal({ kind: 'new-cluster', bare: !!d.bare }); break;
      case 'new-registry': setModal({ kind: 'new-registry', bare: !!d.bare }); break;
      case 'rewind': case 'rewind-home': {
        const id = idOf(d);
        const ws = id ? workspaceFor(host.state, id) ?? host.state?.workspaces?.find(w => w.name === id) : undefined;
        if (ws) setModal({ kind: 'rewind', id: ws.id, bare: !!d.bare });
        break;
      }
      case 'kube-action': {
        const kind: 'cluster' | 'registry' = d.kind === 'registry' ? 'registry' : 'cluster';
        const id: string = d.id;
        if (!id) break;
        if (d.action === 'access') { select(kind === 'cluster' ? { kind: 'cluster', clusterID: id } : { kind: 'registry', registryID: id }); break; }
        if (d.action === 'delete') {
          const list = (kind === 'cluster' ? host.state?.kubeClusters?.clusters : host.state?.kubeClusters?.registries) ?? [];
          const name = list.find((x: any) => String(x.id).toUpperCase() === id.toUpperCase())?.name ?? '';
          setModal({ kind: 'kube-delete', what: kind, id, name });
          break;
        }
        if (['start', 'stop', 'restart'].includes(d.action)) (kind === 'cluster' ? a.kube : a.registry)(id, d.action);
        break;
      }
      case 'toggle-files': setFilePaneOpen(d.open ?? !filePaneOpen); break;
      case 'machines-stage': setStageOverlay(v => (d.on ?? !v)); break;   // dev: show MachineStage over the stage
    }
  };
  useEffect(() => {
    const on = (e: Event) => { const d = (e as CustomEvent).detail; if (d?.what) handler.current(d); };
    window.addEventListener('bromure:open', on);
    const w = window as any;
    w.__bromure = { ...(w.__bromure ?? {}), machines: (what: string, args: Record<string, unknown> = {}) => openMachinesSurface(what, args) };
    return () => window.removeEventListener('bromure:open', on);
  }, []);

  const close = () => setModal(null);
  const wrap = (node: React.ReactNode, bare?: boolean, width = 720) => bare
    ? createPortal(<div style={{ position: 'fixed', left: 0, top: 0, zIndex: 9500 }}>{node}</div>, document.body)
    : <Sheet width={width} onClose={close}>{node}</Sheet>;

  let modalNode: React.ReactNode = null;
  if (modal?.kind === 'new-cluster') {
    modalNode = wrap(<NewKubeClusterSheet workspaces={refs} existingNames={((kube?.clusters ?? []) as any[]).map(c => c.name)} onCancel={close}
                                          onCreate={doc => { close(); a.kubeCreate(doc); }} />, modal.bare, 720);
  } else if (modal?.kind === 'new-registry') {
    modalNode = wrap(<NewRegistrySheet workspaces={refs} existingNames={((kube?.registries ?? []) as any[]).map(r => r.name)} onCancel={close}
                                       onCreate={doc => { close(); a.registryCreate(doc); }} />, modal.bare, 560);
  } else if (modal?.kind === 'rewind') {
    const ws = workspaceFor(host.state, modal.id);
    modalNode = wrap(<RewindSheet host={host} workspaceID={modal.id} name={ws?.name ?? ''} onClose={close}
                                  isRunning={() => { const w = workspaceFor(host.state, modal.id); return isUp(runState(w, vmFor(host.state, modal.id))); }} />, modal.bare, 460);
  } else if (modal?.kind === 'kube-delete') {
    const m = modal;
    modalNode = <Confirm title={m.what === 'cluster' ? `Delete cluster “${m.name}”?` : `Delete registry “${m.name}”?`} confirm="Delete" destructive
      message={m.what === 'cluster'
        ? 'Stops every node and deletes their disks, including all Longhorn volumes. Workspaces lose the cluster from their kubeconfig. This can\'t be undone.'
        : 'Stops the registry VM and deletes every image it holds. Workspaces and clusters stop trusting its address. This can\'t be undone.'}
      onCancel={close}
      onConfirm={() => {
        close();
        if ((m.what === 'cluster' && selection.kind === 'cluster' && selection.clusterID === m.id) || (m.what === 'registry' && selection.kind === 'registry' && selection.registryID === m.id)) select({ kind: 'home' });
        (m.what === 'cluster' ? a.kube : a.registry)(m.id, 'delete');
      }} />;
  }

  // Fleet admission: one waiting Mac at a time; "Decide Later" defers it for this window.
  const next = !modal ? pending.find(m => !deferred.has(m.id)) : undefined;
  const hostName = host.target.name;

  const stage = stageOverlay ? document.querySelector('.hw-stage') : null;
  return <>
    {modalNode}
    {next && <Confirm
      title={hostName ? `“${next.name ?? 'Mac'}” wants to join the fleet on “${hostName}”` : `“${next.name ?? 'Mac'}” wants to join this Mac's fleet`}
      message={'It\'s a Mac running Bromure Sidecar: its agents run natively — not in a sandbox — as that Mac\'s user. Once allowed, it\'s listed beside your VMs, and its agents and the agents in your workspaces can message each other, hand each other work and exchange files.\n\nOnly allow a Mac you trust. You can remove it from the fleet at any time.'}
      confirm="Allow" onConfirm={() => a.machineAdmit(next.id, true)}
      extra={{ label: 'Block', onClick: () => a.machineAdmit(next.id, false) }}
      cancelLabel="Decide Later" onCancel={() => setDeferred(s => new Set(s).add(next.id))} />}
    {stage && createPortal(<div style={{ position: 'absolute', inset: 0, zIndex: 5 }}><MachineStage selection={selection} /></div>, stage)}
  </>;
}
