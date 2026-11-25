import { describe, it, expect } from 'vitest';
import { probeCustomServer, PROBE_TOO_OLD } from '../src/features/editor/categories/probeServer';

// "Test Connection" goes through the mirrored host; the client never fetches
// the custom server itself.

function fakeHost(reply: any) {
  const calls: any[] = [];
  const request = async (method: string, path: string, body?: unknown, opts?: any) => { calls.push({ method, path, body, opts }); return reply; };
  return { calls, request };
}

describe('probeCustomServer', () => {
  it('asks the host and returns its model ids', async () => {
    const h = fakeHost({ ok: true, models: ['qwen3-coder', 'glm-4.6'] });
    expect(await probeCustomServer(h.request, 'http://10.0.0.5:8000/v1', '••••••••')).toEqual(['qwen3-coder', 'glm-4.6']);
    expect(h.calls).toEqual([{ method: 'POST', path: '/models/probe-server', body: { baseURL: 'http://10.0.0.5:8000/v1', apiKey: '••••••••' }, opts: { allowError: true } }]);
  });

  it('sends no key when there is none', async () => {
    const h = fakeHost({ ok: true, models: [] });
    await probeCustomServer(h.request, 'http://x', null);
    expect(h.calls[0].body).toEqual({ baseURL: 'http://x' });
  });

  it("throws the host's reason", async () => {
    const h = fakeHost({ ok: false, error: 'Could not connect to the server.' });
    await expect(probeCustomServer(h.request, 'http://x')).rejects.toThrow('Could not connect to the server.');
  });

  it('says so when the host predates the route', async () => {
    const h = fakeHost({ error: 'bad action or repo' });
    await expect(probeCustomServer(h.request, 'http://x')).rejects.toThrow(PROBE_TOO_OLD);
  });

  it('never touches the network itself', async () => {
    const orig = globalThis.fetch;
    let fetched = false;
    globalThis.fetch = (async () => { fetched = true; throw new Error('direct fetch'); }) as any;
    try { await probeCustomServer(fakeHost({ ok: true, models: ['m'] }).request, 'http://x'); }
    finally { globalThis.fetch = orig; }
    expect(fetched).toBe(false);
  });
});
