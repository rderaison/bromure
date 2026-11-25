// RemoteReconnectingView + RemoteConnectionStatusView (FatClientController.swift).
//
// - An established link that dropped ('reconnecting'): the last mirrored
//   content stays readable, dimmed a touch, with a small material banner on
//   top saying it's coming back. NON-BLOCKING: every click passes through.
// - Never connected yet ('connecting' / 'failed' before the first snapshot):
//   the connection status screen over the window — "Connecting to X…", or why
//   it can't (key not accepted, host key changed) and how to fix it.

import React, { useEffect, useState } from 'react';
import { useHostCtx } from '../../app/hostContext';
import { useHost, publicKeyLine } from '../../app/store';
import { Spinner, Button } from '../../ui/kit';
import { SF } from '../../ui/icons';
import './veil.css';

export function ReconnectingVeil() {
  const { host } = useHostCtx();
  useHost(host);
  const label = host.target.name;
  const established = host.connectedAt > 0 || !!host.state;

  if (established && (host.status === 'reconnecting' || host.status === 'connecting')) {
    const readout = host.rttMs ? `last round trip ${Math.round(host.rttMs)} ms` : '';
    return (
      <div className="veil-reconnect">
        <div className="veil-dim" />
        <div className="veil-banner">
          <Spinner size={16} />
          <div className="veil-banner-text">
            <div className="veil-banner-title">Reconnecting to {label}…</div>
            <div className="veil-banner-sub">The connection dropped. What you see is from just before; it picks up again on its own.</div>
            {readout && <div className="veil-banner-readout">{readout}</div>}
          </div>
        </div>
      </div>
    );
  }

  // First connect, or a failure that needs the user.
  const detail = host.statusDetail;
  const hostKey = host.status === 'failed' && /host (key|signature)/i.test(detail);
  const needsKey = host.status === 'failed' && !hostKey;
  return (
    <div className="veil-status">
      {hostKey ? <>
        <SF name="exclamationmark.shield" size={34} color="var(--orange)" />
        <div className="veil-status-title">“{label}” presented a different host key</div>
        <div className="veil-status-text">Its identity no longer matches the one this device trusted. If the remote Mac was reinstalled, connect to it again from Connect to Remote Bromure… to review the new key; otherwise someone may be intercepting the connection.</div>
      </> : needsKey ? <>
        <SF name="key.slash" size={34} color="var(--label-secondary)" />
        <div className="veil-status-title">“{label}” didn't accept this device's key</div>
        <KeyHint />
      </> : <>
        <Spinner size={28} />
        <div className="veil-status-title">Connecting to {label}…</div>
      </>}
    </div>
  );
}

function KeyHint() {
  const [key, setKey] = useState<string | null>(null);
  useEffect(() => { publicKeyLine().then(setKey).catch(() => {}); }, []);
  const cmd = `bromure-ac remote key add '${key ?? '<generating key…>'}'`;
  return (
    <div className="veil-keyhint">
      <div className="veil-status-text" style={{ textAlign: 'left' }}>This device authenticates to the remote Bromure by SSH key. If the remote has remote access enabled, authorize this device's key on it:</div>
      <div className="veil-keyrow">
        <code className="veil-cmd selectable">{cmd}</code>
        <Button onClick={() => navigator.clipboard?.writeText(cmd).catch(() => {})}>Copy</Button>
      </div>
      <div className="veil-caption">Enable remote access on the remote with: bromure-ac remote enable</div>
    </div>
  );
}
