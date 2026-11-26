import { describe, it, expect, vi, beforeEach } from 'vitest';

// Regression (CWE-613): the desktop sign-out fired SSH-key removal and device
// self-revocation without awaiting them, swallowed their errors and deleted
// the local credential anyway — a failed revocation left the device bearer
// (and its SSH authorization) live on bromure.io with no way to retry.

const calls: string[] = [];
const outcome: Record<string, number | null> = {};   // method → HTTP status to fail with (null: ok)
let stored: any = null;

// method → statuses to fail with, one per call in turn (then succeed).
const queue: Record<string, number[]> = {};
const fail = (m: string) => {
  calls.push(m);
  const st = queue[m]?.length ? queue[m].shift()! : outcome[m];
  if (st != null) return Promise.reject(Object.assign(new Error(`HTTP ${st}`), { status: st }));
  return Promise.resolve({ ok: true });
};

vi.mock('../src/core/cloud/controlPlane', () => ({
  ControlPlane: class {
    removeSSHKey() { return fail('removeSSHKey'); }
    selfRevoke() { return fail('selfRevoke'); }
    webLogout() { return fail('webLogout'); }
  },
  normalizeApiBase: (s: string) => s,
  loadDeviceRecord: async () => stored,
  saveDeviceRecord: async (r: any) => { stored = r; },
  clearDeviceRecord: async () => { calls.push('clearDeviceRecord'); stored = null; },
}));
vi.mock('../src/core/ssh/keys', () => ({ idbGet: async () => undefined, idbPut: async () => {}, idbDelete: async () => {} }));
vi.mock('../src/platform', () => ({ electron: undefined, http: async () => ({ status: 200 }), openExternal() {}, shell: 'electron', SITE_BASE: '', API_BASE: '' }));
vi.mock('../src/app/store', () => ({ publicKeyLine: async () => '' }));

const { account, setRevoke401DelayForTests, refusalIsFinal } = await import('../src/features/connect/account');
setRevoke401DelayForTests(0);

async function signedIn(delivery?: 'cookie', accepted = true, enrolledAt = new Date().toISOString()) {
  stored = { deviceId: 'd1', deviceToken: delivery ? '' : 'tok', apiBase: 'https://bromure.example/api', deviceName: 'x', enrolledAt, delivery, accepted };
  await account.load();
  expect(account.get().record).toBeTruthy();
}

describe('account.signOut', () => {
  beforeEach(() => { calls.length = 0; for (const k of Object.keys(outcome)) delete outcome[k]; for (const k of Object.keys(queue)) delete queue[k]; });

  it('desktop: awaits SSH-key removal and self-revocation, then forgets the credential', async () => {
    await signedIn();
    expect(await account.signOut()).toBe(true);
    expect(calls).toEqual(['removeSSHKey', 'selfRevoke', 'clearDeviceRecord']);
    expect(account.get().record).toBeNull();
  });

  it('desktop: a failed self-revocation keeps the credential and shows the failure', async () => {
    await signedIn();
    outcome.selfRevoke = 503;
    expect(await account.signOut()).toBe(false);
    expect(calls).not.toContain('clearDeviceRecord');
    expect(account.get().record?.deviceToken).toBe('tok');
    expect(stored).toBeTruthy();
    expect(account.get().error).toMatch(/Couldn't sign out of bromure\.io/);
    // …and a retry, once bromure.io answers, completes it.
    delete outcome.selfRevoke; calls.length = 0;
    expect(await account.signOut()).toBe(true);
    expect(account.get().record).toBeNull();
  });

  it('desktop: a failed SSH-key removal keeps the credential (nothing revoked yet)', async () => {
    await signedIn();
    outcome.removeSSHKey = 500;
    expect(await account.signOut()).toBe(false);
    expect(calls).toEqual(['removeSSHKey']);
    expect(account.get().record).toBeTruthy();
    delete outcome.removeSSHKey;
    expect(await account.signOut()).toBe(true);
  });

  it('desktop: already revoked (401, a credential bromure.io accepted before) or no SSH key (404) still signs out', async () => {
    await signedIn();
    outcome.removeSSHKey = 404; outcome.selfRevoke = 401;
    expect(await account.signOut()).toBe(true);
    expect(account.get().record).toBeNull();
    await signedIn();
    outcome.removeSSHKey = 401; calls.length = 0;
    expect(await account.signOut()).toBe(true);
    expect(calls).toEqual(['removeSSHKey', 'clearDeviceRecord']);
  });

  // Regression (CWE-613): right after enrollment a 401 can be propagation lag,
  // not a revocation; forgetting the credential then lost the only one able
  // to revoke a still-live device.
  it('a 401 for a credential never accepted is retried, then keeps the credential', async () => {
    await signedIn(undefined, false);
    outcome.selfRevoke = 401;
    expect(await account.signOut()).toBe(false);
    expect(calls).toEqual(['removeSSHKey', 'selfRevoke', 'selfRevoke', 'selfRevoke', 'selfRevoke']);
    expect(calls).not.toContain('clearDeviceRecord');
    expect(account.get().record?.deviceToken).toBe('tok');
    expect(account.get().error).toMatch(/couldn't be confirmed/);
    delete outcome.selfRevoke;
    expect(await account.signOut()).toBe(true);
  });

  it('…the same for the SSH-key removal and the hosted web logout', async () => {
    await signedIn(undefined, false);
    outcome.removeSSHKey = 401;
    expect(await account.signOut()).toBe(false);
    expect(calls).not.toContain('selfRevoke');
    expect(account.get().record).toBeTruthy();
    delete outcome.removeSSHKey;
    expect(await account.signOut()).toBe(true);
    await signedIn('cookie', false);
    outcome.webLogout = 401; calls.length = 0;
    expect(await account.signOut()).toBe(false);
    expect(calls).toEqual(['webLogout', 'webLogout', 'webLogout', 'webLogout']);
    expect(account.get().record).toBeTruthy();
    delete outcome.webLogout;
    expect(await account.signOut()).toBe(true);
  });

  // Regression (CWE-613 follow-up): a record saved before `accepted` existed
  // starts unaccepted; one revoked before its first successful call answers
  // 401 forever and could never sign out. Past propagation, a 401 is final.
  it('a 401 for a credential enrolled long ago signs out, accepted or not', async () => {
    await signedIn(undefined, false, new Date(Date.now() - 3600_000).toISOString());
    outcome.selfRevoke = 401;
    expect(await account.signOut()).toBe(true);
    expect(calls).toEqual(['removeSSHKey', 'selfRevoke', 'clearDeviceRecord']);
    expect(account.get().record).toBeNull();
  });

  it('a 401 that clears once the credential propagates signs out', async () => {
    await signedIn(undefined, false);
    queue.selfRevoke = [401, 401];
    expect(await account.signOut()).toBe(true);
    expect(calls).toEqual(['removeSSHKey', 'selfRevoke', 'selfRevoke', 'selfRevoke', 'clearDeviceRecord']);
    expect(account.get().record).toBeNull();
  });

  it('hosted (cookie): a failed web logout keeps the identity', async () => {
    await signedIn('cookie');
    outcome.webLogout = 502;
    expect(await account.signOut()).toBe(false);
    expect(account.get().record).toBeTruthy();
    delete outcome.webLogout;
    expect(await account.signOut()).toBe(true);
    expect(account.get().record).toBeNull();
  });
});

describe('refusalIsFinal', () => {
  const rec = (over: Record<string, any>) => ({ deviceId: 'd', deviceToken: 't', apiBase: '', deviceName: '', enrolledAt: '', ...over });
  const now = Date.parse('2026-11-26T12:00:00Z');
  it('final once accepted, past the propagation window, or with no readable enrollment time', () => {
    expect(refusalIsFinal(rec({ accepted: true, enrolledAt: '2026-11-26T11:59:59Z' }), now)).toBe(true);
    expect(refusalIsFinal(rec({ enrolledAt: '2026-11-26T11:00:00Z' }), now)).toBe(true);
    expect(refusalIsFinal(rec({ enrolledAt: '' }), now)).toBe(true);
    expect(refusalIsFinal(rec({ enrolledAt: '2026-11-26T11:58:00Z' }), now)).toBe(false);
  });
});
