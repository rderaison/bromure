// KubeDashboard.swift: a cluster's dashboard (overview / workloads / services
// / storage / access / log) and a container registry's (images / access /
// log), from the mirrored /state `kubeClusters` snapshot; verbs ride
// POST /k8s/<id>/… and /registries/<id>/…. Opening switches the host's probe
// to its fast cadence for as long as the dashboard is up (…/watch).

import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import type { RemoteState } from '../../core/remote/types';
import { Button, Checkbox, Spinner, useMenu } from '../../ui/kit';
import { StatCard, CPUStatCard, useHistory, KubeCard, MiniGauge, Banner, SegPicker, SmallSearch, Confirm, Unavailable, Dot, Radio, SF } from './parts';
import { actions, type KubeAccess } from './actions';
import { copyText, kubeBytes, kubeUptime } from './util';

export const KUBE_BLUE = '#326CE5';
export const REGISTRY_TINT = '#F97316';

type Phase = 'stopped' | 'creating' | 'starting' | 'running' | 'stopping' | 'error' | 'deleting';
const PHASE_NAME: Record<Phase, string> = { stopped: 'Stopped', creating: 'Setting up…', starting: 'Starting…', running: 'Running', stopping: 'Stopping…', error: 'Error', deleting: 'Deleting…' };
const isBusy = (p: Phase) => p === 'creating' || p === 'starting' || p === 'stopping' || p === 'deleting';

const EMULATORS = [
  { kind: 'aws', project: 'floci', port: 4566, cloud: 'AWS', key: 'awsEmulator',
    creds: 'Any credentials work (a 12-digit access key id selects an account).', container: 'Lambda, RDS, …' },
  { kind: 'azure', project: 'floci-az', port: 4577, cloud: 'Azure', key: 'azureEmulator',
    creds: 'The Azurite development account (devstoreaccount1 and its well-known key) works; credentials aren\'t validated. Cosmos DB, Key Vault and the other services answer under per-service paths of the same endpoint.', container: 'Functions, Event Hubs, Cosmos DB engines, …' },
  { kind: 'gcp', project: 'floci-gcp', port: 4588, cloud: 'Google Cloud', key: 'gcpEmulator',
    creds: 'No credentials needed once the emulator variables are set; the default project is floci-local.', container: 'Cloud Run, Cloud SQL, Managed Kafka, …' },
  { kind: 'oci', project: 'floci-oci', port: 4599, cloud: 'Oracle Cloud', key: 'ociEmulator',
    creds: 'Any OCI profile with any RSA key works (signatures are parsed, never verified); the default tenancy is ocid1.tenancy.oc1..flocilocal…, region us-ashburn-1.', container: 'Functions, OKE, …' },
] as const;
const AZURITE_KEY = 'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMh0==';
function clientSetup(kind: string, ep: string): string {
  switch (kind) {
    case 'aws': return `export AWS_ENDPOINT_URL=${ep} AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1`;
    case 'azure': return `export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=${AZURITE_KEY};BlobEndpoint=${ep}/devstoreaccount1;QueueEndpoint=${ep}/devstoreaccount1;TableEndpoint=${ep}/devstoreaccount1"`;
    case 'gcp': { const h = ep.replace(/^https?:\/\//, '').split('/')[0]; return `export STORAGE_EMULATOR_HOST=${ep} PUBSUB_EMULATOR_HOST=${h} FIRESTORE_EMULATOR_HOST=${h} DATASTORE_EMULATOR_HOST=${h} SECRET_MANAGER_EMULATOR_HOST=${h} FIREBASE_AUTH_EMULATOR_HOST=${h} GOOGLE_CLOUD_PROJECT=floci-local`; }
    default: return `oci --endpoint ${ep} os ns get   # any ~/.oci profile with any RSA key; region us-ashburn-1, namespace floci-local`;
  }
}

/** KubeCluster.slug(for:). */
export function kubeSlug(name: string): string {
  let out = '', lastDash = true;
  for (const ch of name.toLowerCase()) {
    if (/[a-z0-9]/.test(ch)) { out += ch; lastDash = false; } else if (!lastDash) { out += '-'; lastDash = true; }
  }
  out = out.replace(/-+$/, '');
  if (!out) out = 'cluster';
  if (/^[0-9]/.test(out)) out = 'k-' + out;
  return out.slice(0, 24);
}

export interface WorkspaceRef { id: string; name: string }

export function useKube(state: RemoteState | null | undefined) {
  const k = state?.kubeClusters;
  return { clusters: (k?.clusters ?? []) as any[], registries: (k?.registries ?? []) as any[], status: (k?.status ?? {}) as Record<string, any> };
}
const statusFor = (k: ReturnType<typeof useKube>, id: string) => k.status[id] ?? k.status[id.toUpperCase()] ?? Object.entries(k.status).find(([x]) => x.toUpperCase() === id.toUpperCase())?.[1] ?? { phase: 'stopped', log: [] };

// ── phase pill ───────────────────────────────────────────────────────────

export function PhasePill({ phase }: { phase: Phase }) {
  const color = phase === 'running' ? 'var(--green)' : phase === 'error' ? 'var(--red)' : phase === 'stopped' ? 'var(--label-secondary)' : 'var(--orange)';
  return (
    <span className="mc-pill" style={{ color, background: `color-mix(in srgb, ${color} 14%, transparent)`, padding: '2px 6px', gap: 4, fontSize: 10.5 }}>
      <span className="dot" style={{ width: 6, height: 6, background: color }} />{PHASE_NAME[phase] ?? phase}
    </span>
  );
}

// ── access picker (creation sheets + editors) ───────────────────────────

export function AccessPicker({ access, workspaces, onChange }: { access: KubeAccess; workspaces: WorkspaceRef[]; onChange: (a: KubeAccess) => void }) {
  const isAll = access.mode === 'all';
  const selected = new Set(access.mode === 'only' ? access.ids.map(x => x.toUpperCase()) : workspaces.map(w => w.id.toUpperCase()));
  const disabled = workspaces.length === 0;
  return (
    <div className="mc-col" style={{ gap: 8 }}>
      <div className="mc-col" style={{ gap: 6 }}>
        <Radio checked={isAll} disabled={disabled} onChange={() => onChange({ mode: 'all' })}>All workspaces, including new ones</Radio>
        <Radio checked={!isAll} disabled={disabled} onChange={() => {
          const ids = selected.size ? [...selected] : workspaces.slice(0, 1).map(w => w.id);
          onChange(ids.length ? { mode: 'only', ids } : { mode: 'all' });
        }}>Only these workspaces</Radio>
      </div>
      {!isAll && (
        <div className="mc-col" style={{ gap: 4, paddingLeft: 18 }}>
          {workspaces.map(w => (
            <Checkbox key={w.id} checked={selected.has(w.id.toUpperCase())} onChange={on => {
              const ids = new Set(selected);
              if (on) ids.add(w.id.toUpperCase()); else ids.delete(w.id.toUpperCase());
              if (!ids.size) return;
              onChange({ mode: 'only', ids: [...ids] });
            }}><span style={{ fontSize: 12 }}>{w.name}</span></Checkbox>
          ))}
          {selected.size <= 1 && <span className="mc-tertiary" style={{ fontSize: 10.5 }}>At least one workspace must keep access.</span>}
        </div>
      )}
      {disabled && <span className="mc-tertiary" style={{ fontSize: 10.5 }}>No workspaces yet — every workspace you create will get access.</span>}
    </div>
  );
}
const accessOf = (a: any): KubeAccess => (a?.mode === 'only' && Array.isArray(a.ids) && a.ids.length ? { mode: 'only', ids: a.ids } : { mode: 'all' });

// ── shared bits ──────────────────────────────────────────────────────────

function LogPane({ lines, query }: { lines: string[]; query: string }) {
  const shown = lines.filter(l => !query || l.toLowerCase().includes(query.toLowerCase()));
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => { const el = ref.current; if (el) el.scrollTop = el.scrollHeight; }, [shown.length]);
  return (
    <div className="mc-scroll" ref={ref}>
      <div className="mc-col" style={{ padding: 14, gap: 1 }}>
        {!shown.length && <KEmpty text="Nothing logged yet." />}
        {shown.map((l, i) => (
          <div key={i} className="selectable" style={{ fontFamily: 'var(--font-mono)', fontSize: 11, whiteSpace: 'pre-wrap',
            color: l.startsWith('✗') ? 'var(--red)' : l.startsWith('▸') || l.startsWith('✓') ? 'var(--label)' : 'var(--label-secondary)' }}>{l}</div>
        ))}
      </div>
    </div>
  );
}
const KEmpty = ({ text }: { text: string }) => <div className="mc-secondary" style={{ fontSize: 12, textAlign: 'center', padding: '30px 0' }}>{text}</div>;

function ActionsMenuButton({ items, title }: { items: Parameters<ReturnType<typeof useMenu>>[1]; title: string }) {
  const menu = useMenu();
  return (
    <button className="mc-icon-btn" title={title} style={{ color: 'var(--label-secondary)' }}
            onClick={e => menu(e.currentTarget.getBoundingClientRect(), items)}>
      <SF name="ellipsis.circle" size={16} />
    </button>
  );
}

// ── cluster dashboard ────────────────────────────────────────────────────

type CPane = 'overview' | 'workloads' | 'services' | 'storage' | 'access' | 'log';

export function KubeDashboard({ host, state, clusterID, workspaces, onGone }: {
  host: RemoteHost; state: RemoteState | null | undefined; clusterID: string; workspaces: WorkspaceRef[]; onGone: () => void;
}) {
  const a = actions(host);
  const k = useKube(state);
  const cluster = k.clusters.find(c => String(c.id).toUpperCase() === clusterID.toUpperCase());
  const status = statusFor(k, clusterID);
  const phase: Phase = status.phase ?? 'stopped';
  const probe = status.probe;
  const [pane, setPane] = useState<CPane>('overview');
  const [query, setQuery] = useState('');
  const [confirmDelete, setConfirmDelete] = useState(false);
  const cpuHist = useHistory(() => cpuPercent(probe), 2000, clusterID);
  useEffect(() => { a.kubeWatch(clusterID, true); return () => a.kubeWatch(clusterID, false); }, [host, clusterID]); // eslint-disable-line
  useEffect(() => {
    if (phase === 'creating') setPane('log');
    if (phase === 'running') setPane(p => (p === 'log' && !(status.log ?? []).length ? 'overview' : p));
  }, [phase]); // eslint-disable-line

  if (!cluster) return <div className="mc-stage window"><Unavailable icon="helm" title="Cluster removed" /></div>;
  const spec = cluster.spec ?? {};
  const nodeCount = spec.nodeCount ?? 1;
  const subtitle = [
    `${nodeCount} node(s)`, `${spec.cpusPerNode ?? 2} vCPU · ${spec.memoryGBPerNode ?? 4} GB each`,
    ...(probe?.version ? [probe.version] : []),
    ...(status.startedAt && phase === 'running' ? [`up ${kubeUptime(new Date(status.startedAt))}`] : []),
  ].join(' · ');
  const search = pane === 'workloads' ? 'Filter pods' : pane === 'services' ? 'Filter services' : pane === 'storage' ? 'Filter volumes' : pane === 'log' ? 'Filter log' : 'Filter';

  return (
    <div className="mc-stage window">
      <div className="mc-dhead">
        <div className="mc-dhead-row">
          <div className="mc-badge" style={{ background: `color-mix(in srgb, ${KUBE_BLUE} 15%, transparent)` }}><SF name="helm" size={18} color={KUBE_BLUE} /></div>
          <div className="mc-col" style={{ gap: 2, minWidth: 0 }}>
            <span className="mc-title16 mc-ellipsis">{cluster.name}</span>
            <span className="mc-row" style={{ gap: 6 }}><PhasePill phase={phase} /><span className="mc-secondary mc-ellipsis" style={{ fontSize: 11 }}>{subtitle}</span></span>
          </div>
          <span className="mc-spacer" />
          <PrimaryActions phase={phase} tint={KUBE_BLUE} start={() => a.kube(clusterID, 'start')} restart={() => a.kube(clusterID, 'restart')} stop={() => a.kube(clusterID, 'stop')} />
          <ActionsMenuButton title="Cluster actions" items={[
            { label: 'Copy kubeconfig', icon: 'doc.on.doc', disabled: !cluster.provisioned, action: async () => { const y = await a.kubeconfig(clusterID); if (y) copyText(y); } },
            { label: 'Workspace access…', icon: 'person.2', action: () => setPane('access') },
            { label: 'Start with Bromure', icon: 'power', checked: cluster.autoStart !== false, action: () => a.kube(clusterID, 'autostart', { on: !(cluster.autoStart !== false) }) },
            { separator: true },
            { label: 'Delete cluster…', icon: 'trash', destructive: true, disabled: isBusy(phase), action: () => setConfirmDelete(true) },
          ]} />
        </div>
        <div className="mc-row" style={{ gap: 10 }}>
          <SegPicker value={pane} onChange={setPane} options={[
            { value: 'overview', label: 'Overview' }, { value: 'workloads', label: 'Workloads' }, { value: 'services', label: 'Services' },
            { value: 'storage', label: 'Storage' }, { value: 'access', label: 'Access' }, { value: 'log', label: 'Log' }]} />
          <span className="mc-spacer" />
          <SmallSearch value={query} onChange={setQuery} placeholder={search} />
        </div>
      </div>
      <div className="mc-divider" />
      {phase === 'error' && status.message ? <Banner kind="error" text={status.message} />
        : isBusy(phase) ? <Banner kind="progress" tint={KUBE_BLUE} text={status.step ?? PHASE_NAME[phase]} /> : null}

      {pane === 'overview' && <ClusterOverview cluster={cluster} status={status} phase={phase} cpuHist={cpuHist} />}
      {pane === 'workloads' && <Workloads probe={probe} query={query} />}
      {pane === 'services' && <Services probe={probe} query={query} />}
      {pane === 'storage' && <Storage cluster={cluster} status={status} phase={phase} query={query} />}
      {pane === 'access' && (
        <div className="mc-scroll"><div className="mc-pad">
          <KubeCard title="Workspace access" icon="person.2">
            <div className="mc-secondary" style={{ fontSize: 11.5 }}>Allowed workspaces get this cluster in their ~/.kube/config (context “{kubeSlug(cluster.name)}”) and kubectl talks to it directly over the VM network. Others never see it.</div>
            <AccessPicker access={accessOf(cluster.access)} workspaces={workspaces} onChange={acc => a.kube(clusterID, 'access', { access: acc })} />
          </KubeCard>
        </div></div>
      )}
      {pane === 'log' && <LogPane lines={status.log ?? []} query={query} />}

      {confirmDelete && <Confirm title="Delete cluster?" destructive confirm={`Delete ${cluster.name}`}
        message="Stops every node and deletes their disks, including all Longhorn volumes. Workspaces lose the cluster from their kubeconfig. This can't be undone."
        onConfirm={() => { setConfirmDelete(false); onGone(); a.kube(clusterID, 'delete'); }} onCancel={() => setConfirmDelete(false)} />}
    </div>
  );
}

function PrimaryActions({ phase, tint, start, restart, stop }: { phase: Phase; tint: string; start: () => void; restart: () => void; stop: () => void }) {
  if (phase === 'stopped' || phase === 'error') return <Button variant="prominent" icon="play.fill" style={{ background: tint }} onClick={start}>Start</Button>;
  if (phase === 'running') return (
    <span className="mc-row" style={{ gap: 8 }}>
      <Button className="mc-btn-bordered" icon="arrow.clockwise" onClick={restart}>Restart</Button>
      <Button className="mc-btn-bordered" icon="stop.fill" onClick={stop}>Stop</Button>
    </span>
  );
  return <span className="mc-row mc-secondary" style={{ gap: 8, fontSize: 12 }}><Spinner size={14} />{PHASE_NAME[phase]}</span>;
}

const sum = (xs: any[] | undefined, f: (x: any) => number) => (xs ?? []).reduce((s, x) => s + (f(x) || 0), 0);
function cpuPercent(p: any): number {
  const cap = sum(p?.nodes, n => n.cpuCapacityM), used = sum(p?.nodes, n => n.cpuUsedM);
  return cap > 0 ? Math.min(100, (used / cap) * 100) : 0;
}

function ClusterOverview({ cluster, status, phase, cpuHist }: { cluster: any; status: any; phase: Phase; cpuHist: number[] }) {
  const p = status.probe;
  const spec = cluster.spec ?? {};
  const ready = (p?.nodes ?? []).filter((n: any) => n.ready).length;
  const total = Math.max(spec.nodeCount ?? 1, p?.nodes?.length ?? 0);
  const pods = p?.podSummary ?? { total: 0, running: 0, pending: 0 };
  const memUsed = sum(p?.nodes, n => n.memUsedBytes), memCap = sum(p?.nodes, n => n.memCapacityBytes);
  const lbCount = (p?.services ?? []).filter((s: any) => s.type === 'LoadBalancer').length;
  const lh = p?.longhorn;
  const storage: [string, string] = lh
    ? [kubeBytes(sum(lh.nodes, n => n.storageAvailableBytes)), `free of ${kubeBytes(sum(lh.nodes, n => n.storageMaximumBytes))} (Longhorn)`]
    : spec.storageEnabled !== false ? ['—', 'Longhorn not ready'] : [`${p?.pvcs?.length ?? 0}`, 'volume claims (local-path)'];
  const lb = spec.loadBalancer ?? 'bromure';
  const emulators = EMULATORS.filter(e => spec[e.key]);
  return (
    <div className="mc-scroll"><div className="mc-pad">
      <div className="mc-stats-grid" style={{ gridTemplateColumns: 'repeat(6, minmax(0, 1fr))' }}>
        <StatCard title="Nodes" value={`${ready}/${total}`} caption={ready === total && total > 0 ? 'all Ready' : 'Ready / total'} icon="server.rack" tint={KUBE_BLUE} />
        <StatCard title="Pods" value={`${pods.running ?? 0}`} caption={(pods.pending ?? 0) > 0 ? `${pods.pending} pending · ${pods.total} total` : `running · ${pods.total ?? 0} total`} icon="cube.fill" tint="var(--green)" />
        <CPUStatCard value={cpuPercent(p)} history={cpuHist} tint="var(--orange)" />
        <StatCard title="Memory" value={memCap > 0 ? kubeBytes(memUsed) : '—'} caption={memCap > 0 ? `of ${kubeBytes(memCap)} allocatable` : 'waiting for metrics'} icon="memorychip" tint="var(--purple)" />
        <StatCard title="Storage" value={storage[0]} caption={storage[1]} icon="externaldrive.fill" tint="var(--teal)" />
        <StatCard title="Load balancers" value={`${lbCount}`} caption={lb === 'bromure' ? (status.hostIP ? `on ${status.hostIP}` : 'no LAN address') : lb === 'metallb' ? 'MetalLB L2' : 'NodePort only'} icon="point.3.connected.trianglepath.dotted" tint="var(--pink)" />
      </div>
      {emulators.map(e => <EmulatorCard key={e.kind} e={e} cluster={cluster} status={status} phase={phase} />)}
      <KubeCard title="Nodes" icon="server.rack">
        <div className="mc-col">
          {(p?.nodes?.length ? p.nodes : null)?.map((n: any) => (
            <div key={n.name} className="mc-krow">
              <Dot color={n.ready ? 'var(--green)' : 'var(--orange)'} />
              <span className="mc-col" style={{ gap: 1 }}>
                <span style={{ fontWeight: 500 }}>{n.name}</span>
                <span className="mc-secondary" style={{ fontSize: 10.5 }}>{[(n.roles ?? []).some((r: string) => r === 'control-plane' || r === 'master') ? 'control plane' : 'worker', n.ip, n.version].filter(Boolean).join(' · ')}</span>
              </span>
              <span className="mc-spacer" />
              <MiniGauge label="CPU" fraction={n.cpuCapacityM > 0 && n.cpuUsedM > 0 ? n.cpuUsedM / n.cpuCapacityM : null} text={n.cpuCapacityM > 0 && n.cpuUsedM > 0 ? `${Math.round(Math.min(100, n.cpuUsedM / n.cpuCapacityM * 100))}%` : '—'} />
              <MiniGauge label="Mem" fraction={n.memCapacityBytes > 0 && n.memUsedBytes > 0 ? n.memUsedBytes / n.memCapacityBytes : null} text={n.memCapacityBytes > 0 && n.memUsedBytes > 0 ? kubeBytes(n.memUsedBytes) : '—'} />
              <span className="mc-secondary mc-num" style={{ fontSize: 11 }}>{n.pods ?? 0} pods</span>
              {(n.pressure ?? []).length > 0 && <span title={n.pressure.join(', ')}><SF name="exclamationmark.triangle.fill" size={12} color="var(--orange)" /></span>}
            </div>
          )) ?? (cluster.nodes ?? []).map((n: any) => (
            <div key={n.id ?? n.name} className="mc-krow">
              <Dot color="color-mix(in srgb, var(--label-secondary) 60%, transparent)" />
              <span style={{ fontWeight: 500 }}>{n.name}</span>
              <span className="mc-secondary" style={{ fontSize: 10.5 }}>{n.role === 'server' ? 'control plane' : 'worker'}</span>
              <span className="mc-spacer" />
              <span className="mc-tertiary mc-num" style={{ fontSize: 11 }}>{n.lastIP ?? ''}</span>
            </div>
          ))}
        </div>
      </KubeCard>
      {lb === 'bromure' && (
        <KubeCard title="LAN load balancer" icon="point.3.connected.trianglepath.dotted">
          {spec.lanPool ? <div className="mc-secondary" style={{ fontSize: 11 }}>Services of type LoadBalancer get their own LAN address from {spec.lanPool}, answered by ARP; the host relays each port into the cluster.</div>
            : status.hostIP ? <div className="mc-secondary" style={{ fontSize: 11 }}>Services of type LoadBalancer are published on this Mac's address {status.hostIP}; the host relays each port into the cluster.</div> : null}
          {!(status.lbEndpoints ?? []).length
            ? <div className="mc-secondary" style={{ fontSize: 12, paddingTop: 4 }}>{phase === 'running' ? 'No LoadBalancer services yet.' : 'Starts with the cluster.'}</div>
            : <div className="mc-col" style={{ paddingTop: 6 }}>{status.lbEndpoints.map((e: any) => (
                <div key={`${e.namespace}/${e.service}:${e.port}`} className="mc-krow" style={{ padding: '5px 0' }}>
                  <Dot color={e.bound ? 'var(--green)' : 'var(--red)'} />
                  <span style={{ fontWeight: 500 }}>{e.namespace}/{e.service}</span>
                  {e.scope === 'vm' && <span className="mc-tag mc-secondary" title="Private: bromure.io/scope: vm — reachable from the workspaces and this Mac, not from the LAN" style={{ fontSize: 9.5, background: 'rgba(var(--mc-ink-rgb), 0.08)' }}>VM network</span>}
                  <span className="mc-spacer" />
                  {e.bound && (e.ip ?? status.hostIP)
                    ? <span className="selectable" style={{ fontFamily: 'var(--font-mono)', fontSize: 11 }}>{e.ip ?? status.hostIP}:{e.port}</span>
                    : <span style={{ fontSize: 11, color: 'var(--red)' }}>{e.error ?? 'pending'}</span>}
                  <span className="mc-tertiary" style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5 }}>→ :{e.nodePort}{String(e.protocolName).toUpperCase() === 'UDP' ? '/udp' : ''}</span>
                </div>))}</div>}
        </KubeCard>
      )}
      {(p?.warnings ?? []).length > 0 && (
        <KubeCard title="Recent warnings" icon="exclamationmark.triangle">
          <div className="mc-col" style={{ gap: 6 }}>
            {p.warnings.slice(0, 8).map((w: any, i: number) => (
              <div key={i} className="mc-col" style={{ gap: 1 }}>
                <span className="mc-row" style={{ gap: 6 }}>
                  <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--orange)' }}>{w.reason}</span>
                  <span className="mc-secondary mc-ellipsis" style={{ fontSize: 11 }}>{w.namespace ? `${w.namespace}/${w.object}` : w.object}</span>
                  {w.count > 1 && <span className="mc-tertiary" style={{ fontSize: 10 }}>×{w.count}</span>}
                </span>
                <span className="selectable" style={{ fontSize: 11 }}>{w.message}</span>
              </div>
            ))}
          </div>
        </KubeCard>
      )}
      {phase === 'stopped' && !p && (
        <KubeCard title="Cluster is stopped" icon="moon.zzz">
          <div className="mc-secondary" style={{ fontSize: 12 }}>{cluster.provisioned
            ? `Start the cluster to boot its ${spec.nodeCount ?? 1} node VM(s). Workspaces already carry its kubeconfig; kubectl works as soon as the API server is back.`
            : 'Provisioning never completed. Start the cluster to run the setup again.'}</div>
        </KubeCard>
      )}
    </div></div>
  );
}

function EmulatorCard({ e, cluster, status, phase }: { e: typeof EMULATORS[number]; cluster: any; status: any; phase: Phase }) {
  const addon = status.probe?.emulators?.[e.kind];
  const tag = (() => { const img: string | undefined = addon?.image; const i = img?.lastIndexOf(':') ?? -1; const t = i >= 0 ? img!.slice(i + 1) : ''; return t && !t.includes('/') ? t : undefined; })();
  let lan: string | undefined, vmNet: string | undefined;
  const ep = (status.lbEndpoints ?? []).find((x: any) => x.namespace === e.project && x.port === e.port && x.bound);
  if (ep && (ep.ip ?? status.hostIP)) lan = `http://${ep.ip ?? status.hostIP}:${ep.port}`;
  const svc = (status.probe?.services ?? []).find((s: any) => s.namespace === e.project && s.name === e.project);
  if (svc) {
    if (!lan && svc.ingress?.[0]) lan = `http://${svc.ingress[0]}:${e.port}`;
    const np = (svc.ports ?? []).find((x: any) => x.port === e.port)?.nodePort;
    const server = (cluster.nodes ?? []).find((n: any) => n.role === 'server')?.lastIP;
    if (np > 0 && server) vmNet = `http://${server}:${np}`;
  }
  const running = [e.project, tag].filter(Boolean).join(' ');
  return (
    <KubeCard title={`${e.cloud} emulator`} icon="cloud.fill">
      <div className="mc-row" style={{ gap: 6 }}>
        <Dot color={addon?.ready ? 'var(--green)' : !addon ? 'color-mix(in srgb, var(--label-secondary) 40%, transparent)' : 'var(--orange)'} />
        <span style={{ fontSize: 12 }}>{!addon ? (phase === 'running' ? 'Not installed' : 'Starts with the cluster') : `${e.project} ${addon.ready ? 'ready' : 'starting'}`}</span>
        <span className="mc-spacer" />
        <span className="mc-tertiary" style={{ fontSize: 10.5 }}>{running} · port {e.port}</span>
      </div>
      {lan && <div className="mc-row" style={{ gap: 6 }}><span className="mc-secondary" style={{ fontSize: 11, width: 170 }}>From this Mac and the LAN</span><span className="selectable" style={{ fontFamily: 'var(--font-mono)', fontSize: 11 }}>{lan}</span></div>}
      {vmNet && <div className="mc-row" style={{ gap: 6 }}><span className="mc-secondary" style={{ fontSize: 11, width: 170 }}>From the workspaces</span><span className="selectable" style={{ fontFamily: 'var(--font-mono)', fontSize: 11 }}>{vmNet}</span></div>}
      {(vmNet ?? lan) && <div className="selectable" style={{ fontFamily: 'var(--font-mono)', fontSize: 11, padding: 8, borderRadius: 7, background: 'rgba(var(--mc-ink-rgb), 0.05)', wordBreak: 'break-all' }}>{clientSetup(e.kind, (vmNet ?? lan)!)}</div>}
      <div className="mc-secondary" style={{ fontSize: 10.5 }}>{e.creds} State persists on the cluster's default storage class. Services that spawn containers — {e.container} — use the node's Docker and are best effort.</div>
    </KubeCard>
  );
}

function Workloads({ probe, query }: { probe: any; query: string }) {
  const pods = ((probe?.pods ?? []) as any[]).filter(p => !query || `${p.namespace}/${p.name}`.toLowerCase().includes(query.toLowerCase()));
  const grouped = useMemo(() => {
    const m = new Map<string, any[]>();
    for (const p of pods) m.set(p.namespace, [...(m.get(p.namespace) ?? []), p]);
    return [...m.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [pods]);
  const d = probe?.deployments;
  return (
    <div className="mc-scroll"><div className="mc-col" style={{ padding: 18, gap: 14 }}>
      {d?.total > 0 && <div className="mc-secondary" style={{ fontSize: 11 }}>{d.available}/{d.total} deployments available</div>}
      {!pods.length ? <KEmpty text={probe?.full ? 'No pods.' : 'Collecting workloads…'} /> : grouped.map(([ns, list]) => (
        <KubeCard key={ns} title={ns} icon="folder" trailing={list.length}>
          <div className="mc-col">
            {[...list].sort((a, b) => a.name.localeCompare(b.name)).map(p => {
              const healthy = p.phase === 'Running' && p.ready === p.containers && !p.reason;
              return (
                <div key={p.name} className="mc-krow" style={{ padding: '4px 0' }}>
                  <Dot color={healthy ? 'var(--green)' : p.phase === 'Succeeded' ? 'var(--label-secondary)' : 'var(--orange)'} />
                  <span className="mc-ellipsis">{p.name}</span>
                  <span className="mc-spacer" />
                  {p.reason ? <span style={{ fontSize: 10.5, fontWeight: 500, color: 'var(--orange)' }}>{p.reason}</span> : <span className="mc-secondary" style={{ fontSize: 10.5 }}>{p.phase}</span>}
                  <span className="mc-secondary mc-num" style={{ fontSize: 11 }}>{p.ready}/{p.containers}</span>
                  {p.restarts > 0 && <span className="mc-num" style={{ fontSize: 10.5, color: 'var(--orange)' }}>↻{p.restarts}</span>}
                  <span className="mc-tertiary mc-ellipsis" style={{ fontSize: 10.5, width: 110, textAlign: 'right' }}>{p.node}</span>
                </div>
              );
            })}
          </div>
        </KubeCard>
      ))}
    </div></div>
  );
}

function Services({ probe, query }: { probe: any; query: string }) {
  const list = ((probe?.services ?? []) as any[])
    .filter(s => !query || `${s.namespace}/${s.name}`.toLowerCase().includes(query.toLowerCase()))
    .sort((a, b) => (a.type === 'LoadBalancer' ? 0 : 1) - (b.type === 'LoadBalancer' ? 0 : 1) || a.namespace.localeCompare(b.namespace) || a.name.localeCompare(b.name));
  const portsText = (s: any) => (s.ports ?? []).map((p: any) => {
    let t = `${p.port}`;
    if (p.targetPort && p.targetPort !== `${p.port}`) t += `→${p.targetPort}`;
    if (p.nodePort > 0) t += ` (node ${p.nodePort})`;
    if ((p.protocol ?? 'TCP') !== 'TCP') t += `/${p.protocol}`;
    return t;
  }).join('  ');
  return (
    <div className="mc-scroll"><div className="mc-col" style={{ padding: 18, gap: 10 }}>
      {!list.length ? <KEmpty text="No services." /> : list.map(s => {
        const lb = s.type === 'LoadBalancer';
        return (
          <div key={`${s.namespace}/${s.name}`} className="mc-row" style={{ alignItems: 'flex-start', gap: 10, padding: 10, borderRadius: 10, background: 'rgba(var(--mc-ink-rgb), 0.04)' }}>
            <span style={{ width: 18, display: 'grid', placeItems: 'center' }}><SF name={lb ? 'point.3.connected.trianglepath.dotted' : s.type === 'NodePort' ? 'arrow.up.right.square' : 'circle.grid.cross'} size={12} color={lb ? 'var(--pink)' : 'var(--label-secondary)'} /></span>
            <span className="mc-col" style={{ gap: 2, flex: 1, minWidth: 0 }}>
              <span className="mc-row" style={{ gap: 6 }}>
                <span style={{ fontSize: 12, fontWeight: 500 }}>{s.namespace}/{s.name}</span>
                <span style={{ fontSize: 10, padding: '1px 5px', borderRadius: 999, background: 'rgba(var(--mc-ink-rgb), 0.08)' }}>{s.type}</span>
              </span>
              <span className="mc-secondary" style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5 }}>{portsText(s)}</span>
              {lb && (!(s.ingress ?? []).length
                ? <span style={{ fontSize: 10.5, color: 'var(--orange)' }}>External IP: pending</span>
                : <span className="selectable" style={{ fontSize: 10.5, color: 'var(--green)' }}>External IP: {s.ingress.join(', ')}</span>)}
            </span>
            <span className="mc-tertiary" style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5 }}>{s.clusterIP}</span>
          </div>
        );
      })}
    </div></div>
  );
}

function Storage({ cluster, status, phase, query }: { cluster: any; status: any; phase: Phase; query: string }) {
  const p = status.probe, lh = p?.longhorn, spec = cluster.spec ?? {};
  const q = query.toLowerCase();
  const vols = ((lh?.volumes ?? []) as any[]).filter(v => !q || v.name.toLowerCase().includes(q) || (v.pvc ?? '').toLowerCase().includes(q));
  const pvcs = ((p?.pvcs ?? []) as any[]).filter(c => !q || `${c.namespace}/${c.name}`.toLowerCase().includes(q));
  const syn = spec.synology;
  const replicas = Math.max(1, Math.min(3, spec.nodeCount ?? 1));
  return (
    <div className="mc-scroll"><div className="mc-col" style={{ padding: 18, gap: 14 }}>
      {lh ? (
        <KubeCard title="Longhorn" icon="externaldrive.badge.icloud">
          <div className="mc-row" style={{ gap: 6 }}>
            <Dot color={lh.ready ? 'var(--green)' : 'var(--orange)'} />
            <span style={{ fontSize: 12 }}>{lh.ready ? 'Ready' : 'Starting up'}</span>
            <span className="mc-secondary" style={{ fontSize: 11 }}>· {kubeBytes(sum(lh.nodes, n => n.storageAvailableBytes))} free of {kubeBytes(sum(lh.nodes, n => n.storageMaximumBytes))} · {replicas} replica(s) · iSCSI</span>
          </div>
          {(lh.nodes ?? []).length > 0 && <div className="mc-col" style={{ paddingTop: 6 }}>{lh.nodes.map((n: any) => (
            <div key={n.name} className="mc-row" style={{ padding: '4px 0', gap: 6 }}>
              <Dot size={7} color={n.ready && n.schedulable ? 'var(--green)' : 'var(--orange)'} />
              <span style={{ fontSize: 11.5 }}>{n.name}</span>
              <span className="mc-spacer" />
              <MiniGauge label="Used" fraction={n.storageMaximumBytes > 0 ? (n.storageMaximumBytes - n.storageAvailableBytes) / n.storageMaximumBytes : null} text={kubeBytes(n.storageAvailableBytes) + ' free'} />
            </div>))}</div>}
          {vols.length > 0 && <>
            <div className="mc-divider" style={{ margin: '4px 0' }} />
            <div className="mc-col">{vols.map(v => (
              <div key={v.name} className="mc-krow" style={{ padding: '5px 0' }}>
                <Dot color={v.robustness === 'healthy' ? 'var(--green)' : v.robustness === 'degraded' ? 'var(--orange)' : 'var(--label-secondary)'} />
                <span className="mc-col" style={{ gap: 1 }}>
                  <span style={{ fontWeight: 500 }}>{v.pvc ? `${v.namespace}/${v.pvc}` : v.name}</span>
                  <span className="mc-secondary" style={{ fontSize: 10.5 }}>{v.state} · {v.robustness} · {v.replicas} replica(s){v.node ? ` · on ${v.node}` : ''}</span>
                </span>
                <span className="mc-spacer" />
                <span className="mc-secondary mc-num" style={{ fontSize: 11 }}>{kubeBytes(v.actualSizeBytes)} / {kubeBytes(v.sizeBytes)}</span>
              </div>))}</div>
          </>}
        </KubeCard>
      ) : spec.storageEnabled !== false ? <KEmpty text={phase === 'running' ? 'Longhorn is coming up…' : 'Longhorn storage starts with the cluster.'} /> : null}
      {syn?.host && syn?.username && (
        <KubeCard title="Synology NAS" icon="externaldrive.connected.to.line.below">
          <div className="mc-row" style={{ gap: 6 }}>
            <Dot color={p?.synology?.ready ? 'var(--green)' : !p?.synology ? 'color-mix(in srgb, var(--label-secondary) 40%, transparent)' : 'var(--orange)'} />
            <span style={{ fontSize: 12 }}>{!p?.synology ? (phase === 'running' ? 'Driver not installed' : 'Starts with the cluster') : p.synology.ready ? 'Driver ready' : 'Driver starting'}</span>
            <span className="mc-secondary" style={{ fontSize: 11 }}>· {syn.host}:{syn.port ?? 5000}</span>
          </div>
        </KubeCard>
      )}
      <KubeCard title="Volume claims" icon="internaldrive" trailing={pvcs.length}>
        {!pvcs.length ? <div className="mc-secondary" style={{ fontSize: 12 }}>No PersistentVolumeClaims.</div> : <div className="mc-col">{pvcs.map(c => (
          <div key={`${c.namespace}/${c.name}`} className="mc-krow" style={{ padding: '5px 0' }}>
            <Dot color={c.phase === 'Bound' ? 'var(--green)' : 'var(--orange)'} />
            <span className="mc-col" style={{ gap: 1 }}>
              <span style={{ fontWeight: 500 }}>{c.namespace}/{c.name}</span>
              <span className="mc-secondary" style={{ fontSize: 10.5 }}>{c.phase} · {c.storageClass} · {(c.modes ?? []).join(',')}</span>
            </span>
            <span className="mc-spacer" />
            <span className="mc-secondary mc-num" style={{ fontSize: 11 }}>{kubeBytes(c.capacityBytes > 0 ? c.capacityBytes : c.requestBytes)}</span>
          </div>))}</div>}
      </KubeCard>
    </div></div>
  );
}

// ── registry dashboard ───────────────────────────────────────────────────

type RPane = 'images' | 'access' | 'log';

export function RegistryDashboard({ host, state, registryID, workspaces, onGone }: {
  host: RemoteHost; state: RemoteState | null | undefined; registryID: string; workspaces: WorkspaceRef[]; onGone: () => void;
}) {
  const a = actions(host);
  const k = useKube(state);
  const reg = k.registries.find(r => String(r.id).toUpperCase() === registryID.toUpperCase());
  const status = statusFor(k, registryID);
  const phase: Phase = status.phase ?? 'stopped';
  const info = status.registry;
  const [pane, setPane] = useState<RPane>('images');
  const [query, setQuery] = useState('');
  const [confirmDelete, setConfirmDelete] = useState(false);
  useEffect(() => { a.registryWatch(registryID, true); return () => a.registryWatch(registryID, false); }, [host, registryID]); // eslint-disable-line
  useEffect(() => {
    if (phase === 'creating') setPane('log');
    if (phase === 'running') setPane(p => (p === 'log' ? 'images' : p));
  }, [phase]);
  if (!reg) return <div className="mc-stage window"><Unavailable icon="shippingbox" title="Registry removed" /></div>;
  const subtitle = [...(status.address ? [status.address] : []), `${reg.memoryGB ?? 1} GB RAM · ${reg.diskGB ?? 40} GB disk`,
    ...(status.startedAt && phase === 'running' ? [`up ${kubeUptime(new Date(status.startedAt))}`] : [])].join(' · ');
  const repos = ((info?.repositories ?? []) as any[]).filter(r => !query || r.name.toLowerCase().includes(query.toLowerCase()));
  const imageCount = ((info?.repositories ?? []) as any[]).reduce((s, r) => s + (r.tags?.length ?? 0), 0);
  return (
    <div className="mc-stage window">
      <div className="mc-dhead">
        <div className="mc-dhead-row">
          <div className="mc-badge" style={{ background: `color-mix(in srgb, ${REGISTRY_TINT} 15%, transparent)` }}><SF name="shippingbox.and.arrow.backward" size={17} color={REGISTRY_TINT} /></div>
          <div className="mc-col" style={{ gap: 2, minWidth: 0 }}>
            <span className="mc-title16 mc-ellipsis">{reg.name}</span>
            <span className="mc-row" style={{ gap: 6 }}><PhasePill phase={phase} /><span className="mc-secondary mc-ellipsis" style={{ fontSize: 11 }}>{subtitle}</span></span>
          </div>
          <span className="mc-spacer" />
          <PrimaryActions phase={phase} tint={REGISTRY_TINT} start={() => a.registry(registryID, 'start')} restart={() => a.registry(registryID, 'restart')} stop={() => a.registry(registryID, 'stop')} />
          <ActionsMenuButton title="Registry actions" items={[
            { label: 'Copy address', icon: 'doc.on.doc', disabled: !status.address, action: () => status.address && copyText(status.address) },
            { label: 'Workspace access…', icon: 'person.2', action: () => setPane('access') },
            { label: 'Start with Bromure', icon: 'power', checked: reg.autoStart !== false, action: () => a.registry(registryID, 'autostart', { on: !(reg.autoStart !== false) }) },
            { separator: true },
            { label: 'Delete registry…', icon: 'trash', destructive: true, disabled: isBusy(phase), action: () => setConfirmDelete(true) },
          ]} />
        </div>
        <div className="mc-row" style={{ gap: 10 }}>
          <SegPicker value={pane} onChange={setPane} options={[{ value: 'images', label: 'Images' }, { value: 'access', label: 'Access' }, { value: 'log', label: 'Log' }]} />
          <span className="mc-spacer" />
          <SmallSearch value={query} onChange={setQuery} placeholder="Filter images" />
        </div>
      </div>
      <div className="mc-divider" />
      {phase === 'error' && status.message ? <Banner kind="error" text={status.message} />
        : isBusy(phase) ? <Banner kind="progress" tint={KUBE_BLUE} text={status.step ?? PHASE_NAME[phase]} /> : null}
      {pane === 'images' && (
        <div className="mc-scroll"><div className="mc-col" style={{ padding: 18, gap: 14 }}>
          <div className="mc-stats-grid" style={{ gridTemplateColumns: 'repeat(3, minmax(0, 1fr))' }}>
            <StatCard title="Repositories" value={`${info?.repositories?.length ?? 0}`} caption={`${imageCount} tagged images`} icon="shippingbox.fill" tint={REGISTRY_TINT} />
            <StatCard title="Disk" value={info ? kubeBytes(info.diskUsedBytes ?? 0) : '—'} caption={info ? `of ${kubeBytes(info.diskTotalBytes ?? 0)}` : 'waiting for the registry'} icon="internaldrive" tint="var(--teal)" />
            <StatCard title="Address" value={status.address ?? '—'} caption="plain HTTP on the VM network" icon="network" tint="var(--purple)" />
          </div>
          {status.address && (
            <KubeCard title="Push from a workspace" icon="terminal">
              <div className="selectable" style={{ fontFamily: 'var(--font-mono)', fontSize: 11, whiteSpace: 'pre' }}>{`docker build -t ${status.address}/myapp:dev .\ndocker push ${status.address}/myapp:dev\nkubectl run myapp --image=${status.address}/myapp:dev`}</div>
              <div className="mc-secondary" style={{ fontSize: 10.5 }}>dockerd in allowed workspaces already trusts this address, and BROMURE_REGISTRY carries it. Every cluster pulls from it without extra configuration.</div>
            </KubeCard>
          )}
          <KubeCard title="Images" icon="square.stack.3d.up" trailing={repos.length}>
            {!repos.length ? <div className="mc-secondary" style={{ fontSize: 12 }}>{phase === 'running' ? 'Nothing pushed yet.' : 'Start the registry to see its images.'}</div>
              : <div className="mc-col">{repos.map(r => (
                  <div key={r.name} className="mc-krow" style={{ alignItems: 'flex-start', padding: '5px 0' }}>
                    <span style={{ width: 16 }}><SF name="shippingbox" size={11} className="mc-secondary" /></span>
                    <span className="mc-col" style={{ gap: 2, flex: 1, minWidth: 0 }}>
                      <span className="selectable" style={{ fontWeight: 500 }}>{r.name}</span>
                      <span className="mc-secondary selectable" style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5 }}>{(r.tags ?? []).length ? r.tags.join('  ') : 'no tags'}</span>
                    </span>
                    <span className="mc-tertiary mc-num" style={{ fontSize: 11 }}>{(r.tags ?? []).length}</span>
                  </div>))}</div>}
          </KubeCard>
        </div></div>
      )}
      {pane === 'access' && (
        <div className="mc-scroll"><div className="mc-pad">
          <KubeCard title="Workspace access" icon="person.2">
            <div className="mc-secondary" style={{ fontSize: 11.5 }}>Allowed workspaces get {status.address ?? 'the registry'} as an insecure registry for docker and BROMURE_REGISTRY in their shell. Every cluster can pull from it.</div>
            <AccessPicker access={accessOf(reg.access)} workspaces={workspaces} onChange={acc => a.registry(registryID, 'access', { access: acc })} />
          </KubeCard>
        </div></div>
      )}
      {pane === 'log' && <LogPane lines={status.log ?? []} query={query} />}
      {confirmDelete && <Confirm title="Delete registry?" destructive confirm={`Delete ${reg.name}`}
        message="Stops the registry VM and deletes every image it holds. Workspaces and clusters stop trusting its address. This can't be undone."
        onConfirm={() => { setConfirmDelete(false); onGone(); a.registry(registryID, 'delete'); }} onCancel={() => setConfirmDelete(false)} />}
    </div>
  );
}
