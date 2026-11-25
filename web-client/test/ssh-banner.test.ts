import { describe, it, expect, vi } from 'vitest';
import { SSHConnection, SSHError } from '../src/core/ssh/client';
import type { ByteStream } from '../src/core/net/stream';

// A transport that opens and then stays silent: a bromure.io relay whose
// server end never joins (a server without the ws-relay listener).
function silentStream(): ByteStream & { closed: boolean } {
  return { closed: false, write() {}, close() { this.closed = true; }, onData: () => {}, onClose: () => {} };
}

describe('SSH banner timeout', () => {
  it('fails with code nobanner instead of hanging', async () => {
    vi.useFakeTimers();
    try {
      const s = silentStream();
      const p = SSHConnection.connect(s, { username: 'u', verifyHostKey: async () => true });
      const caught = p.catch(e => e);
      await vi.advanceTimersByTimeAsync(26_000);
      const e = await caught;
      expect(e).toBeInstanceOf(SSHError);
      expect((e as SSHError).code).toBe('nobanner');
      expect(s.closed).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });
});
