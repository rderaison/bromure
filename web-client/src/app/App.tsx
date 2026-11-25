// Root: appearance, menus, and the two top-level screens — the host picker
// ("Connect to Remote Bromure") and a host's mirror window. Route lives in the
// hash (#/host/<id>) so the hosted app deep-links and Electron windows can
// each show one host.

import React, { useEffect, useState, useSyncExternalStore } from 'react';
import { MenuHost } from '../ui/kit';
import { HostWindow } from './HostWindow';
import { ConnectScreen } from '../features/connect/ConnectScreen';
import { TrustPrompts } from '../features/connect/TrustPrompts';
import { peerTargetFor } from '../features/connect/peers';
import { connectionFor, savedHosts, targetForSaved, publicKeyLine } from './store';
import type { RemoteHost } from '../core/remote/host';
import { devRelay } from '../platform';
import { appearance } from './appearance';

function useRoute() {
  const [hash, setHash] = useState(location.hash);
  useEffect(() => {
    const on = () => setHash(location.hash);
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return hash;
}

export function navigate(hash: string) { location.hash = hash; }

export function App() {
  useSyncExternalStore(appearance.subscribe, appearance.effective);
  const route = useRoute();
  const [host, setHost] = useState<RemoteHost | null>(null);
  const hostID = /^#\/host\/([^/?]+)/.exec(route)?.[1];
  const peerID = /^#\/peer\/([^/?]+)/.exec(route)?.[1];

  // A bromure.io server (#/peer/<deviceID>), reached through the ws-relay.
  useEffect(() => {
    if (!peerID) return;
    let live = true;
    peerTargetFor(peerID).then(t => {
      if (!live || !t) { if (live) setHost(null); return; }
      const h = connectionFor(t);
      setHost(h);
      h.start().catch(() => {});
    });
    return () => { live = false; };
  }, [peerID]);

  useEffect(() => {
    if (!hostID) { if (!peerID) setHost(null); return; }
    const saved = savedHosts.all().find(h => h.id === hostID);
    if (!saved) { setHost(null); return; }
    const h = connectionFor(targetForSaved(saved));
    setHost(h);
    h.start().catch(() => {});
  }, [hostID]);

  // Electron smoke tests (shot mode only): connect to BROMURE_TEST_HOST.
  useEffect(() => {
    const t = window.bromureElectron?.shotTest;
    if (!t || hostID) return;
    savedHosts.upsert({ id: 'shot-test', name: t.host, address: t.host, port: t.port, user: t.user });
    navigate('#/host/shot-test');
  }, [hostID]);

  // Dev: `?dev=demo` → connect to the demo server through the dev relay.
  useEffect(() => {
    const p = new URLSearchParams(location.search);
    if (p.get('dev') !== 'demo' || !devRelay || hostID) return;
    (async () => {
      const base = devRelay.replace(/^ws/, 'http');
      const who = await (await fetch(base + '/whoami')).json();
      await fetch(base + '/authorize', { method: 'POST', body: JSON.stringify({ key: await publicKeyLine() }) });
      const port = +(p.get('port') ?? 2399);
      const existing = savedHosts.all().find(h => h.id === 'demo');
      savedHosts.upsert({ id: 'demo', name: 'Demo server', address: '127.0.0.1', port, user: who.user, pinnedFingerprint: existing?.pinnedFingerprint });
      navigate('#/host/demo');
    })().catch(e => console.error('dev connect', e));
  }, [hostID]);

  return (
    <MenuHost>
      {host ? <HostWindow key={host.target.id} host={host} /> : <ConnectScreen />}
      <TrustPrompts />
    </MenuHost>
  );
}
