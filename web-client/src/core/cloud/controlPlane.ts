// bromure.io control plane (bromure-infra) — the same REST contract the Swift
// ControlPlaneClient speaks: device enrollment (Ed25519 challenge), the
// server directory, connection grants, the signaling device-channel, SSH key
// publication — plus the ws-relay a browser uses to reach a server's sshd
// (SSH stays end to end; bromure.io pipes opaque bytes).

import { WebSocketStream, type ByteStream } from '../net/stream';
import { toBase64, toHex, utf8 } from '../ssh/wire';
import { idbGet, idbPut, idbDelete } from '../ssh/keys';

export interface DeviceInfo {
  id: string; name: string; capability?: string | null; online?: boolean; lastSeenAt?: string | null;
  lastSeenIp?: string | null; sshUsername?: string | null; p2pServer?: boolean; revoked?: boolean;
  [k: string]: unknown;
}

export interface DeviceRecord {
  /** Bearer token (Electron). EMPTY for the hosted app: there the device
   *  identity is an httpOnly cookie (`bromure_device`) the page never sees —
   *  a device token can publish an authorized SSH key, so it must not be
   *  readable by script (XSS). See `delivery`. */
  deviceId: string; deviceToken: string; apiBase: string; userId?: string; orgKind?: string;
  delivery?: 'cookie';
  deviceName: string; enrolledAt: string;
  /** The workspace's slug (the connect window's account label). */
  orgSlug?: string;
  /** bromure.io accepted this credential at least once (a call with it
   *  succeeded). Until then a 401 may be enrollment propagation lag, not a
   *  revocation (AcceptedCredential in the macOS app). */
  accepted?: boolean;
}

/** How the platform performs HTTP to bromure.io (Electron: main process). */
export type HttpFn = (url: string, init: { method: string; headers: Record<string, string>; body?: string }) =>
  Promise<{ status: number; json: any }>;

export const defaultHttp: HttpFn = async (url, init) => {
  const r = await fetch(url, { method: init.method, headers: init.headers, body: init.body, credentials: 'include' });
  let json: any = {};
  try { json = await r.json(); } catch {}
  return { status: r.status, json };
};

export function normalizeApiBase(raw: string): string {
  let u = raw.trim().replace(/\/+$/, '');
  if (!/^https?:\/\//.test(u)) u = 'https://' + u;
  // The enroll link embeds the site origin; the device API lives under /api.
  if (/^https:\/\/(www\.)?bromure\.io$/.test(u)) u += '/api';
  return u;
}

export class ControlPlane {
  constructor(readonly apiBase: string, private http: HttpFn = defaultHttp) {}

  private async call<T>(method: string, path: string, body?: unknown, bearer?: string, retried = false): Promise<T> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    // Cookie identity (hosted): the cookie rides by itself; mutating calls
    // carry the CSRF token. When it isn't known (after a reload: the csrf
    // cookie is Path=/api, unreadable from /client), GET /v1/devices/csrf
    // fetches it first.
    const csrfGuarded = !bearer && method !== 'GET';
    if (bearer) headers.Authorization = `Bearer ${bearer}`;
    else if (csrfGuarded) {
      if (!csrfToken()) await this.refreshCsrf();
      const t = csrfToken(); if (t) headers['X-CSRF-Token'] = t;
    }
    const r = await this.http(this.apiBase + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    if (r.status === 403 && csrfGuarded && !retried) {
      // A stale token (rotated server-side): learn the current one, retry once.
      setCsrfToken(null);
      await this.refreshCsrf();
      if (csrfToken()) return this.call<T>(method, path, body, bearer, true);
    }
    if (r.status === 401) throw Object.assign(new Error('Signed out of bromure.io'), { status: 401 });
    if (r.status < 200 || r.status >= 300) throw Object.assign(new Error(r.json?.error ?? r.json?.message ?? `HTTP ${r.status}`), { status: r.status });
    return r.json as T;
  }

  // ── enrollment (two-phase Ed25519 challenge) ─────────────────────────────
  /** `cookie`: the hosted app's delivery (httpOnly cookie, no token in the
   *  response). `key`: re-use this device's enrollment key — re-enrolling the
   *  same key is idempotent server-side (same device, fresh credential). */
  async enroll(code: string, deviceName: string, opts: { cookie?: boolean; key?: CryptoKeyPair } = {}): Promise<{ record: DeviceRecord; key: CryptoKeyPair }> {
    const key = opts.key ?? await crypto.subtle.generateKey({ name: 'Ed25519' } as any, false, ['sign', 'verify']) as CryptoKeyPair;
    const pub = new Uint8Array(await crypto.subtle.exportKey('raw', key.publicKey));
    const begin = await this.call<any>('POST', '/v1/devices/enroll', {
      code, devicePubkey: toHex(pub), deviceName,
    });
    const challengeId: string = begin.challengeId;
    const msg = utf8(begin.signPayload ?? `bromure-p2p-enroll:v1:${challengeId}:${begin.challenge}`);
    const sig = new Uint8Array(await crypto.subtle.sign({ name: 'Ed25519' } as any, key.privateKey, msg as BufferSource));
    const done = await this.call<any>('POST', '/v1/devices/enroll',
      { challengeId, signature: toBase64(sig), ...(opts.cookie ? { delivery: 'cookie' } : {}) });
    if (opts.cookie) setCsrfToken(done.csrfToken);
    const record: DeviceRecord = {
      deviceId: done.deviceId, deviceToken: opts.cookie ? '' : done.deviceToken,
      ...(opts.cookie ? { delivery: 'cookie' as const } : {}),
      apiBase: this.apiBase, userId: done.userId, orgKind: done.orgKind, orgSlug: done.orgSlug ?? undefined, deviceName,
      enrolledAt: new Date().toISOString(),
    };
    return { record, key };
  }

  listDevices(bearer: string) { return this.call<{ devices: DeviceInfo[] }>('GET', '/v1/devices', undefined, bearer).then(r => r.devices ?? []); }
  requestConnection(bearer: string, deviceId: string) {
    return this.call<{ connection: { id: string; expiresAt: string } }>('POST', '/v1/connections', { deviceId }, bearer).then(r => r.connection);
  }
  uploadSSHKey(bearer: string, sshPublicKey: string) {
    return this.call('POST', '/v1/devices/ssh-key', { sshPublicKey, sshUsername: 'web' }, bearer);
  }
  removeSSHKey(bearer: string) { return this.call('DELETE', '/v1/devices/ssh-key', undefined, bearer); }
  selfRevoke(bearer: string) { return this.call('POST', '/v1/devices/self-revoke', {}, bearer); }
  /** Cookie identity: extends the 24h sliding idle TTL (send while visible). */
  /** Cookie identity: (re)learn the CSRF token (a safe GET, no token needed). */
  async refreshCsrf() {
    const r = await this.call<{ csrfToken?: string }>('GET', '/v1/devices/csrf').catch(() => undefined);
    if (r?.csrfToken) setCsrfToken(r.csrfToken);
  }
  /** …and echoes the current CSRF token: kept in memory only. */
  async heartbeat() {
    const r = await this.call<{ ok?: boolean; csrfToken?: string } | undefined>('POST', '/v1/devices/heartbeat', {});
    if (r?.csrfToken) setCsrfToken(r.csrfToken);
    return r;
  }
  /** Cookie identity: revoke the device and clear its cookies. */
  async webLogout() {
    const r = await this.call('POST', '/v1/devices/web/logout', {});
    setCsrfToken(null);
    return r;
  }

  wsBase() { return this.apiBase.replace(/^http/, 'ws'); }

  /** Dial a server through the ws-relay: grant → `offer {note:"ws-relay"}` on
   *  the device channel → join `/v1/connections/:id/relay` as the dialer. */
  async dialRelay(bearer: string, deviceId: string): Promise<ByteStream> {
    const grant = await this.requestConnection(bearer, deviceId);
    // Bearer (Electron): in the subprotocol, since a WebSocket can't carry
    // headers. Cookie (hosted): nothing — the cookie rides the same-origin upgrade.
    const ch = await WebSocketStream.open(`${this.wsBase()}/v1/device-channel`, bearer ? ['bromure.device.v1', `bearer.${bearer}`] : undefined);
    // The device channel is text JSON; WebSocketStream hands us bytes.
    let relay: ByteStream;
    try {
      const frame = JSON.stringify({ connectionId: grant.id, seq: 1, kind: 'offer', payload: { v: 1, note: 'ws-relay' } });
      ch.sendText(frame);
      relay = await WebSocketStream.open(`${this.wsBase()}/v1/connections/${encodeURIComponent(grant.id)}/relay`,
        bearer ? ['bromure.relay.v1', `bearer.${bearer}`] : undefined);
    } catch (e) {
      // No relay: the signaling socket has nothing left to carry.
      ch.close();
      throw e;
    }
    // The signaling socket is only needed to deliver the offer.
    setTimeout(() => ch.close(), 5000);
    return relay;
  }
}

// ── CSRF token (cookie identity) ─────────────────────────────────────────
// Memory only: from the enrollment response, GET /v1/devices/csrf (after a
// reload) and every heartbeat response — the device cookies are Path=/api, so
// a /client page can't read them. The cookie read below only serves a server
// that still sets the csrf cookie at Path=/ (no /csrf endpoint) — drop it
// once bromure.io runs the Path=/api cookies everywhere.
let csrfMem: string | null = null;
export function setCsrfToken(t: string | undefined | null) { csrfMem = t ?? null; }
export function csrfToken(): string | null {
  if (csrfMem) return csrfMem;
  if (typeof document === 'undefined') return null;
  const m = /(?:^|;\s*)bromure_device_csrf=([^;]+)/.exec(document.cookie);
  return m ? decodeURIComponent(m[1]) : null;
}

// ── this device's bromure.io identity (IndexedDB) ─────────────────────────

export async function loadDeviceRecord(): Promise<DeviceRecord | undefined> { return idbGet<DeviceRecord>('device-record'); }
export async function saveDeviceRecord(r: DeviceRecord) { await idbPut('device-record', r); }
export async function clearDeviceRecord() { await idbDelete('device-record'); }
