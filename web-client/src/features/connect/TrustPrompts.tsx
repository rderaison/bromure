// Host-key TOFU, changed-key warning and the password fallback
// (FatClientConnect.swift RemoteConnectView.hostKey / passwordStep). The
// connect window shows these steps inline for the connection it drives
// (claimTrustInline); any other connection's prompt — a reconnect from a
// mirror window, a `#/host/…` deep link — comes up as a sheet here.

import React, { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { hostTrust } from '../../app/trust';
import { publicKeyLine } from '../../app/store';
import type { HostKeyInfo } from '../../core/remote/host';
import { Button, Sheet, TextField, cx } from '../../ui/kit';
import { SF } from '../../ui/icons';
import './connect.css';

// ── inline claims ─────────────────────────────────────────────────────────

const claimed = new Set<string>();
const claimListeners = new Set<() => void>();
let claimVersion = 0;
/** The connect window handles prompts for `targetID` itself while claimed. */
export function claimTrustInline(targetID: string): () => void {
  claimed.add(targetID); claimVersion++; claimListeners.forEach(l => l());
  return () => { claimed.delete(targetID); claimVersion++; claimListeners.forEach(l => l()); };
}

// ── steps (shared by the connect window and the sheets) ──────────────────

export function HostKeyStep({ info, changed, previous, displayName, onCancel, onTrust }: {
  info: HostKeyInfo; changed: boolean; previous?: string; displayName: string;
  onCancel: () => void; onTrust: () => void;
}) {
  return (
    <div className="cx-step" onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); onTrust(); } }}>
      {changed ? (<>
        <div className="cx-headline cx-red"><SF name="exclamationmark.triangle.fill" size={14} /> The remote's SSH host key has CHANGED</div>
        <div className="cx-callout cx-secondary">This can mean the remote was reinstalled — or that someone is impersonating it (man-in-the-middle). Only continue if you expect this change.</div>
        {previous && <div className="cx-mono-caption cx-secondary">Previously: {previous}</div>}
      </>) : (
        <div className="cx-callout cx-secondary">First time connecting to {displayName}. Verify this fingerprint matches the remote (Preferences → Remote Access shows it):</div>
      )}
      <div className="cx-fingerprint selectable">{info.fingerprint}</div>
      <div className="cx-buttons">
        <span className="cx-spacer" />
        <Button onClick={onCancel}>Cancel</Button>
        <Button variant="prominent" destructive={changed} autoFocus onClick={onTrust}>
          {changed ? 'Trust New Key & Continue' : 'Trust & Continue'}
        </Button>
      </div>
    </div>
  );
}

export function PasswordStep({ displayName, error, shakes, user, onUser, onSubmit, onCancel, onShowKey }: {
  displayName: string; error?: string | null; shakes: number;
  /** The live "Remote user" field (the connect window); absent in a sheet. */
  user?: string; onUser?: (u: string) => void;
  onSubmit: (pw: string) => void; onCancel: () => void; onShowKey: () => void;
}) {
  const [pw, setPw] = useState('');
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => { setPw(''); ref.current?.focus(); }, [shakes]);
  const submit = () => { if (pw) onSubmit(pw); };
  return (
    <div className="cx-step">
      <div className="cx-callout cx-secondary">This device isn't authorized on {displayName} yet. Enter the remote Mac's login user and password — or, on a Linux server, your account name and a one-time code from its admin — to pair. Bromure will remember this device so you won't be asked again.</div>
      {onUser && (
        <label className="cx-field">
          <span className="cx-field-label">Remote user</span>
          <TextField value={user ?? ''} placeholder="username" onChange={e => onUser(e.target.value)} />
        </label>
      )}
      <div key={shakes} className={cx('cx-shake', shakes > 0 && 'go')}>
        <TextField ref={ref} type="password" value={pw} placeholder="Password" autoFocus style={{ width: '100%' }}
                   onChange={e => setPw(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); submit(); } }} />
      </div>
      {error && <div className="cx-callout cx-red">{error}</div>}
      <div className="cx-buttons">
        <Button onClick={onShowKey}>Show this device's key</Button>
        <span className="cx-spacer" />
        <Button onClick={onCancel}>Cancel</Button>
        <Button variant="prominent" disabled={!pw} onClick={submit}>Sign In</Button>
      </div>
    </div>
  );
}

/** "This Mac's public key (copied)" alert. */
export function ClientKeySheet({ onClose }: { onClose: () => void }) {
  const [key, setKey] = useState('');
  useEffect(() => {
    publicKeyLine().then(k => { setKey(k); navigator.clipboard?.writeText(k).catch(() => {}); });
  }, []);
  return (
    <Sheet width={420} onClose={onClose}>
      <div className="cx-alert">
        <div className="cx-alert-title">This device's public key (copied)</div>
        <div className="cx-alert-text">To authorize this device without a password, run on the remote:</div>
        <div className="cx-alert-code selectable">bromure-ac remote key add '{key}'</div>
      </div>
      <div className="sheet-footer"><Button variant="prominent" autoFocus onClick={onClose}>OK</Button></div>
    </Sheet>
  );
}

// ── sheets for unclaimed prompts ─────────────────────────────────────────

export function TrustPrompts() {
  const p = useSyncExternalStore(hostTrust.subscribe, hostTrust.current);
  useSyncExternalStore(l => { claimListeners.add(l); return () => { claimListeners.delete(l); }; }, () => claimVersion);
  const [showKey, setShowKey] = useState(false);
  if (showKey) return <ClientKeySheet onClose={() => setShowKey(false)} />;
  if (!p || claimed.has(p.host.id)) return null;
  const name = p.host.name;
  if (p.kind === 'password') {
    return (
      <Sheet width={480} onClose={() => p.resolve(null)}>
        <div className="cx-sheet">
          <div className="cx-title">Connect to Remote Bromure</div>
          <PasswordStep displayName={name} shakes={p.attempt - 1} error={p.attempt > 1 ? 'Incorrect password. Try again.' : null}
                        onSubmit={pw => p.resolve(pw)} onCancel={() => p.resolve(null)} onShowKey={() => setShowKey(true)} />
        </div>
      </Sheet>
    );
  }
  return (
    <Sheet width={480} onClose={() => p.resolve(false)}>
      <div className="cx-sheet">
        <div className="cx-title">Connect to Remote Bromure</div>
        <HostKeyStep info={p.info} changed={p.kind === 'changed'} previous={p.kind === 'changed' ? p.host.pinnedFingerprint : undefined}
                     displayName={name} onCancel={() => p.resolve(false)} onTrust={() => p.resolve(true)} />
      </div>
    </Sheet>
  );
}

// Screenshot hook: `__bromure.trustPreview('confirm' | 'changed' | 'password')`
// raises a stand-in prompt (no connection behind it).
if (typeof window !== 'undefined') {
  const host = { id: 'preview', name: 'Mac Studio', username: 'sonya', pinnedFingerprint: 'SHA256:7FhQ2mXcV9pLk3RzqWn0bT4yUe8sGd1aJcK5vOiP2aY', dial: () => Promise.reject(new Error('preview')) };
  const info = { blob: new Uint8Array(), fingerprint: 'SHA256:q3Vx8k2mN0pZtY6rL1eH9cWfA4uJ7sDbG5nKiO2xRyE' };
  (window as any).__bromure = { ...(window as any).__bromure,
    trustPreview: (k: 'confirm' | 'changed' | 'password', attempt = 1) =>
      k === 'password' ? hostTrust.password(host, attempt) : k === 'changed' ? hostTrust.changed(info, host) : hostTrust.confirm(info, host) };
}
