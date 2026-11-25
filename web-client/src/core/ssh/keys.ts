// The client's SSH identity: an Ed25519 key generated with WebCrypto.
// In the app it's created NON-extractable and persisted as a CryptoKey in
// IndexedDB (structured clone), so script on the page can sign with it but
// can't read the private bytes out. Tests use an extractable JWK.

import type { ClientKey } from './client';
import { ed25519Blob, fingerprintOf } from './client';
import { toBase64 } from './wire';

export async function generateClientKey(extractable = false): Promise<ClientKey & { publicKey: CryptoKey }> {
  const kp = await crypto.subtle.generateKey({ name: 'Ed25519' } as any, extractable, ['sign', 'verify']) as CryptoKeyPair;
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
  return { privateKey: kp.privateKey, publicKey: kp.publicKey, publicRaw };
}

export function openSSHPublicLine(publicRaw: Uint8Array, comment = 'bromure-web'): string {
  return `ssh-ed25519 ${toBase64(ed25519Blob(publicRaw))} ${comment}`;
}

export async function keyFingerprint(publicRaw: Uint8Array): Promise<string> {
  return fingerprintOf(ed25519Blob(publicRaw));
}

export async function importJWKKey(jwk: JsonWebKey): Promise<ClientKey> {
  const privateKey = await crypto.subtle.importKey('jwk', jwk, { name: 'Ed25519' } as any, false, ['sign']);
  const x = jwk.x!.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(x + '='.repeat((4 - x.length % 4) % 4));
  const publicRaw = Uint8Array.from(bin, c => c.charCodeAt(0));
  return { privateKey, publicRaw };
}

// ── IndexedDB persistence ────────────────────────────────────────────────

const DB = 'bromure-client';
const STORE = 'keys';

function idb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function idbGet<T>(key: string): Promise<T | undefined> {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const r = db.transaction(STORE).objectStore(STORE).get(key);
    r.onsuccess = () => resolve(r.result as T | undefined);
    r.onerror = () => reject(r.error);
  });
}

export async function idbPut(key: string, value: unknown): Promise<void> {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

export async function idbDelete(key: string): Promise<void> {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).delete(key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

/** This device's persistent SSH identity (created on first use). */
export async function deviceSSHKey(): Promise<ClientKey> {
  const existing = await idbGet<{ privateKey: CryptoKey; publicRaw: Uint8Array }>('ssh-ed25519');
  if (existing) return existing;
  const k = await generateClientKey(false);
  await idbPut('ssh-ed25519', { privateKey: k.privateKey, publicRaw: k.publicRaw });
  return { privateKey: k.privateKey, publicRaw: k.publicRaw };
}
