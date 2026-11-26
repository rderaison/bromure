// "Connect to Remote Bromure" (FatClientConnect.swift RemoteConnectView +
// RemoteConnectModel): one picker over "My servers · bromure.io" (the account's
// directory, polled while open) and servers saved by address, the bromure.io
// sign-in bar, the add/edit form, then the connect phases — reach the host,
// verify its key (TOFU / changed-key warning), key auth, the password
// fallback that enrolls this device's key — with Cancel throughout.
//
// The hosted app can't open TCP connections: there, every server is a
// bromure.io peer (ws-relay) and the by-address half is hidden.

import React, { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { Button, Spinner, TextField, cx, useMenu, useTooltip } from '../../ui/kit';
import { SF } from '../../ui/icons';
import { Lights } from '../../app/windows';
import { hostTrust } from '../../app/trust';
import { closeConnection, connectionFor, savedHosts, targetForSaved, useSavedHosts, type SavedHost } from '../../app/store';
import type { HostTarget } from '../../core/remote/host';
import type { DeviceInfo } from '../../core/cloud/controlPlane';
import { canDialDirect, electron, shell } from '../../platform';
import { account, takeConnectRequest, hasConnectRequest, CONNECT_EVENT } from './account';
import { deviceDisplayName, peerTarget, rememberPeerUser } from './peers';
import { ClientKeySheet, HostKeyStep, PasswordStep, claimTrustInline } from './TrustPrompts';
import './connect.css';

type Phase =
  | { k: 'editing' }
  | { k: 'working'; msg: string }
  | { k: 'password'; error: string | null }
  | { k: 'unreachable'; msg: string };

type Target = HostTarget & { peerDeviceID?: string };

const connectLabel = (user: string, address: string, port: number) => `${user}@${address}:${port}`;

function relative(iso: string | null | undefined, now = Date.now()): string | null {
  const t = iso ? Date.parse(iso) : NaN;
  if (!isFinite(t)) return null;
  const s = Math.round((t - now) / 1000);
  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
  const a = Math.abs(s);
  if (a < 60) return rtf.format(s, 'second');
  if (a < 3600) return rtf.format(Math.round(s / 60), 'minute');
  if (a < 86400) return rtf.format(Math.round(s / 3600), 'hour');
  if (a < 86400 * 7) return rtf.format(Math.round(s / 86400), 'day');
  if (a < 86400 * 30) return rtf.format(Math.round(s / 604800), 'week');
  if (a < 86400 * 365) return rtf.format(Math.round(s / 2592000), 'month');
  return rtf.format(Math.round(s / 31536000), 'year');
}

function useAccount() { return useSyncExternalStore(account.subscribe, account.get); }

export function ConnectScreen() {
  const acct = useAccount();
  const saved = useSavedHosts();
  const savedSorted = useMemo(() => [...saved].sort((a, b) =>
    (Date.parse(b.lastConnectedAt ?? '') || 0) - (Date.parse(a.lastConnectedAt ?? '') || 0)), [saved]);
  const direct = canDialDirect;
  const signedIn = !!acct.record;
  const servers = signedIn ? acct.servers : [];
  const tip = useTooltip();
  const menu = useMenu();

  const [phase, setPhase] = useState<Phase>({ k: 'editing' });
  const [selection, setSelection] = useState<string | null>(null);
  const [showingForm, setShowingForm] = useState(false);
  const [showKey, setShowKey] = useState(false);
  const [shakes, setShakes] = useState(0);
  // form fields
  const [name, setName] = useState('');
  const [address, setAddress] = useState('');
  const [port, setPort] = useState('2222');
  const [user, setUser] = useState('');
  const editingID = useRef<string | null>(null);

  // the connection being driven
  const attempt = useRef(0);
  const current = useRef<{ target: Target; release: () => void; displayName: string } | null>(null);
  const presetPassword = useRef<string | null>(null);
  const passwordAsked = useRef(false);
  const prompt = useSyncExternalStore(hostTrust.subscribe, hostTrust.current);
  const ours = prompt && current.current && prompt.host.id === current.current.target.id ? prompt : null;

  useEffect(() => account.watch(), []);
  useEffect(() => () => { current.current?.release(); }, []);

  // Default selection: the first reachable server, else the newest saved host.
  useEffect(() => {
    if (selection) return;
    const s = servers.find(x => x.online) ?? servers[0];
    if (s) setSelection('peer:' + s.id);
    else if (direct && savedSorted[0]) setSelection('host:' + savedSorted[0].id);
  }, [servers, savedSorted, selection, direct]);

  // Password prompts for our connection: answer a carried password (a user
  // edit restarted the connection), else show the step.
  useEffect(() => {
    if (!ours || ours.kind !== 'password') return;
    passwordAsked.current = true;
    if (presetPassword.current != null) {
      const pw = presetPassword.current; presetPassword.current = null;
      setPhase({ k: 'working', msg: 'Signing in…' });
      ours.resolve(pw);
      return;
    }
    if (ours.attempt > 1) setShakes(n => n + 1);
    setPhase(p => ({ k: 'password', error: ours.attempt > 1 ? 'Incorrect password. Try again.' : (p.k === 'password' ? p.error : null) }));
  }, [ours]);

  const finishWith = (p: Phase) => {
    current.current?.release();
    if (current.current) closeConnection(current.current.target.id);
    current.current = null;
    setPhase(p);
  };

  /** Drive one connection through the phases; on success open its window. */
  const run = async (target: Target, displayName: string, how: { peerName?: string; label: string; onSuccess: () => void }) => {
    const n = ++attempt.current;
    current.current?.release();
    const existing = connectionFor(target);
    if (existing.status === 'connected') { how.onSuccess(); return; }
    closeConnection(target.id);
    current.current = { target, release: claimTrustInline(target.id), displayName };
    passwordAsked.current = false;
    const pinned = !!target.pinnedFingerprint;
    setPhase({ k: 'working', msg: how.peerName ? `Connecting to ${how.peerName} via bromure.io…` : pinned ? 'Authenticating…' : `Contacting ${how.label}…` });
    let dialed = false, dialing = false;
    const dial = target.dial;
    target.dial = async () => {
      dialing = true;
      const s = await dial();
      dialed = true;
      if (attempt.current === n) setPhase({ k: 'working', msg: pinned ? 'Authenticating…' : how.peerName ? `Verifying ${how.peerName}…` : `Contacting ${how.label}…` });
      return s;
    };
    const h = connectionFor(target);
    try {
      await h.start();
      if (attempt.current !== n) { h.stop(); return; }
      current.current?.release();
      current.current = null;
      presetPassword.current = null;
      how.onSuccess();
    } catch (e: any) {
      if (attempt.current !== n) return;
      target.dial = dial;
      const code = e?.code as string | undefined;
      if (code === 'hostkey' && /not trusted/.test(e?.message ?? '')) { finishWith({ k: 'editing' }); return; }
      if (code === 'auth') {
        if (passwordAsked.current && /Authentication failed/.test(e?.message ?? '')) {
          // Three wrong passwords end an SSH attempt; keep asking inline.
          current.current?.release(); current.current = null;
          closeConnection(target.id);
          run(target, displayName, how);
          setShakes(x => x + 1);
          setPhase({ k: 'password', error: 'Incorrect password. Try again.' });
          return;
        }
        if (passwordAsked.current) { finishWith({ k: 'editing' }); return; }   // password step cancelled
        finishWith({ k: 'unreachable', msg: `This device isn't authorized on ${displayName}, and it doesn't accept passwords.\n\nAuthorize this device's key on the remote (Show this device's key), or allow password sign-in in its Remote Access settings, then try again.` });
        return;
      }
      if (code === 'hostkey') { finishWith({ k: 'unreachable', msg: 'Host key verification failed.' }); return; }
      // Failed before reaching the network (this device's key store, say).
      if (!dialing) { finishWith({ k: 'unreachable', msg: `Couldn't start the connection: ${e?.message ?? e}` }); return; }
      if (!dialed) {
        finishWith({ k: 'unreachable', msg: how.peerName
          ? `Couldn't establish a connection to ${how.peerName}.\n\nIt may have just gone offline, or no network path could be set up to it. Check that both can reach bromure.io, then try again.`
          : direct
            ? `Couldn't reach ${how.label}.\n\nMake sure the remote Bromure is running with remote access enabled (Preferences → Remote Access, or \`bromure-ac remote enable\`), and that the address and port are correct.`
            : (e?.message ?? 'Direct connections need the desktop app.') });
      } else if (how.peerName && code === 'nobanner') {
        // The relay opened but the server never joined it: its Bromure
        // predates connections from the web and desktop clients (ws-relay).
        finishWith({ k: 'unreachable', msg: `bromure.io accepted the connection, but ${how.peerName} never answered it.\n\n${how.peerName} may be running a Bromure version that can't take connections from this app yet. Update Bromure on it, make sure Remote Access is enabled, then try again.` });
      } else {
        finishWith({ k: 'unreachable', msg: how.peerName
          ? `Reached ${how.peerName} over bromure.io, but its SSH front door didn't answer. Make sure Remote Access is still enabled on it.`
          : `Couldn't reach ${how.label}.\n\n${e?.message ?? ''}`.trim() });
      }
    }
  };

  const connectSaved = (h: SavedHost, overrideUser?: string) => {
    const u = overrideUser ?? h.user;
    const target: Target = targetForSaved({ ...h, user: u });
    run(target, h.address, {
      label: connectLabel(u, h.address, h.port),
      onSuccess: () => {
        savedHosts.upsert({ ...h, user: u, pinnedFingerprint: target.pinnedFingerprint, lastConnectedAt: new Date().toISOString() });
        location.hash = `#/host/${h.id}`;
      },
    });
  };

  const connectPeer = (s: DeviceInfo, overrideUser?: string) => {
    if (!acct.record) return;
    const t = peerTarget(s, acct.record);
    if (overrideUser) t.username = overrideUser;
    setUser(t.username);
    const nm = deviceDisplayName(s);
    run(t, nm, {
      peerName: nm, label: nm,
      onSuccess: () => { rememberPeerUser(s.id, t.username); location.hash = `#/peer/${s.id}`; },
    });
  };

  /** The form's Connect (RemoteConnectModel.begin + adoptSavedIdentity). */
  const beginFromForm = () => {
    const addr = address.trim(); if (!addr) return;
    const p = parseInt(port, 10) || 2222;
    const u = user.trim();
    const same = saved.find(h => h.address === addr && h.port === p && h.user === u)
      ?? (editingID.current ? saved.find(h => h.id === editingID.current) : undefined);
    // The host key belongs to the endpoint, not the login user.
    const pin = saved.find(h => h.address === addr && h.port === p && h.pinnedFingerprint)?.pinnedFingerprint;
    const host: SavedHost = {
      id: same?.id ?? crypto.randomUUID().toUpperCase(), name: name.trim() || same?.name || addr,
      address: addr, port: p, user: u, pinnedFingerprint: pin, lastConnectedAt: same?.lastConnectedAt,
    };
    connectSaved(host);
  };

  // A `#connect?device=` link (bromure.io/app's Connect button): once signed
  // in and the directory is in, connect straight to that server — or say why
  // not and leave the chooser up.
  const [connectTick, setConnectTick] = useState(0);
  useEffect(() => {
    const on = () => setConnectTick(n => n + 1);
    window.addEventListener(CONNECT_EVENT, on);
    return () => window.removeEventListener(CONNECT_EVENT, on);
  }, []);
  useEffect(() => {
    if (!signedIn || !acct.directoryLoaded || !hasConnectRequest()) return;
    const id = takeConnectRequest();
    const s = id ? servers.find(x => x.id.toLowerCase() === id.toLowerCase()) : undefined;
    if (!s) { setPhase({ k: 'unreachable', msg: "That server isn't in your bromure.io account (or it was removed). Pick one below." }); return; }
    setSelection('peer:' + s.id);
    if (s.online) connectPeer(s);
    else setPhase({ k: 'unreachable', msg: `${deviceDisplayName(s)} is offline. Start Bromure on it, then connect.` });
  }, [signedIn, acct.directoryLoaded, servers, connectTick]); // eslint-disable-line

  const selectedPeer = selection?.startsWith('peer:') ? servers.find(s => s.id === selection.slice(5)) : undefined;
  const selectedHost = selection?.startsWith('host:') ? saved.find(h => h.id === selection.slice(5)) : undefined;
  const canConnectSelection = !!(selectedPeer?.online || selectedHost);
  const connectSelected = () => {
    if (selectedPeer?.online) connectPeer(selectedPeer);
    else if (selectedHost) { setUser(selectedHost.user); connectSaved(selectedHost); }
  };

  const prefill = (h?: SavedHost) => {
    editingID.current = h?.id ?? null;
    setName(h?.name ?? ''); setAddress(h?.address ?? ''); setPort(String(h?.port ?? 2222)); setUser(h?.user ?? '');
    setShowingForm(true);
  };

  const cancelConnect = () => {
    attempt.current++;
    if (ours) { if (ours.kind === 'password') ours.resolve(null); else ours.resolve(false); }
    presetPassword.current = null;
    finishWith({ k: 'editing' });
  };
  const returnTo = (() => { try { return sessionStorage.getItem('bromure.connect.returnTo'); } catch { return null; } })();
  const canClose = !!returnTo || !!electron;
  const closeWindow = () => {
    if (phase.k !== 'editing' && phase.k !== 'unreachable') { cancelConnect(); return; }
    if (returnTo) { try { sessionStorage.removeItem('bromure.connect.returnTo'); } catch {} location.hash = returnTo; }
    else if (electron) electron.windowControl('close');
  };

  /** The password step's live user field: an edit restarts the attempt as
   *  that user, carrying the typed password (SSH fixes the user per attempt). */
  const submitPassword = (pw: string) => {
    const cur = current.current;
    if (!ours || ours.kind !== 'password' || !cur) return;
    const u = user.trim();
    if (u && u !== cur.target.username) {
      presetPassword.current = pw;
      const t = cur.target;
      attempt.current++;
      ours.resolve(null);
      cur.release(); closeConnection(t.id); current.current = null;
      if (t.peerDeviceID) { const s = servers.find(x => x.id === t.peerDeviceID); if (s) connectPeer(s, u); }
      else {
        const h = saved.find(x => x.id === t.id)
          ?? { id: t.id, name: name.trim() || address.trim(), address: address.trim(), port: parseInt(port, 10) || 2222, user: u };
        connectSaved(h, u);
      }
      return;
    }
    setPhase({ k: 'working', msg: 'Signing in…' });
    ours.resolve(pw);
  };

  // Escape = Cancel, Return = the default button (picker / form / unreachable).
  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') { e.preventDefault(); closeWindow(); }
    else if (e.key === 'Enter' && !(e.target as HTMLElement).closest('.cx-step-inline')) {
      if (phase.k === 'unreachable') { e.preventDefault(); setPhase({ k: 'editing' }); }
      else if (phase.k === 'editing' && !ours && !showingForm && canConnectSelection) { e.preventDefault(); connectSelected(); }
      else if (phase.k === 'editing' && !ours && showingForm && address.trim() && user.trim()) { e.preventDefault(); beginFromForm(); }
    }
  };

  const displayName = current.current?.displayName ?? '';

  let body: React.ReactNode;
  if (ours && (ours.kind === 'confirm' || ours.kind === 'changed')) {
    body = <div className="cx-step-inline"><HostKeyStep info={ours.info} changed={ours.kind === 'changed'} displayName={displayName}
                        previous={ours.kind === 'changed' ? current.current?.target.pinnedFingerprint : undefined}
                        onCancel={cancelConnect}
                        onTrust={() => { setPhase({ k: 'working', msg: 'Authenticating…' }); ours.resolve(true); }} /></div>;
  } else if (phase.k === 'password' && ours?.kind === 'password') {
    body = <div className="cx-step-inline"><PasswordStep displayName={displayName} error={phase.error} shakes={shakes} user={user} onUser={setUser}
                         onSubmit={submitPassword} onCancel={cancelConnect} onShowKey={() => setShowKey(true)} /></div>;
  } else if (phase.k === 'working' || phase.k === 'password') {
    body = (
      <div className="cx-working">
        <div className="cx-working-row"><Spinner size={16} /><span>{phase.k === 'working' ? phase.msg : 'Connecting…'}</span></div>
        <div className="cx-buttons"><span className="cx-spacer" /><Button onClick={cancelConnect}>Cancel</Button></div>
      </div>
    );
  } else if (phase.k === 'unreachable') {
    body = (
      <div className="cx-step">
        <div className="cx-headline"><SF name="wifi.exclamationmark" size={15} /> Can't connect</div>
        <div className="cx-callout cx-secondary cx-pre">{phase.msg}</div>
        <div className="cx-buttons">
          <span className="cx-spacer" />
          <Button onClick={closeWindow} disabled={!canClose}>Cancel</Button>
          <Button variant="prominent" autoFocus onClick={() => setPhase({ k: 'editing' })}>Back</Button>
        </div>
      </div>
    );
  } else if (showingForm && direct) {
    body = (
      <div className="cx-step">
        <div className="cx-callout cx-secondary">Mirror another Mac running Bromure — its grid, workspaces, tabs and automations — over SSH.</div>
        <Field label="Name" value={name} onChange={setName} placeholder="e.g. rack mini" autoFocus />
        <Field label="Address" value={address} onChange={setAddress} placeholder="host or IP" />
        <div className="cx-hstack">
          <Field label="Port" value={port} onChange={setPort} placeholder="2222" width={130} />
          <Field label="Remote user" value={user} onChange={setUser} placeholder="username" />
        </div>
        <div className="cx-buttons">
          <Button onClick={() => setShowingForm(false)}>Back</Button>
          <Button onClick={() => setShowKey(true)}>Show this device's key</Button>
          <span className="cx-spacer" />
          <Button onClick={closeWindow} disabled={!canClose}>Cancel</Button>
          <Button variant="prominent" disabled={!address.trim() || !user.trim()} onClick={beginFromForm}>Connect</Button>
        </div>
      </div>
    );
  } else {
    const hasAny = servers.length > 0 || (direct && savedSorted.length > 0);
    const err = acct.error ?? acct.directoryError;
    body = (
      <div className="cx-picker">
        <div className="cx-callout cx-secondary">
          {direct
            ? 'Mirror another Mac running Bromure — its grid, workspaces, tabs and automations. Sign in to reach your servers from anywhere, or add one directly by address on your LAN.'
            : 'Mirror a Mac running Bromure — its grid, workspaces, tabs and automations. Sign in with bromure.io to reach your servers from anywhere.'}
        </div>
        {hasAny ? (
          <div className="cx-list" role="listbox">
            {signedIn && servers.length > 0 && (<>
              <div className="cx-list-section">My servers · bromure.io</div>
              {servers.map((s, i) => {
                const reachable = !!s.online;
                const seen = relative(s.lastSeenAt as string | null);
                return (
                  <div key={s.id} className={cx('cx-row', i % 2 === 1 && 'alt', selection === 'peer:' + s.id && 'on', !reachable && 'offline')}
                       {...tip.bind(reachable ? `Connect to ${deviceDisplayName(s)}` : `${deviceDisplayName(s)} hasn't connected to bromure.io recently`)}
                       onClick={() => { if (reachable) setSelection('peer:' + s.id); }}
                       onDoubleClick={() => { if (reachable) connectPeer(s); }}>
                    <SF name="macmini.fill" size={16} className="cx-row-icon" />
                    <div className="cx-row-text">
                      <div className="cx-row-title">{deviceDisplayName(s)}</div>
                      {reachable ? <div className="cx-row-sub cx-green">Active now</div>
                        : seen ? <div className="cx-row-sub cx-tertiary">Last seen {seen}</div>
                        : <div className="cx-row-sub cx-tertiary">Offline</div>}
                    </div>
                    <span className={cx('cx-dot', reachable && 'on')} />
                    <span className={cx('cx-row-state', reachable ? 'cx-green' : 'cx-tertiary')}>{reachable ? 'reachable' : 'offline'}</span>
                  </div>
                );
              })}
            </>)}
            {direct && savedSorted.length > 0 && (<>
              <div className="cx-list-section">{signedIn ? 'On this network' : 'Saved servers'}</div>
              {savedSorted.map((h, i) => {
                const last = relative(h.lastConnectedAt);
                return (
                  <div key={h.id} className={cx('cx-row', (i + (signedIn ? servers.length : 0)) % 2 === 1 && 'alt', selection === 'host:' + h.id && 'on')}
                       {...tip.bind(`Connect to ${connectLabel(h.user, h.address, h.port)}`)}
                       onClick={() => setSelection('host:' + h.id)}
                       onDoubleClick={() => connectSaved(h)}
                       onContextMenu={e => { e.preventDefault(); setSelection('host:' + h.id); menu(e, [
                         { label: 'Connect', action: () => connectSaved(h) },
                         { label: 'Edit…', action: () => prefill(h) },
                         { separator: true },
                         { label: 'Remove', destructive: true, action: () => { savedHosts.remove(h.id); setSelection(null); } },
                       ]); }}>
                    <SF name="macmini.fill" size={16} className="cx-row-icon" />
                    <div className="cx-row-text">
                      <div className="cx-row-title">{h.name || h.address}</div>
                      <div className="cx-row-sub cx-secondary">{connectLabel(h.user, h.address, h.port)}</div>
                    </div>
                    {last && <span className="cx-row-state cx-tertiary">{last}</span>}
                  </div>
                );
              })}
            </>)}
          </div>
        ) : (
          <div className="cx-empty">
            {signedIn && acct.directoryLoading ? (<>
              <Spinner size={14} />
              <div className="cx-callout cx-secondary">Looking for your servers…</div>
            </>) : (<>
              <SF name="macmini" size={30} className="cx-tertiary" />
              <div className="cx-callout cx-secondary cx-center cx-pre">
                {signedIn
                  ? (direct ? 'No servers in your workspace yet.\nEnable Remote Access on the Mac you want to reach, or add one by address.'
                            : 'No servers in your workspace yet.\nEnable Remote Access on the Mac you want to reach.')
                  : (direct ? 'Sign in with bromure.io to see your servers, or add one by address.'
                            : 'Sign in with bromure.io to see your servers.')}
              </div>
            </>)}
          </div>
        )}
        {err && <div className="cx-caption cx-red">{err}</div>}
        {!direct && <div className="cx-caption cx-tertiary">Adding a server by address needs the Bromure desktop app: a browser can't open direct connections, so here every server is reached through bromure.io.</div>}

        <div className="cx-account">
          {acct.busy && <Spinner size={12} />}
          {signedIn ? (<>
            <SF name="person.crop.circle.badge.checkmark" size={15} className="cx-secondary" />
            <span>{account.label()}</span>
            <Button variant="borderless" {...tip.bind('Refresh servers')} onClick={() => account.loadDirectory()}><SF name="arrow.clockwise" size={13} /></Button>
            <span className="cx-spacer" />
            <Button variant="link" disabled={acct.busy} onClick={async () => { if (await account.signOut()) setSelection(null); }}>Sign Out</Button>
          </>) : (<>
            <SF name="person.crop.circle.badge.plus" size={15} className="cx-secondary" />
            <Button onClick={() => account.signIn()}>Sign in with bromure.io</Button>
            <span className="cx-spacer" />
          </>)}
        </div>

        <div className="cx-buttons">
          {direct && (
            <div className="cx-pm">
              <button {...tip.bind('Add a server by address')} onClick={() => prefill()}><SF name="plus" size={12} /></button>
              <span className="cx-pm-sep" />
              <button disabled={!selectedHost} {...tip.bind('Remove the selected saved server')}
                      onClick={() => { if (selectedHost) { savedHosts.remove(selectedHost.id); setSelection(null); } }}><SF name="minus" size={12} /></button>
            </div>
          )}
          <Button onClick={() => setShowKey(true)}>Show this device's key</Button>
          <span className="cx-spacer" />
          <Button onClick={closeWindow} disabled={!canClose}>Cancel</Button>
          <Button variant="prominent" disabled={!canConnectSelection} onClick={connectSelected}>Connect</Button>
        </div>
      </div>
    );
  }

  return (
    <div className="cx-screen" onKeyDown={onKeyDown}>
      <div className="cx-window" role="dialog" aria-label="Connect to Remote Bromure">
        <div className="cx-titlebar" data-drag>
          {shell === 'electron' && electron
            ? <Lights onClose={() => electron!.windowControl('close')} onMinimize={() => electron!.windowControl('minimize')} onZoom={() => electron!.windowControl('maximize')} />
            : <span className="cx-lights-spacer" />}
          <span className="cx-titlebar-title">Connect to Remote Bromure</span>
          <span className="cx-lights-spacer" />
        </div>
        <div className="cx-content">
          <div className="cx-title">Connect to Remote Bromure</div>
          {body}
        </div>
      </div>
      {showKey && <ClientKeySheet onClose={() => setShowKey(false)} />}
      {tip.node}
    </div>
  );
}

function Field({ label, value, onChange, placeholder, width, autoFocus }: {
  label: string; value: string; onChange: (v: string) => void; placeholder: string; width?: number; autoFocus?: boolean;
}) {
  return (
    <label className="cx-field" style={width ? { width, flex: 'none' } : undefined}>
      <span className="cx-field-label">{label}</span>
      <TextField value={value} placeholder={placeholder} autoFocus={autoFocus} onChange={e => onChange(e.target.value)} />
    </label>
  );
}
