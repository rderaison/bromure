// The Security window's OCSF ▾ menu (OCSFExport.swift). On the Mac the
// toggle streams every event the LOCAL engines record to daily JSONL files;
// a mirrored host's engines run on the host (its own setting decides), so
// the web client offers a one-shot export of the rows shown instead, mapped
// to the same OCSF classes as far as a timeline row allows.

import type { MenuItem } from '../../ui/kit';
import { usePersisted } from '../../app/hostContext';
import { saveFile } from '../../platform';
import type { SecEvent } from './model';

export const CURRENT_SCHEMA = '1.8.0';

export function useOCSF() {
  const [schema, setSchema] = usePersisted<string>('bromure.ocsf.schemaVersion', CURRENT_SCHEMA);
  return { enabled: false, schema, setSchema };
}

const isIPv4 = (s?: string) => !!s && /^\d{1,3}(\.\d{1,3}){3}$/.test(s);

/** One row as an OCSF event (the row's engine stands in for its type). */
export function ocsfEvent(e: SecEvent, hostName: string, version: string): Record<string, unknown> {
  let cls = 0, clsName = 'Base Event', cat = 0, catName = 'Uncategorized';
  let activity: [number, string] = [99, 'Other'];
  const allowed: boolean | undefined = e.kind === 'info' ? undefined : e.kind === 'allowed';
  let severity: [number, string] = allowed === false ? [3, 'Medium'] : [1, 'Informational'];
  const extra: Record<string, unknown> = {};
  switch (e.engine) {
    case 'Firewall': {
      cls = 4001; clsName = 'Network Activity'; cat = 4; catName = 'Network Activity'; activity = [1, 'Open'];
      const fw = e.firewall;
      if (fw) {
        const ep: Record<string, unknown> = {};
        if (fw.host) { if (isIPv4(fw.host)) ep.ip = fw.host; else ep.domain = fw.host; }
        if (fw.ip) ep.ip = fw.ip;
        if (fw.port != null) ep.port = fw.port;
        extra.dst_endpoint = ep;
        extra.firewall_rule = { type: 'bromure', name: fw.rule ?? 'egress' };
      }
      break;
    }
    case 'Supply chain': case 'Guardrails':
      cls = 4002; clsName = 'HTTP Activity'; cat = 4; catName = 'Network Activity'; activity = [3, 'Get'];
      extra.firewall_rule = { type: 'bromure', name: e.engine === 'Guardrails' ? 'guardrails' : 'supply-chain' };
      break;
    case 'Credential brokering': case 'PII protection': case 'Credential used': case 'Agent delegation':
      cls = 6003; clsName = 'API Activity'; cat = 6; catName = 'Application Activity';
      break;
    case 'Prompt injection':
      cls = 2004; clsName = 'Detection Finding'; cat = 2; catName = 'Findings'; activity = [1, 'Create'];
      extra.finding_info = { uid: 'prompt-injection', title: 'Prompt injection' };
      break;
    case 'Guest sandbox':
      cls = 1001; clsName = 'File System Activity'; cat = 1; catName = 'System Activity';
      severity = [2, 'Low'];
      break;
  }
  const obj: Record<string, unknown> = {
    class_uid: cls, class_name: clsName, category_uid: cat, category_name: catName,
    activity_id: activity[0], activity_name: activity[1], type_uid: cls * 100 + activity[0],
    severity_id: severity[0], severity: severity[1],
    time: Math.round(e.time),
    message: `${e.condition} — ${e.decision}`,
    metadata: {
      uid: crypto.randomUUID().toLowerCase(), version,
      product: { name: 'Bromure Agentic Coding', vendor_name: 'Bromure', version: 'web' },
      log_name: e.eventType ?? e.engine,
    },
    container: { uid: e.profileID.toLowerCase(), ...(e.workspace ? { name: e.workspace } : {}) },
    device: { hostname: (e.workspace ?? '').toLowerCase().replace(/[^a-z0-9-]+/g, '-'), type_id: 99, type: 'Sandbox',
              os: { name: 'Linux', type_id: 200, type: 'Linux' } },
    observation_point_id: 2,
    ...extra,
    unmapped: { bromure_engine: e.engine, bromure_condition: e.condition, bromure_decision: e.decision, bromure_host: hostName,
                ...(e.detail ? { bromure_detail: e.detail } : {}) },
  };
  if (allowed !== undefined) {
    Object.assign(obj, {
      action_id: allowed ? 1 : 2, action: allowed ? 'Allowed' : 'Denied',
      disposition_id: allowed ? 1 : 2, disposition: allowed ? 'Allowed' : 'Blocked',
      status_id: allowed ? 1 : 2, status: allowed ? 'Success' : 'Failure',
    });
  }
  // `downgrade`: 1.3.0 consumers don't know container / observation_point_id.
  if (version.localeCompare('1.3.0', undefined, { numeric: true }) <= 0) {
    delete obj.container; delete obj.observation_point_id;
  }
  return obj;
}

export function ocsfMenuItems(o: ReturnType<typeof useOCSF>, events: SecEvent[], hostName: string): MenuItem[] {
  return [
    {
      label: 'Export OCSF JSON…', disabled: !events.length,
      action: () => {
        const day = new Date().toISOString().slice(0, 10);
        const lines = events.map(e => JSON.stringify(ocsfEvent(e, hostName, o.schema))).join('\n') + '\n';
        saveFile(`bromure-ocsf.${day}.jsonl`, lines, 'application/x-ndjson');
      },
    },
    { separator: true },
    { header: 'Schema' },
    { label: 'OCSF 1.8.0', checked: o.schema === '1.8.0', action: () => o.setSchema('1.8.0') },
    { label: 'OCSF 1.3.0 (Security Lake, Splunk, CrowdStrike)', checked: o.schema === '1.3.0', action: () => o.setSchema('1.3.0') },
  ];
}
