// A bromure.io server as a HostTarget (RemoteConnectModel.peerHost): dialed
// through the ws-relay (ControlPlane.dialRelay — SSH stays end to end), its
// host key pinned under the stable alias `bromure-peer-<deviceID>` (the relay
// endpoint says nothing about which server answered). Username precedence:
// the server's published sshUsername, else the one that worked last time.

import { ControlPlane, loadDeviceRecord, type DeviceInfo, type DeviceRecord } from '../../core/cloud/controlPlane';
import type { HostTarget } from '../../core/remote/host';
import { http } from '../../platform';
import { account } from './account';

const PINS_KEY = 'bromure.peerHostKeys.v1';
const USER_KEY = (id: string) => `bromure.peer.user.${id}`;

export const peerTargetID = (deviceID: string) => `peer-${deviceID}`;
export const peerAlias = (deviceID: string) => `bromure-peer-${deviceID}`;

function readPins(): Record<string, string> {
  try { return JSON.parse(localStorage.getItem(PINS_KEY) || '{}'); } catch { return {}; }
}
export function peerPin(deviceID: string): string | undefined { return readPins()[peerAlias(deviceID)]; }
export function setPeerPin(deviceID: string, fp: string | undefined) {
  const pins = readPins();
  if (fp) pins[peerAlias(deviceID)] = fp; else delete pins[peerAlias(deviceID)];
  try { localStorage.setItem(PINS_KEY, JSON.stringify(pins)); } catch {}
}

export function isValidSSHUser(u: string) {
  return !!u && u.length <= 64 && !u.startsWith('-') && /^[A-Za-z0-9_.@-]+$/.test(u);
}
export function rememberedPeerUser(id: string): string | null {
  try { const v = localStorage.getItem(USER_KEY(id)); return v && isValidSSHUser(v) ? v : null; } catch { return null; }
}
export function rememberPeerUser(id: string, user: string) {
  try { localStorage.setItem(USER_KEY(id), user); } catch {}
}

export const deviceDisplayName = (d: Pick<DeviceInfo, 'id' | 'name'>) => (d.name ? d.name : d.id.slice(0, 8));

/** The HostTarget for a directory server. `pinnedFingerprint` reads and writes
 *  the alias pin, so RemoteHost's TOFU / changed-key path persists it. */
export function peerTarget(server: DeviceInfo, record: DeviceRecord): HostTarget & { peerDeviceID: string } {
  const published = typeof server.sshUsername === 'string' && isValidSSHUser(server.sshUsername) ? server.sshUsername : null;
  const user = published ?? rememberedPeerUser(server.id) ?? '';
  const id = server.id;
  const t = {
    id: peerTargetID(id),
    name: deviceDisplayName(server),
    username: user,
    peerDeviceID: id,
    dial: () => new ControlPlane(record.apiBase, http).dialRelay(record.deviceToken, id),
  } as HostTarget & { peerDeviceID: string };
  Object.defineProperty(t, 'pinnedFingerprint', {
    get: () => peerPin(id),
    set: (fp: string | undefined) => setPeerPin(id, fp),
    enumerable: true, configurable: true,
  });
  return t;
}

/** For the `#/peer/<deviceID>` route: the target from the directory (fetched
 *  if the connect window hasn't loaded it). Null when signed out or unknown. */
export async function peerTargetFor(deviceID: string): Promise<(HostTarget & { peerDeviceID: string }) | null> {
  const record = account.get().record ?? (await loadDeviceRecord().catch(() => undefined)) ?? null;
  if (!record) return null;
  let server = account.get().servers.find(s => s.id === deviceID);
  if (!server) {
    try {
      const list = await new ControlPlane(record.apiBase, http).listDevices(record.deviceToken);
      server = list.find(s => s.id === deviceID);
    } catch { /* offline: fall through */ }
  }
  // Only a server the directory lists for THIS account: a link can't make us
  // dial an arbitrary id (and hand it our device token on the relay).
  if (!server) return null;
  return peerTarget(server, record);
}
