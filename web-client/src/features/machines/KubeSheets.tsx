// The Infrastructure creation sheets (KubeDashboard.swift NewKubeClusterSheet
// / NewRegistrySheet): the host provisions; the mirror shows the new
// machine on the next /state.

import React, { useMemo, useState } from 'react';
import { Button, Switch } from '../../ui/kit';
import { Stepper, Radio, SF } from './parts';
import { AccessPicker, kubeSlug, KUBE_BLUE, REGISTRY_TINT, type WorkspaceRef } from './KubeDashboard';
import type { KubeAccess } from './actions';

// ── grouped-form pieces (Form .formStyle(.grouped)) ──────────────────────

export function FSection({ title, footer, children }: { title?: React.ReactNode; footer?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div className="mc-col">
      {title && <div className="mc-fsec-title">{title}</div>}
      <div className="mc-fsec">{children}</div>
      {footer}
    </div>
  );
}
export function FRow({ label, children, style }: { label: React.ReactNode; children?: React.ReactNode; style?: React.CSSProperties }) {
  return <div className="mc-frow" style={style}><span className="mc-flabel">{label}</span>{children}</div>;
}
export const Caption = ({ children }: { children: React.ReactNode }) => <div className="mc-ffoot">{children}</div>;
function FText({ label, value, onChange, placeholder, type }: { label: string; value: string; onChange: (v: string) => void; placeholder?: string; type?: string }) {
  return <FRow label={label}><input className="mc-finput" type={type} value={value} placeholder={placeholder} spellCheck={false} onChange={e => onChange(e.target.value)} /></FRow>;
}
function FToggle({ label, value, onChange }: { label: React.ReactNode; value: boolean; onChange: (v: boolean) => void }) {
  return <FRow label={label}><Switch size="regular" checked={value} onChange={onChange} /></FRow>;
}

// ── New Kubernetes cluster ───────────────────────────────────────────────

type Cat = 'General' | 'Nodes' | 'Storage' | 'Networking' | 'Add-ons' | 'Access';
const CATS: { id: Cat; icon: string; color: string }[] = [
  { id: 'General', icon: 'helm', color: KUBE_BLUE },
  { id: 'Nodes', icon: 'server.rack', color: 'var(--indigo)' },
  { id: 'Storage', icon: 'internaldrive.fill', color: 'var(--orange)' },
  { id: 'Networking', icon: 'network', color: 'var(--teal)' },
  { id: 'Add-ons', icon: 'puzzlepiece.extension.fill', color: 'var(--purple)' },
  { id: 'Access', icon: 'person.2.fill', color: 'var(--green)' },
];
const LB = [
  { kind: 'bromure', name: 'Bromure LAN load balancer', summary: 'Published on this Mac\'s LAN address by port, or on spare LAN addresses from a pool. Reachable from your LAN, this Mac and the workspaces.' },
  { kind: 'metallb', name: 'MetalLB, VM network only', summary: 'Layer-2 MetalLB hands out addresses from the VM network (a range kept out of its DHCP). Reachable from the workspaces and this Mac; nothing is exposed on your LAN.' },
  { kind: 'none', name: 'None (NodePort only)', summary: 'Services of type LoadBalancer stay pending; use NodePort or ClusterIP.' },
] as const;
const EMU = [
  { kind: 'aws', key: 'awsEmulator', project: 'floci', cloud: 'AWS', short: 'AWS', port: 4566, services: 'S3, DynamoDB, SQS, SNS, Lambda, API Gateway, Step Functions, EventBridge, Cognito' },
  { kind: 'azure', key: 'azureEmulator', project: 'floci-az', cloud: 'Azure', short: 'Azure', port: 4577, services: 'Blob, Queue and Table Storage, Cosmos DB, Key Vault, Service Bus, Event Hubs, Event Grid, Functions, Azure SQL, App Configuration' },
  { kind: 'gcp', key: 'gcpEmulator', project: 'floci-gcp', cloud: 'Google Cloud', short: 'GCP', port: 4588, services: 'Cloud Storage, Pub/Sub, Firestore, Datastore, Secret Manager, Cloud KMS, Cloud Run, Cloud Functions, Cloud Tasks, Cloud SQL, BigQuery' },
  { kind: 'oci', key: 'ociEmulator', project: 'floci-oci', cloud: 'Oracle Cloud', short: 'OCI', port: 4599, services: 'Object Storage, Queue, Streaming, Vault, KMS, Secrets, Functions, Identity, OKE' },
] as const;
const validPin = (p?: string) => !p?.trim() || /^[A-Za-z0-9._\-:/@]+$/.test(p.trim());

interface Spec {
  nodeCount: number; cpusPerNode: number; memoryGBPerNode: number; storageEnabled: boolean; storageDiskGB: number;
  loadBalancer: 'bromure' | 'metallb' | 'none'; ingress: boolean; lanPool?: string;
  awsEmulator: boolean; azureEmulator: boolean; gcpEmulator: boolean; ociEmulator: boolean; emulatorVersions: Record<string, string>;
}

export function NewKubeClusterSheet({ workspaces, existingNames, onCreate, onCancel }: {
  workspaces: WorkspaceRef[]; existingNames: string[];
  onCreate: (doc: Record<string, unknown>) => void; onCancel: () => void;
}) {
  const [name, setName] = useState(() => {
    const base = 'Kube cluster';
    let c = base, n = 2;
    while (existingNames.some(x => x.toLowerCase() === c.toLowerCase())) c = `${base} ${n++}`;
    return c;
  });
  const [spec, setSpec] = useState<Spec>({ nodeCount: 1, cpusPerNode: 2, memoryGBPerNode: 4, storageEnabled: true, storageDiskGB: 40,
    loadBalancer: 'metallb', ingress: true, awsEmulator: false, azureEmulator: false, gcpEmulator: false, ociEmulator: false, emulatorVersions: {} });
  const [access, setAccess] = useState<KubeAccess>({ mode: 'all' });
  const [autoStart, setAutoStart] = useState(true);
  const [synOn, setSynOn] = useState(false);
  const [syn, setSyn] = useState({ host: '', port: 5000, https: false, username: '', location: '', protocolKind: 'iscsi', fsType: 'ext4' });
  const [synPw, setSynPw] = useState('');
  const [cat, setCat] = useState<Cat>('General');
  const set = (p: Partial<Spec>) => setSpec(s => ({ ...s, ...p }));

  const totalMem = spec.nodeCount * spec.memoryGBPerNode;
  const totalDisk = spec.storageEnabled ? spec.nodeCount * spec.storageDiskGB : 0;
  const replicas = Math.max(1, Math.min(3, spec.nodeCount));
  const emulators = EMU.filter(e => spec[e.key]);
  const synConfigured = !!syn.host.trim() && !!syn.username.trim();
  const synVolumes = syn.location.split(',').map(s => s.trim()).filter(Boolean).map(s => (s.startsWith('/') ? s : '/' + s));
  const synClasses = synVolumes.length ? synVolumes.map(v => 'bromure-synology-' + v.replace(/^\/+|\/+$/g, '').toLowerCase()) : ['bromure-synology'];
  const blocker = !name.trim() ? 'Give the cluster a name.'
    : synOn && !synConfigured ? 'Synology: address and user are required.'
    : synOn && !synPw ? 'Synology: password is required.'
    : (() => { const bad = emulators.find(e => !validPin(spec.emulatorVersions[e.kind])); return bad ? `${bad.project} version: a tag such as 2.1.0 or a full image reference.` : null; })();
  const summary = [`${spec.nodeCount} node(s) · ${spec.cpusPerNode} vCPU · ${spec.memoryGBPerNode} GB each`,
    ...(synOn ? ['Synology'] : []), ...(spec.storageEnabled ? ['Longhorn'] : []),
    spec.loadBalancer === 'bromure' ? 'LAN LB' : spec.loadBalancer === 'metallb' ? 'MetalLB' : 'no LB', ...emulators.map(e => e.short)].join(' · ');
  const storageSummary = [...(synOn ? ['Synology NAS (default)'] : []),
    ...(spec.storageEnabled ? [`Longhorn, ${spec.storageDiskGB} GB per node${synOn ? '' : ' (default)'}`] : []), 'local-path'].join(' · ');
  const addOnsSummary = [...(spec.ingress ? ['Traefik'] : []), ...emulators.map(e => `${e.cloud} emulator`)].join(' · ') || 'None';

  const create = () => {
    if (blocker) return;
    const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
    const final: Record<string, unknown> = { ...spec,
      nodeCount: clamp(spec.nodeCount, 1, 8), cpusPerNode: clamp(spec.cpusPerNode, 1, 16), memoryGBPerNode: clamp(spec.memoryGBPerNode, 2, 64),
      storageDiskGB: clamp(spec.storageDiskGB, 10, 2000) };
    if (synOn && synConfigured) final.synology = syn;
    onCreate({ name: name.trim(), spec: final, access, autoStart, ...(synOn && synPw ? { synologyPassword: synPw } : {}) });
  };

  const detail = (() => {
    switch (cat) {
      case 'General': return <>
        <FSection footer={<Caption>Nodes are named k8s-{kubeSlug(name || 'Kube cluster')}-1, -2, … The cluster is a shared machine: every workspace on its access list gets it in ~/.kube/config, and their agents learn about it through the infrastructure MCP.</Caption>}>
          <FText label="Name" value={name} onChange={setName} placeholder="Kube cluster" />
          <FToggle label="Start with Bromure" value={autoStart} onChange={setAutoStart} />
        </FSection>
        <FSection title="Summary">
          <FRow label="Nodes"><span className="mc-fval">{spec.nodeCount} × {spec.cpusPerNode} vCPU, {spec.memoryGBPerNode} GB</span></FRow>
          <FRow label="Storage"><span className="mc-fval">{storageSummary}</span></FRow>
          <FRow label="Load balancer"><span className="mc-fval">{LB.find(l => l.kind === spec.loadBalancer)!.name}</span></FRow>
          <FRow label="Add-ons"><span className="mc-fval">{addOnsSummary}</span></FRow>
        </FSection>
      </>;
      case 'Nodes': return (
        <FSection footer={<>
          <Caption>{spec.nodeCount === 1 ? `One node: control plane and workloads together. ${totalMem} GB of RAM in total.` : `Node 1 is the control plane and also runs workloads; the others join as workers. ${totalMem} GB of RAM in total.`}</Caption>
        </>}>
          <FRow label="Nodes"><Stepper value={spec.nodeCount} min={1} max={8} onChange={v => set({ nodeCount: v })} label={spec.nodeCount} /></FRow>
          <FRow label="vCPUs per node"><Stepper value={spec.cpusPerNode} min={1} max={16} onChange={v => set({ cpusPerNode: v })} label={spec.cpusPerNode} /></FRow>
          <FRow label="Memory per node"><Stepper value={spec.memoryGBPerNode} min={2} max={64} onChange={v => set({ memoryGBPerNode: v })} label={`${spec.memoryGBPerNode} GB`} /></FRow>
        </FSection>
      );
      case 'Storage': return <>
        <FSection footer={<Caption>{spec.storageEnabled
          ? `Replicated block volumes served over iSCSI from a dedicated data disk on every node. ${totalDisk} GB reserved in total (sparse: only written blocks use space), ${replicas} replica(s). Storage class bromure-longhorn${synOn ? '' : ', the default'}.`
          : 'Off: only k3s\'s node-local local-path class, which pins a pod to its node.'}</Caption>}>
          <FToggle label="Longhorn distributed storage" value={spec.storageEnabled} onChange={v => set({ storageEnabled: v })} />
          {spec.storageEnabled && <FRow label="Data disk per node"><Stepper value={spec.storageDiskGB} min={10} max={2000} step={10} onChange={v => set({ storageDiskGB: v })} label={`${spec.storageDiskGB} GB`} /></FRow>}
        </FSection>
        <FSection footer={synOn ? <>
          <Caption>{synVolumes.length ? `Storage classes: ${synClasses.join(', ')} — the first is the default.` : 'Leave volumes empty and DSM picks a volume with free space (storage class bromure-synology, the default). Name volumes to get one class each, the first one default.'}</Caption>
          <Caption>Volumes through Synology's CSI driver (iSCSI LUNs or SMB shares). The password is stored encrypted on this Mac and only lands in the cluster's own Secrets; the DSM account needs storage-manager rights. The driver's manifests are fetched from Synology's GitHub at setup.</Caption>
        </> : <Caption>Persistent volumes on your NAS through Synology's CSI driver; becomes the default storage class.</Caption>}>
          <FToggle label="Synology NAS" value={synOn} onChange={setSynOn} />
          {synOn && <>
            <FText label="DSM address" value={syn.host} placeholder="nas.local or 192.168.1.10" onChange={v => setSyn(s => ({ ...s, host: v }))} />
            <FText label="Port" value={String(syn.port)} onChange={v => setSyn(s => ({ ...s, port: parseInt(v, 10) || 0 }))} />
            <FToggle label="HTTPS" value={syn.https} onChange={v => setSyn(s => ({ ...s, https: v }))} />
            <FText label="DSM user" value={syn.username} onChange={v => setSyn(s => ({ ...s, username: v }))} />
            <FText label="DSM password" type="password" value={synPw} onChange={setSynPw} />
            <FText label="Volumes (optional)" value={syn.location} placeholder="/volume1, /volume3" onChange={v => setSyn(s => ({ ...s, location: v }))} />
            <FRow label="Protocol">
              <select className="mc-finput" style={{ flex: 'none' }} value={syn.protocolKind} onChange={e => setSyn(s => ({ ...s, protocolKind: e.target.value }))}>
                <option value="iscsi">iSCSI (block LUNs)</option><option value="smb">SMB (shared folders)</option>
              </select>
            </FRow>
            <FText label="Filesystem" value={syn.fsType} onChange={v => setSyn(s => ({ ...s, fsType: v }))} />
          </>}
        </FSection>
      </>;
      case 'Networking': return <>
        <FSection footer={spec.loadBalancer === 'bromure' ? <>
          <Caption>A pool of spare addresses on your LAN gives each LoadBalancer Service its own address, answered by ARP like MetalLB — nothing on this Mac is exposed. Leave it empty to share the Mac's address by port.</Caption>
          <Caption>Per Service: the annotation bromure.io/scope: vm keeps it private (an address on the VM network, for the workspaces and this Mac only); bromure.io/loadBalancerIP asks for a specific address. Agents get this from the infrastructure MCP.</Caption>
        </> : spec.loadBalancer === 'metallb' ? <Caption>Twenty addresses at the top of the VM subnet are reserved for MetalLB when the cluster is set up. Workspaces reach them directly; the Mac does through the VM network interface.</Caption> : null}>
          <div className="mc-frow" style={{ alignItems: 'flex-start' }}>
            <span className="mc-flabel" style={{ flex: 'none', width: 110 }}>Load balancer</span>
            <span className="mc-col" style={{ gap: 8, flex: 1 }}>
              {LB.map(l => (
                <label key={l.kind} className="mc-row" style={{ gap: 8, alignItems: 'flex-start' }}>
                  <Radio checked={spec.loadBalancer === l.kind} onChange={() => set({ loadBalancer: l.kind })} />
                  <span className="mc-col" style={{ gap: 1 }}><span>{l.name}</span><span className="mc-secondary" style={{ fontSize: 10 }}>{l.summary}</span></span>
                </label>
              ))}
            </span>
          </div>
          {spec.loadBalancer === 'bromure' && <FText label="LAN address pool" value={spec.lanPool ?? ''} placeholder="10.0.0.20-10.0.0.29 (optional)" onChange={v => set({ lanPool: v || undefined })} />}
        </FSection>
        <FSection footer={<Caption>k3s's bundled ingress. With the LAN load balancer it publishes ports 80 and 443 on this Mac.</Caption>}>
          <FToggle label="Traefik ingress controller" value={spec.ingress} onChange={v => set({ ingress: v })} />
        </FSection>
      </>;
      case 'Add-ons': return (
        <FSection footer={<>
          <Caption>Local clouds inside the cluster, from the floci family: each one a LoadBalancer Service on its own port, with data kept on the cluster's storage. The dashboard and the agents' infrastructure MCP hand out the endpoints and the test credentials. Free and open source (MIT), pulled from Docker Hub at setup. Services that spawn containers use the node's Docker and are best effort.</Caption>
          {EMU.map(e => <Caption key={e.kind}>{e.cloud} ({e.project}), port {e.port}: {e.services} and more.</Caption>)}
          <Caption>Leave a version empty to get the latest release on Docker Hub at setup. A tag (2.1.0) or a full image reference pins it.</Caption>
        </>}>
          {EMU.map(e => (
            <React.Fragment key={e.kind}>
              <FToggle label={`${e.cloud} emulator (${e.project})`} value={spec[e.key]} onChange={v => set({ [e.key]: v } as Partial<Spec>)} />
              {spec[e.key] && <FText label={`${e.project} version`} value={spec.emulatorVersions[e.kind] ?? ''} placeholder="latest release"
                                     onChange={v => setSpec(s => { const ev = { ...s.emulatorVersions }; if (v.trim()) ev[e.kind] = v.trim(); else delete ev[e.kind]; return { ...s, emulatorVersions: ev }; })} />}
            </React.Fragment>
          ))}
        </FSection>
      );
      case 'Access': return (
        <FSection title="Kubeconfig" footer={<Caption>Workspaces on the list get the cluster in their ~/.kube/config and see it through the infrastructure MCP. You can change this later from the dashboard.</Caption>}>
          <div style={{ padding: '10px 0' }}><AccessPicker access={access} workspaces={workspaces} onChange={setAccess} /></div>
        </FSection>
      );
    }
  })();

  return (
    <div className="mc-sheet" style={{ width: 720, height: 520 }}>
      <div className="mc-row" style={{ flex: 1, minHeight: 0, alignItems: 'stretch' }}>
        <div className="mc-cat-list">
          {CATS.map(c => (
            <div key={c.id} className={'mc-cat' + (cat === c.id ? ' on' : '')} onClick={() => setCat(c.id)}>
              <span className="mc-cat-icon" style={{ background: `linear-gradient(${c.color}, color-mix(in srgb, ${c.color} 82%, #000))` }}><SF name={c.icon} size={12} color="#fff" /></span>
              {c.id}
            </div>
          ))}
        </div>
        <div className="mc-vdivider" />
        <div className="mc-scroll" style={{ background: 'var(--mc-sheet-content, var(--text-bg))' }}>
          <div className="mc-col" style={{ padding: 24, gap: 16 }}>
            <div className="mc-sheet-title">{name.trim() || 'New Kubernetes cluster'}</div>
            <div className="mc-form mc-form-grouped">{detail}</div>
          </div>
        </div>
      </div>
      <div className="mc-sheet-bar">
        <Button onClick={onCancel}>Cancel</Button>
        {blocker && <span className="mc-secondary" style={{ fontSize: 10 }}>{blocker}</span>}
        <span className="mc-spacer" />
        <span className="mc-tertiary mc-ellipsis" style={{ fontSize: 10 }}>{summary}</span>
        <Button variant="prominent" disabled={!!blocker} onClick={create}>Create</Button>
      </div>
    </div>
  );
}

// ── New container registry ───────────────────────────────────────────────

export function NewRegistrySheet({ workspaces, existingNames, onCreate, onCancel }: {
  workspaces: WorkspaceRef[]; existingNames: string[]; onCreate: (doc: Record<string, unknown>) => void; onCancel: () => void;
}) {
  const [name, setName] = useState(() => {
    let c = 'registry', n = 2;
    while (existingNames.some(x => x.toLowerCase() === c.toLowerCase())) c = `registry ${n++}`;
    return c;
  });
  const [memoryGB, setMemory] = useState(1);
  const [diskGB, setDisk] = useState(40);
  const [access, setAccess] = useState<KubeAccess>({ mode: 'all' });
  const [autoStart, setAutoStart] = useState(true);
  const can = !!name.trim();
  return (
    <div className="mc-sheet" style={{ width: 560, height: 600 }}>
      <div className="mc-scroll" style={{ background: 'var(--mc-sheet-content, var(--text-bg))' }}>
        <div className="mc-col" style={{ padding: 24, gap: 16 }}>
          <div className="mc-row" style={{ gap: 10 }}>
            <span className="mc-cat-icon" style={{ background: `linear-gradient(${REGISTRY_TINT}, color-mix(in srgb, ${REGISTRY_TINT} 82%, #000))` }}><SF name="shippingbox.and.arrow.backward" size={12} color="#fff" /></span>
            <span className="mc-sheet-title">{name.trim() || 'New container registry'}</span>
          </div>
          <div className="mc-form mc-form-grouped">
            <FSection footer={<Caption>A private Docker registry in its own VM: build in a workspace, push here, run it in a cluster. Plain HTTP on the VM network; it never leaves this Mac.</Caption>}>
              <FText label="Name" value={name} onChange={setName} placeholder="registry" />
              <FToggle label="Start with Bromure" value={autoStart} onChange={setAutoStart} />
            </FSection>
            <FSection title="Machine">
              <FRow label="Memory"><Stepper value={memoryGB} min={1} max={16} onChange={setMemory} label={`${memoryGB} GB`} /></FRow>
              <FRow label="Image storage"><Stepper value={diskGB} min={10} max={2000} step={10} onChange={setDisk} label={`${diskGB} GB`} /></FRow>
            </FSection>
            <FSection title="Push access" footer={<Caption>Every cluster can pull from the registry; pushing is per workspace (docker there trusts it and $BROMURE_REGISTRY holds its address). The image disk is sparse: only pushed layers use space.</Caption>}>
              <div style={{ padding: '10px 0' }}><AccessPicker access={access} workspaces={workspaces} onChange={setAccess} /></div>
            </FSection>
          </div>
        </div>
      </div>
      <div className="mc-sheet-bar">
        <Button onClick={onCancel}>Cancel</Button>
        <span className="mc-spacer" />
        <span className="mc-tertiary" style={{ fontSize: 10 }}>{memoryGB} GB RAM · {diskGB} GB for images</span>
        <Button variant="prominent" disabled={!can} onClick={() => can && onCreate({ name: name.trim(), memoryGB, diskGB, access, autoStart })}>Create</Button>
      </div>
    </div>
  );
}
