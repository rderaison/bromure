// The machine verbs the fat client sends (FatClientController.swift's
// RemoteHostController: startWorkspace / shutdownWorkspace / … / kubeAction).

import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';

export type KubeAccess = { mode: 'all' } | { mode: 'only'; ids: string[] };

export function actions(host: RemoteHost) {
  return {
    start: (id: string) => host.send('POST', '/vms', { profile: id, detach: true }),
    shutdown: (id: string) => host.send('DELETE', `/vms/${seg(id)}`, { action: 'shutdown' }),
    suspend: (id: string) => host.send('DELETE', `/vms/${seg(id)}`, { action: 'suspend' }),
    reboot: (id: string, hard = false) => host.send('POST', `/vms/${seg(id)}/reboot`, { mode: hard ? 'hard' : 'soft' }),
    newTab: (id: string) => host.send('POST', `/sessions/${seg(id)}/tab`, { action: 'new' }),
    selectTab: (id: string, index: number) => host.send('POST', `/sessions/${seg(id)}/tab`, { action: 'select', index }),
    setFusion: (id: string, engaged: boolean) => host.send('POST', `/vms/${seg(id)}/fusion`, { engaged }),
    setModel: (id: string, modelID: string) => host.send('POST', `/vms/${seg(id)}/model`, { modelID }),
    setRouting: (id: string, mode: 'cloud' | 'local' | string) => host.send('POST', `/vms/${seg(id)}/routing`, { mode }),
    deleteWorkspace: (id: string) => host.request('DELETE', `/profiles/${seg(id)}`, undefined, { allowError: true }),
    docker: (id: string, body: Record<string, unknown>) => host.send('POST', `/vms/${seg(id)}/docker`, body),
    dockerWatch: (id: string, on: boolean) => { host.request('POST', `/vms/${seg(id)}/docker`, { action: 'watch', on }).catch(() => {}); },
    kube: (id: string, action: string, body?: Record<string, unknown>) => host.send('POST', `/k8s/${seg(id)}/${action}`, body ?? {}),
    kubeWatch: (id: string, on: boolean) => { host.request('POST', `/k8s/${seg(id)}/watch`, { on }).catch(() => {}); },
    kubeCreate: (doc: Record<string, unknown>) => host.send('POST', '/k8s', { action: 'create', ...doc }),
    kubeconfig: async (id: string): Promise<string | null> => {
      try { const r = await host.request('POST', `/k8s/${seg(id)}/kubeconfig`, {}); return r?.kubeconfig ?? null; } catch { return null; }
    },
    registry: (id: string, action: string, body?: Record<string, unknown>) => host.send('POST', `/registries/${seg(id)}/${action}`, body ?? {}),
    registryWatch: (id: string, on: boolean) => { host.request('POST', `/registries/${seg(id)}/watch`, { on }).catch(() => {}); },
    registryCreate: (doc: Record<string, unknown>) => host.send('POST', '/registries', { action: 'create', ...doc }),
    machineAdmit: (id: string, allow: boolean) => host.send('POST', '/machines/approve', { id, allow }),
    machineForget: (id: string) => host.send('POST', '/machines/forget', { id }),
    checkpoints: async (id: string): Promise<{ id: string; createdAt: Date; allocatedBytes: number }[]> => {
      try {
        const r = await host.request('GET', `/vms/${seg(id)}/checkpoints`);
        return ((r?.checkpoints ?? []) as any[])
          .filter(d => d.target === 'home' && typeof d.id === 'string')
          .map(d => ({ id: d.id, createdAt: new Date((d.createdAt ?? 0) * 1000), allocatedBytes: d.allocatedBytes ?? 0 }))
          .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
      } catch { return []; }
    },
    rewindHome: async (id: string, checkpoint: string): Promise<string | null> => {
      try {
        const r = await host.request('POST', `/vms/${seg(id)}/revert`, { checkpoint, target: 'home' }, { allowError: true });
        if (r && r.ok !== false && !r.error) { host.refreshSoon(); return null; }
        return r?.error ?? 'The server didn\'t answer.';
      } catch (e: any) { return e?.message ?? 'The server didn\'t answer.'; }
    },
    session: (id: string, action: string, body?: Record<string, unknown>) => host.send('POST', `/agent-sessions/${seg(id)}/${action}`, body ?? {}),
  };
}
