import { describe, it, expect } from 'vitest';
import { requestResending } from '../src/features/boards/resend';

// "Ask <session> to fix it" failed at once with "the server didn't answer"
// when the connection under it had died while idle; sending it again worked.
// A hand-over that's safe to send twice is now resent once by itself.

function flaky(failures: number, reply: any = { ok: true }) {
  let calls = 0;
  const send = async () => { calls++; if (calls <= failures) throw new Error('channel closed'); return reply; };
  return { send, calls: () => calls };
}

describe('requestResending', () => {
  it('resends once a request that got no answer', async () => {
    const f = flaky(1);
    expect(await requestResending(f.send, true, 0)).toEqual({ ok: true });
    expect(f.calls()).toBe(2);
  });

  it('gives up after the one resend', async () => {
    const f = flaky(2);
    await expect(requestResending(f.send, true, 0)).rejects.toThrow('channel closed');
    expect(f.calls()).toBe(2);
  });

  it("doesn't resend what isn't safe to send twice", async () => {
    const f = flaky(1);
    await expect(requestResending(f.send, false, 0)).rejects.toThrow('channel closed');
    expect(f.calls()).toBe(1);
  });

  it('takes an answer as final, even an error', async () => {
    const f = flaky(0, { error: 'that session is gone' });
    expect(await requestResending(f.send, true, 0)).toEqual({ error: 'that session is gone' });
    expect(f.calls()).toBe(1);
  });
});
