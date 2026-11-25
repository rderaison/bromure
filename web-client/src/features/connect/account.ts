// This device's bromure.io identity and the server directory the connect
// window renders — P2PEnrollmentCoordinator + RemoteConnectModel's account
// half. Sign-in opens bromure.io/app/enroll with a one-shot `state` nonce;
// only a callback echoing that nonce completes it (an unsolicited link can't
// enroll this device into someone else's workspace):
//   Electron: the system browser, back on `bromure-client://enroll?code&api&state`
//   (its own scheme: `bromure://` belongs to the macOS app / Bromure).
//   Hosted:   this tab goes to the page (return_to=/client/) and comes back
//             with `#enroll?code=…&api=…&state=…`.
// After enrolling, the device publishes its SSH key (POST /v1/devices/ssh-key)
// so the user's servers authorize it without a password.

import {
  ControlPlane, normalizeApiBase, loadDeviceRecord, saveDeviceRecord, clearDeviceRecord,
  type DeviceInfo, type DeviceRecord,
} from '../../core/cloud/controlPlane';
import { idbPut, idbDelete } from '../../core/ssh/keys';
import { electron, http, openExternal, shell, SITE_BASE, API_BASE } from '../../platform';
import { publicKeyLine } from '../../app/store';

export interface AccountSnapshot {
  record: DeviceRecord | null;
  loaded: boolean;
  busy: boolean;
  error: string | null;
  servers: DeviceInfo[];
  directoryLoading: boolean;
  directoryError: string | null;
  /** Doc/screenshot stand-in (?connectdemo=1): no bromure.io calls. */
  demo: boolean;
}

const STATE_KEY = 'bromure.enroll.state';
const DEMO = typeof location !== 'undefined' && new URLSearchParams(location.search).get('connectdemo') === '1';

let snap: AccountSnapshot = {
  record: null, loaded: false, busy: false, error: null, servers: [], directoryLoading: false, directoryError: null, demo: DEMO,
};
const listeners = new Set<() => void>();
function set(patch: Partial<AccountSnapshot>) { snap = { ...snap, ...patch }; for (const l of [...listeners]) l(); }

let directoryEverLoaded = false;
let firstLoad401Retries = 0;
let timer: ReturnType<typeof setInterval> | null = null;
let watchers = 0;

export const account = {
  get: () => snap,
  subscribe(l: () => void) { listeners.add(l); return () => { listeners.delete(l); }; },

  signedIn: () => !!snap.record,
  label: () => snap.record ? (snap.record.orgSlug || 'bromure.io') : null,
  controlPlane: () => snap.record ? new ControlPlane(snap.record.apiBase, http) : null,

  async load() {
    if (DEMO) {
      set({
        loaded: true,
        record: { deviceId: 'demo-client', deviceToken: 'demo', apiBase: 'https://bromure.io/api', deviceName: 'This device', enrolledAt: new Date().toISOString(), orgSlug: 'Pothos & Co.' },
        servers: [{ id: 'd-studio-7f2c', name: 'Mac Studio', capability: 'server', revoked: false, online: true, lastSeenAt: null, self: false, sshUsername: 'sonya' }],
      });
      return;
    }
    const record = (await loadDeviceRecord().catch(() => undefined)) ?? null;
    set({ record: snap.record ?? record, loaded: true });
  },

  /** Open the browser to the bromure.io enrollment handoff. */
  signIn() {
    const state = crypto.randomUUID().toUpperCase();
    // The API this sign-in talks to is bound HERE, with the nonce: the callback's
    // own `api=` can't redirect enrollment (and the one-shot code) elsewhere.
    const pending: PendingSignIn = { state, api: normalizeApiBase(API_BASE) };
    try { sessionStorage.setItem(STATE_KEY, JSON.stringify(pending)); } catch {}
    pendingState = pending;
    set({ error: null });
    const u = new URL(SITE_BASE.replace(/\/+$/, '') + '/app/enroll');
    u.searchParams.set('capability', 'client');
    u.searchParams.set('state', state);
    if (shell === 'web') {
      u.searchParams.set('return_to', '/client/');
      location.assign(u.toString());
    } else {
      // The desktop client's own scheme (bromure:// is the macOS app's).
      u.searchParams.set('return_scheme', 'bromure-client');
      // So bromure.io's brief "Opening…" screen names the right app.
      const plat = electron?.platform;
      if (plat === 'win32' || plat === 'linux') u.searchParams.set('platform', plat === 'win32' ? 'windows' : 'linux');
      openExternal(u.toString());
    }
  },

  /** Complete a sign-in from the callback (deep link or `#enroll?…`).
   *  No-op unless `state` matches the in-flight sign-in. */
  async complete(raw: string) {
    const q = raw.slice(raw.indexOf('?') + 1);
    const p = new URLSearchParams(q);
    const code = p.get('code'), state = p.get('state');
    let pending = pendingState;
    try { pending = pending ?? JSON.parse(sessionStorage.getItem(STATE_KEY) ?? 'null'); } catch {}
    if (!code || !state || !pending || typeof pending !== 'object' || state !== pending.state) return;
    const cbApi = p.get('api');
    if (cbApi && normalizeApiBase(cbApi) !== pending.api) { set({ error: 'The sign-in came back from an unexpected server. Try again.' }); return; }
    const api = pending.api;
    pendingState = null;
    try { sessionStorage.removeItem(STATE_KEY); } catch {}
    set({ busy: true, error: null });
    try {
      const cp = new ControlPlane(api, http);
      const { record, key } = await cp.enroll(code, deviceName());
      await idbPut('device-identity', { privateKey: key.privateKey, publicKey: key.publicKey });
      await saveDeviceRecord(record);
      directoryEverLoaded = false; firstLoad401Retries = 0;
      set({ record, busy: false, servers: [] });
      // The user's servers authorize this device's SSH key (no password).
      cp.uploadSSHKey(record.deviceToken, await publicKeyLine()).catch(e => console.warn('ssh-key publish', e));
      account.loadDirectory();
    } catch (e: any) {
      set({ busy: false, error: describeEnrollError(e) });
    }
  },

  /** Retire this device on bromure.io, then forget it locally. */
  async signOut() {
    const rec = snap.record;
    stopTimer();
    if (rec && !DEMO) {
      const cp = new ControlPlane(rec.apiBase, http);
      cp.removeSSHKey(rec.deviceToken).catch(() => {});
      cp.selfRevoke(rec.deviceToken).catch(() => {});
    }
    await clearDeviceRecord().catch(() => {});
    await idbDelete('device-identity').catch(() => {});
    directoryEverLoaded = false; firstLoad401Retries = 0;
    set({ record: null, servers: [], directoryError: null, error: null });
    if (watchers) startTimer();
  },

  async loadDirectory(silent = false) {
    const rec = snap.record;
    if (!rec || DEMO) return;
    if (!silent) set({ directoryError: null });
    if (!snap.servers.length) set({ directoryLoading: true });
    try {
      const devices = await new ControlPlane(rec.apiBase, http).listDevices(rec.deviceToken);
      if (snap.record !== rec) return;
      // Our own row (you don't mirror yourself), revoked devices and Sidecar
      // Macs (they serve no mirror) are left out.
      set({ servers: devices.filter(d => !d.self && !d.revoked && d.capability !== 'agent-host'), directoryLoading: false });
      directoryEverLoaded = true; firstLoad401Retries = 0;
    } catch (e: any) {
      set({ directoryLoading: false });
      if (snap.record !== rec) return;
      if (e?.status === 401 && directoryEverLoaded) {
        // Loaded before: a 401 now is a real revocation of this device.
        await clearDeviceRecord().catch(() => {});
        set({ record: null, servers: [], directoryError: "This device's bromure.io registration was revoked. Sign in again." });
      } else if (e?.status === 401) {
        // First load after sign-in: still propagating, or no servers yet.
        set({ servers: [] });
        if (firstLoad401Retries < 3) { firstLoad401Retries++; setTimeout(() => account.loadDirectory(true), 2000); }
      } else if (!silent) {
        set({ directoryError: "Couldn't load your servers." });
        setTimeout(() => account.loadDirectory(true), 2000);
      }
    }
  },

  /** The connect window polls the directory while it's open (12 s), so a
   *  server that stops heartbeating greys out within a cycle. */
  watch(): () => void {
    watchers++;
    if (snap.record) account.loadDirectory();
    startTimer();
    return () => { watchers = Math.max(0, watchers - 1); if (!watchers) stopTimer(); };
  },
};

interface PendingSignIn { state: string; api: string }
let pendingState: PendingSignIn | null = null;

function startTimer() {
  if (timer) return;
  timer = setInterval(() => account.loadDirectory(true), 12000);
}
function stopTimer() { if (timer) clearInterval(timer); timer = null; }

function deviceName(): string {
  const ua = navigator.userAgent;
  const os = /Windows/.test(ua) ? 'Windows' : /Mac OS X/.test(ua) ? 'Mac' : /Linux/.test(ua) ? 'Linux' : 'computer';
  if (electron) return `Bromure on ${os === 'computer' ? 'this computer' : os}`;
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  return `${browser} on ${os}`;
}

/** P2PEnrollmentCoordinator.describe */
function describeEnrollError(e: any): string {
  const status = e?.status as number | undefined;
  if (status === 404) return 'This authorization is invalid or already used.';
  if (status === 410) return 'This authorization expired — sign in again.';
  if (status) return `Enrollment failed (HTTP ${status}).`;
  if (e?.name === 'NotSupportedError') return "Couldn't sign the enrollment challenge.";
  return `Couldn't reach bromure.io: ${e?.message ?? e}`;
}

// ── callbacks ────────────────────────────────────────────────────────────

if (typeof window !== 'undefined') {
  // Electron: bromure-client://enroll?code=…&api=…&state=…
  electron?.onDeepLink(url => { if (/^bromure-client:\/\/enroll/i.test(url)) account.complete(url); });
  // Hosted: the enroll page returns to /client/#enroll?…
  if (location.hash.startsWith('#enroll?')) {
    const h = location.hash;
    history.replaceState(null, '', location.pathname + location.search);
    account.complete(h);
  }
  account.load();
  // Dev/test runs only (a dev relay is configured): drive sign-in from scripts.
  if (new URLSearchParams(location.search).has('devRelay') || import.meta.env?.DEV) {
    (window as any).__bromure = { ...(window as any).__bromure, account };
  }
}
