// The stage for a machine selection (RemoteHostWindow's showWorkspace /
// selectWorkspaceName / showDockerDashboard / showKubeDashboard /
// showRegistryDashboard / showGrid):
//
//   workspace, no windowIndex  → the VM dashboard (a name-row click: always
//                                the dashboard, running or not)
//   workspace + windowIndex    → running/booting: TerminalStage on that tmux
//                                window; off/suspended: the VM dashboard
//   docker                     → the Docker dashboard (running VM only)
//   cluster / registry         → the Kubernetes / registry dashboards
//   machines / grid            → the Machines overview

import { GridStage } from '../terminal/GridStage';
import React from 'react';
import { useHostCtx, type StageSelection } from '../../app/hostContext';
import { useRemote, useHost } from '../../app/store';
import { TerminalStage } from '../terminal/TerminalStage';
import { VMDashboard } from './VMDashboard';
import { DockerDashboard } from './DockerDashboard';
import { KubeDashboard, RegistryDashboard } from './KubeDashboard';
import { MachinesOverview } from './MachinesOverview';
import { Unavailable } from './parts';
import { isUp, runState, vmFor, workspaceFor } from './util';
import './machines.css';

export function MachineStage({ selection }: { selection: StageSelection }) {
  const { host, select } = useHostCtx();
  useHost(host);
  const state = host.state;
  const workspaces = useRemote(host, s => s.workspaces) ?? [];
  const refs = workspaces.map(w => ({ id: w.id, name: w.name }));

  switch (selection.kind) {
    case 'workspace': {
      const ws = workspaceFor(state, selection.workspaceID);
      if (!ws) return <div className="mc-stage"><Unavailable icon="server.rack" title={state ? 'Machine removed' : ''} /></div>;
      const vm = vmFor(state, ws.id);
      const rs = runState(ws, vm);
      if (selection.windowIndex !== undefined && isUp(rs)) {
        return <TerminalStage key={ws.id} workspaceID={ws.id} windowIndex={selection.windowIndex}
                              onWindowChange={i => { if (i !== selection.windowIndex) select({ kind: 'workspace', workspaceID: ws.id, windowIndex: i }); }} />;
      }
      return <VMDashboard key={ws.id} host={host} ws={ws} vm={vm} state={rs} />;
    }
    case 'docker': {
      const ws = workspaceFor(state, selection.workspaceID);
      const vm = ws && vmFor(state, ws.id);
      if (!ws) return <div className="mc-stage"><Unavailable icon="shippingbox" title="Machine removed" /></div>;
      if (!vm || !isUp(runState(ws, vm))) return <VMDashboard key={ws.id} host={host} ws={ws} vm={vm} state={runState(ws, vm)} />;
      return <DockerDashboard key={ws.id} host={host} ws={ws} vm={vm} initialContainer={selection.containerID} />;
    }
    case 'cluster':
      return <KubeDashboard key={selection.clusterID} host={host} state={state} clusterID={selection.clusterID} workspaces={refs}
                            onGone={() => select({ kind: 'home' })} />;
    case 'registry':
      return <RegistryDashboard key={selection.registryID} host={host} state={state} registryID={selection.registryID} workspaces={refs}
                                onGone={() => select({ kind: 'home' })} />;
    case 'machines':
      return <MachinesOverview />;
    case 'grid':
      return <GridStage />;
    default:
      return null;
  }
}
export default MachineStage;
