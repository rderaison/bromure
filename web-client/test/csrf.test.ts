import { describe, it, expect, beforeEach } from 'vitest';
import { ControlPlane, setCsrfToken } from '../src/core/cloud/controlPlane';

// The hosted app's device cookies are Path=/api: a /client page can't read the
// csrf cookie, so the token lives in memory — learned at enrollment, fetched
// with GET /v1/devices/csrf after a reload, and echoed by every heartbeat.

type Call = { path: string; method: string; csrf?: string; auth?: string };
function fakeServer(opts: { token: string; served?: string }) {
  const calls: Call[] = [];
  let current = opts.token;
  const http = async (url: string, init: { method: string; headers: Record<string, string> }) => {
    const path = new URL(url).pathname.replace(/^\/api/, '');
    calls.push({ path, method: init.method, csrf: init.headers['X-CSRF-Token'], auth: init.headers.Authorization });
    if (path === '/v1/devices/csrf' && init.method === 'GET') return { status: 200, json: { csrfToken: opts.served ?? current } };
    if (!init.headers.Authorization && init.method !== 'GET' && init.headers['X-CSRF-Token'] !== current) return { status: 403, json: { error: 'csrf' } };
    if (path === '/v1/devices/heartbeat') return { status: 200, json: { ok: true, csrfToken: current } };
    return { status: 200, json: { connection: { id: 'c1', expiresAt: '' } } };
  };
  return { calls, http: http as any, rotate(t: string) { current = t; } };
}
const trace = (calls: Call[]) => calls.map(c => `${c.method} ${c.path}${c.csrf ? ' ' + c.csrf : ''}`);

describe('CSRF token (cookie identity)', () => {
  beforeEach(() => setCsrfToken(null));

  it('after a reload (no token in memory) a mutation fetches the token first', async () => {
    const s = fakeServer({ token: 'T1' });
    await new ControlPlane('https://x/api', s.http).requestConnection('', 'dev1');
    expect(trace(s.calls)).toEqual(['GET /v1/devices/csrf', 'POST /v1/connections T1']);
  });

  it('the heartbeat after a reload carries the fetched token, and its echo is kept', async () => {
    const s = fakeServer({ token: 'T1' });
    const cp = new ControlPlane('https://x/api', s.http);
    await cp.heartbeat();
    await cp.requestConnection('', 'dev1');
    expect(trace(s.calls)).toEqual(['GET /v1/devices/csrf', 'POST /v1/devices/heartbeat T1', 'POST /v1/connections T1']);
  });

  it('a stale token (403) is re-fetched once and the call retried', async () => {
    const s = fakeServer({ token: 'T1' });
    setCsrfToken('T1');
    s.rotate('T2');
    await new ControlPlane('https://x/api', s.http).requestConnection('', 'dev1');
    expect(trace(s.calls)).toEqual(['POST /v1/connections T1', 'GET /v1/devices/csrf', 'POST /v1/connections T2']);
  });

  it('a 403 that a fresh token does not fix is not retried forever', async () => {
    const s = fakeServer({ token: 'T1', served: 'WRONG' });
    await expect(new ControlPlane('https://x/api', s.http).requestConnection('', 'dev1')).rejects.toMatchObject({ status: 403 });
    expect(s.calls.filter(c => c.path === '/v1/connections')).toHaveLength(2);
  });

  it('bearer (desktop) calls never fetch or send a CSRF token', async () => {
    const s = fakeServer({ token: 'T1' });
    await new ControlPlane('https://x/api', s.http).requestConnection('tok', 'dev1');
    expect(s.calls).toEqual([{ path: '/v1/connections', method: 'POST', csrf: undefined, auth: 'Bearer tok' }]);
  });
});
