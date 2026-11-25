// FlowLineage (NetworkLineageView.swift): one network flow's lineage,
// assembled from Security Timeline rows — the `net.flow` event, the agent's
// reasoning for the tool call that caused it (`agent.reasoning`, joined on
// `tool_use_id`), and every other flow the same tool call caused.

import type { SecEvent } from '../model';

export interface Proc { id: number; pid: number; comm: string; exe?: string; argv?: string }

export interface FlowLineage {
  event: SecEvent;
  proto: string;
  destination: string;
  port: number;
  ip?: string;
  sport?: number;
  dev?: string;
  viaProxy: boolean;
  count: number;
  decision: string;
  layer?: string;
  reason?: string;
  processes: Proc[];
  tool?: string;
  toolUseID?: string;
  confidence?: string;
  command?: string;
  reasoning?: string;
  prompt?: string;
  intent?: string;
  /** Other flows from the same tool call, newest first. */
  siblings: SecEvent[];
}

const s = (d: any, k: string): string | undefined => (d && typeof d[k] === 'string' ? d[k] : undefined);
const i = (d: any, k: string): number | undefined => (d && typeof d[k] === 'number' && Number.isInteger(d[k]) ? d[k] : undefined);

export function toolUseID(e: SecEvent): string | undefined {
  const d = e.detail;
  if (!d) return undefined;
  if (d.agent && typeof d.agent === 'object') return s(d.agent, 'tool_use_id');
  return s(d, 'tool_use_id');
}

/** The lineage behind `event` (a `net.flow` row, or an `agent.reasoning`
 *  row: then its first flow, or the reasoning alone). */
export function flowLineage(event: SecEvent, all: SecEvent[]): FlowLineage | null {
  const d = event.detail;
  if (!d) return null;
  const id = toolUseID(event);
  const flows = id ? all.filter(e => e.eventType === 'net.flow' && e.profileID === event.profileID && toolUseID(e) === id) : [];
  const flow: SecEvent | undefined = event.eventType === 'net.flow' ? event : flows[flows.length - 1];
  const fd = flow?.detail;
  const procs: Proc[] = [];
  if (Array.isArray(fd?.processes)) {
    fd!.processes.forEach((p: any, n: number) => {
      if (!p || typeof p !== 'object') return;
      procs.push({ id: n, pid: i(p, 'pid') ?? 0, comm: s(p, 'comm') ?? '?', exe: s(p, 'exe'), argv: s(p, 'argv') });
    });
  }
  const agent = fd?.agent && typeof fd.agent === 'object' ? fd.agent : undefined;
  let reasoningEvent: SecEvent | undefined;
  if (id) for (let k = all.length - 1; k >= 0; k--) {
    const e = all[k];
    if (e.eventType === 'agent.reasoning' && e.profileID === event.profileID && s(e.detail, 'tool_use_id') === id) { reasoningEvent = e; break; }
  }
  const why = reasoningEvent?.detail ?? (event.eventType === 'agent.reasoning' ? d : undefined);
  const text = s(why, 'text');
  return {
    event: flow ?? event,
    proto: (s(fd, 'proto') ?? '').toUpperCase(),
    destination: [s(fd, 'host'), s(fd, 'dst')].find(x => x != null && x !== '') ?? '—',
    port: i(fd, 'dport') ?? 0,
    ip: s(fd, 'host') != null ? s(fd, 'dst') : undefined,
    sport: i(fd, 'sport'),
    dev: s(fd, 'dev'),
    viaProxy: fd?.via_proxy === true,
    count: i(fd, 'count') ?? 1,
    decision: s(fd, 'decision') ?? (flow ? 'unknown' : 'none'),
    layer: s(fd, 'layer'),
    reason: s(fd, 'reason'),
    processes: procs,
    tool: s(agent, 'tool') ?? s(reasoningEvent?.detail ?? d, 'tool'),
    toolUseID: id,
    confidence: s(agent, 'confidence'),
    command: s(fd, 'command'),
    reasoning: text ? text : undefined,
    prompt: s(why, 'prompt'),
    intent: s(why, 'intent'),
    siblings: flows.filter(e => e.id !== flow?.id).reverse(),
  };
}

export function layerName(layer: string) {
  switch (layer) {
    case 'l4': return 'firewall (L4)';
    case 'l7': return 'request policy (L7)';
    case 'identity': return 'binary identity';
    case 'proxy': return 'proxy';
    default: return layer;
  }
}

/** `lineageTint`: a CSS color token. */
export function lineageTint(decision: string) {
  switch (decision) {
    case 'deny': return 'var(--red)';
    case 'allow': return 'var(--green)';
    case 'audit': case 'raw': return 'var(--orange)';
    default: return 'var(--gray)';
  }
}

export function decisionLabel(decision: string) {
  switch (decision) {
    case 'deny': return 'Blocked';
    case 'allow': return 'Allowed';
    case 'audit': return 'Audited';
    case 'unfiltered': return 'Not filtered';
    case 'raw': return 'Raw frames';
    case 'none': return 'No flow';
    default: return 'Seen';
  }
}
