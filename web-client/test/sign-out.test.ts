import { describe, it, expect, vi, beforeEach } from 'vitest';

// Regression (CWE-613): the desktop sign-out fired SSH-key removal and device
// self-revocation without awaiting them, swallowed their errors and deleted
// the local credential anyway — a failed revocation left the device bearer
// (and its SSH authorization) live on bromure.io with no way to retry.

const calls: string[] = [];
const outcome: Record<string, number | null> = {};   // method → HTTP status to fail with (null: ok)
let stored: any = null;

const fail = (m: string) => { calls.push(m); const st = outcome[m]; if (st != null) return Promise.reject(Object.assign(new Error(`HTTP ${st}`), { status: st })); return Promise.resolve({ ok: true }); };

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

const { account } = await import('../src/features/connect/account');

async function signedIn(delivery?: 'cookie') {
  stored = { deviceId: 'd1', deviceToken: delivery ? '' : 'tok', apiBase: 'https://bromure.example/api', deviceName: 'x', enrolledAt: '', delivery };
  await account.load();
  expect(account.get().record).toBeTruthy();
}

describe('account.signOut', () => {
  beforeEach(() => { calls.length = 0; for (const k of Object.keys(outcome)) delete outcome[k]; });

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

  it('desktop: already revoked (401) or no SSH key (404) still signs out', async () => {
    await signedIn();
    outcome.removeSSHKey = 404; outcome.selfRevoke = 401;
    expect(await account.signOut()).toBe(true);
    expect(account.get().record).toBeNull();
    await signedIn();
    outcome.removeSSHKey = 401; calls.length = 0;
    expect(await account.signOut()).toBe(true);
    expect(calls).toEqual(['removeSSHKey', 'clearDeviceRecord']);
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
