// The lineage sheet's demo data — BromureAC.swift's `ui-shot which=lineage`
// fixture (an agent installs a dependency; its postinstall script phones home
// and is denied). Used for screenshots / pixel comparison only.

import type { SecEvent } from '../model';

export function lineageDemo(which: 'lineage' | 'lineage-allowed' = 'lineage'): { events: SecEvent[]; focus: SecEvent } {
  const pid = 'C804D9CE-5548-44A0-89BA-B319D80DB174';
  const t0 = Date.now() - 300_000;
  const reasoning = {
    tool_use_id: 'toolu_01Demo', tool: 'Bash', truncated: false,
    text: "The health check needs an HTTP client with timeouts and retries. I'll add axios rather than hand-rolling fetch retries, then run the tests.",
    prompt: 'Add a health check that retries the payments API with a timeout.',
    intent: 'Install axios',
  };
  const r: SecEvent = {
    id: 'demo-r', time: t0, engine: 'Agent reasoning', condition: `Bash: ${reasoning.text}`, decision: 'before the tool call',
    kind: 'info', profileID: pid, workspace: 'Payments API', eventType: 'agent.reasoning', detail: reasoning,
  };
  const base: [number, string, string, string][] = [
    [412, 'claude', '/usr/bin/node', 'claude'],
    [980, 'bash', '/usr/bin/bash', "/bin/bash -c -l eval 'npm install axios' < /dev/null"],
    [981, 'npm', '/usr/bin/node', 'npm install axios'],
  ];
  const flow = (id: string, chain: typeof base, host: string, ip: string, decision: string, at: number, reason?: string): SecEvent => {
    const d: Record<string, any> = {
      proto: 'tcp', dst: ip, host, dport: 443, sport: 41000 + at, decision, layer: 'l7', count: 1,
      processes: chain.map(([p, comm, exe, argv]) => ({ pid: p, comm, exe, argv })),
      agent: { tool: 'Bash', tool_use_id: 'toolu_01Demo', confidence: 'exact' },
      command: 'npm install axios',
    };
    if (reason) d.reason = reason;
    return {
      id, time: t0 + at * 1000, engine: 'Network',
      condition: `Bash \`npm install axios\`: ${[...chain.map(c => c[1]), `TCP ${host}:443`].join(' → ')}`,
      decision: decision === 'deny' ? `denied — ${reason}` : 'allowed',
      kind: decision === 'deny' ? 'blocked' : 'allowed', profileID: pid, workspace: 'Payments API',
      eventType: 'net.flow', detail: d,
    };
  };
  const registry = flow('demo-a', base, 'registry.npmjs.org', '104.16.3.35', 'allow', 2);
  const postinstall: typeof base = [...base, [1290, 'sh', '/usr/bin/dash', 'sh -c node scripts/postinstall.js'],
    [1291, 'node', '/usr/bin/node', 'node scripts/postinstall.js']];
  const phoneHome = flow('demo-d', postinstall, 'telemetry.example.net', '203.0.113.24', 'deny', 5, 'no matching network policy');
  return { events: [r, registry, phoneHome], focus: which === 'lineage' ? phoneHome : registry };
}
