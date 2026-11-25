import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Regression: a refused/timed-out relay open left the already-open
// device-channel (signaling) WebSocket open; every retry leaked one.

const opened: { url: string; closed: boolean }[] = [];
let relayOutcome: 'ok' | 'refused' = 'ok';

vi.mock('../src/core/net/stream', () => ({
  WebSocketStream: {
    open: vi.fn(async (url: string) => {
      if (url.endsWith('/relay') && relayOutcome === 'refused') throw new Error('relay refused (1008)');
      const s = { url, closed: false, write() {}, onData() {}, onClose() {}, sendText() {}, close() { s.closed = true; } };
      opened.push(s);
      return s;
    }),
  },
}));

const { ControlPlane } = await import('../src/core/cloud/controlPlane');

const http = (async () => ({ status: 200, json: { connection: { id: 'c1', expiresAt: '' } } })) as any;

describe('dialRelay', () => {
  beforeEach(() => { opened.length = 0; vi.useFakeTimers(); });
  afterEach(() => vi.useRealTimers());

  it('closes the device-channel when the relay open fails', async () => {
    relayOutcome = 'refused';
    const cp = new ControlPlane('https://bromure.example', http);
    await expect(cp.dialRelay('tok', 'dev1')).rejects.toThrow('relay refused');
    const ch = opened.find(s => s.url.endsWith('/v1/device-channel'))!;
    expect(ch).toBeTruthy();
    expect(ch.closed).toBe(true);
  });

  it('on success, keeps the device-channel briefly for the offer, then closes it', async () => {
    relayOutcome = 'ok';
    const cp = new ControlPlane('https://bromure.example', http);
    const relay = await cp.dialRelay('tok', 'dev1') as any;
    const ch = opened.find(s => s.url.endsWith('/v1/device-channel'))!;
    expect(relay.url).toMatch(/\/v1\/connections\/c1\/relay$/);
    expect(ch.closed).toBe(false);
    await vi.advanceTimersByTimeAsync(5000);
    expect(ch.closed).toBe(true);
    expect(relay.closed).toBe(false);
  });
});
